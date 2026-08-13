/**
 * shared/print-mode.ts — print-mode (headless) detection for extensions.
 *
 * isPrintMode(): true when the process is running in print mode (headless
 * `pi -p` / `pi --print` / task sub-agents / background workers).
 *
 * #172/#228: pi NEVER sets PI_MODE (verified 2026-08-13 — pi parses -p/--print
 * into an internal flag in cli/args.js and exports nothing). Only
 * builtin-tools/swarm_daemon set PI_MODE for their OWN spawns. Therefore an
 * env-only check is dead code in bare `pi -p` runs, and extensions that gate
 * output/behavior on PI_MODE would emit interactive-mode output in headless
 * sessions. This helper checks BOTH:
 *   1. env.PI_MODE === "print"  — set by builtin-tools/swarm_daemon for their
 *      spawned children (env-first precedence: those children MUST be treated
 *      as print mode even when their argv lacks -p/--print).
 *   2. argv includes "-p" or "--print" — the bare `pi -p` case (the #172
 *      regression the env-only check missed).
 *
 * The env and argv params are test seams (mirrors the sequence-enforcer
 * resolveMode seam and repo-freshness exported-internals pattern); runtime
 * callers use the defaults.
 */

export function isPrintMode(
  env: Record<string, string | undefined> = process.env,
  argv: string[] = process.argv,
): boolean {
  if (env.PI_MODE === "print") return true;
  return argv.includes("-p") || argv.includes("--print");
}
