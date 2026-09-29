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
//   4. Failure is never a skip. A transient git failure (3s timeout, git absent,
//      corrupt `.git`), or an opt-out file that exists but cannot be read, DENIES
//      rather than silently skipping the deny check — the same fail-closed rule
//      that stops a key alone from enabling egress.
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
  | "repo-root-unresolved"
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

/** The deny vocabulary shared by the env flag and the repo file. */
const DISABLE_VALUES = new Set([
  "",
  "0",
  "false",
  "off",
  "no",
  "n",
  "disable",
  "disabled",
  "never",
]);

// Per-process memoization: these git lookups are stable for a given path and the
// default `isCloudEnabled(config)` path evaluates the gate repeatedly (once per
// agent_end), so an uncached execSync made the gate cost a subprocess per call.
// ONLY successful resolutions are cached: memoizing a FAILURE is what let one
// transient git error (timeout, git absent, corrupt `.git`) disable the repo
// opt-out for the rest of the process — a fail-open (#803 review cycle 1 P0).
const MAIN_ROOT_CACHE = new Map<string, string>();
const PROJECT_ROOT_CACHE = new Map<string, string>();

/**
 * The MAIN checkout root for a cwd, or null when it cannot be resolved (not a
 * git repo, git missing, or git failed). For a linked worktree (`git worktree
 * add`, including this repo's own `.worktrees/<branch>` layout) `--show-toplevel`
 * is the worktree path, so a repo-local deny file at the main root would
 * otherwise be bypassed. `dirname(--git-common-dir)` alone is NOT a checkout
 * root: for `--separate-git-dir` it yields the PARENT of the worktree, and for a
 * submodule it yields `.git/modules`. Resolve the current worktree explicitly —
 * when the current git dir IS the shared dir we are in the MAIN worktree, so
 * `--show-toplevel` is its root; only a linked worktree has a distinct git dir,
 * and there the shared dir's parent is the main root.
 */
export function resolveMainRepoRoot(cwd: string): string | null {
  const cached = MAIN_ROOT_CACHE.get(cwd);
  if (cached !== undefined) return cached;
  const resolved = resolveMainRootUncached(cwd);
  if (resolved !== null) MAIN_ROOT_CACHE.set(cwd, resolved);
  return resolved;
}

function resolveMainRootUncached(cwd: string): string | null {
  try {
    const raw = execSync(
      "git rev-parse --path-format=absolute --git-dir --git-common-dir --show-toplevel",
      {
        encoding: "utf-8",
        cwd,
        timeout: 3000,
        stdio: ["ignore", "pipe", "ignore"],
      },
    ).trim();
    const [gitDir, commonDir, topLevel] = raw.split("\n").map((l) => l.trim());
    if (!gitDir || !commonDir || !topLevel) return null;
    return gitDir === commonDir ? topLevel : dirname(commonDir);
  } catch {
    // NOT memoized (see cache note); the gate treats an unresolvable scope as a
    // deny rather than skipping the deny check.
    return null;
  }
}

/**
 * True when the given root carries a repo-scoped DENY. Only an explicit
 * `{"cloud": false}` — or a value in the SAME deny vocabulary the env flag
 * accepts, so a repo author can mirror it — denies. `cloud: true` is ignored (a
 * repo can never grant itself egress, see policy note above). Malformed JSON is
 * NOT a deny (documented, tested choice). A file that EXISTS but cannot be read
 * (EACCES/ENOTDIR/EISDIR) IS a deny: silently skipping it lets an opt-out fail
 * open. An unrecognised `cloud` value also denies, and warns.
 */
function readOptOutFile(root: string): boolean {
  const file = join(root, PROJECT_CAPTURE_RELPATH);
  let raw: string;
  try {
    raw = readFileSync(file, "utf-8");
  } catch (err) {
    const code = (err as NodeJS.ErrnoException | undefined)?.code;
    if (code === "ENOENT") return false; // absent is not a deny
    console.warn(
      `[capture-gate] repo opt-out ${file} exists but cannot be read (${code ?? String(err)}) — treating it as a DENY (fail closed)`,
    );
    return true;
  }
  let parsed: { cloud?: unknown } | null;
  try {
    parsed = JSON.parse(raw) as { cloud?: unknown } | null;
  } catch {
    return false; // malformed JSON is not a deny (documented choice)
  }
  const cloud = parsed?.cloud;
  if (cloud === undefined || cloud === null) return false; // nothing declared
  if (cloud === true) return false; // a repo can never grant itself egress
  if (cloud === false) return true;
  if (typeof cloud === "string" && DISABLE_VALUES.has(cloud.trim().toLowerCase())) {
    return true; // same deny vocabulary as the env flag
  }
  console.warn(
    `[capture-gate] repo opt-out ${file} has an unrecognised "cloud" value ${JSON.stringify(cloud)} — treating it as a DENY (fail closed)`,
  );
  return true;
}

