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
 * Runtime guard (round-2 F2, hardened by #1074): the sweep NEVER signals the
 * orchestrator's own group, and the ONLY thing that AUTHORISES signalling a
 * group is a construction proof — the caller passed `spawnedPid` (the pid its
 * own `spawn({ detached: true })` call returned) and the target pgid IS that
 * pid. POSIX `setsid` makes the child a new session + group leader, so its
 * group id is its own pid; that pid was freshly allocated to a child of this
 * process and cannot be the orchestrator's own pgid while the orchestrator
 * lives. `spawnedPid !== process.pid` is a second, independent conjunct.
 *
 * A MEASUREMENT never authorises — it may only REFUSE, and that refusal runs
 * on EVERY sweep (proven targets included), so the proof and the own-group
 * refusal are independent defences rather than one short-circuiting the other.
 * `ps` under load can time out on a LIVE pid and return null (#1074);
 * pre-#1074 that null skipped the refusal and let `killGroup` proceed — a
 * fail-open. Post-#1074 a null refuses nothing (the construction proof alone
 * gates the signal), while a SUCCESSFUL reading that equals `pgid` refuses even
 * a proven target — so a caller that passed its own pgid as `spawnedPid` still
 * cannot signal its own group. A wrong, stale or aliased reading can therefore
 * only cause a false REFUSE (fail-closed), never a false signal. There is
 * deliberately no cache of the own pgid: caching a wrong-but-valid reading
 * would make the error permanent, and the probe can never authorise, so its
 * cost buys safety.
 *
 * The five skip reasons: `disabled` (TASK_SWEEP=0 / SUBAGENT_SWEEP=0 safety
 * valve — `*_DETACHED=0` implies `*_SWEEP=0`), `non-detached` (the child
 * shares the parent's pgid), `invalid-pgid` (non-integer or <= 1 — never
 * `kill(-1, ·)` broadcast / `kill(0, ·)`), `parent-pgid` (measured equal to
 * the orchestrator's own group), `identity-unverified` (not proven, and the
 * measurement is unavailable or unequal).
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

/** #1074: pgrep/ps cap on the sweep path — env-overridable (default 5s;
 * invalid/absent/non-positive → default). Mirrors tree-kill's `execTimeoutMs`
 * (extensions/shared/tree-kill.ts:18-27), which caps the SAME binaries on the
 * kill path; the cap only bites when `ps`/`pgrep` themselves hang (a healthy
 * probe is ~30-70ms). A GETTER, not a const: the only way to force a
 * deterministic timeout in a test. Kept at 2s until #1074 — the issue's whole
 * evidence is that 2s is too tight under load. */
export function sweepExecTimeoutMs(): number {
	const n = parseInt(process.env.PROCESS_SWEEP_EXEC_TIMEOUT_MS ?? "5000", 10);
	return Number.isInteger(n) && n > 0 ? n : 5000;
}

/** The process-group id of `pid` via `ps -o pgid= -p <pid>` (macOS + Linux;
 * Node exposes no process.getpgid).
 *
 * ⚠️ LOSSY BY CONTRACT (#1074): `null` means "dead pid OR `ps` failed/timed
 * out" — the two are NOT distinguishable here. Under load a `ps` spawn can
 * exceed the cap on a LIVE pid, so a caller that reads `null` as "gone" is
 * reading a failed measurement as a fact. That is exactly how the own-pgid
 * guard used to fail open. Use it only where `null` is safe either way (a
 * refusal, a skip, a fallback), and NEVER to authorise signalling a group.
 *
 * Prefer `groupExists(pgid)` for a group liveness/emptiness VERDICT (spawn-free,
 * nothing to time out); read `null` here as "not measured OR absent", never as
 * one of the two. NOT deprecated: this remains the only pid→pgid mapping in the
 * module (it is how a caller learns the `pgid` to sweep at all) and the
 * own-group refusal in `sweepProcessGroup` is built on it — do not delete it. */
export function getPgid(pid: number): number | null {
	if (!Number.isInteger(pid) || pid <= 1) return null;
	try {
		const out = execSync(`ps -o pgid= -p ${pid}`, { timeout: sweepExecTimeoutMs(), encoding: "utf-8" }).trim();
		const n = Number(out);
		return Number.isInteger(n) && n > 0 ? n : null;
	} catch {
		return null;
	}
}

/** List the member pids of process group `pgid` via `pgrep -g` (macOS +
 * Linux). pgrep exits 1 with no output when the group is empty/dead — that is
 * an empty list, not an error.
 *
 * ⚠️ LOSSY BY CONTRACT (#1074): `[]` means "empty group OR `pgrep` failed",
 * and a `pgrep` timeout is therefore indistinguishable from a verified-empty
 * group. That conflation is what made `sweepProcessGroup`'s verify phase
 * return `{ ok: true }` on a FAILED probe. The verify verdict no longer uses
 * this function (#1074: it uses the spawn-free `groupExists`); here `[]`
 * remains a safe "nothing to name / nothing to kill" answer.
 *
 * Use `groupExists(pgid)` for an emptiness VERDICT; keep `[]` here as "no
 * members known". NOT deprecated: `killProcessGroup`'s per-pid fallback still
 * needs the member list — do not delete it. */
export function listPgid(pgid: number): number[] {
	if (!Number.isInteger(pgid) || pgid <= 1) return [];
	try {
		const out = execSync(`pgrep -g ${pgid}`, { timeout: sweepExecTimeoutMs(), encoding: "utf-8" });
		return parsePidList(out);
	} catch {
		return [];
	}
}

/** #1074: the errno DECISION behind `groupExists`, split out because it is the
 * branch that makes the verify verdict fail-CLOSED and is otherwise untestable
 * (forcing a real EPERM needs a second user). Only `ESRCH` proves the group is
 * gone; every other outcome — `EPERM` (the group exists but is not ours to
 * signal), `EACCES`, an errno-less throw, or `undefined` — must read as STILL
 * PRESENT. Never rewrite this as a truthiness test on `code`: `undefined` would
 * then mean "gone" and a refused probe would report a clean sweep. */
export function isGroupAbsent(errno: string | undefined): boolean {
	return errno === "ESRCH";
}

/** #1074 A4: spawn-free process-group EXISTENCE probe — the verify-empty
 * verdict, with no subprocess and therefore no timeout to confuse with an
 * empty group. `process.kill(-pgid, 0)` sends NO signal (signal 0): `ESRCH`
 * means no such process group (its last member left) ⇒ empty; success or
 * `EPERM` (exists but not ours to signal) ⇒ at least one member remains.
 *
 * The `pgid <= 1` guard is MANDATORY, not defensive: `process.kill(-1, 0)` is
 * a broadcast probe over EVERY process we may signal, and `process.kill(0, 0)`
 * targets the caller's own group. */
export function groupExists(pgid: number): boolean {
	if (!Number.isInteger(pgid) || pgid <= 1) return false;
	try {
		process.kill(-pgid, 0);
		return true;
	} catch (e) {
		return !isGroupAbsent((e as NodeJS.ErrnoException).code);
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
		// A failed `pgrep` here yields [] and therefore signals nobody: the safe
		// (fail-closed) direction. #1074: it can no longer masquerade as a clean
		// sweep, because `sweepProcessGroup`'s verdict is the spawn-free
		// `groupExists` probe, which stays true while any member lives.
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
	/** #1074 A3 — the AUTHORISATION for signalling. The pid returned by the
	 * caller's own `spawn({ detached: true })` call (`proc.pid`), i.e. the pid
	 * of the setsid child whose group is `pgid`. A detached child IS its own
	 * group leader, so `spawnedPid === pgid` proves the target group is one
	 * this process created and cannot be the orchestrator's own.
	 *
	 * NOT the pgid — passing `pgid` itself here (or a pgid-shaped variable)
	 * makes the proof a tautology. Without a valid `spawnedPid` the sweep is
	 * REFUSED (`identity-unverified`): a measurement never authorises a signal. */
	spawnedPid?: number;
	/** True when the tool-level opt-out env is set (TASK_SWEEP=0 /
	 * SUBAGENT_SWEEP=0) — disables the settle-path sweep ENTIRELY. */
	disabled?: boolean;
	/** Test hooks (armExitWatchdog `kill` injectable precedent): override the
	 * group signal/list primitives. Defaults are the real killProcessGroup /
	 * listPgid. */
	killGroup?: (pgid: number, signal: NodeJS.Signals) => void;
	listGroup?: (pgid: number) => number[];
	/** #1074 A4 test hook: override the spawn-free group-existence VERDICT.
	 * Defaults to the real `groupExists`; `pgrep` (`listGroup`) only names
	 * survivors now, so injecting it can no longer fake a clean sweep. */
	existsGroup?: (pgid: number) => boolean;
	/** #1074 test hook: override the own-group MEASUREMENT (`getPgid(process.pid)`).
	 * Blast radius is safe BY DIRECTION: the measurement is refusal-only, so an
	 * injected value can add or remove a REFUSAL but can never AUTHORISE a signal
	 * (the construction proof is a separate conjunct). It exists so the refusal
	 * branch — the module's central invariant — can be pinned deterministically,
	 * without depending on `ps` answering under load. */
	ownPgid?: () => number | null;
}

export interface SweepResult {
	ok: boolean;
	/** Present when the sweep was skipped (guard / opt-out) — the reason. */
	skipped?: string;
	/** Member pids still alive after SIGKILL (verify-empty failure, F9d). EMPTY
	 * when the group is confirmed present but the naming probe (`pgrep`) was
	 * unmeasured — a verify failure is `ok: false` with NO `skipped`, never an
	 * empty `survivors` on its own. */
	survivors: number[];
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Sweep process group `pgid`: guard → SIGTERM → wait timeoutMs → SIGKILL →
 * verify the group no longer EXISTS. Never throws; verify failures resolve
 * `{ ok: false, survivors }` with a warning (F9d). Skipped (guard / opt-out)
 * resolves `{ ok: false, skipped }` with a warning — the parent's own group is
 * NEVER signaled (round-2 F2).
 *
 * The guard (#1074): signalling is AUTHORISED only by the construction proof
 * `detached === true && spawnedPid is a valid pid !== process.pid &&
 * pgid === spawnedPid` (see SweepOptions.spawnedPid). Anything else is
 * refused: measured-equal to the orchestrator's own group (`parent-pgid`) or
 * unprovable (`identity-unverified`). The own-group measurement is evaluated on
 * EVERY sweep — a successful match refuses even a proven target — and can only
 * refuse, never authorise, so a `ps` timeout under load cannot fail open.
 *
 * The verify verdict is the spawn-free `groupExists` (#1074 A4) — no
 * subprocess, so a failed `pgrep` can no longer be read as "verified empty";
 * `pgrep` is only asked to NAME the survivors for the warning.
 *
 * Callers run this fire-and-forget AFTER the dispatch resolves — sweep
 * latency never counts against the resolve indicator (F3).
 */
export async function sweepProcessGroup(pgid: number, opts: SweepOptions = {}): Promise<SweepResult> {
	const { signal = "SIGTERM", timeoutMs = 5000, detached, disabled } = opts;
	const killGroup = opts.killGroup ?? killProcessGroup;
	const listGroup = opts.listGroup ?? listPgid;
	const existsGroup = opts.existsGroup ?? groupExists;
	const ownPgidOf = opts.ownPgid ?? (() => getPgid(process.pid));

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
	// Invalid/trivial group ids are refused BEFORE any signal primitive is
	// reachable: `process.kill(-1, ·)` is a broadcast over every process we may
	// signal and `process.kill(0, ·)` targets the caller's own group.
	if (!Number.isInteger(pgid) || pgid <= 1) {
		console.error(`[process-sweep] REFUSED — pgid ${pgid} is not a usable process-group id — never signal it`);
		return { ok: false, skipped: "invalid-pgid", survivors: [] };
	}

	// #1074: the own-group measurement runs on EVERY sweep and is REFUSAL-ONLY.
	// It deliberately does NOT sit inside the `!proven` branch: a caller that
	// passed its own pgid as `spawnedPid` would then satisfy the construction
	// proof AND skip this refusal, leaving the invariant "never signal the
	// orchestrator's own group" resting on caller-supplied numbers alone. The
	// measurement answers ONE question — "is this the orchestrator's own
	// group?" — and its yes refuses unconditionally, while its "could not
	// measure" (null) refuses nothing and still cannot authorise (the proof
	// below is the only authorisation).
	const ownPgid = ownPgidOf();
	if (ownPgid !== null && pgid === ownPgid) {
		console.error(`[process-sweep] REFUSED — pgid ${pgid} is the orchestrator's OWN process group — never signal it`);
		return { ok: false, skipped: "parent-pgid", survivors: [] };
	}

	// #1074 A3 — the only AUTHORISATION: the target group is the one our own
	// detached child created (setsid ⇒ pgid === the child's pid). No measurement
	// is consulted here, so a probe blackout cannot disable a legitimate sweep.
	const proven =
		detached === true &&
		Number.isInteger(opts.spawnedPid) &&
		(opts.spawnedPid as number) > 1 &&
		// A fork cannot return the parent's pid — a second, independent conjunct.
		opts.spawnedPid !== process.pid &&
		pgid === opts.spawnedPid;

	if (!proven) {
		console.error(
			`[process-sweep] REFUSED — pgid ${pgid} is not provably the caller's own detached-child group (detached=${detached}, spawnedPid=${opts.spawnedPid ?? "<missing>"}) — refusing to signal (fail-closed, #1074)`,
		);
		return { ok: false, skipped: "identity-unverified", survivors: [] };
	}

	killGroup(pgid, signal);
	await sleep(timeoutMs);
	killGroup(pgid, "SIGKILL");

	// Verify-empty with a short poll — SIGKILL delivery + process-table
	// teardown can lag a few hundred ms; a false "survivor" here would mark a
	// clean sweep as failed. Survivors that persist past the poll are real
	// (setsid-escaped / unkillable members) — F9d.
	//
	// #1074 A4: the VERDICT is the spawn-free `existsGroup(pgid)` — it cannot
	// time out, so a failed `pgrep` can never be read as "verified empty".
	// `listGroup` is now ADVISORY ONLY (naming the survivors for the warning).
	// Poll the spawn-free verdict; `listGroup` is consulted ONCE afterwards and
	// only to NAME survivors in the warning. #1074: naming inside the loop made
	// every iteration a blocking `execSync` (5 × the cap during a `pgrep` storm)
	// for a value that only ever reached a log line.
	for (let i = 0; i < 5; i++) {
		if (!existsGroup(pgid)) return { ok: true, survivors: [] };
		await sleep(200);
	}
	if (!existsGroup(pgid)) return { ok: true, survivors: [] };
	const survivors = listGroup(pgid);
	console.warn(
		`[process-sweep] verify-empty FAILED — member(s) remain in pgid ${pgid}` +
			(survivors.length > 0
				? `: ${survivors.join(", ")}`
				: " (pgrep unmeasured — names unavailable)") +
			` (setsid-escaped or unkillable member). Complementary catch: pgrep -f <marker-nonce>. Also check for index.lock / partial worktree state before re-dispatching into that worktree (#195).`,
	);
	return { ok: false, survivors };
}
