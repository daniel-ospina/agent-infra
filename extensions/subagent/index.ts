/**
 * Subagent Tool - Delegate tasks to specialized agents
 *
 * Spawns a separate `pi` process for each subagent invocation,
 * giving it an isolated context window.
 *
 * Supports three modes:
 *   - Single: { agent: "name", task: "..." }
 *   - Parallel: { tasks: [{ agent: "name", task: "..." }, ...] }
 *   - Chain: { chain: [{ agent: "name", task: "... {previous} ..." }, ...] }
 *
 * Uses JSON mode to capture structured output from subagents.
 */

import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
// #36: shared sub-agent PATH augmentation (python3 resolution for MCP servers)
import { getSubAgentPath, DEFAULT_TOOL_STALL_MS } from "../builtin-tools/index.js";

// #208: local constants (the builtin-tools equivalents live on the builtin
// task tool; the ext keeps its own copies so it stays self-contained).
const DEFAULT_BACKSTOP_MARGIN_MS = 1_800_000; // 30 min over tool-stall
const DEFAULT_EXIT_SETTLE_GRACE_MS = 2_000; // exit-settle grace (2s)
// #137: recursive process-tree kill for abort/timeout (orphan MCP reaping)
import { treeKill } from "../shared/tree-kill.js";
// #208: shared pgid-anchored process-group sweep (settle-path orphan reaping)
import { getPgid, sweepProcessGroup } from "../shared/process-sweep.js";
import type { AgentToolResult } from "@earendil-works/pi-agent-core";
import type { Message } from "@earendil-works/pi-ai";
import { StringEnum } from "@earendil-works/pi-ai";
import {
	CONFIG_DIR_NAME,
	type ExtensionAPI,
	getAgentDir,
	getMarkdownTheme,
	withFileMutationQueue,
} from "@earendil-works/pi-coding-agent";
import { Container, Markdown, Spacer, Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import { type AgentConfig, type AgentScope, discoverAgents } from "./agents.ts";

const MAX_PARALLEL_TASKS = 8;
const MAX_CONCURRENCY = 4;
const COLLAPSED_ITEM_COUNT = 10;
const PER_TASK_OUTPUT_CAP = 50 * 1024;

function formatTokens(count: number): string {
	if (count < 1000) return count.toString();
	if (count < 10000) return `${(count / 1000).toFixed(1)}k`;
	if (count < 1000000) return `${Math.round(count / 1000)}k`;
	return `${(count / 1000000).toFixed(1)}M`;
}

function formatUsageStats(
	usage: {
		input: number;
		output: number;
		cacheRead: number;
		cacheWrite: number;
		cost: number;
		contextTokens?: number;
		turns?: number;
	},
	model?: string,
): string {
	const parts: string[] = [];
	if (usage.turns) parts.push(`${usage.turns} turn${usage.turns > 1 ? "s" : ""}`);
	if (usage.input) parts.push(`↑${formatTokens(usage.input)}`);
	if (usage.output) parts.push(`↓${formatTokens(usage.output)}`);
	if (usage.cacheRead) parts.push(`R${formatTokens(usage.cacheRead)}`);
	if (usage.cacheWrite) parts.push(`W${formatTokens(usage.cacheWrite)}`);
	if (usage.cost) parts.push(`$${usage.cost.toFixed(4)}`);
	if (usage.contextTokens && usage.contextTokens > 0) {
		parts.push(`ctx:${formatTokens(usage.contextTokens)}`);
	}
	if (model) parts.push(model);
	return parts.join(" ");
}

function formatToolCall(
	toolName: string,
	args: Record<string, unknown>,
	themeFg: (color: any, text: string) => string,
): string {
	const shortenPath = (p: string) => {
		const home = os.homedir();
		return p.startsWith(home) ? `~${p.slice(home.length)}` : p;
	};

	switch (toolName) {
		case "bash": {
			const command = (args.command as string) || "...";
			const preview = command.length > 60 ? `${command.slice(0, 60)}...` : command;
			return themeFg("muted", "$ ") + themeFg("toolOutput", preview);
		}
		case "read": {
			const rawPath = (args.file_path || args.path || "...") as string;
			const filePath = shortenPath(rawPath);
			const offset = args.offset as number | undefined;
			const limit = args.limit as number | undefined;
			let text = themeFg("accent", filePath);
			if (offset !== undefined || limit !== undefined) {
				const startLine = offset ?? 1;
				const endLine = limit !== undefined ? startLine + limit - 1 : "";
				text += themeFg("warning", `:${startLine}${endLine ? `-${endLine}` : ""}`);
			}
			return themeFg("muted", "read ") + text;
		}
		case "write": {
			const rawPath = (args.file_path || args.path || "...") as string;
			const filePath = shortenPath(rawPath);
			const content = (args.content || "") as string;
			const lines = content.split("\n").length;
			let text = themeFg("muted", "write ") + themeFg("accent", filePath);
			if (lines > 1) text += themeFg("dim", ` (${lines} lines)`);
			return text;
		}
		case "edit": {
			const rawPath = (args.file_path || args.path || "...") as string;
			return themeFg("muted", "edit ") + themeFg("accent", shortenPath(rawPath));
		}
		case "ls": {
			const rawPath = (args.path || ".") as string;
			return themeFg("muted", "ls ") + themeFg("accent", shortenPath(rawPath));
		}
		case "find": {
			const pattern = (args.pattern || "*") as string;
			const rawPath = (args.path || ".") as string;
			return themeFg("muted", "find ") + themeFg("accent", pattern) + themeFg("dim", ` in ${shortenPath(rawPath)}`);
		}
		case "grep": {
			const pattern = (args.pattern || "") as string;
			const rawPath = (args.path || ".") as string;
			return (
				themeFg("muted", "grep ") +
				themeFg("accent", `/${pattern}/`) +
				themeFg("dim", ` in ${shortenPath(rawPath)}`)
			);
		}
		default: {
			const argsStr = JSON.stringify(args);
			const preview = argsStr.length > 50 ? `${argsStr.slice(0, 50)}...` : argsStr;
			return themeFg("accent", toolName) + themeFg("dim", ` ${preview}`);
		}
	}
}

interface UsageStats {
	input: number;
	output: number;
	cacheRead: number;
	cacheWrite: number;
	cost: number;
	contextTokens: number;
	turns: number;
}

export interface SingleResult {
	agent: string;
	agentSource: "user" | "project" | "unknown";
	task: string;
	exitCode: number;
	messages: Message[];
	stderr: string;
	usage: UsageStats;
	model?: string;
	stopReason?: string;
	errorMessage?: string;
	step?: number;
	/** #137: directory where this result was cached (see getCacheDir). */
	cachePath?: string;
}

interface SubagentDetails {
	mode: "single" | "parallel" | "chain";
	agentScope: AgentScope;
	projectAgentsDir: string | null;
	results: SingleResult[];
}

function getFinalOutput(messages: Message[]): string {
	for (let i = messages.length - 1; i >= 0; i--) {
		const msg = messages[i];
		if (msg.role === "assistant") {
			for (const part of msg.content) {
				if (part.type === "text") return part.text;
			}
		}
	}
	return "";
}

export function isFailedResult(result: SingleResult): boolean {
	return (
		result.exitCode !== 0 ||
		result.stopReason === "error" ||
		result.stopReason === "aborted" ||
		// #137: per-task timeout is a failure — the worker was killed, not done.
		result.stopReason === "timeout" ||
		// #208: an external cut (signal-death) is a failure — the worker is
		// dead, not done; the orchestrator must re-dispatch, not accept.
		result.stopReason === "cut"
	);
}

export function getResultOutput(result: SingleResult): string {
	if (!isFailedResult(result)) {
		return getFinalOutput(result.messages) || "(no output)";
	}
	// #137: abort/timeout results — surface the worker's own output over the
	// generic interrupt message so a completed/partial result is never masked
	// (an Escape after completion must not hide the finished worker's work).
	if (
		result.stopReason === "aborted" ||
		result.stopReason === "timeout" ||
		result.stopReason === "completed_before_abort" ||
		// #208: a cut result carries whatever the worker produced before the
		// signal — surface partial messages first (mirrors #137's timeout
		// treatment).
		result.stopReason === "cut"
	) {
		const output = getFinalOutput(result.messages);
		if (output) return output;
	}
	return result.errorMessage || result.stderr || getFinalOutput(result.messages) || "(no output)";
}

// ── #137 abort/timeout decision functions (pure, unit-tested) ──────────

/**
 * #137 F3: the abort handler is a no-op when the process already exited
 * (`proc.exitCode !== null`). Prevents an Escape arriving after worker
 * completion from killing anything or marking the run as aborted.
 */
export function shouldAbortBeNoop(procExitCode: number | null, wasAborted: boolean): boolean {
	return wasAborted && procExitCode !== null;
}

/**
 * #137 F4: an abort only counts as such when the process did NOT exit
 * cleanly. exitCode 0 (clean exit — abort arrived after completion) is
 * never an abort; null (signal-killed) or non-zero is. Replaces the old
 * unconditional `throw new Error("Subagent was aborted")`.
 */
export function shouldThrowOnAbort(procExitCode: number | null, wasAborted: boolean): boolean {
	return wasAborted && procExitCode !== 0;
}

/** #137 F1: per-task timeout, env-overridable. 0/negative/NaN → disabled. */
export const DEFAULT_TASK_TIMEOUT_MS = 1_800_000;

export function getTaskTimeoutMs(raw: string | undefined = process.env.SUBAGENT_TASK_TIMEOUT_MS): number {
	if (raw === undefined || raw.trim() === "") return DEFAULT_TASK_TIMEOUT_MS;
	const n = Number(raw);
	// 0, negative, or non-numeric → disabled (backward compat; garbage env
	// input must never kill productive agents instantly).
	if (!Number.isFinite(n) || n <= 0) return 0;
	return n;
}

// ── #208: cut contract + backstop (pure, unit-tested) ────────────────────

/**
 * #208 D6: settle stopReason from the RAW close code + dispatch flags.
 * Used by BOTH the close path and the exit-settle fallback (the grace race
 * must not lose the branches). An externally signal-killed child (code null)
 * with no timeout/abort in progress maps to "cut". Documented limitation:
 * the ext has no tool state, so a CLEAN mid-tool exit is undetectable here —
 * only signal-death maps to cut (D6, scope).
 */
export interface ResolveStopReasonInput {
	timedOut: boolean;
	wasAborted: boolean;
	backstopFired: boolean;
}

export function resolveStopReason(code: number | null, i: ResolveStopReasonInput): string | undefined {
	if (i.timedOut) return "timeout";
	if (i.wasAborted) {
		// #137 F4: abort after clean exit → completed_before_abort (valid result).
		if (!shouldThrowOnAbort(code, i.wasAborted)) return "completed_before_abort";
		return "aborted";
	}
	if (i.backstopFired) return "cut";
	if (code === null) return "cut"; // signal-death — NEW (#208)
	return undefined;
}

/** #208 D4: subagent backstop margin over taskTimeout (15 min). */
export const DEFAULT_SUBAGENT_BACKSTOP_MARGIN_MS = 900_000;

/**
 * #208 D4: the last-resort parent-await bound for the ext. taskTimeout + 15min
 * when taskTimeout > 0; a FIXED tool-stall + 30min (6h30m = 23_400_000) when
 * SUBAGENT_TASK_TIMEOUT_MS=0 — the timeout opt-out must NOT reinstate the
 * unbounded wait (the ext has no marker clause to bound a long-lived child
 * otherwise). SUBAGENT_BACKSTOP_MS overrides; 0 = off (deliberate
 * unbounded-wait config).
 */
export function getSubagentBackstopMs(taskTimeoutMs: number): number {
	const raw = Number(process.env.SUBAGENT_BACKSTOP_MS);
	if (Number.isFinite(raw) && raw === 0) return 0; // explicit opt-out
	if (Number.isFinite(raw) && raw > 0) return raw;
	if (taskTimeoutMs > 0) return taskTimeoutMs + DEFAULT_SUBAGENT_BACKSTOP_MARGIN_MS;
	return DEFAULT_TOOL_STALL_MS + DEFAULT_BACKSTOP_MARGIN_MS;
}

/** #208 round-3 F1 (option a): byte-freshness window — SUBAGENT_BACKSTOP_FRESH_MS
 * (default 60 min, floor 60s). */
export function getSubagentBackstopFreshMs(): number {
	const raw = Number(process.env.SUBAGENT_BACKSTOP_FRESH_MS);
	return Math.max(60_000, Number.isFinite(raw) && raw > 0 ? raw : 3_600_000);
}

/**
 * #208 round-3 F1 (option a — byte-freshness proxy): the backstop fires only
 * when (a) the deadline (backstopMs since start) has been reached AND (b) no
 * stdout/stderr bytes within the fresh window. A healthy agent that emitted
 * bytes within the window is exempt → the timer re-arms. Weaker semantics
 * documented: unlike the builtin's marker gate, a >60-min-silent healthy ext
 * agent is NOT exempt — the ext emits no liveness signal by design
 * (Out-of-scope); this is the price of bounding the ext's otherwise
 * unbounded wait in the timeout=0 config.
 */
export interface BackstopShouldFireInput {
	now: number;
	startedAt: number;
	/** Last stdout/stderr byte timestamp (0 = never emitted). */
	lastOutputAt: number;
	backstopMs: number;
	freshWindowMs: number;
}

export function backstopShouldFire(i: BackstopShouldFireInput): boolean {
	if (i.now - i.startedAt < i.backstopMs) return false;
	if (i.lastOutputAt > 0 && i.now - i.lastOutputAt <= i.freshWindowMs) return false;
	return true;
}

// ── #137 F6: result caching to disk (defense in depth) ──────────────────

/**
 * Cache directory for a dispatch: `~/.pi/agent/task-results/<sha256>` where
 * the digest is over `agent|task|timestamp`. Collision-tolerant (the
 * timestamp makes dispatches unique).
 */
export function getCacheDir(agent: string, task: string, timestamp: number = Date.now()): string {
	const digest = createHash("sha256").update(`${agent}|${task}|${timestamp}`).digest("hex");
	return path.join(os.homedir(), ".pi", "agent", "task-results", digest);
}

/**
 * Fire-and-forget result cache write — never on the critical path, never
 * rejects the caller. The orchestrator (an LLM) can read `result.json` to
 * recover a completed worker's output after an abort/timeout.
 */
export function cacheResult(dir: string, result: SingleResult): void {
	try {
		const filePath = path.join(dir, "result.json");
		fs.promises
			.mkdir(dir, { recursive: true })
			.then(() => fs.promises.writeFile(filePath, JSON.stringify(result, null, 2), "utf-8"))
			.catch(() => {
				// Fire-and-forget: caching must never fail the dispatch.
			});
	} catch {
		// Sync construction errors — ignore.
	}
}

function truncateParallelOutput(output: string): string {
	const byteLength = Buffer.byteLength(output, "utf8");
	if (byteLength <= PER_TASK_OUTPUT_CAP) return output;

	let truncated = output.slice(0, PER_TASK_OUTPUT_CAP);
	while (Buffer.byteLength(truncated, "utf8") > PER_TASK_OUTPUT_CAP) {
		truncated = truncated.slice(0, -1);
	}
	return `${truncated}\n\n[Output truncated: ${byteLength - Buffer.byteLength(truncated, "utf8")} bytes omitted. Full output preserved in tool details.]`;
}

type DisplayItem = { type: "text"; text: string } | { type: "toolCall"; name: string; args: Record<string, any> };

function getDisplayItems(messages: Message[]): DisplayItem[] {
	const items: DisplayItem[] = [];
	for (const msg of messages) {
		if (msg.role === "assistant") {
			for (const part of msg.content) {
				if (part.type === "text") items.push({ type: "text", text: part.text });
				else if (part.type === "toolCall") items.push({ type: "toolCall", name: part.name, args: part.arguments });
			}
		}
	}
	return items;
}

async function mapWithConcurrencyLimit<TIn, TOut>(
	items: TIn[],
	concurrency: number,
	fn: (item: TIn, index: number) => Promise<TOut>,
): Promise<TOut[]> {
	if (items.length === 0) return [];
	const limit = Math.max(1, Math.min(concurrency, items.length));
	const results: TOut[] = new Array(items.length);
	let nextIndex = 0;
	const workers = new Array(limit).fill(null).map(async () => {
		while (true) {
			const current = nextIndex++;
			if (current >= items.length) return;
			results[current] = await fn(items[current], current);
		}
	});
	await Promise.all(workers);
	return results;
}

async function writePromptToTempFile(agentName: string, prompt: string): Promise<{ dir: string; filePath: string }> {
	const tmpDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), "pi-subagent-"));
	const safeName = agentName.replace(/[^\w.-]+/g, "_");
	const filePath = path.join(tmpDir, `prompt-${safeName}.md`);
	await withFileMutationQueue(filePath, async () => {
		await fs.promises.writeFile(filePath, prompt, { encoding: "utf-8", mode: 0o600 });
	});
	return { dir: tmpDir, filePath };
}

