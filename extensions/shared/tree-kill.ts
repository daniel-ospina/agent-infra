/**
 * tree-kill.ts — recursively kill a process tree.
 *
 * Used by the subagent extension (#137) to reap orphaned MCP server
 * processes when a sub-agent is aborted or times out: a sub-agent's own
 * `process.on("exit")` cleanup (mcp-client transport kill) only runs during
 * a graceful SIGTERM shutdown, and only if MCP disconnects complete within
 * the 5s window before SIGKILL. treeKill walks the parent-PID tree
 * (depth-first, children before parents) so MCP servers spawned by the
 * sub-agent die even when their parent's cleanup never runs.
 *
 * ponytail: single file, no dependencies beyond Node.js built-ins.
 * Cross-platform: macOS (pgrep), Linux (pgrep), fallback to ps.
 */

import { execSync } from "node:child_process";

/** #209: pgrep/ps cap on the kill path — env-overridable
 * (TREE_KILL_EXEC_TIMEOUT_MS, default 5s; invalid/absent/non-positive →
 * default). A watchdog that fires but cannot kill leaves a zombie — the cap
 * must be generous and deterministic (no retry: retry-under-load compounds
 * storms, and the kill-path cap must not retry). Read per call. */
export function execTimeoutMs(): number {
  const n = parseInt(process.env.TREE_KILL_EXEC_TIMEOUT_MS ?? "5000", 10);
  return Number.isInteger(n) && n > 0 ? n : 5000;
}

/** Parse whitespace/newline-separated PID output from pgrep/ps. */
export function parsePidList(output: string): number[] {
	return output
		.split(/\s+/)
		.map((s) => s.trim())
		.filter((s) => /^\d+$/.test(s))
		.map(Number);
}

/**
 * Direct children of `pid` via `pgrep -P` (macOS + Linux), falling back to
 * `ps -axo pid=,ppid=` (BSD-style, works on macOS and GNU/Linux — GNU's
 * `--ppid` flag is not available on macOS ps, so filtering is done here).
 * Returns [] when the tool is unavailable, errors, or the process has no
 * children (or no longer exists).
 */
export function getChildPids(pid: number): number[] {
	try {
		const result = execSync(`pgrep -P ${pid}`, { timeout: execTimeoutMs(), encoding: "utf-8" });
		return parsePidList(result);
	} catch {
		// pgrep not available, errored, or no children — try the ps fallback.
	}
	try {
		const result = execSync(`ps -axo pid=,ppid=`, { timeout: execTimeoutMs(), encoding: "utf-8" });
		const children: number[] = [];
		for (const line of result.split(/\n/)) {
			const m = line.trim().match(/^(\d+)\s+(\d+)$/);
			if (m && Number(m[2]) === pid) children.push(Number(m[1]));
		}
		return children;
	} catch {
		return [];
	}
}

/**
 * Recursively kill a process tree (children first, depth-first).
 *
 * Double-pass (plan R2): children spawned between the first listing and the
 * kill are caught by a second listing before the parent itself is killed.
 * A 2s execSync timeout bounds pgrep/ps hangs (plan R3); on failure the
 * parent is still signalled directly.
 *
 * Never throws: processes that are already dead raise ESRCH, which is
 * swallowed here (the caller may kill an already-exited PID racily).
 */
export function treeKill(pid: number, signal: NodeJS.Signals = "SIGTERM"): void {
	if (!Number.isInteger(pid) || pid <= 1) return;

	for (let pass = 0; pass < 2; pass++) {
		let children: number[] = [];
		try {
			children = getChildPids(pid);
		} catch {
			children = [];
		}
		for (const childPid of children) {
			treeKill(childPid, signal);
		}
	}

	try {
		process.kill(pid, signal);
	} catch {
		// Process already dead — ignore
	}
}
