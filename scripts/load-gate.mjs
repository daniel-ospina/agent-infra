#!/usr/bin/env node
/**
 * load-gate.mjs — shared load gate for batch wrappers (#209).
 *
 * One pure, env-overridable, CLI-consumable load gate for bash wrappers
 * (and the documented contract for future cross-repo consumers — swarm's
 * `state_machine.py` is the documented handoff, out of scope here).
 *
 * Signal: `os.loadavg()[0]` — the 1-min exponential average, I/O-inclusive.
 * loadavg includes tasks waiting on I/O (not just CPU runnable), which makes
 * it SENSITIVE to exactly the BGSAVE-storm class this gate targets (an
 * I/O-heavy save storm raises it). It is host-wide and trailing: blind to
 * cgroup quotas / VM steal / container neighbors — accepted for a same-host
 * fleet (see docs/ops/load-policy.md).
 *
 * macOS (Darwin) semantics: loadavg counts THREADS, so per-core readings run
 * higher on macOS than Linux (idle systems can show load > 1.0). Defaults are
 * calibrated to Linux; on macOS spurious SUSPENSION is the safe direction
 * (deferrals are loud and resumable). Set per-host env thresholds.
 *
 * Thresholds (per-core normalized, anchored to the wt-291 operating point —
 * load ~25 on 10 cores):
 *   LOAD_SUSPEND_THRESHOLD  default 2.5 × os.cpus().length  — suspend at ≥ this
 *   LOAD_RESUME_THRESHOLD   default 1.5 × os.cpus().length  — resume only below
 *   LOAD_GATE_MAX_WAIT_MIN  default 10                      — wrapper poll cap
 *                                                             (consumed by the WRAPPER;
 *                                                             0 = no poll)
 * Ordering clamp: `resume > suspend` → `resume = suspend` (safe direction —
 * tightens the resume point; preserves the LOAD_SUSPEND_THRESHOLD=0
 * always-defer hook). Validity: absent/empty/non-finite/negative → default;
 * `0` is VALID for suspend/resume/maxWaitMin (the deterministic-defer test
 * hook).
 *
 * Exit-code contract (pinned): 0 = proceed / 2 = usage error / 3 = deferred —
 * re-invoke (the wrapper's defer exit; distinct from 0/1/2 so invokers cannot
 * mistake it for success). Exit 4 is reserved for any future abort-after-
 * trigger semantics and is never used by this issue.
 *
 * Usage:
 *   node scripts/load-gate.mjs check [--deferred] [--json] [--force]
 *
 * Hysteresis is wired into the CLI: plain `check` gates on `shouldSuspend`
 * (exit 0 while load1 < suspend, exit 3 at load1 ≥ suspend — the entry-gate
 * rule); `check --deferred` (the wrapper's bounded-poll re-check context; the
 * poll loop itself lives in the WRAPPER) gates on `shouldResume` — exit 0 ONLY
 * when load1 < resume (a deferred batch stays deferred until load drops BELOW
 * resume; a single-sample dip never thrash-resumes). `--force` sets
 * LOAD_GATE_FORCE=1 (the env var alone also works) → exit 0 unconditionally.
 */

import os from "node:os";
import { pathToFileURL } from "node:url";

export const DEFAULT_SUSPEND_MULT = 2.5;
export const DEFAULT_RESUME_MULT = 1.5;

/** 1-min loadavg (real host signal — tests MUST inject via run()'s deps). */
export function readLoad1() {
  return os.loadavg()[0];
}

/** Valid env threshold: absent/empty/non-finite/negative → default; `0` valid. */
function parseThreshold(raw, dflt) {
  if (raw === undefined || raw === null) return dflt;
  const s = String(raw).trim();
  if (s === "") return dflt;
  const n = Number(s);
  return Number.isFinite(n) && n >= 0 ? n : dflt;
}

