// repo-freshness.ts — ambient git freshness for agent sessions (#178/#180)
//
// Long-lived cmux pi panes drift: origin moves on, the checkout stays stale,
// and agents working from it silently re-introduce already-fixed code. This
// extension keeps the idle default branch fresh and surfaces feature-branch
// drift:
//
//   - session_start + every AGENT_REPO_FRESHNESS_INTERVAL_MS (default 20 min):
//     git fetch (30s timeout, silent failure) + state check vs origin/<default>
//   - default branch + clean tree + not-ahead + no merge/rebase/lock →
//       mode auto (default): git pull --ff-only, logged per pull
//       mode warn:           hint only
//   - feature branch → report-only "N behind origin/<default>" (NEVER pulls)
//   - ahead → report unpushed; diverged → guidance, never pull
//   - agent-infra excluded — auto-sync.ts owns that repo (no double-pull)
//
// Safety envelope (research-verified, project #178): pulls only ever happen
// on the default branch with a clean tree, ff-only; git re-checks dirtiness
// at pull time (final arbiter); merge/rebase/index.lock all skip silently.
// Consistent with main-worktree-guard's documented interception surface
// (tool_call only) — extension-level pulls are outside it, same class as
// auto-sync.ts; observable via log lines + AGENT_REPO_FRESHNESS_DISABLED=1.
//
// Self-contained by necessity: root-level flat extensions cannot resolve
// sibling imports (#5611) — only the ExtensionAPI type is imported.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execSync } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";

// ── Knobs ───────────────────────────────────────────────────────────────

export const DEFAULT_FRESHNESS_INTERVAL_MS = 1_200_000; // 20 min
export const MIN_FRESHNESS_INTERVAL_MS = 300_000; // 5 min
export const FETCH_TIMEOUT_MS = 30_000;
export const PULL_TIMEOUT_MS = 120_000;

/** Clamp a raw interval (≥5 min; non-finite/≤0 → 20 min default). */
export function clampFreshnessIntervalMs(raw: number): number {
  if (!Number.isFinite(raw) || raw <= 0) return DEFAULT_FRESHNESS_INTERVAL_MS;
  return Math.max(MIN_FRESHNESS_INTERVAL_MS, raw);
}

export function getFreshnessIntervalMs(
  env: Record<string, string | undefined> = process.env,
): number {
  return clampFreshnessIntervalMs(Number(env.AGENT_REPO_FRESHNESS_INTERVAL_MS));
}

export function getFreshnessMode(
  env: Record<string, string | undefined> = process.env,
): "auto" | "warn" {
  return env.AGENT_REPO_FRESHNESS_MODE === "warn" ? "warn" : "auto";
}

export function freshnessDisabled(
  env: Record<string, string | undefined> = process.env,
): boolean {
  return env.AGENT_REPO_FRESHNESS_DISABLED === "1";
}

// ── Git inspection (exported for tests) ─────────────────────────────────

function git(repo: string, args: string, opts: { timeout?: number; quiet?: boolean } = {}): string {
  return execSync(`git -C "${repo}" ${args}`, {
    encoding: "utf-8",
    timeout: opts.timeout ?? 10_000,
    stdio: opts.quiet === false ? undefined : ["ignore", "pipe", "pipe"],
  }).trim();
}

function tryGit(repo: string, args: string, opts: { timeout?: number } = {}): string | null {
  try {
    return git(repo, args, { ...opts, quiet: true });
  } catch {
    return null;
  }
}

export function isGitRepo(cwd: string): boolean {
  return tryGit(cwd, "rev-parse --git-dir") !== null;
}

export function hasOrigin(cwd: string): boolean {
  return tryGit(cwd, "remote get-url origin") !== null;
}

