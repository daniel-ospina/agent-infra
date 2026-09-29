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
//      corrupt `.git`), or an opt-out file that exists but cannot be read or
//      parsed, DENIES rather than silently skipping the deny check — the same
//      fail-closed rule that stops a key alone from enabling egress. A directory
//      git DEFINITIVELY reports as "not a git repository" is not a failure ONLY
//      once every ancestor has been checked for an opt-out: a directory with no
//      repo root can still sit UNDER a directory that declares one (the deny file
//      is honoured at any `projectDir`), so the opt-in stands only when that
//      deny-only ancestor walk has found nothing.
//
// Precedence note (deliberate): env still wins over the file for CREDENTIALS
// (TORTOISE_API_KEY / TORTOISE_API_URL) — a credential is not a consent gate.
// For the EGRESS TOGGLE the precedence is inverted at the file/env boundary:
// the operator file is the only enable, the env flag and the project file can
// only deny. Env-wins for a data-egress switch is what made #803 surprising.

import { existsSync, lstatSync, readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";

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

/**
 * Config-file string guard, SHARED by both capture extensions (#803 review
 * cycle 3 P2). A hand-written config field can be any JSON type, and a SILENT
 * drop of a mistyped `apiUrl` sends full transcripts to the DEFAULT hosted
 * endpoint instead of the operator's intended host — carrying the Bearer key
 * with them. That is the #775 "wrong host, silently" class, so the drop must
 * never be silent. ONLY `undefined` counts as ABSENT: `null` (and every other
 * non-string) is PRESENT-and-wrong, and is warned about and dropped.
 */
export function asConfigStringField(args: {
  /** The owning extension's log tag, e.g. `[reflect-hook]`. */
  prefix: string;
  /** The config key, used verbatim in the warning. */
  field: string;
  value: unknown;
  /** Named in the warning when `field` is `apiUrl`. */
  defaultApiUrl: string;
}): string | undefined {
  const { prefix, field, value, defaultApiUrl } = args;
  if (value === undefined) return undefined;
  if (typeof value === "string") return value;
  const consequence =
    field === "apiUrl"
      ? ` — hosted capture will target the DEFAULT endpoint ${defaultApiUrl} instead`
      : field === "apiKey"
        ? " — hosted capture will be treated as keyless (no upload)"
        : "";
  const got = value === null ? "null" : typeof value;
  console.warn(
    `${prefix} config "${field}" is present but not a string (got ${got}); ignoring it${consequence}`,
  );
  return undefined;
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
// ONLY a resolved root is cached: memoizing a FAILURE is what let one transient
// git error (timeout, git absent, corrupt `.git`) disable the repo opt-out for
// the rest of the process — a fail-open (#803 review cycle 1 P0). A "not a git
// repository" answer is likewise not cached, because a later `git init` would
// invalidate it.
const MAIN_ROOT_CACHE = new Map<string, string>();
const PROJECT_ROOT_CACHE = new Map<string, string>();

/** git's exit-128 "not a git repository" diagnostic (a definitive answer, not a failure). */
const NOT_A_REPO_RE = /not a git repository/i;

/**
 * Does `cwd` or ANY ancestor carry a `.git` entry (dir, file, OR symlink)? git
 * reports a corrupt/incomplete repository boundary with the SAME `fatal: not a
 * git repository` (exit 128) it uses for a plain directory, so the message alone
 * cannot tell them apart. If a boundary exists but git rejected it, the repo
 * scope is UNRESOLVABLE (fail closed); only a walk that finds no `.git` entry
 * anywhere is the definitive "not a repository" answer.
 *
 * `lstat`, NOT `existsSync`/`stat`: `existsSync` FOLLOWS symlinks, so a broken or
 * looping `.git` symlink (unmounted volume, deleted central gitdir, a `git
 * archive`/ZIP export, a `cp -r` that excluded the target) read as ABSENT —
 * flipping a repository boundary git REJECTS into the definitive "not a repo"
 * answer and enabling capture (review cycle 3 P0). A `.git` ENTRY of any kind is
 * a boundary. A non-ENOENT stat failure is likewise a boundary: fail closed.
 */
function hasGitBoundary(cwd: string): boolean {
  let dir = resolve(cwd);
  for (;;) {
    try {
      lstatSync(join(dir, ".git"));
      return true;
    } catch (err) {
      if ((err as NodeJS.ErrnoException | undefined)?.code !== "ENOENT") return true;
    }
    const parent = dirname(dir);
    if (parent === dir) return false;
    dir = parent;
  }
}

/**
 * Is there a repo-scoped opt-out at `cwd` or ANY ancestor? DENY-ONLY, so it can
 * only ever narrow egress (#803 review cycle 3 P0). Two cases need it:
 *
 *   - the cwd is NOT in a repository (`.git` absent, renamed away, or a broken
 *     symlink), so there is no resolved main root to read — but an ancestor
 *     opt-out still exists and must be honoured. "No repo root" does NOT imply
 *     "no deny to miss": `PROJECT_CAPTURE_RELPATH` is honoured at ANY directory;
 *   - the cwd IS in a repo but the opt-out sits at an INTERMEDIATE ancestor
 *     (`R/pkg/{src/deep}` with the deny at `R/pkg`), which the two-candidate-root
 *     check (cwd + main root) never reads.
 */
function ancestorDenyExists(cwd: string): boolean {
  let dir = resolve(cwd);
  for (;;) {
    if (readOptOutFile(dir)) return true;
    const parent = dirname(dir);
    if (parent === dir) return false;
    dir = parent;
  }
}

/** Three-way answer to "where is the main checkout root of this cwd?" */
interface MainRootResolution {
  /** The main checkout root, or null when it could not be determined. */
  root: string | null;
  /**
   * True when git answered DEFINITIVELY that `cwd` is not inside any repository
   * (`fatal: not a git repository`, exit 128) AND no ancestor carries a `.git`
   * boundary. That is a resolved answer with no roots to search, so there is no
   * repo-scoped deny file at a REPO root the gate could miss — the operator's
   * explicit `cloud: true` opt-in stands (a plain directory or `$HOME` is a
   * legitimate launch cwd). An opt-out at any other ancestor is still honoured:
   * the caller walks ancestors with {@link ancestorDenyExists} before trusting
   * this answer. `resolved:false` is reserved for a genuine failure — git absent,
   * a timeout, a corrupt `.git` (git reports it with the same message), or a
   * layout whose main root cannot be named (see {@link resolveMainRepoRoot}).
   */
  notARepo: boolean;
  /**
   * True when git answered DEFINITIVELY `fatal: not a git repository` (exit 128)
   * but a `.git` boundary DOES exist above — a corrupt/incomplete repository, or
   * a boundary git rejects (a broken/looping symlink left by an unmounted volume,
   * a deleted central gitdir, a `cp -r` that excluded the target, a ZIP export).
   * This is NOT a genuine git failure, so an ancestor opt-out — a purely
   * filesystem read that does not depend on git — is still trustworthy and must
   * be honoured before failing closed (review cycle 3 P0). It is tracked
   * separately from `notARepo` precisely because a genuine failure (git absent,
   * a timeout) must NOT be treated as a definitive answer.
   */
  boundaryRejected: boolean;
}

/**
 * The MAIN checkout root for a cwd, or null when it cannot be resolved. For a
 * linked worktree (`git worktree add`, including this repo's own
 * `.worktrees/<branch>` layout) `--show-toplevel` is the worktree path, so a
 * repo-local deny file at the main root would otherwise be bypassed. When the
 * current git dir IS the shared dir we are in the MAIN worktree, so
 * `--show-toplevel` is its root; only a linked worktree has a distinct git dir,
 * and there the shared dir's parent (`<main>/.git` → `<main>`) is the main root.
 *
 * UNSUPPORTED LAYOUTS (fail closed, return null): a linked worktree whose common
 * dir is not `<checkout>/.git` — i.e. a worktree of a `--separate-git-dir`
 * checkout, or of a submodule (`<super>/.git/modules/<name>`). git cannot name
 * the main worktree of a `--separate-git-dir` repository at all (neither
 * `core.worktree` nor `git worktree list` yields it: the latter reports the git
 * dir as the main worktree), so the only safe answer is "unresolvable" — the
 * gate then fails closed instead of reading a deny file at a WRONG root.
 */
export function resolveMainRepoRoot(cwd: string): string | null {
  return resolveMainRootDetailed(cwd).root;
}

function resolveMainRootDetailed(cwd: string): MainRootResolution {
  const cached = MAIN_ROOT_CACHE.get(cwd);
  if (cached !== undefined) return { root: cached, notARepo: false, boundaryRejected: false };
  const result = resolveMainRootUncached(cwd);
  // Only a resolved ROOT is memoized (see cache note).
  if (result.root !== null) MAIN_ROOT_CACHE.set(cwd, result.root);
  return result;
}

function resolveMainRootUncached(cwd: string): MainRootResolution {
  try {
    // Deliberately NOT `--path-format=absolute`: that option only exists in git
    // >= 2.31, so older git would exit non-zero here and disable cloud capture
    // for EVERY directory, including inside a valid repo. The outputs are
    // absolutised below with resolve(cwd, p), which is idempotent for the
    // already-absolute submodule-gitfile case.
    const raw = execSync("git rev-parse --git-dir --git-common-dir --show-toplevel", {
      encoding: "utf-8",
      cwd,
      timeout: 3000,
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
    const [gitDir, commonDir, topLevel] = raw.split("\n").map((l) => l.trim());
    if (!gitDir || !commonDir || !topLevel) {
      return { root: null, notARepo: false, boundaryRejected: false };
    }
    const absGitDir = resolve(cwd, gitDir);
    const absCommonDir = resolve(cwd, commonDir);
    if (absGitDir === absCommonDir) {
      // The current worktree IS the main worktree of the shared repo.
      return { root: resolve(cwd, topLevel), notARepo: false, boundaryRejected: false };
    }
    const candidate = dirname(absCommonDir);
    if (existsSync(join(candidate, ".git"))) {
      return { root: candidate, notARepo: false, boundaryRejected: false };
    }
    // Composite layout (`--separate-git-dir` checkout or submodule): the common
    // dir's parent is not a checkout root. Fail closed — see the docstring.
    return { root: null, notARepo: false, boundaryRejected: false };
  } catch (err) {
    // NOT memoized (see cache note). A definitive "not a git repository" (exit
    // 128) is a resolved answer, not a failure — but ONLY when no `.git` boundary
    // exists above: git emits the identical message for a corrupt/incomplete
    // repo, which must fail closed (policy rule 4). Anything else (git absent, a
    // timeout) is unresolvable.
    const e = err as { status?: number; stderr?: unknown } | undefined;
    const stderr = typeof e?.stderr === "string" ? e.stderr : "";
    const answered = e?.status === 128 && NOT_A_REPO_RE.test(stderr);
    const boundary = answered && hasGitBoundary(cwd);
    return { root: null, notARepo: answered && !boundary, boundaryRejected: boundary };
  }
}

/**
 * True when the given root carries a repo-scoped DENY. Only an explicit
 * `{"cloud": false}` — or a value in the SAME deny vocabulary the env flag
 * accepts, so a repo author can mirror it — denies. `cloud: true` is ignored (a
 * repo can never grant itself egress, see policy note above). A file that EXISTS
 * but cannot be read (EACCES/ENOTDIR/EISDIR) or cannot be PARSED (malformed
 * JSON) IS a deny: silently skipping it lets an opt-out fail open (policy rule
 * 4). An unrecognised `cloud` value also denies, and warns.
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
    // Policy rule 4: an opt-out file that exists but cannot be read or parsed
    // DENIES. Malformed JSON used to fall through to "no deny", silently
    // disabling a repo's opt-out (review cycle 2 P2).
    console.warn(
      `[capture-gate] repo opt-out ${file} is not valid JSON — treating it as a DENY (fail closed)`,
    );
    return true;
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
 * the git scope could not be determined — a genuine git failure (absent/
 * timeout/corrupt `.git`) or an unnameable layout (see
 * {@link resolveMainRepoRoot}) — so the gate fails closed instead of assuming
 * "no deny". A directory git definitively reports as NOT a repository is
 * resolved — but ONLY after every ancestor has been checked for an opt-out
 * (a non-repo cwd can still sit under a directory that declares one).
 * Checks the session root, ANY ancestor, and the main checkout root, so a deny at
 * `<main>/.pi/tortoise-capture.json` still applies inside a linked worktree and a
 * deny at an intermediate package directory still applies to its descendants.
 */
export function resolveProjectCaptureScope(projectDir?: string): ProjectCaptureScope {
  if (!projectDir) return { denied: false, resolved: true };
  if (readOptOutFile(projectDir)) return { denied: true, resolved: true };
  const { root: mainRoot, notARepo, boundaryRejected } = resolveMainRootDetailed(projectDir);
  if (mainRoot === null) {
    // Before trusting a definitive "not a repository" — or resolving a REJECTED
    // boundary as a failure — walk ancestors for the deny file itself (review
    // cycle 3 P0). "No repo root" does NOT imply "no deny to miss": the opt-out
    // is honoured at ANY directory, so a cwd inside a repo whose `.git` is absent,
    // renamed away, or a broken/looping symlink could still sit under an ancestor
    // `{"cloud":false}`. Deny-only, so it can only ever narrow. A GENUINE git
    // failure (`boundaryRejected` false, `notARepo` false) is excluded on purpose:
    // it already fails closed below, and the reason must stay
    // `repo-root-unresolved`/`no-api-key` rather than claim a deny we did not
    // verify (review cycle 2 P2).
    if ((notARepo || boundaryRejected) && ancestorDenyExists(projectDir)) {
      return { denied: true, resolved: true };
    }
    return { denied: false, resolved: notARepo };
  }
  if (mainRoot !== projectDir && readOptOutFile(mainRoot)) {
    return { denied: true, resolved: true };
  }
  // Resolved path, same root cause: the opt-out may sit at an INTERMEDIATE
  // ancestor between the cwd and the main root (`R/pkg` for `R/pkg/src/deep`),
  // which the two candidate roots above never read.
  if (ancestorDenyExists(projectDir)) return { denied: true, resolved: true };
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
  // A repo/env deny wins over everything, so the operator sees the most specific
  // reason. Only AFTER that does the key check come first, so a missing key is
  // reported as the actionable `no-api-key` rather than masked by an
  // unresolvable scope (review cycle 2 P2): `repo-root-unresolved` is reserved
  // for a scope that cannot be trusted WHILE the config is otherwise enable-capable.
  const scope = resolveProjectCaptureScope(input.projectDir);
  if (scope.denied) {
    return { enabled: false, reason: "repo-opt-out" };
  }
  if (!input.apiKey || input.apiKey.trim().length === 0) {
    return { enabled: false, reason: "no-api-key" };
  }
  // Skipping the deny check because git failed is a fail-open: a transient git
  // error must never turn a repo opt-out into an upload. Deny instead.
  if (!scope.resolved) {
    return { enabled: false, reason: "repo-root-unresolved" };
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