/** Config from env: per-core defaults + env overrides + ordering clamp. */
export function configFromEnv(env = process.env) {
  const cores = os.cpus().length;
  let suspend = parseThreshold(env.LOAD_SUSPEND_THRESHOLD, Math.round(DEFAULT_SUSPEND_MULT * cores));
  let resume = parseThreshold(env.LOAD_RESUME_THRESHOLD, Math.round(DEFAULT_RESUME_MULT * cores));
  // Ordering clamp (safe direction): resume never above suspend — preserves
  // the LOAD_SUSPEND_THRESHOLD=0 always-defer hook.
  if (resume > suspend) resume = suspend;
  return { suspend, resume, cores };
}

/** Suspend when load1 ≥ suspend (entry-gate rule). */
export function shouldSuspend(load1, cfg) {
  return load1 >= cfg.suspend;
}

/** Resume only when load1 < resume (hysteresis — no single-dip thrash). */
export function shouldResume(load1, cfg) {
  return load1 < cfg.resume;
}

/** Plain check verdict = shouldSuspend: "go" | "suspend". */
export function check(load1, cfg) {
  return shouldSuspend(load1, cfg) ? "suspend" : "go";
}

const USAGE = `Usage: node scripts/load-gate.mjs check [--deferred] [--json] [--force]

  check        Gate on the current 1-min loadavg.
  --deferred   Re-check context (wrapper bounded poll): exit 0 ONLY when
               load < LOAD_RESUME_THRESHOLD (hysteresis resume rule).
  --json       Print {load1, suspend, resume, verdict, thresholds} to stdout.
  --force      Bypass the gate (sets LOAD_GATE_FORCE=1; the env var alone
               also works) → exit 0 unconditionally.

Exit codes: 0 = proceed, 2 = usage error, 3 = deferred — re-invoke.
Env: LOAD_SUSPEND_THRESHOLD (default 2.5×cores), LOAD_RESUME_THRESHOLD
     (default 1.5×cores), LOAD_GATE_FORCE.`;

/**
 * CLI dispatcher with injectable deps (the test seam — no global state).
 * `deps = { env, getLoad1, log }`; `log` defaults to console.error (stderr).
 * Returns the exit code; the main entry calls process.exit(code).
 */
export function run(argv, deps) {
  const { env = process.env, getLoad1 = readLoad1, log = console.error } = deps ?? {};
  const args = argv.slice(2);
  if (args[0] !== "check") {
    log("Error: missing/unknown subcommand — expected 'check'");
    log(USAGE);
    return 2;
  }
  const flags = args.slice(1);
  const unknown = flags.filter((f) => !["--deferred", "--json", "--force"].includes(f));
  if (unknown.length > 0) {
    log(`Error: unknown flag '${unknown[0]}'`);
    log(USAGE);
    return 2;
  }
  const deferred = flags.includes("--deferred");
  const json = flags.includes("--json");
  const force = flags.includes("--force") || env.LOAD_GATE_FORCE === "1";

  if (force) {
    const load1 = getLoad1();
    if (json) {
      const cfg = configFromEnv(env);
      console.log(JSON.stringify({ load1, suspend: cfg.suspend, resume: cfg.resume, verdict: "go", thresholds: { suspend: cfg.suspend, resume: cfg.resume } }));
    }
    return 0;
  }

  const cfg = configFromEnv(env);
  const load1 = getLoad1();
  const go = deferred ? shouldResume(load1, cfg) : !shouldSuspend(load1, cfg);
  const verdict = go ? "go" : "deferred";
  if (json) {
    console.log(JSON.stringify({ load1, suspend: cfg.suspend, resume: cfg.resume, verdict, thresholds: { suspend: cfg.suspend, resume: cfg.resume } }));
  } else {
    log(`[load-gate] ${verdict} (load1=${load1}, suspend=${cfg.suspend}, resume=${cfg.resume})`);
  }
  return go ? 0 : 3;
}

const isMain =
  process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url;
if (isMain) {
  process.exit(run(process.argv, {}));
}
