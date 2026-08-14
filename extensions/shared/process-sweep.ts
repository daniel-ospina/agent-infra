/**
 * process-sweep.ts — shared pgid-anchored process-group sweep (#208).
 *
 * The settle-path orphan sweep for task dispatch (builtin `task` tool +
 * subagent extension): when a dispatch resolves (exit-settle path or an
 * abnormal settle), a pipe-holding orphan grandchild (MCP server / bash fork)
 * may outlive the child and delay `close` indefinitely — the observed ~6h
 * block (issue #208). The sweep anchors on the CHILD's process group (pgid),
 * captured at spawn AFTER switching the builtin spawn to detached
 * (setsid → own session/group). pgid persists across reparenting (PPID→1) and
 * covers forks AND MCP servers in one group — unlike treeKill's PPID walk,
 * which breaks on reparented orphans.
 *
 * Runtime guard (round-2 F2): the sweep NEVER signals the orchestrator's own
 * group. It skips + warns when the spawn was non-detached (the child shares
 * the parent's pgid), when disabled (TASK_SWEEP=0 / SUBAGENT_SWEEP=0 safety
 * valve — `*_DETACHED=0` implies `*_SWEEP=0`), or when the target pgid equals
 * the parent's own pgid (identity check via getPgid(process.pid)).
 *
 * setsid-escape residual (F9d): a grandchild that escapes to its own
 * session/group leaves the swept pgid — the helper cannot see or kill it. The
 * complementary catch is the caller-level `pgrep -f <marker-nonce>` argv
 * pattern (the dispatch nonce is env-carried into the child). Verify-empty
 * failures (survivors after SIGKILL) log a warning and resolve WITH warning —
 * they never throw and never block the settle.
 *
 * #195 note: a killed mid-write worker can leave `index.lock` / partial
 * worktree state behind — run the #195 worktree-recovery path before
 * re-dispatching into that worktree (doc-level coupling, no code dependency).
 *
 * ponytail: single file, no dependencies beyond Node.js built-ins.
 * Cross-platform: macOS + Linux (pgrep/ps).
 */

import { execSync } from "node:child_process";
import { parsePidList } from "./tree-kill.js";

const EXEC_TIMEOUT_MS = 2000;

/** The process-group id of `pid` via `ps -o pgid= -p <pid>` (macOS + Linux;
 * Node exposes no process.getpgid). Null on failure / dead pid. */
export function getPgid(pid: number): number | null {
	if (!Number.isInteger(pid) || pid <= 1) return null;
	try {
		const out = execSync(`ps -o pgid= -p ${pid}`, { timeout: EXEC_TIMEOUT_MS, encoding: "utf-8" }).trim();
		const n = Number(out);
		return Number.isInteger(n) && n > 0 ? n : null;
	} catch {
		return null;
	}
}

/** List the member pids of process group `pgid` via `pgrep -g` (macOS +
 * Linux). pgrep exits 1 with no output when the group is empty/dead — that is
 * an empty list, not an error. Returns [] on tool failure. */
export function listPgid(pgid: number): number[] {
	if (!Number.isInteger(pgid) || pgid <= 1) return [];
	try {
		const out = execSync(`pgrep -g ${pgid}`, { timeout: EXEC_TIMEOUT_MS, encoding: "utf-8" });
		return parsePidList(out);
	} catch {
		return [];
	}
}

/**
 * Signal every member of process group `pgid` via `process.kill(-pgid,
 * signal)` (ESRCH swallowed — the group may already be gone). Fallback: list
 * the group via `pgrep -g` and signal each pid individually (covers platforms
 * where negative-pid kills are unavailable).
 */
export function killProcessGroup(pgid: number, signal: NodeJS.Signals = "SIGTERM"): void {
	if (!Number.isInteger(pgid) || pgid <= 1) return;
	try {
		process.kill(-pgid, signal);
	} catch {
		// ESRCH (group gone) or an unavailable negative-pid kill — per-pid fallback.
		for (const pid of listPgid(pgid)) {
			try {
				process.kill(pid, signal);
			} catch {
				// Already dead — ignore.
			}
		}
	}
}