export function getPiInvocation(args: string[]): { command: string; args: string[] } {
	const currentScript = process.argv[1];
	const isBunVirtualScript = currentScript?.startsWith("/$bunfs/root/");
	if (currentScript && !isBunVirtualScript && fs.existsSync(currentScript)) {
		return { command: process.execPath, args: [currentScript, ...args] };
	}

	const execName = path.basename(process.execPath).toLowerCase();
	const isGenericRuntime = /^(node|bun)(\.exe)?$/.test(execName);
	if (!isGenericRuntime) {
		return { command: process.execPath, args };
	}

	return { command: "pi", args };
}

type OnUpdateCallback = (partial: AgentToolResult<SubagentDetails>) => void;

export async function runSingleAgent(
	defaultCwd: string,
	agents: AgentConfig[],
	agentName: string,
	task: string,
	cwd: string | undefined,
	step: number | undefined,
	signal: AbortSignal | undefined,
	onUpdate: OnUpdateCallback | undefined,
	makeDetails: (results: SingleResult[]) => SubagentDetails,
): Promise<SingleResult> {
	const agent = agents.find((a) => a.name === agentName);

	if (!agent) {
		const available = agents.map((a) => `"${a.name}"`).join(", ") || "none";
		return {
			agent: agentName,
			agentSource: "unknown",
			task,
			exitCode: 1,
			messages: [],
			stderr: `Unknown agent: "${agentName}". Available agents: ${available}.`,
			usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
			step,
		};
	}

	const args: string[] = ["--mode", "json", "-p", "--no-session"];
	if (agent.model) args.push("--model", agent.model);
	if (agent.tools && agent.tools.length > 0) args.push("--tools", agent.tools.join(","));

	let tmpPromptDir: string | null = null;
	let tmpPromptPath: string | null = null;

	const currentResult: SingleResult = {
		agent: agentName,
		agentSource: agent.source,
		task,
		exitCode: 0,
		messages: [],
		stderr: "",
		usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
		model: agent.model,
		step,
	};

	// #137 F6: every completed dispatch (success/failure/timeout/abort) is
	// cached to disk so the orchestrator can recover the worker's output.
	const cacheDir = getCacheDir(agentName, task);
	const emitUpdate = () => {
		if (onUpdate) {
			onUpdate({
				content: [{ type: "text", text: getFinalOutput(currentResult.messages) || "(running...)" }],
				details: makeDetails([currentResult]),
			});
		}
	};

	try {
		if (agent.systemPrompt.trim()) {
			const tmp = await writePromptToTempFile(agent.name, agent.systemPrompt);
			tmpPromptDir = tmp.dir;
			tmpPromptPath = tmp.filePath;
			args.push("--append-system-prompt", tmpPromptPath);
		}

		args.push(`Task: ${task}`);
		let wasAborted = false;
		let timedOut = false;

		const exitCode = await new Promise<number>((resolve) => {
			const invocation = getPiInvocation(args);
			// #36: Ensure sub-agent PATH includes common python3 locations
			// so MCP servers using bare `python3` resolve.
			const augmentedPath = getSubAgentPath();
			// #137 F8: detached spawn gives the sub-agent its own process group,
			// so treeKill can signal it (and its MCP server children) without
			// ever signalling the orchestrator. Opt out via SUBAGENT_DETACHED=0.
			const detached = process.env.SUBAGENT_DETACHED !== "0";
			const proc = spawn(invocation.command, invocation.args, {
				cwd: cwd ?? defaultCwd,
				shell: false,
				detached,
				stdio: ["ignore", "pipe", "pipe"],
				env: { ...process.env, PATH: augmentedPath },
			});
			// #208: pgid captured at spawn — for a detached spawn this is the
			// child's OWN group (setsid); the shared sweep helper's runtime
			// guard skips + warns when SUBAGENT_DETACHED=0 (the child shares
			// the orchestrator's pgid — never signal it; implies
			// SUBAGENT_SWEEP=0).
			const childPgid: number | null = getPgid(proc.pid ?? 0) ?? proc.pid ?? null;
			// #208 F1: settle-exactly-once — `settled` gates EVERY settle path
			// (exit-settle, close, backstop, error); `swept` gates the
			// fire-and-forget settle-path sweep. graceTimer is cleared when
			// close fires first (a stale timer can never re-fire into a
			// recycled pgid); backstopTimer is cleared on settle and never
			// re-armed after settle.
			let settled = false;
			let swept = false;
			let graceTimer: NodeJS.Timeout | null = null;
			let backstopTimer: NodeJS.Timeout | undefined;
			let backstopFired = false;
			const startedAt = Date.now();
			let lastOutputAt = 0;

			// Heartbeat: prevent silence timeout during long tool calls (review dispatches, batch reads).
			// Research: 30s interval balances false-positives (<5s jitter risk) vs detection speed (>30s misses crashes).
			// Uses stdout empty line — processLine skips whitespace-only lines (#6539).
			const HEARTBEAT_MS = 30_000;
			const heartbeat = setInterval(() => {
				if (proc.exitCode === null && !proc.killed) {
					process.stdout.write("\n");
					emitUpdate();
				}
			}, HEARTBEAT_MS);

			// #137 F1: per-task hard cap for hung workers. When it fires the
			// process tree is killed (SIGTERM → 5s → SIGKILL) and the result is
			// returned with stopReason "timeout". 0 disables (backward compat).
			const taskTimeoutMs = getTaskTimeoutMs();
			let taskTimeout: NodeJS.Timeout | undefined;
			if (taskTimeoutMs > 0) {
				taskTimeout = setTimeout(() => {
					if (wasAborted) return; // abort already in progress — it owns the kill
					if (proc.exitCode !== null || proc.killed) return; // already exited
					timedOut = true;
					killTree("SIGTERM");
				}, taskTimeoutMs);
			}

			// #137 F8: recursive process-group kill — children (MCP servers)
			// die before the sub-agent itself, so aborted sessions leave no
			// orphans. SIGKILL fallback after 5s mirrors the old kill sequence.
			const killTree = (signal: NodeJS.Signals) => {
				const pid = proc.pid;
				if (pid !== undefined) {
					treeKill(pid, signal);
				} else {
					proc.kill(signal);
				}
				const sigkillTimer = setTimeout(() => {
					if (proc.exitCode === null && !proc.killed) {
						if (pid !== undefined) treeKill(pid, "SIGKILL");
						else proc.kill("SIGKILL");
					}
				}, 5000);
				sigkillTimer.unref?.();
				proc.once("close", () => clearTimeout(sigkillTimer));
			};

			// #208 F1/F2: settle-exactly-once + settle-path sweep hook.
			// doResolve wraps resolve(code ?? 0) — the settle + the sweep run
			// EXACTLY ONCE per dispatch. Sweep gating (round-3 F2): whenever
			// the exit-settle path resolved (close didn't fire within grace —
			// a live pipe-holder keeps the pgid alive, so pgid-recycle risk
			// does not apply there) OR an abnormal reason resolved via the
			// close path (stopReason ∈ {timeout, aborted, cut} — incl. the
			// backstop, which maps to "cut" — or a non-zero exit); no-sweep
			// ONLY for close-within-grace with code 0 and no kill stopReason.
			// Fire-and-forget AFTER resolve — sweep latency never counts
			// against the resolve indicator (F3). Safety valve (D2):
			// SUBAGENT_SWEEP=0 disables the settle-path sweep ENTIRELY; a
			// non-detached spawn (SUBAGENT_DETACHED=0) is skipped + warned by
			// the shared guard — the orchestrator's own group is never
			// signaled (implies SUBAGENT_SWEEP=0).
			const doResolve = (code: number | null, opts?: { settlePath?: "close" | "exit"; stopReason?: string }) => {
				if (settled) return;
				settled = true;
				if (graceTimer) {
					clearTimeout(graceTimer);
					graceTimer = null;
				}
				if (backstopTimer) {
					clearTimeout(backstopTimer);
					backstopTimer = undefined;
				}
				const shouldSweep =
					opts?.settlePath === "exit" ||
					(opts?.stopReason !== undefined && opts.stopReason !== "completed_before_abort") ||
					(code !== null && code !== 0);
				if (shouldSweep && process.env.SUBAGENT_SWEEP !== "0" && childPgid !== null && !swept) {
					swept = true;
					void sweepProcessGroup(childPgid, { detached });
				}
				resolve(code ?? 0);
			};

			// #208 D4/round-3 F1 (option a — byte-freshness proxy): backstop
			// timer — the last-resort parent-await bound (the ext has no marker
			// stream, so no stateFresh analog beyond output activity). ONE-SHOT
			// per dispatch: armed at spawn, fires at backstopMs (taskTimeout +
			// 15min, or fixed 6h30m when timeout=0), re-armed for another
			// interval when the freshness gate passes (bytes within the fresh
			// window — healthy agent); fires ONCE per cut when the gate is
			// failing (emitting-then-silent class stays bounded); cleared on
			// settle; never re-armed after settle. SUBAGENT_BACKSTOP_MS
			// overrides; 0 = off (deliberate unbounded-wait config).
			const backstopMs = getSubagentBackstopMs(taskTimeoutMs);
			const backstopFreshWindowMs = getSubagentBackstopFreshMs();
			if (backstopMs > 0) {
				const backstopFire = () => {
					if (settled) return;
					if (proc.exitCode !== null || proc.killed) return; // already exited — close will settle
					if (!backstopShouldFire({ now: Date.now(), startedAt, lastOutputAt, backstopMs, freshWindowMs: backstopFreshWindowMs })) {
						// healthy (bytes within the fresh window) — re-arm for
						// another interval; the backstop is not a total dispatch cap.
						backstopTimer = setTimeout(backstopFire, backstopMs);
						return;
					}
					backstopFired = true;
					killTree("SIGTERM");
					// resolve IMMEDIATELY — never wait on close (the child may
					// be wedged / a pipe-holder alive).
					if (buffer.trim()) processLine(buffer);
					const reason = resolveStopReason(null, { timedOut, wasAborted, backstopFired });
					if (reason) currentResult.stopReason = reason;
					emitUpdate();
					doResolve(null, { settlePath: "close", stopReason: reason });
				};
				backstopTimer = setTimeout(backstopFire, backstopMs);
			}

			let buffer = "";

			const processLine = (line: string) => {
				if (!line.trim()) return;
				let event: any;
				try {
					event = JSON.parse(line);
				} catch {
					return;
				}

				if (event.type === "message_end" && event.message) {
					const msg = event.message as Message;
					currentResult.messages.push(msg);

					if (msg.role === "assistant") {
						currentResult.usage.turns++;
						const usage = msg.usage;
						if (usage) {
							currentResult.usage.input += usage.input || 0;
							currentResult.usage.output += usage.output || 0;
							currentResult.usage.cacheRead += usage.cacheRead || 0;
							currentResult.usage.cacheWrite += usage.cacheWrite || 0;
							currentResult.usage.cost += usage.cost?.total || 0;
							currentResult.usage.contextTokens = usage.totalTokens || 0;
						}
						if (!currentResult.model && msg.model) currentResult.model = msg.model;
						if (msg.stopReason) currentResult.stopReason = msg.stopReason;
						if (msg.errorMessage) currentResult.errorMessage = msg.errorMessage;
					}
					emitUpdate();
				}

				if (event.type === "tool_result_end" && event.message) {
					currentResult.messages.push(event.message as Message);
					emitUpdate();
				}
			};

			proc.stdout.on("data", (data) => {
				buffer += data.toString();
				lastOutputAt = Date.now(); // #208: byte-freshness proxy (backstop gate)
				const lines = buffer.split("\n");
				buffer = lines.pop() || "";
				for (const line of lines) processLine(line);
			});

			proc.stderr.on("data", (data) => {
				currentResult.stderr += data.toString();
				lastOutputAt = Date.now(); // #208: byte-freshness proxy (backstop gate)
			});

			proc.on("close", (code) => {
				clearInterval(heartbeat);
				if (taskTimeout) clearTimeout(taskTimeout);
				if (graceTimer) {
					clearTimeout(graceTimer);
					graceTimer = null;
				}
				if (buffer.trim()) processLine(buffer);
				// #137 + #208: settle stopReason from the RAW close code via the
				// shared mapping (same taxonomy as the exit-settle fallback —
				// the grace race must not lose the branches). null (killed by
				// signal) is distinct from 0 (clean exit); resolve() below
				// collapses null → 0 for the exitCode field. #208 cut contract
				// (D6): signal-death maps to stopReason "cut" with exitCode
				// staying 0 (the raw code was null — do not fabricate).
				// Documented limitation: the ext has no tool state, so a CLEAN
				// mid-tool exit is undetectable here — only signal-death maps
				// to cut.
				const reason = resolveStopReason(code, { timedOut, wasAborted, backstopFired });
				if (reason === "aborted") {
					currentResult.errorMessage = `Subagent was aborted (user-initiated). Result cache: ${cacheDir}`;
				}
				if (reason) currentResult.stopReason = reason;
				// F2: one final update after close so the core's streaming display
				// receives a terminal state instead of an endless spinner.
				emitUpdate();
				doResolve(code, { settlePath: "close", stopReason: reason });
			});

			proc.on("exit", (code: number | null) => {
				// #208 F1: grace-race exit-settle — `exit` fires BEFORE `close`,
				// and the final-output composition lives in the close path.
				// Defer settle by 2s: if `close` fires within the grace the
				// NORMAL path is unchanged; only when an orphan holds the pipes
				// (close never fires) does the exit-settle run (replicating the
				// finalize composition incl. the stopReason branches). The grace
				// timer is CLEARED when close fires first (F1) — a stale timer
				// can never re-fire into a recycled pgid.
				clearInterval(heartbeat);
				if (taskTimeout) clearTimeout(taskTimeout);
				graceTimer = setTimeout(() => {
					graceTimer = null;
					if (buffer.trim()) processLine(buffer);
					const reason = resolveStopReason(code, { timedOut, wasAborted, backstopFired });
					if (reason === "aborted") {
						currentResult.errorMessage = `Subagent was aborted (user-initiated). Result cache: ${cacheDir}`;
					}
					if (reason) currentResult.stopReason = reason;
					emitUpdate();
					doResolve(code, { settlePath: "exit", stopReason: reason });
				}, DEFAULT_EXIT_SETTLE_GRACE_MS);
			});

			proc.on("error", () => {
				clearInterval(heartbeat);
				if (taskTimeout) clearTimeout(taskTimeout);
				doResolve(1, { settlePath: "close" });
			});

			if (signal) {
				// #137 F3: abort is a no-op when the process already exited or a
				// timeout already killed it. F4: after close we return a result
				// record instead of throwing, so completed work is never lost.
				const killProc = () => {
					if (timedOut) return;
					if (shouldAbortBeNoop(proc.exitCode, wasAborted)) return;
					wasAborted = true;
					killTree("SIGTERM");
				};
				if (signal.aborted) killProc();
				else signal.addEventListener("abort", killProc, { once: true });
			}
		});

		currentResult.exitCode = exitCode;
		currentResult.cachePath = cacheDir;
		// F6: persist the result (success, failure, timeout, or abort) before
		// returning — the orchestrator can recover it from disk if needed.
		cacheResult(cacheDir, currentResult);
		return currentResult;
	} finally {
		if (tmpPromptPath)
			try {
				fs.unlinkSync(tmpPromptPath);
			} catch {
				/* ignore */
			}
		if (tmpPromptDir)
			try {
				fs.rmdirSync(tmpPromptDir);
			} catch {
				/* ignore */
			}
	}
}