/** Default branch via origin/HEAD (fallback "main" when unset). */
export function defaultBranch(cwd: string): string {
  const ref = tryGit(cwd, "symbolic-ref --short refs/remotes/origin/HEAD");
  if (ref) {
    const name = ref.replace(/^origin\//, "");
    if (name) return name;
  }
  return "main";
}

export function currentBranch(cwd: string): string | null {
  const b = tryGit(cwd, "branch --show-current");
  return b === null || b === "" ? null : b;
}

/**
 * Sync state of the repo vs origin/<branch> (call AFTER fetch):
 *   "current"  HEAD === origin/<branch>
 *   "behind"   origin/<branch> has commits HEAD lacks (ff pull possible)
 *   "ahead"    HEAD has commits origin/<branch> lacks
 *   "diverged" neither side is an ancestor of the other
 */
export function syncState(cwd: string, branch: string): "current" | "behind" | "ahead" | "diverged" {
  const head = tryGit(cwd, "rev-parse HEAD");
  const remote = tryGit(cwd, `rev-parse origin/${branch}`);
  if (head === null || remote === null) return "current"; // undetermined — don't act
  if (head === remote) return "current";
  if (tryGit(cwd, `merge-base --is-ancestor HEAD origin/${branch} && echo yes`) === "yes") return "behind";
  if (tryGit(cwd, `merge-base --is-ancestor origin/${branch} HEAD && echo yes`) === "yes") return "ahead";
  return "diverged";
}

export function behindCount(cwd: string, branch: string): number {
  const out = tryGit(cwd, `rev-list --count HEAD..origin/${branch}`);
  const n = Number(out ?? "");
  return Number.isInteger(n) && n >= 0 ? n : 0;
}

export function aheadCount(cwd: string, branch: string): number {
  const out = tryGit(cwd, `rev-list --count origin/${branch}..HEAD`);
  const n = Number(out ?? "");
  return Number.isInteger(n) && n >= 0 ? n : 0;
}

export function repoClean(cwd: string): boolean {
  return tryGit(cwd, "status --porcelain") === "";
}

export function mergeOrRebaseInProgress(cwd: string): boolean {
  const gitDir = tryGit(cwd, "rev-parse --git-dir");
  if (!gitDir) return false;
  const abs = gitDir.startsWith("/") ? gitDir : `${cwd}/${gitDir}`;
  return existsSync(`${abs}/MERGE_HEAD`) || existsSync(`${abs}/REBASE_HEAD`) || existsSync(`${abs}/rebase-merge`) || existsSync(`${abs}/rebase-apply`);
}

export function indexLocked(cwd: string): boolean {
  const gitDir = tryGit(cwd, "rev-parse --git-dir");
  if (!gitDir) return false;
  const abs = gitDir.startsWith("/") ? gitDir : `${cwd}/${gitDir}`;
  return existsSync(`${abs}/index.lock`);
}

/** Default branch checked out in any worktree ≠ current checkout → true.
 * SELF-EXCLUSION is mandatory: `git worktree list --porcelain` includes the
 * current checkout — without excluding it, the main checkout on the default
 * branch would always "find itself elsewhere" and never pull (plan-review P3). */
export function defaultBranchInOtherWorktree(cwd: string, branch: string): boolean {
  const out = tryGit(cwd, "worktree list --porcelain");
  if (!out) return false;
  const selfGitDir = tryGit(cwd, "rev-parse --absolute-git-dir");
  if (!selfGitDir) return false;
  // porcelain entries are separated by blank lines
  for (const entry of out.split("\n\n")) {
    const lines = entry.split("\n");
    const gitdirLine = lines.find((l) => l.startsWith("gitdir "));
    const branchLine = lines.find((l) => l.startsWith("branch "));
    if (!gitdirLine || !branchLine) continue;
    const b = branchLine.slice("branch ".length).replace(/^refs\/heads\//, "");
    if (b !== branch) continue;
    // self-exclusion (mandatory): skip our own checkout
    if (gitdirLine.slice("gitdir ".length) === selfGitDir) continue;
    return true;
  }
  return false;
}

// ── Agent-infra detection (local re-implementation — flat files cannot
//    import siblings, #5611; same semantics as main-worktree-guard's
//    classify-git.mjs isAgentInfraRepo — plan-review fold) ───────────────

export function isAgentInfraRepo(cwd: string, env: Record<string, string | undefined> = process.env): boolean {
  let toplevel: string | null = null;
  try {
    toplevel = execSync(`git -C "${cwd}" rev-parse --show-toplevel`, {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
  } catch {
    return false;
  }
  let real: string = toplevel;
  try {
    real = realpathSync(toplevel);
  } catch { /* keep unresolved toplevel */ }
  for (const key of ["AGENT_INFRA_PATH", "AGENT_INFRA_ROOT"]) {
    const v = env[key];
    if (!v) continue;
    try {
      if (realpathSync(v) === real) return true;
    } catch { /* env path unreadable */ }
  }
  // Fingerprint: manifest.json + pi-bootstrap/setup.sh at toplevel
  return existsSync(`${toplevel}/manifest.json`) && existsSync(`${toplevel}/pi-bootstrap/setup.sh`);
}

// ── Pull step (exported — tests invoke it directly to exercise git's own
//    pull-time aborts, the layer-2 final arbiter) ────────────────────────

export interface PullResult {
  ok: boolean;
  from: string;
  to: string;
  error?: string;
}

/** Attempt the ff-only pull. NEVER forces anything; git itself aborts on
 * dirty trees / untracked collisions / divergence. */
export function tryFastForwardPull(cwd: string, branch: string): PullResult {
  const from = tryGit(cwd, "rev-parse --short HEAD") ?? "?";
  try {
    execSync(`git -C "${cwd}" pull --ff-only origin "${branch}"`, {
      encoding: "utf-8",
      timeout: PULL_TIMEOUT_MS,
      stdio: ["ignore", "pipe", "pipe"],
    });
    return { ok: true, from, to: tryGit(cwd, "rev-parse --short HEAD") ?? "?" };
  } catch (e) {
    const err = e as { stderr?: Buffer | string; message?: string };
    const detail = (err.stderr ? String(err.stderr) : err.message ?? "unknown").trim().split("\n")[0];
    return { ok: false, from, to: from, error: detail };
  }
}

// ── Tick (the ambient check — exported for tests) ───────────────────────

export interface FreshnessReport {
  action:
    | "skipped-not-git" | "skipped-no-origin" | "skipped-disabled"
    | "skipped-agent-infra" | "skipped-detached" | "skipped-busy"
    | "skipped-worktree" | "current" | "ahead" | "diverged"
    | "pulled" | "pull-failed" | "warn-behind" | "report-feature-branch";
  repo?: string;
  detail?: string;
}

export function freshnessTick(
  cwd: string,
  env: Record<string, string | undefined> = process.env,
  log: (line: string) => void = console.log,
): FreshnessReport {
  const report = (action: FreshnessReport["action"], detail?: string): FreshnessReport =>
    ({ action, repo: cwd, detail });

  if (freshnessDisabled(env)) return report("skipped-disabled");
  if (!isGitRepo(cwd)) return report("skipped-not-git");
  if (!hasOrigin(cwd)) return report("skipped-no-origin");
  if (isAgentInfraRepo(cwd, env)) return report("skipped-agent-infra");

  const branch = defaultBranch(cwd);
  const current = currentBranch(cwd);
  if (!current) return report("skipped-detached");

  // Feature branch → report-only. NEVER pull non-default branches.
  if (current !== branch) {
    tryGit(cwd, `fetch origin "${branch}" --quiet`, { timeout: FETCH_TIMEOUT_MS });
    const n = behindCount(cwd, branch);
    if (n > 0) {
      log(`[repo-freshness] ℹ️  ${cwd}: branch '${current}' is ${n} commit(s) behind origin/${branch} — reconcile before PR (commit-workflow Pre-PR Freshness Check)`);
    }
    return report("report-feature-branch", `behind=${n}`);
  }

  // Default branch: fetch first (silent failure = offline)
  const fetched = tryGit(cwd, `fetch origin "${branch}" --quiet`, { timeout: FETCH_TIMEOUT_MS });
  if (fetched === null) return report("skipped-no-origin"); // offline — silent

  const state = syncState(cwd, branch);
  if (state === "current") return report("current");

  if (state === "ahead") {
    const n = aheadCount(cwd, branch);
    log(`[repo-freshness] ℹ️  ${cwd}: ahead of origin/${branch} (${n} unpushed commit(s)) — push when ready`);
    return report("ahead", `ahead=${n}`);
  }

  if (state === "diverged") {
    log(`[repo-freshness] ⚠️  ${cwd}: DIVERGED from origin/${branch} — ff pull blocked. Inspect: git log --oneline --left-right HEAD...origin/${branch}`);
    return report("diverged");
  }

  // behind — guard checks before any pull
  if (mergeOrRebaseInProgress(cwd) || indexLocked(cwd)) return report("skipped-busy");
  if (defaultBranchInOtherWorktree(cwd, branch)) return report("skipped-worktree");

  const n = behindCount(cwd, branch);
  if (!repoClean(cwd)) {
    log(`[repo-freshness] ⚠️  ${cwd}: ${n} behind origin/${branch} but working tree is DIRTY — commit or stash, then: git pull --ff-only origin ${branch}`);
    return report("warn-behind", "dirty");
  }

  if (getFreshnessMode(env) === "warn") {
    log(`[repo-freshness] ⚠️  ${cwd}: ${n} behind origin/${branch} — run: git pull --ff-only origin ${branch}`);
    return report("warn-behind", `behind=${n}`);
  }

  const pull = tryFastForwardPull(cwd, branch);
  if (pull.ok) {
    log(`[repo-freshness] ✅ auto-pull ${cwd} ${pull.from}→${pull.to} (was ${n} behind origin/${branch})`);
    return report("pulled", `${pull.from}→${pull.to}`);
  }
  // git refused at pull time (final arbiter) — report, never force
  log(`[repo-freshness] ⚠️  ${cwd}: pull aborted by git: ${pull.error ?? "unknown"}`);
  return report("pull-failed", pull.error);
}

// ── Extension entry ─────────────────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  if (freshnessDisabled()) return;

  let timer: ReturnType<typeof setInterval> | null = null;

  const tick = () => {
    try {
      freshnessTick(process.cwd());
    } catch {
      // ambient hygiene must never break a session
    }
  };

  pi.on("session_start", async () => {
    // Sub-agents: no pulls, no noise (matches auto-sync.ts)
    if (process.env.PI_MODE === "print") return;
    tick(); // immediate check on session start
    if (timer) clearInterval(timer);
    timer = setInterval(tick, getFreshnessIntervalMs());
    timer.unref?.(); // never hold the event loop (#153 class)
  });

  // pi extension rules: timers start in session_start, clear in session_shutdown
  pi.on("session_shutdown", async () => {
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
  });
}