export interface SweepOptions {
	/** TERM signal for the first phase (default SIGTERM). */
	signal?: NodeJS.Signals;
	/** Grace between TERM and KILL (default 5000). */
	timeoutMs?: number;
	/** False when the caller spawned NON-detached (the child shares the
	 * orchestrator's pgid) — the sweep skips + warns (round-2 F2 guard). */
	detached?: boolean;
	/** True when the tool-level opt-out env is set (TASK_SWEEP=0 /
	 * SUBAGENT_SWEEP=0) — disables the settle-path sweep ENTIRELY. */
	disabled?: boolean;
	/** Test hooks (armExitWatchdog `kill` injectable precedent): override the
	 * group signal/list primitives. Defaults are the real killProcessGroup /
	 * listPgid. */
	killGroup?: (pgid: number, signal: NodeJS.Signals) => void;
	listGroup?: (pgid: number) => number[];
}

export interface SweepResult {
	ok: boolean;
	/** Present when the sweep was skipped (guard / opt-out) — the reason. */
	skipped?: string;
	/** Member pids still alive after SIGKILL (verify-empty failure, F9d). */
	survivors: number[];
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Sweep process group `pgid`: guard → `pgrep -g` → SIGTERM → wait timeoutMs →
 * SIGKILL → verify `pgrep -g` empty. Never throws; verify-empty failures
 * resolve `{ ok: false, survivors }` with a warning (F9d). Skipped (guard /
 * opt-out) resolves `{ ok: false, skipped }` with a warning — the parent's
 * own group is NEVER signaled (round-2 F2).
 *
 * Callers run this fire-and-forget AFTER the dispatch resolves — sweep
 * latency never counts against the resolve indicator (F3).
 */
export async function sweepProcessGroup(pgid: number, opts: SweepOptions = {}): Promise<SweepResult> {
	const { signal = "SIGTERM", timeoutMs = 5000, detached, disabled } = opts;
	const killGroup = opts.killGroup ?? killProcessGroup;
	const listGroup = opts.listGroup ?? listPgid;

	if (disabled) {
		console.error(`[process-sweep] settle-path sweep DISABLED (safety valve) — skipping pgid ${pgid}`);
		return { ok: false, skipped: "disabled", survivors: [] };
	}
	if (detached === false) {
		console.error(
			`[process-sweep] non-detached spawn — skipping pgid ${pgid} — the child shares the orchestrator's process group; NEVER signal it (TASK_DETACHED=0 / SUBAGENT_DETACHED=0)`,
		);
		return { ok: false, skipped: "non-detached", survivors: [] };
	}
	const ownPgid = getPgid(process.pid);
	if (ownPgid !== null && pgid === ownPgid) {
		console.error(`[process-sweep] REFUSED — pgid ${pgid} is the orchestrator's OWN process group — never signal it`);
		return { ok: false, skipped: "parent-pgid", survivors: [] };
	}

	killGroup(pgid, signal);
	await sleep(timeoutMs);
	killGroup(pgid, "SIGKILL");

	// Verify-empty with a short poll — SIGKILL delivery + process-table
	// teardown can lag a few hundred ms; a false "survivor" here would mark a
	// clean sweep as failed. Survivors that persist past the poll are real
	// (setsid-escaped / unkillable members) — F9d.
	let survivors: number[] = [];
	for (let i = 0; i < 5; i++) {
		survivors = listGroup(pgid);
		if (survivors.length === 0) break;
		await sleep(200);
	}
	if (survivors.length > 0) {
		console.warn(
			`[process-sweep] verify-empty FAILED — ${survivors.length} survivor(s) remain in pgid ${pgid}: ${survivors.join(", ")} (setsid-escaped or unkillable member). Complementary catch: pgrep -f <marker-nonce>. Also check for index.lock / partial worktree state before re-dispatching into that worktree (#195).`,
		);
		return { ok: false, survivors };
	}
	return { ok: true, survivors: [] };
}
