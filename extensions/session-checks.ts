// session-checks.ts — #432 (issue #431 Option C): run hub-state-check +
// skill-lint-oracle from pi's TCC-approved session_start instead of launchd.
//
// Why: macOS TCC blocks launchd-spawned processes from reading ~/Documents
// (EPERM — bash, git, node AND python; #427 probe), and hub-state-check
// (repo drift) + skill-lint-oracle (skill-lint drift lock) inherently read
// the repos there. Interactive pi sessions run inside an approved tree, so
// the same scripts work from session_start. Age gates preserve the former
// cadence (hub 6h, oracle 24h) while pi runs; silent when fresh.
//
// Hub repo surface = TORTOISE_REPO / sibling tortoise ONLY — parity with the
// retired launchd job, which was deliberately tortoise-only: agent-infra is
// #99-exempt from hub discipline (its in-main dirt is sanctioned work;
// main-worktree-guard warns, never flags). Add repos via SESSION_CHECKS_REPOS.
//
// Safety:
//   - never crashes session startup (all errors swallowed → log line)
//   - sub-agents (print mode) never run checks
//   - mkdir-lock per check: parallel pi sessions don't double-run; stale
//     locks (>30 min — above the oracle's 900s budget) are taken over (a
//     crashed session can't wedge the gate)
//   - state epochs recorded after every attempt (bounded re-runs even when a
//     check fails — a drift state re-probes on cadence, not every session)
//
// Env knobs (all optional):
//   SESSION_CHECKS_OFF=1      disable entirely
//   SESSION_CHECKS_HUB_H      hub staleness window in hours (default 6; 0 = never auto-run)
//   SESSION_CHECKS_ORACLE_H   oracle staleness window in hours (default 24; 0 = never auto-run)
//   SESSION_CHECKS_REPOS      extra hub repos (space-separated, absolute)
//   SESSION_CHECKS_STATE      state dir (default ~/.pi/agent/state)
//   LOAD_GATE_MAX_WAIT_MIN=0  (set by us) oracle defers immediately on a
//                             loaded machine instead of polling 10 min inline
//
// The corrupted-jobs' former launchd templates are retired via
// templates/launchd/RETIRED (install-launchd.sh unloads them on machines
// that installed them pre-retirement).

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { isPrintMode } from "./shared/print-mode.js";

export const HUB_H_DEFAULT = 6;
export const ORACLE_H_DEFAULT = 24;
const LOCK_STALE_MS = 30 * 60 * 1000; // > oracle budget (900s) so a live run is never stolen
const HUB_TIMEOUT_MS = 120_000;
const ORACLE_TIMEOUT_MS = 900_000; // > the oracle's own load-gate poll ceiling (~600s) + run

// ── pure gate helpers (unit-testable) ──────────────────────────────────

/** A check is due when its last run epoch is older than `hours` (seconds). */
export function due(nowSec: number, lastEpoch: number, hours: number): boolean {
  if (hours <= 0) return false; // window disabled → never auto-run
  return nowSec - lastEpoch >= hours * 3600;
}

/** Last run epoch from the state dir (0 = never ran). */
export function lastRunEpoch(dir: string, name: string): number {
  try {
    const n = Number(readFileSync(join(dir, `${name}.last`), "utf8"));
    return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0;
  } catch {
    return 0;
  }
}

/**
 * Default hub repos: TORTOISE_REPO env → sibling tortoise → extra repos.
 * Deliberately NOT agent-infra: the retired launchd hub job was tortoise-only
 * — agent-infra is #99-exempt from hub discipline (its in-main dirt is
 * sanctioned, normal work; main-worktree-guard warns rather than flags).
 */
export function resolveHubRepos(infraPath: string): string[] {
  const repos: string[] = [];
  const envRepo = process.env.TORTOISE_REPO;
  if (envRepo && existsSync(envRepo)) repos.push(envRepo);
  const sibling = join(dirname(infraPath), "tortoise");
  if (existsSync(sibling)) repos.push(sibling);
  const extra = process.env.SESSION_CHECKS_REPOS;
  if (extra) {
    for (const r of extra.split(/\s+/)) {
      if (r && existsSync(r)) repos.push(r);
    }
  }
  return [...new Set(repos)];
}

