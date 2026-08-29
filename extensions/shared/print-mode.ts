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
 *   2. argv "-p"/"--print" — the bare `pi -p` case (the #172 regression the
 *      env-only check missed).
 *
 * The env and argv params are test seams (mirrors the sequence-enforcer
 * resolveMode seam and repo-freshness exported-internals pattern); runtime
 * callers use the defaults.
 *
 * isPrintModeEnv(): env-only variant. — HISTORICAL (#201 decision; SUPERSEDED
 * by #357 below for the sequence-enforcer's semantic sites). #201 scoped the
 * enforcer's SEMANTIC mode decisions (resolveMode gate/warn, timeout park/pop)
 * to the env marker, reasoning that a bare shell `pi -p` CAN dispatch `task`
 * and should keep gate. #357 reverses that for the enforcer (see below).
 * isPrintModeEnv is retained for callers OUTSIDE the enforcer that still want
 * the env-only signal (e.g. output/silence gates). Do NOT restore the carve-
 * out for resolveMode/handleSequenceTimeout without revisiting the checkpoint
 * deadlock evidence (#357: 118/118 production blocks in the bare-shell class).
 *
 * #357 (Task 4) — the #201 carve-out is REVERSED for semantic mode decisions:
 * resolveMode() now uses isPrintMode(env, argv) as its fallback. The carve-out
 * assumed bare-shell `pi -p` workers can always dispatch task — but the
 * checkpoint step-gate (Enforcement A #5039) is unsatisfiable AND inescapable
 * in exactly that class (workers deadlock: 118/118 production blocks). A worker
 * that hits a checkpoint gate with a gate-mode default has no in-session escape
 * (loop_enforcer/read are also blocked until a token exists), so warn is the
 * safe default for ALL print sessions, env- or argv-detected. Explicit
 * AGENT_SEQUENCE_MODE/ELDATO_SEQUENCE_MODE/PI_ENFORCER_MODE/mode-file
 * overrides still force gate/strict. handleSequenceTimeout's park/pop predicate
 * uses the same (env, argv) seam so parked behavior and the audited mode match.
 * --mode json/rpc spawns remain gate-resolving residuals (documented in the
 * #357 scoping doc) — the helper itself is unchanged.
 */

const VALUE_TAKING_FLAGS = new Set([
  "--provider", "--model", "--api-key", "--system-prompt", "--name", "-n",
  "--session", "--session-id", "--fork", "--session-dir", "--models",
  "--tools", "-t", "--exclude-tools", "-xt", "--thinking", "--export",
  "--extension", "-e", "--skill", "--prompt-template", "--theme",
  "--mode", "--append-system-prompt",
  // --tui-mode/--list-models only consume the next token when it is NOT
  // flag-like (pi leaves "-p" unconsumed) — excluded to avoid false negatives.
]);

/**
 * True when argv contains the print-mode flag. Mirrors pi's parser: a token
 * following a value-taking flag is that flag's VALUE, never a flag itself —
 * `pi --model -p hello` parses model="-p" with print=false (interactive), so
 * the helper must NOT treat that "-p" as print mode (issue #228 review P3).
 */
function argvHasPrintFlag(argv: string[]): boolean {
  for (let i = 1; i < argv.length; i++) {
    const tok = argv[i];
    if (VALUE_TAKING_FLAGS.has(tok)) {
      i++; // skip the flag's value
      continue;
    }
    if (tok === "-p" || tok === "--print") return true;
  }
  return false;
}

export function isPrintMode(
  env: Record<string, string | undefined> = process.env,
  argv: string[] = process.argv,
): boolean {
  if (env.PI_MODE === "print") return true;
  return argvHasPrintFlag(argv);
}

/**
 * #285 P1-A: task-tool capability from argv — is `task` in the session's tool
 * allowlist? The subagent tool passes agent.tools.join(",") as the --tools
 * value (extensions/subagent/index.ts); a MISSING --tools flag means the
 * default toolset, which includes task. Value-taking-flag aware (mirrors
 * argvHasPrintFlag): a token following --tools/-t is that flag's VALUE, never
 * a flag. --exclude-tools containing task, or --no-tools, → restricted.
 * Env/argv param seam for deterministic e2e (the verification-gate harness's
 * process.argv has no --tools, so scenarios inject one explicitly).
 */
export function argvAllowsTask(argv: string[] = process.argv): boolean {
  for (let i = 1; i < argv.length; i++) {
    const tok = argv[i];
    if (tok === "--tools" || tok === "-t") {
      const value = argv[i + 1];
      if (value === undefined) return false; // dangling flag — fail-closed
      return value.split(",").map((s) => s.trim()).includes("task");
    }
    if (tok.startsWith("--tools=")) {
      return tok.slice("--tools=".length).split(",").map((s) => s.trim()).includes("task");
    }
    if (tok === "--exclude-tools" || tok === "-xt") {
      const value = argv[i + 1];
      if (value !== undefined && value.split(",").map((s) => s.trim()).includes("task")) {
        return false; // task explicitly excluded
      }
    } else if (tok.startsWith("--exclude-tools=")) {
      if (tok.slice("--exclude-tools=".length).split(",").map((s) => s.trim()).includes("task")) {
        return false;
      }
    }
    if (tok === "--no-tools") return false;
    if (VALUE_TAKING_FLAGS.has(tok)) {
      i++; // skip the flag's value
      continue;
    }
  }
  return true; // no --tools flag → default toolset includes task
}

/** Env-only variant — for semantic mode decisions (see header #201 note). */
export function isPrintModeEnv(
  env: Record<string, string | undefined> = process.env,
): boolean {
  return env.PI_MODE === "print";
}