const TaskItem = Type.Object({
	agent: Type.String({ description: "Name of the agent to invoke" }),
	task: Type.String({ description: "Task to delegate to the agent" }),
	cwd: Type.Optional(Type.String({ description: "Working directory for the agent process" })),
});

const ChainItem = Type.Object({
	agent: Type.String({ description: "Name of the agent to invoke" }),
	task: Type.String({ description: "Task with optional {previous} placeholder for prior output" }),
	cwd: Type.Optional(Type.String({ description: "Working directory for the agent process" })),
});

const AgentScopeSchema = StringEnum(["user", "project", "both"] as const, {
	description: 'Which agent directories to use. Default: "user". Use "both" to include project-local agents.',
	default: "user",
});

const SubagentParams = Type.Object({
	agent: Type.Optional(Type.String({ description: "Name of the agent to invoke (for single mode)" })),
	task: Type.Optional(Type.String({ description: "Task to delegate (for single mode)" })),
	tasks: Type.Optional(Type.Array(TaskItem, { description: "Array of {agent, task} for parallel execution" })),
	chain: Type.Optional(Type.Array(ChainItem, { description: "Array of {agent, task} for sequential execution" })),
	agentScope: Type.Optional(AgentScopeSchema),
	confirmProjectAgents: Type.Optional(
		Type.Boolean({ description: "Prompt before running project-local agents. Default: true.", default: true }),
	),
	cwd: Type.Optional(Type.String({ description: "Working directory for the agent process (single mode)" })),
});