// ── exec seam ───────────────────────────────────────────────────────────

export interface ExecResult {
  code: number; // -1 = timed out / spawned-with-error (no exit code)
  stdout: string;
  stderr: string;
  timedOut: boolean;
}
export type ExecFn = (
  cmd: string,
  args: string[],
  opts: { cwd?: string; timeoutMs: number; env?: Record<string, string | undefined> }
) => Promise<ExecResult>;

export function execFileAsync(cmd: string, args: string[], opts: { cwd?: string; timeoutMs: number; env?: Record<string, string | undefined> }): Promise<ExecResult> {
  return new Promise((resolve) => {
    execFile(cmd, args, { cwd: opts.cwd, timeout: opts.timeoutMs, maxBuffer: 32 * 1024 * 1024, encoding: "utf8", env: opts.env ?? process.env }, (err, stdout, stderr) => {
      if (!err) {
        resolve({ code: 0, stdout: stdout ?? "", stderr: stderr ?? "", timedOut: false });
        return;
      }
      const e = err as NodeJS.ErrnoException & { killed?: boolean };
      resolve({
        code: typeof e.code === "number" ? e.code : -1,
        stdout: stdout ?? "",
        stderr: stderr ?? "",
        timedOut: Boolean(e.killed),
      });
    });
  });
}

// ── orchestration ───────────────────────────────────────────────────────

export interface SessionChecksOptions {
  infraPath: string;
  state?: string;
  nowSec?: number;
  hubHours?: number;
  oracleHours?: number;
  repos?: string[]; // explicit hub repos (default: resolveHubRepos)
  exec?: ExecFn; // seam for tests
  log?: (line: string) => void;
}

export interface SessionChecksSummary {
  ran: string[]; // names of checks executed this pass
  lines: string[]; // human-readable log lines (caller prefixes)
}

function tryLock(dir: string, name: string): boolean {
  const lockDir = join(dir, "locks");
  try {
    mkdirSync(lockDir, { recursive: true });
  } catch {
    return false; // lock dir unwritable — degrade to a skip, never a hook error
  }
  const lock = join(lockDir, `${name}.lock`);
  try {
    mkdirSync(lock, { recursive: false });
    return true;
  } catch {
    // held — is it stale? (a crashed session leaves the lock behind)
    try {
      if (Date.now() - statSync(lock).mtimeMs > LOCK_STALE_MS) {
        rmSync(lock, { recursive: true, force: true });
        mkdirSync(lock, { recursive: false });
        return true;
      }
    } catch {
      /* raced — treat as held */
    }
    return false;
  }
}

function releaseLock(dir: string, name: string): void {
  try {
    rmSync(join(dir, "locks", `${name}.lock`), { recursive: true, force: true });
  } catch {
    /* best effort */
  }
}

function recordRun(dir: string, name: string, epochSec: number): void {
  try {
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, `${name}.last`), String(epochSec));
  } catch {
    /* state dir unwritable — cadence degrades to every-session; acceptable */
  }
}

async function runGated(
  dir: string,
  name: string,
  hours: number,
  summary: SessionChecksSummary,
  exec: ExecFn,
  epochSec: number,
  doRun: () => Promise<{ code: number; tail: string; elapsedS: number }>
): Promise<void> {
  if (!due(epochSec, lastRunEpoch(dir, name), hours)) return; // fresh — silent
  if (!tryLock(dir, name)) {
    summary.lines.push(`${name}: skipped (another session is running it)`);
    return;
  }
  try {
    const { code, tail, elapsedS } = await doRun();
    summary.ran.push(name);
    if (code === 0) {
      recordRun(dir, name, epochSec); // success → full window before re-probe
      summary.lines.push(`${name}: PASS (${elapsedS.toFixed(1)}s)`);
    } else if (code === 3) {
      // cron-quality-gates convention: 3 = load-gate DEFERRED — the check did
      // NOT run (system too loaded). Do NOT burn the epoch: retry next session.
      summary.lines.push(`${name}: DEFERRED (load gate — retry next session)${tail ? ` — ${tail}` : ""}`);
    } else {
      // Record the ATTEMPT (not just success) so a failing check re-probes on
      // cadence instead of every session start.
      recordRun(dir, name, epochSec);
      const why = tail ? ` — ${tail}` : "";
      summary.lines.push(`${name}: ${code === -1 ? "TIMEOUT/ERROR" : `FAIL rc=${code}`}${why}`);
    }
  } finally {
    releaseLock(dir, name);
  }
}