/**
 * Best-effort git toplevel for a cwd, falling back to the cwd itself. This is the
 * #803 gate scope: pi launched from a subdirectory (e.g. `repo/packages/x`) must
 * still resolve the repo root that owns `.pi/tortoise-capture.json`, otherwise
 * the repo opt-out is silently bypassed. stderr is discarded so a non-git cwd
 * does not print `fatal: not a git repository` at extension registration.
 * A FAILURE (git absent/failed) is not cached, so a transient error does not
 * pin the fallback for the rest of the process.
 */
export function resolveProjectRoot(cwd: string): string {
  const cached = PROJECT_ROOT_CACHE.get(cwd);
  if (cached !== undefined) return cached;
  let resolved: string | null = null;
  try {
    resolved =
      execSync("git rev-parse --show-toplevel", {
        encoding: "utf-8",
        cwd,
        timeout: 3000,
        stdio: ["ignore", "pipe", "ignore"],
      }).trim() || null;
  } catch {
    resolved = null;
  }
  if (resolved === null) return cwd; // not cached: a failure must be retryable
  PROJECT_ROOT_CACHE.set(cwd, resolved);
  return resolved;
}

/** The resolved repo scope for the gate, plus whether that scope is trustworthy. */
export interface ProjectCaptureScope {
  /** A deny was found, or the opt-out exists but could not be honoured. */
  denied: boolean;
  /** The git roots resolved, so "no deny found" is trustworthy. */
  resolved: boolean;
}

/**
 * Read the repo-scoped opt-out for a project dir. An omitted `projectDir`
 * deliberately skips the repo check (`resolved: true`). `resolved: false` means
 * the git scope could not be determined (git absent/failed, or not a git repo),
 * so the gate fails closed instead of assuming "no deny". Checks BOTH the
 * session root and the main checkout root, so a deny at
 * `<main>/.pi/tortoise-capture.json` still applies inside a linked worktree.
 */
export function resolveProjectCaptureScope(projectDir?: string): ProjectCaptureScope {
  if (!projectDir) return { denied: false, resolved: true };
  if (readOptOutFile(projectDir)) return { denied: true, resolved: true };
  const mainRoot = resolveMainRepoRoot(projectDir);
  if (mainRoot === null) return { denied: false, resolved: false };
  if (mainRoot !== projectDir && readOptOutFile(mainRoot)) {
    return { denied: true, resolved: true };
  }
  return { denied: false, resolved: true };
}

/** Boolean form of {@link resolveProjectCaptureScope}: was an opt-out honoured? */
export function projectCaptureOptOut(projectDir?: string): boolean {
  return resolveProjectCaptureScope(projectDir).denied;
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
  const scope = resolveProjectCaptureScope(input.projectDir);
  if (scope.denied) {
    return { enabled: false, reason: "repo-opt-out" };
  }
  // Skipping the deny check because git failed is a fail-open: a transient git
  // error must never turn a repo opt-out into an upload. Deny instead.
  if (!scope.resolved) {
    return { enabled: false, reason: "repo-root-unresolved" };
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
    case "repo-root-unresolved":
      return `[reflect-hook] capture OFF — could not resolve the repo root to check for a per-repo opt-out${projectDir ? ` (${projectDir})` : ""}; failing closed; ${local}`;
    case "env-disabled":
      return `[reflect-hook] capture OFF — ${CLOUD_ENV_FLAG} disables capture for this session; ${local}`;
    case "no-api-key":
      return `[reflect-hook] capture OFF — "cloud": true but no TORTOISE_API_KEY/apiKey configured (${configPath}); ${local}`;
    case "cloud-not-enabled":
    default:
      return `[reflect-hook] capture OFF — hosted capture requires explicit opt-in ("cloud": true in ${configPath}); ${local}`;
  }
}
