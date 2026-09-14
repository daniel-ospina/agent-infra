// capture-gate.ts — shared hosted-capture egress gate (#803)
//
// Why this module exists: the Tortoise API key is a GRAPH CONNECTION concern
// (it is also the MCP Bearer header), while a captured session is a full
// conversation transcript — a DATA EGRESS concern. Before #803, reflect-hook
// treated key presence as consent to upload, so exporting the key for the MCP
// header silently shipped every repo's transcripts (including eval runs) to the
// hosted org. The two extensions also disagreed: tortoise-capture required
// `cloud: true` AND a key, reflect-hook required only the key.
//
// Policy — one gate, shared by both extensions, fail-closed and deny-wins:
//
//   1. Hosted capture requires an EXPLICIT `"cloud": true` opt-in in the
//      operator-controlled config (~/.pi/agent/tortoise-config.json). A key —
//      from env or file — never enables egress on its own.
//   2. A repo may only NARROW the gate, never widen it. A project-scoped
//      `<repo>/.pi/tortoise-capture.json` containing `{"cloud": false}` forces
//      capture OFF regardless of global config. A repo-authored file must never
//      be able to grant itself egress (that would be fail-open).
//   3. `TORTOISE_CAPTURE_CLOUD=0|false|off|no` (or empty) forces capture OFF for
//      a session. The env flag may tighten, never loosen: setting it to `1`
//      with no config opt-in does NOT enable capture.
//
// Precedence note (deliberate): env still wins over the file for CREDENTIALS
// (TORTOISE_API_KEY / TORTOISE_API_URL) — a credential is not a consent gate.
// For the EGRESS TOGGLE the precedence is inverted at the file/env boundary:
// the operator file is the only enable, the env flag and the project file can
// only deny. Env-wins for a data-egress switch is what made #803 surprising.

import { readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { dirname, join } from "node:path";

/** Project-scoped deny file, relative to the repo root. */
export const PROJECT_CAPTURE_RELPATH = join(".pi", "tortoise-capture.json");
/** Env flag that can force capture OFF for one session (never ON). */
export const CLOUD_ENV_FLAG = "TORTOISE_CAPTURE_CLOUD";

export type CaptureGateReason =
  | "enabled"
  | "cloud-not-enabled"
  | "no-api-key"
  | "repo-opt-out"
  | "env-disabled";

export interface CaptureGateResult {
  enabled: boolean;
  reason: CaptureGateReason;
}

export interface CaptureGateInput {
  /** Raw `cloud` value from the operator config file. Only literal `true` opts in. */
  cloud: unknown;
  /** Bearer key resolved from env/file (trimmed or raw — both accepted). */
  apiKey: string;
  /** Repo root to check for a project-scoped opt-out. Omitted → no repo deny. */
  projectDir?: string;
  env?: NodeJS.ProcessEnv;
}

const DISABLE_VALUES = new Set(["", "0", "false", "off", "no"]);

// Per-process memoization: these git lookups are stable for a given path and the
// default `isCloudEnabled(config)` path evaluates the gate repeatedly (once per
// agent_end), so an uncached execSync made the gate cost a subprocess per call.
const MAIN_ROOT_CACHE = new Map<string, string | null>();
const PROJECT_ROOT_CACHE = new Map<string, string>();

/**
 * Parent of the shared git dir — the MAIN checkout root. For a linked worktree
 * (`git worktree add`, including this repo's own `.worktrees/<branch>` layout)
 * `--show-toplevel` is the worktree path, so a repo-local deny file at the main
 * root would otherwise be bypassed. Returns null outside a git repo.
 */
export function resolveMainRepoRoot(cwd: string): string | null {
  const cached = MAIN_ROOT_CACHE.get(cwd);
  if (cached !== undefined) return cached;
  let result: string | null = null;
  try {
    const common = execSync("git rev-parse --git-common-dir", {
      encoding: "utf-8",
      cwd,
      timeout: 3000,
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (common) {
      result = dirname(common.startsWith("/") ? common : join(cwd, common));
    }
  } catch {
    result = null;
  }
  MAIN_ROOT_CACHE.set(cwd, result);
  return result;
}

function readOptOutFile(root: string): boolean {
  try {
    const raw = JSON.parse(
      readFileSync(join(root, PROJECT_CAPTURE_RELPATH), "utf-8"),
    ) as { cloud?: unknown };
    return raw?.cloud === false;
  } catch {
    return false;
  }
}

/**
 * Best-effort git toplevel for a cwd, falling back to the cwd itself. This is the
 * #803 gate scope: pi launched from a subdirectory (e.g. `repo/packages/x`) must
 * still resolve the repo root that owns `.pi/tortoise-capture.json`, otherwise
 * the repo opt-out is silently bypassed. stderr is discarded so a non-git cwd
 * does not print `fatal: not a git repository` at extension registration.
 */
export function resolveProjectRoot(cwd: string): string {
  const cached = PROJECT_ROOT_CACHE.get(cwd);
  if (cached !== undefined) return cached;
  let result = cwd;
  try {
    result =
      execSync("git rev-parse --show-toplevel", {
        encoding: "utf-8",
        cwd,
        timeout: 3000,
        stdio: ["ignore", "pipe", "ignore"],
      }).trim() || cwd;
  } catch {
    result = cwd;
  }
  PROJECT_ROOT_CACHE.set(cwd, result);
  return result;
}

/**
 * Read the repo-scoped opt-out. Only an explicit `{"cloud": false}` denies —
 * a missing/unreadable/malformed file is not a deny, and `cloud: true` in a repo
 * file is ignored (a repo cannot grant itself egress, see policy note above).
 * Checks BOTH the session root and the main checkout root, so a deny at
 * `<main>/.pi/tortoise-capture.json` still applies inside a linked worktree.
 */
export function projectCaptureOptOut(projectDir?: string): boolean {
  if (!projectDir) return false;
  if (readOptOutFile(projectDir)) return true;
  const mainRoot = resolveMainRepoRoot(projectDir);
  return mainRoot !== null && mainRoot !== projectDir && readOptOutFile(mainRoot);
}

/** True when the env flag explicitly turns capture OFF for this session. */
export function envCaptureDisabled(env: NodeJS.ProcessEnv = process.env): boolean {
  const raw = env[CLOUD_ENV_FLAG];
  if (typeof raw !== "string") return false;
  return DISABLE_VALUES.has(raw.trim().toLowerCase());
}

/**
 * The one gate both capture extensions use. Deny reasons win over the opt-in so
 * the logged reason is the most specific one the operator can act on.
 */
export function resolveCaptureGate(input: CaptureGateInput): CaptureGateResult {
  // Cloud opt-in is checked FIRST: with no opt-in there is nothing to deny, and
  // this short-circuit avoids the git spawns in projectCaptureOptOut on every
  // gate evaluation for the (default) local-capture case.
  if (input.cloud !== true) {
    return { enabled: false, reason: "cloud-not-enabled" };
  }
  if (envCaptureDisabled(input.env)) {
    return { enabled: false, reason: "env-disabled" };
  }
  if (projectCaptureOptOut(input.projectDir)) {
    return { enabled: false, reason: "repo-opt-out" };
  }
  if (!input.apiKey || input.apiKey.trim().length === 0) {
    return { enabled: false, reason: "no-api-key" };
  }
  return { enabled: true, reason: "enabled" };
}

/**
 * One honest startup line: ON/OFF + destination + why. Used by reflect-hook;
 * tortoise-capture keeps its own (long-standing) wording for the local path but
 * routes the same gate decision.
 */
export function captureStatusLine(args: {
  gate: CaptureGateResult;
  apiUrl: string;
  fallbackDir: string;
  configPath: string;
  projectDir?: string;
}): string {
  const { gate, apiUrl, fallbackDir, configPath, projectDir } = args;
  if (gate.enabled) {
    return `[reflect-hook] capture ON — hosted tortoise capture → ${apiUrl}/v1/sessions (opt-in: "cloud": true)`;
  }
  const local = `sessions saved locally to ${fallbackDir} only`;
  switch (gate.reason) {
    case "repo-opt-out":
      return `[reflect-hook] capture OFF — repo opt-out${projectDir ? ` (${join(projectDir, PROJECT_CAPTURE_RELPATH)})` : ""}; ${local}`;
    case "env-disabled":
      return `[reflect-hook] capture OFF — ${CLOUD_ENV_FLAG} disables capture for this session; ${local}`;
    case "no-api-key":
      return `[reflect-hook] capture OFF — "cloud": true but no TORTOISE_API_KEY/apiKey configured (${configPath}); ${local}`;
    case "cloud-not-enabled":
    default:
      return `[reflect-hook] capture OFF — hosted capture requires explicit opt-in ("cloud": true in ${configPath}); ${local}`;
  }
}