export async function runSessionChecks(opts: SessionChecksOptions): Promise<SessionChecksSummary> {
  const dir = opts.state ?? join(homedir(), ".pi", "agent", "state");
  const summary: SessionChecksSummary = { ran: [], lines: [] };
  const now = Math.floor((opts.nowSec ?? Date.now() / 1000));
  const exec = opts.exec ?? execFileAsync;
  const infra = opts.infraPath;

  const hubScript = join(infra, "scripts", "checkout-hygiene", "hub-state-check.sh");
  const oracleScript = join(infra, "scripts", "cron-quality-gates.sh");
  if (!existsSync(hubScript) || !existsSync(oracleScript)) {
    summary.lines.push(`scripts missing under ${infra} — checks skipped`);
    return summary;
  }
  const repos = opts.repos ?? resolveHubRepos(infra);
  const hubArgs = [];
  if (repos.length === 0) {
    // Parity with the retired launchd job: tortoise-only surface by default.
    // Nothing resolved → skip the hub leg loudly rather than fall back to the
    // script's $PWD default (which could check agent-infra — #99-exempt).
    summary.lines.push("hub-state-check: skipped (no tortoise repo — set TORTOISE_REPO)");
  } else {
    for (const r of repos) hubArgs.push("--repo", r);
    hubArgs.push("--gh-report");
    await runGated(dir, "hub-state-check", opts.hubHours ?? HUB_H_DEFAULT, summary, exec, now, async () => {
      const s = Date.now();
      const res = await exec("bash", [hubScript, ...hubArgs], { timeoutMs: HUB_TIMEOUT_MS });
      const out = `${res.stdout}\n${res.stderr}`.trim();
      return { code: res.code, tail: out.split("\n").slice(-2).join(" ").slice(0, 240), elapsedS: (Date.now() - s) / 1000 };
    });
  }

  await runGated(dir, "skill-lint-oracle", opts.oracleHours ?? ORACLE_H_DEFAULT, summary, exec, now, async () => {
    const s = Date.now();
    const res = await exec("bash", [oracleScript, "oracle"], {
      cwd: infra,
      // Defer-immediately on a loaded machine: cron-quality-gates' inline
      // load-gate poll (default 10 min) would otherwise freeze session
      // start; rc=3 DEFERRED retries next session with no epoch burn.
      env: { ...process.env, LOAD_GATE_MAX_WAIT_MIN: "0" },
      timeoutMs: ORACLE_TIMEOUT_MS,
    });
    const out = `${res.stdout}\n${res.stderr}`.trim();
    return { code: res.code, tail: out.split("\n").slice(-1).join(" ").slice(0, 240), elapsedS: (Date.now() - s) / 1000 };
  });

  return summary;
}

// ── pi registration ──────────────────────────────────────────────────────

function numEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") return fallback; // absent/empty/blank → fallback (≠ 0!)
  const v = Number(raw);
  // >=0 passes through (0 = disable the window: never auto-run); invalid → fallback.
  return Number.isFinite(v) && v >= 0 ? v : fallback;
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async () => {
    const infra = process.env.AGENT_INFRA_PATH;
    if (!infra) return; // not configured — silent
    if (isPrintMode()) return; // sub-agents: no checks, no noise
    if (process.env.SESSION_CHECKS_OFF === "1") return;
    try {
      const summary = await runSessionChecks({
        infraPath: infra,
        state: process.env.SESSION_CHECKS_STATE || undefined, // advertised knob (unset → default)
        hubHours: numEnv("SESSION_CHECKS_HUB_H", HUB_H_DEFAULT),
        oracleHours: numEnv("SESSION_CHECKS_ORACLE_H", ORACLE_H_DEFAULT),
      });
      for (const line of summary.lines) console.log(`[session-checks] ${line}`);
    } catch (err) {
      // A session_start hook must never take pi down.
      console.warn(`[session-checks] hook error: ${err instanceof Error ? err.message : String(err)}`);
    }
  });
}