export default function (pi: ExtensionAPI) {
	pi.registerTool({
		name: "subagent",
		label: "Subagent",
		description: [
			"Delegate tasks to specialized subagents with isolated context.",
			"Modes: single (agent + task), parallel (tasks array), chain (sequential with {previous} placeholder).",
			`Default agent scope is "user" (from ${path.join(getAgentDir(), "agents")}).`,
			`To enable project-local agents in ${CONFIG_DIR_NAME}/agents, set agentScope: "both" (or "project").`,
		].join(" "),
		parameters: SubagentParams,

		async execute(_toolCallId, params, signal, onUpdate, ctx) {
			const agentScope: AgentScope = params.agentScope ?? "user";
			const discovery = discoverAgents(ctx.cwd, agentScope);
			const agents = discovery.agents;
			const confirmProjectAgents = params.confirmProjectAgents ?? true;

			const hasChain = (params.chain?.length ?? 0) > 0;
			const hasTasks = (params.tasks?.length ?? 0) > 0;
			const hasSingle = Boolean(params.agent && params.task);
			const modeCount = Number(hasChain) + Number(hasTasks) + Number(hasSingle);

			const makeDetails =
				(mode: "single" | "parallel" | "chain") =>
				(results: SingleResult[]): SubagentDetails => ({
					mode,
					agentScope,
					projectAgentsDir: discovery.projectAgentsDir,
					results,
				});

			if (modeCount !== 1) {
				const available = agents.map((a) => `${a.name} (${a.source})`).join(", ") || "none";
				return {
					content: [
						{
							type: "text",
							text: `Invalid parameters. Provide exactly one mode.\nAvailable agents: ${available}`,
						},
					],
					details: makeDetails("single")([]),
				};
			}

			if ((agentScope === "project" || agentScope === "both") && confirmProjectAgents && ctx.hasUI) {
				const requestedAgentNames = new Set<string>();
				if (params.chain) for (const step of params.chain) requestedAgentNames.add(step.agent);
				if (params.tasks) for (const t of params.tasks) requestedAgentNames.add(t.agent);
				if (params.agent) requestedAgentNames.add(params.agent);

				const projectAgentsRequested = Array.from(requestedAgentNames)
					.map((name) => agents.find((a) => a.name === name))
					.filter((a): a is AgentConfig => a?.source === "project");

				if (projectAgentsRequested.length > 0) {
					const names = projectAgentsRequested.map((a) => a.name).join(", ");
					const dir = discovery.projectAgentsDir ?? "(unknown)";
					const ok = await ctx.ui.confirm(
						"Run project-local agents?",
						`Agents: ${names}\nSource: ${dir}\n\nProject agents are repo-controlled. Only continue for trusted repositories.`,
					);
					if (!ok)
						return {
							content: [{ type: "text", text: "Canceled: project-local agents not approved." }],
							details: makeDetails(hasChain ? "chain" : hasTasks ? "parallel" : "single")([]),
						};
				}
			}

			if (params.chain && params.chain.length > 0) {
				const results: SingleResult[] = [];
				let previousOutput = "";

				for (let i = 0; i < params.chain.length; i++) {
					const step = params.chain[i];
					const taskWithContext = step.task.replace(/\{previous\}/g, previousOutput);

					// Create update callback that includes all previous results
					const chainUpdate: OnUpdateCallback | undefined = onUpdate
						? (partial) => {
								// Combine completed results with current streaming result
								const currentResult = partial.details?.results[0];
								if (currentResult) {
									const allResults = [...results, currentResult];
									onUpdate({
										content: partial.content,
										details: makeDetails("chain")(allResults),
									});
								}
							}
						: undefined;

					// #137 F5: runSingleAgent never throws on abort, but network/OS
					// failures can still surface — convert to a failed result and
					// keep the chain's previously accumulated steps.
					let result: SingleResult;
					try {
						result = await runSingleAgent(
							ctx.cwd,
							agents,
							step.agent,
							taskWithContext,
							step.cwd,
							i + 1,
							signal,
							chainUpdate,
							makeDetails("chain"),
						);
					} catch (err) {
						const message = err instanceof Error ? err.message : String(err);
						result = {
							agent: step.agent,
							agentSource: "unknown",
							task: taskWithContext,
							exitCode: 1,
							messages: [],
							stderr: message,
							usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
							stopReason: "error",
							errorMessage: message,
							step: i + 1,
						};
					}
					results.push(result);

					const isError = isFailedResult(result);
					if (isError) {
						const errorMsg = getResultOutput(result);
						return {
							content: [{ type: "text", text: `Chain stopped at step ${i + 1} (${step.agent}): ${errorMsg}` }],
							details: makeDetails("chain")(results),
							isError: true,
						};
					}
					previousOutput = getFinalOutput(result.messages);
				}
				return {
					content: [{ type: "text", text: getFinalOutput(results[results.length - 1].messages) || "(no output)" }],
					details: makeDetails("chain")(results),
				};
			}

			if (params.tasks && params.tasks.length > 0) {
				if (params.tasks.length > MAX_PARALLEL_TASKS)
					return {
						content: [
							{
								type: "text",
								text: `Too many parallel tasks (${params.tasks.length}). Max is ${MAX_PARALLEL_TASKS}.`,
							},
						],
						details: makeDetails("parallel")([]),
					};

				// Track all results for streaming updates
				const allResults: SingleResult[] = new Array(params.tasks.length);

				// Initialize placeholder results
				for (let i = 0; i < params.tasks.length; i++) {
					allResults[i] = {
						agent: params.tasks[i].agent,
						agentSource: "unknown",
						task: params.tasks[i].task,
						exitCode: -1, // -1 = still running
						messages: [],
						stderr: "",
						usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
					};
				}

				const emitParallelUpdate = () => {
					if (onUpdate) {
						const running = allResults.filter((r) => r.exitCode === -1).length;
						const done = allResults.filter((r) => r.exitCode !== -1).length;
						onUpdate({
							content: [
								{ type: "text", text: `Parallel: ${done}/${allResults.length} done, ${running} running...` },
							],
							details: makeDetails("parallel")([...allResults]),
						});
					}
				};

				const results = await mapWithConcurrencyLimit(params.tasks, MAX_CONCURRENCY, async (t: (typeof params.tasks)[number], index) => {
					// #137 F5: never let one task's throw drop the batch — synthesize
					// an error result and keep every other task's outcome.
					let result: SingleResult;
					try {
						result = await runSingleAgent(
							ctx.cwd,
							agents,
							t.agent,
							t.task,
							t.cwd,
							undefined,
							signal,
							// Per-task update callback
							(partial) => {
								if (partial.details?.results[0]) {
									allResults[index] = partial.details.results[0];
									emitParallelUpdate();
								}
							},
							makeDetails("parallel"),
						);
					} catch (err) {
						const message = err instanceof Error ? err.message : String(err);
						result = {
							agent: t.agent,
							agentSource: "unknown",
							task: t.task,
							exitCode: 1,
							messages: [],
							stderr: message,
							usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
							stopReason: "error",
							errorMessage: message,
						};
					}
					allResults[index] = result;
					emitParallelUpdate();
					return result;
				});

				const successCount = results.filter((r) => !isFailedResult(r)).length;
				const summaries = results.map((r) => {
					const output = truncateParallelOutput(getResultOutput(r));
					const status = isFailedResult(r)
						? `failed${r.stopReason && r.stopReason !== "end" ? ` (${r.stopReason})` : ""}`
						: "completed";
					return `### [${r.agent}] ${status}\n\n${output}`;
				});
				return {
					content: [
						{
							type: "text",
							text: `Parallel: ${successCount}/${results.length} succeeded\n\n${summaries.join("\n\n---\n\n")}`,
						},
					],
					details: makeDetails("parallel")(results),
				};
			}

			if (params.agent && params.task) {
				let result: SingleResult;
				try {
					result = await runSingleAgent(
						ctx.cwd,
						agents,
						params.agent,
						params.task,
						params.cwd,
						undefined,
						signal,
						onUpdate,
						makeDetails("single"),
					);
				} catch (err) {
					// #137 F5: never throw — surface as a failed result.
					const message = err instanceof Error ? err.message : String(err);
					result = {
						agent: params.agent,
						agentSource: "unknown",
						task: params.task,
						exitCode: 1,
						messages: [],
						stderr: message,
						usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
						stopReason: "error",
						errorMessage: message,
					};
				}
				const isError = isFailedResult(result);
				if (isError) {
					const errorMsg = getResultOutput(result);
					return {
						content: [{ type: "text", text: `Agent ${result.stopReason || "failed"}: ${errorMsg}` }],
						details: makeDetails("single")([result]),
						isError: true,
					};
				}
				return {
					content: [{ type: "text", text: getFinalOutput(result.messages) || "(no output)" }],
					details: makeDetails("single")([result]),
				};
			}

			const available = agents.map((a) => `${a.name} (${a.source})`).join(", ") || "none";
			return {
				content: [{ type: "text", text: `Invalid parameters. Available agents: ${available}` }],
				details: makeDetails("single")([]),
			};
		},

		renderCall(args, theme, _context) {
			const scope: AgentScope = args.agentScope ?? "user";
			if (args.chain && args.chain.length > 0) {
				let text =
					theme.fg("toolTitle", theme.bold("subagent ")) +
					theme.fg("accent", `chain (${args.chain.length} steps)`) +
					theme.fg("muted", ` [${scope}]`);
				for (let i = 0; i < Math.min(args.chain.length, 3); i++) {
					const step = args.chain[i];
					// Clean up {previous} placeholder for display
					const cleanTask = step.task.replace(/\{previous\}/g, "").trim();
					const preview = cleanTask.length > 40 ? `${cleanTask.slice(0, 40)}...` : cleanTask;
					text +=
						"\n  " +
						theme.fg("muted", `${i + 1}.`) +
						" " +
						theme.fg("accent", step.agent) +
						theme.fg("dim", ` ${preview}`);
				}
				if (args.chain.length > 3) text += `\n  ${theme.fg("muted", `... +${args.chain.length - 3} more`)}`;
				return new Text(text, 0, 0);
			}
			if (args.tasks && args.tasks.length > 0) {
				let text =
					theme.fg("toolTitle", theme.bold("subagent ")) +
					theme.fg("accent", `parallel (${args.tasks.length} tasks)`) +
					theme.fg("muted", ` [${scope}]`);
				for (const t of args.tasks.slice(0, 3)) {
					const preview = t.task.length > 40 ? `${t.task.slice(0, 40)}...` : t.task;
					text += `\n  ${theme.fg("accent", t.agent)}${theme.fg("dim", ` ${preview}`)}`;
				}
				if (args.tasks.length > 3) text += `\n  ${theme.fg("muted", `... +${args.tasks.length - 3} more`)}`;
				return new Text(text, 0, 0);
			}
			const agentName = args.agent || "...";
			const preview = args.task ? (args.task.length > 60 ? `${args.task.slice(0, 60)}...` : args.task) : "...";
			let text =
				theme.fg("toolTitle", theme.bold("subagent ")) +
				theme.fg("accent", agentName) +
				theme.fg("muted", ` [${scope}]`);
			text += `\n  ${theme.fg("dim", preview)}`;
			return new Text(text, 0, 0);
		},

		renderResult(result, { expanded }, theme, _context) {
			const details = result.details as SubagentDetails | undefined;
			if (!details || details.results.length === 0) {
				const text = result.content[0];
				return new Text(text?.type === "text" ? text.text : "(no output)", 0, 0);
			}

			const mdTheme = getMarkdownTheme();

			const renderDisplayItems = (items: DisplayItem[], limit?: number) => {
				const toShow = limit ? items.slice(-limit) : items;
				const skipped = limit && items.length > limit ? items.length - limit : 0;
				let text = "";
				if (skipped > 0) text += theme.fg("muted", `... ${skipped} earlier items\n`);
				for (const item of toShow) {
					if (item.type === "text") {
						const preview = expanded ? item.text : item.text.split("\n").slice(0, 3).join("\n");
						text += `${theme.fg("toolOutput", preview)}\n`;
					} else {
						text += `${theme.fg("muted", "→ ") + formatToolCall(item.name, item.args, theme.fg.bind(theme))}\n`;
					}
				}
				return text.trimEnd();
			};

			if (details.mode === "single" && details.results.length === 1) {
				const r = details.results[0];
				const isError = isFailedResult(r);
				const icon = isError ? theme.fg("error", "✗") : theme.fg("success", "✓");
				const displayItems = getDisplayItems(r.messages);
				const finalOutput = getFinalOutput(r.messages);

				if (expanded) {
					const container = new Container();
					let header = `${icon} ${theme.fg("toolTitle", theme.bold(r.agent))}${theme.fg("muted", ` (${r.agentSource})`)}`;
					if (isError && r.stopReason) header += ` ${theme.fg("error", `[${r.stopReason}]`)}`;
					container.addChild(new Text(header, 0, 0));
					if (isError && r.errorMessage)
						container.addChild(new Text(theme.fg("error", `Error: ${r.errorMessage}`), 0, 0));
					container.addChild(new Spacer(1));
					container.addChild(new Text(theme.fg("muted", "─── Task ───"), 0, 0));
					container.addChild(new Text(theme.fg("dim", r.task), 0, 0));
					container.addChild(new Spacer(1));
					container.addChild(new Text(theme.fg("muted", "─── Output ───"), 0, 0));
					if (displayItems.length === 0 && !finalOutput) {
						container.addChild(new Text(theme.fg("muted", "(no output)"), 0, 0));
					} else {
						for (const item of displayItems) {
							if (item.type === "toolCall")
								container.addChild(
									new Text(
										theme.fg("muted", "→ ") + formatToolCall(item.name, item.args, theme.fg.bind(theme)),
										0,
										0,
									),
								);
						}
						if (finalOutput) {
							container.addChild(new Spacer(1));
							container.addChild(new Markdown(finalOutput.trim(), 0, 0, mdTheme));
						}
					}
					const usageStr = formatUsageStats(r.usage, r.model);
					if (usageStr) {
						container.addChild(new Spacer(1));
						container.addChild(new Text(theme.fg("dim", usageStr), 0, 0));
					}
					return container;
				}

				let text = `${icon} ${theme.fg("toolTitle", theme.bold(r.agent))}${theme.fg("muted", ` (${r.agentSource})`)}`;
				if (isError && r.stopReason) text += ` ${theme.fg("error", `[${r.stopReason}]`)}`;
				if (isError && r.errorMessage) text += `\n${theme.fg("error", `Error: ${r.errorMessage}`)}`;
				else if (displayItems.length === 0) text += `\n${theme.fg("muted", "(no output)")}`;
				else {
					text += `\n${renderDisplayItems(displayItems, COLLAPSED_ITEM_COUNT)}`;
					if (displayItems.length > COLLAPSED_ITEM_COUNT) text += `\n${theme.fg("muted", "(Ctrl+O to expand)")}`;
				}
				const usageStr = formatUsageStats(r.usage, r.model);
				if (usageStr) text += `\n${theme.fg("dim", usageStr)}`;
				return new Text(text, 0, 0);
			}

			const aggregateUsage = (results: SingleResult[]) => {
				const total = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, turns: 0 };
				for (const r of results) {
					total.input += r.usage.input;
					total.output += r.usage.output;
					total.cacheRead += r.usage.cacheRead;
					total.cacheWrite += r.usage.cacheWrite;
					total.cost += r.usage.cost;
					total.turns += r.usage.turns;
				}
				return total;
			};

			if (details.mode === "chain") {
				const successCount = details.results.filter((r) => r.exitCode === 0).length;
				const icon = successCount === details.results.length ? theme.fg("success", "✓") : theme.fg("error", "✗");

				if (expanded) {
					const container = new Container();
					container.addChild(
						new Text(
							icon +
								" " +
								theme.fg("toolTitle", theme.bold("chain ")) +
								theme.fg("accent", `${successCount}/${details.results.length} steps`),
							0,
							0,
						),
					);

					for (const r of details.results) {
						const rIcon = r.exitCode === 0 ? theme.fg("success", "✓") : theme.fg("error", "✗");
						const displayItems = getDisplayItems(r.messages);
						const finalOutput = getFinalOutput(r.messages);

						container.addChild(new Spacer(1));
						container.addChild(
							new Text(
								`${theme.fg("muted", `─── Step ${r.step}: `) + theme.fg("accent", r.agent)} ${rIcon}`,
								0,
								0,
							),
						);
						container.addChild(new Text(theme.fg("muted", "Task: ") + theme.fg("dim", r.task), 0, 0));

						// Show tool calls
						for (const item of displayItems) {
							if (item.type === "toolCall") {
								container.addChild(
									new Text(
										theme.fg("muted", "→ ") + formatToolCall(item.name, item.args, theme.fg.bind(theme)),
										0,
										0,
									),
								);
							}
						}

						// Show final output as markdown
						if (finalOutput) {
							container.addChild(new Spacer(1));
							container.addChild(new Markdown(finalOutput.trim(), 0, 0, mdTheme));
						}

						const stepUsage = formatUsageStats(r.usage, r.model);
						if (stepUsage) container.addChild(new Text(theme.fg("dim", stepUsage), 0, 0));
					}

					const usageStr = formatUsageStats(aggregateUsage(details.results));
					if (usageStr) {
						container.addChild(new Spacer(1));
						container.addChild(new Text(theme.fg("dim", `Total: ${usageStr}`), 0, 0));
					}
					return container;
				}

				// Collapsed view
				let text =
					icon +
					" " +
					theme.fg("toolTitle", theme.bold("chain ")) +
					theme.fg("accent", `${successCount}/${details.results.length} steps`);
				for (const r of details.results) {
					const rIcon = r.exitCode === 0 ? theme.fg("success", "✓") : theme.fg("error", "✗");
					const displayItems = getDisplayItems(r.messages);
					text += `\n\n${theme.fg("muted", `─── Step ${r.step}: `)}${theme.fg("accent", r.agent)} ${rIcon}`;
					if (displayItems.length === 0) text += `\n${theme.fg("muted", "(no output)")}`;
					else text += `\n${renderDisplayItems(displayItems, 5)}`;
				}
				const usageStr = formatUsageStats(aggregateUsage(details.results));
				if (usageStr) text += `\n\n${theme.fg("dim", `Total: ${usageStr}`)}`;
				text += `\n${theme.fg("muted", "(Ctrl+O to expand)")}`;
				return new Text(text, 0, 0);
			}

			if (details.mode === "parallel") {
				const running = details.results.filter((r) => r.exitCode === -1).length;
				const successCount = details.results.filter((r) => r.exitCode !== -1 && !isFailedResult(r)).length;
				const failCount = details.results.filter((r) => r.exitCode !== -1 && isFailedResult(r)).length;
				const isRunning = running > 0;
				const icon = isRunning
					? theme.fg("warning", "⏳")
					: failCount > 0
						? theme.fg("warning", "◐")
						: theme.fg("success", "✓");
				const status = isRunning
					? `${successCount + failCount}/${details.results.length} done, ${running} running`
					: `${successCount}/${details.results.length} tasks`;

				if (expanded && !isRunning) {
					const container = new Container();
					container.addChild(
						new Text(
							`${icon} ${theme.fg("toolTitle", theme.bold("parallel "))}${theme.fg("accent", status)}`,
							0,
							0,
						),
					);

					for (const r of details.results) {
						const rIcon = isFailedResult(r) ? theme.fg("error", "✗") : theme.fg("success", "✓");
						const displayItems = getDisplayItems(r.messages);
						const finalOutput = getFinalOutput(r.messages);

						container.addChild(new Spacer(1));
						container.addChild(
							new Text(`${theme.fg("muted", "─── ") + theme.fg("accent", r.agent)} ${rIcon}`, 0, 0),
						);
						container.addChild(new Text(theme.fg("muted", "Task: ") + theme.fg("dim", r.task), 0, 0));

						// Show tool calls
						for (const item of displayItems) {
							if (item.type === "toolCall") {
								container.addChild(
									new Text(
										theme.fg("muted", "→ ") + formatToolCall(item.name, item.args, theme.fg.bind(theme)),
										0,
										0,
									),
								);
							}
						}

						// Show final output as markdown
						if (finalOutput) {
							container.addChild(new Spacer(1));
							container.addChild(new Markdown(finalOutput.trim(), 0, 0, mdTheme));
						}

						const taskUsage = formatUsageStats(r.usage, r.model);
						if (taskUsage) container.addChild(new Text(theme.fg("dim", taskUsage), 0, 0));
					}

					const usageStr = formatUsageStats(aggregateUsage(details.results));
					if (usageStr) {
						container.addChild(new Spacer(1));
						container.addChild(new Text(theme.fg("dim", `Total: ${usageStr}`), 0, 0));
					}
					return container;
				}

				// Collapsed view (or still running)
				let text = `${icon} ${theme.fg("toolTitle", theme.bold("parallel "))}${theme.fg("accent", status)}`;
				for (const r of details.results) {
					const rIcon =
						r.exitCode === -1
							? theme.fg("warning", "⏳")
							: isFailedResult(r)
								? theme.fg("error", "✗")
								: theme.fg("success", "✓");
					const displayItems = getDisplayItems(r.messages);
					text += `\n\n${theme.fg("muted", "─── ")}${theme.fg("accent", r.agent)} ${rIcon}`;
					if (displayItems.length === 0)
						text += `\n${theme.fg("muted", r.exitCode === -1 ? "(running...)" : "(no output)")}`;
					else text += `\n${renderDisplayItems(displayItems, 5)}`;
				}
				if (!isRunning) {
					const usageStr = formatUsageStats(aggregateUsage(details.results));
					if (usageStr) text += `\n\n${theme.fg("dim", `Total: ${usageStr}`)}`;
				}
				if (!expanded) text += `\n${theme.fg("muted", "(Ctrl+O to expand)")}`;
				return new Text(text, 0, 0);
			}

			const text = result.content[0];
			return new Text(text?.type === "text" ? text.text : "(no output)", 0, 0);
		},
	});
}
