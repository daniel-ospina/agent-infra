// repo-freshness.ts — ambient git freshness for agent sessions (#178/#180)
//
// Long-lived cmux pi panes drift: origin moves on, the checkout stays stale,
// and agents working from it silently re-introduce already-fixed code. This
// NOTE: root-level flat extensions CAN import ./shared/* (verified 2026-08-13 — the
// #5611 sibling-import constraint is stale for the current jiti/static loader).
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
// Self-contained by default: only the ExtensionAPI type is imported — except
// shared helpers (./shared/print-mode.js; the #5611 sibling-import constraint
// is stale for the current jiti/static loader, verified 2026-08-13).

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execSync } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import { isPrintMode } from "./shared/print-mode.js";

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

/** Kill-switch for the superseded-dirty-tree auto-reset (#178 L2 extension). */
export function autoHealDisabled(
  env: Record<string, string | undefined> = process.env,
): boolean {
  return env.AGENT_REPO_FRESHNESS_NO_AUTOHEAL === "1";
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
  const remote = tryGit(cwd, `rev-parse ${q(`origin/${branch}`)}`);
  if (head === null || remote === null) return "current"; // undetermined — don't act
  if (head === remote) return "current";
  if (tryGit(cwd, `merge-base --is-ancestor HEAD ${q(`origin/${branch}`)} && echo yes`) === "yes") return "behind";
  if (tryGit(cwd, `merge-base --is-ancestor ${q(`origin/${branch}`)} HEAD && echo yes`) === "yes") return "ahead";
  return "diverged";
}

export function behindCount(cwd: string, branch: string): number {
  const out = tryGit(cwd, `rev-list --count HEAD..${q(`origin/${branch}`)}`);
  const n = Number(out ?? "");
  return Number.isInteger(n) && n >= 0 ? n : 0;
}

export function aheadCount(cwd: string, branch: string): number {
  const out = tryGit(cwd, `rev-list --count ${q(`origin/${branch}`)}..HEAD`);
  const n = Number(out ?? "");
  return Number.isInteger(n) && n >= 0 ? n : 0;
}

export function repoClean(cwd: string): boolean {
  return tryGit(cwd, "status --porcelain") === "";
}

/** Shell-quote a path for execSync interpolation (single-quote wrap + escape). */
function q(path: string): string {
  return "'" + path.replace(/'/g, `'\\''`) + "'";
}

/**
 * Is the dirty working tree fully superseded by origin/<branch> — i.e., is
 * `git reset --hard origin/<branch>` PROVABLY lossless?
 *
 * Safety semantics (git-reset docs): reset --hard discards changes to tracked
 * files and "untracked files or directories in the way of writing any tracked
 * files are simply deleted". So:
 *  - tracked delta vs origin/<branch>: only status D allowed (origin has a
 *    file the local tree lacks — reset RESTORES it, no local content lost).
 *    Any M/R/T/A (content differs, renamed, or local-only) means local work
 *    would be lost by reset → diverging.
 *  - untracked paths AT origin-tracked locations: must be blob-identical to
 *    origin's version (reset would delete them; identical ⇒ lossless).
 *  - untracked paths origin does NOT track: preserved by reset — not blockers.
 *
 * Missing origin/<branch> ref ⇒ NOT superseded (fail-closed; never reset to
 * a nonexistent ref). Returns { superseded, diverging } where diverging lists
 * the non-superseded paths for triage.
 */
export function dirtySuperseded(
  cwd: string,
  refSha: string, // verified origin/<branch> sha captured at the call site (TOCTOU-safe)
): { superseded: boolean; diverging: string[] } {
  const qRef = q(refSha); // injection-safe interpolation (sha is hex-only, but quote anyway)
  const diverging: string[] = [];
  // Tracked worktree delta vs origin/<branch>: only status D is allowed
  // (origin has a file the local tree lacks — reset RESTORES it, lossless).
  // Any other status (M/R/T/A/C…) means local work would be lost → diverging.
  // Only the STATUS LETTER matters, so default-quoted output is fine here.
  const ns = tryGit(cwd, `diff --name-status ${qRef}`);
  if (ns === null) {
    return { superseded: false, diverging: ["check-failed: diff --name-status"] };
  }
  for (const line of ns.split("\n").filter(Boolean)) {
    const status = line.split("\t")[0] || line;
    if (status !== "D") diverging.push(line.slice(0, 120));
  }
  // Index-vs-origin delta (MM hole): staged content that differs from origin
  // is only safe if it is also in HEAD (committed → recoverable by reset,
  // which moves HEAD). `git diff --cached origin/<branch>` non-D entries with
  // `git diff --cached HEAD` NON-empty → staged-only content → diverging.
  const cached = tryGit(cwd, `diff --cached --name-status ${qRef}`);
  if (cached === null) {
    return { superseded: false, diverging: ["check-failed: diff --cached --name-status"] };
  }
  if (cached.split("\n").filter(Boolean).some((l) => (l.split("\t")[0] || l) !== "D")) {
    const cachedVsHead = tryGit(cwd, "diff --cached --name-status HEAD");
    if (cachedVsHead === null) {
      diverging.push("check-failed: diff --cached HEAD");
    } else if (cachedVsHead.trim().length > 0) {
      diverging.push("index has staged content not present in HEAD or origin");
    }
  }
  // Origin-tracked path set — exact, NUL-separated (no quoting artifacts).
  const ls = tryGit(cwd, `ls-tree -r --name-only -z ${qRef}`);
  if (ls === null) {
    return { superseded: false, diverging: ["check-failed: ls-tree"] };
  }
  const trackedSet = new Set(ls.split("\0").filter(Boolean));
  // Untracked AND IGNORED entries — `status --porcelain -z --ignored=all`
  // (collapsed dirs: `?? dir/` / `!! dir/`; -uall would hide dirs; git never
  // lists EMPTY untracked dirs — accepted, zero content). Ignored files are
  // otherwise INVISIBLE to status/diff, yet reset --hard also deletes ignored
  // files "in the way of writing any tracked files" (e.g. a gitignored local
  // .env at a path origin now tracks — unrecoverable since never staged).
  // git reset --hard deletes untracked
  // files/dirs "in the way of writing any tracked files", so any path
  // overlap with an origin-tracked path is a potential delete → diverging
  // unless it is an exact-path FILE match with an identical blob.
  // assume-unchanged tracked mods (`git update-index --assume-unchanged`, the
  // widespread "pin local config" pattern) are invisible to diff/status — yet
  // reset --hard still overwrites them. `git ls-files -v` flags them with a
  // lowercase 'h'; compare their local blob vs origin → differ ⇒ diverging.
  const lsf = tryGit(cwd, "ls-files -v -z");
  if (lsf === null) {
    return { superseded: false, diverging: ["check-failed: ls-files -v"] };
  }
  for (const rec of lsf.split("\0").filter(Boolean)) {
    if (rec[0] !== "h") continue; // assume-unchanged only ('s' skip-worktree is preserved by reset)
    const path = rec.slice(2); // -z emits raw paths, no quotepath C-escaping
    if (!trackedSet.has(path)) continue; // genuinely absent from origin — preserved
    const originBlob = tryGit(cwd, `rev-parse ${qRef}:${q(path)}`);
    if (originBlob === null) {
      diverging.push(`check-failed: rev-parse for assume-unchanged ${path}`);
      continue;
    }
    const localHash = tryGit(cwd, `hash-object ${q(path)}`);
    if (localHash === null || localHash !== originBlob) diverging.push(`assume-unchanged: ${path}`);
  }
  // Case-insensitive filesystems (macOS APFS / Windows NTFS, core.ignorecase
  // = true by default for clones) can have a local `readme.md` collide with an
  // origin-tracked `Readme.md` — byte-case Set membership would miss it and
  // reset --hard would destroy the local file. Fold both sides when the repo
  // is case-insensitive.
  const ignoreCase = tryGit(cwd, "config --bool core.ignorecase") === "true";
  const fold = (s: string): string => (ignoreCase ? s.toLowerCase() : s);
  const trackedList = [...trackedSet];
  const statusZ = tryGit(cwd, "status --porcelain -z --ignored=traditional");
  if (statusZ === null) {
    return { superseded: false, diverging: ["check-failed: status --porcelain"] };
  }
  for (const entry of statusZ.split("\0").filter(Boolean)) {
    if (!entry.startsWith("?? ") && !entry.startsWith("!! ")) continue;
    const u = entry.slice(3);
    const isDir = u.endsWith("/");
    const path = isDir ? u.slice(0, -1) : u;
    const pf = fold(path);
    // exact-path collision — allow only if blob-identical (resolve the REAL
    // case of the tracked path so `rev-parse ref:path` resolves on the fs)
    const real = trackedList.find((t) => fold(t) === pf) ?? null;
    if (!isDir && real !== null) {
      const originBlob = tryGit(cwd, `rev-parse ${qRef}:${q(real)}`);
      const localHash = tryGit(cwd, `hash-object ${q(path)}`);
      if (originBlob === null || localHash === null || localHash !== originBlob) {
        diverging.push(u); // exact-path collision with different content
      }
    } else if (
      trackedList.some((t) => {
        const tf = fold(t);
        return tf === pf || tf.startsWith(pf + "/") || pf.startsWith(tf + "/"); // exact or any prefix overlap
      })
    ) {
      diverging.push(u); // reset would write a tracked path at/under this untracked/ignored file/dir
    }
    // else: no origin overlap — preserved by reset, not a blocker
  }
  return { superseded: diverging.length === 0, diverging };
}
export function mergeOrRebaseInProgress(cwd: string): boolean {
  // --absolute-git-dir works on POSIX AND Windows drive-letter paths
  const gitDir = tryGit(cwd, "rev-parse --absolute-git-dir");
  if (!gitDir) return false;
  return existsSync(`${gitDir}/MERGE_HEAD`) || existsSync(`${gitDir}/REBASE_HEAD`) || existsSync(`${gitDir}/rebase-merge`) || existsSync(`${gitDir}/rebase-apply`) || existsSync(`${gitDir}/CHERRY_PICK_HEAD`) || existsSync(`${gitDir}/REVERT_HEAD`) || existsSync(`${gitDir}/BISECT_LOG`);
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
    execSync(`git -C "${cwd}" pull --ff-only origin ${q(branch)}`, {
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
    | "pulled" | "pull-failed" | "warn-behind" | "report-feature-branch"
    | "cleaned-superseded";
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
    tryGit(cwd, `fetch origin ${q(branch)} --quiet`, { timeout: FETCH_TIMEOUT_MS });
    const n = behindCount(cwd, branch);
    if (n > 0) {
      log(`[repo-freshness] ℹ️  ${cwd}: branch '${current}' is ${n} commit(s) behind origin/${branch} — reconcile before PR (commit-workflow Pre-PR Freshness Check)`);
    }
    return report("report-feature-branch", `behind=${n}`);
  }

  // Default branch: fetch first (silent failure = offline)
  const fetched = tryGit(cwd, `fetch origin ${q(branch)} --quiet`, { timeout: FETCH_TIMEOUT_MS });
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
    const dirtyCount = (tryGit(cwd, "status --porcelain") ?? "").split("\n").filter(Boolean).length;
    if (getFreshnessMode(env) !== "warn" && !autoHealDisabled(env)) {
      // Capture the verified origin/<branch> sha BEFORE the classification and
      // reset to THAT sha (TOCTOU-safe — a concurrent fetch must not move the
      // target between the lossless check and the reset).
      const refSha = tryGit(cwd, `rev-parse ${q(`origin/${branch}`)}`);
      if (refSha) {
        const sup = dirtySuperseded(cwd, refSha);
        if (sup.superseded) {
          // Every dirty path's content is already on origin/<branch> — reset is
          // provably lossless. This is the "staged work already merged via PRs"
          // class; auto-cleaning it prevents 100s of commits of silent drift.
          const reset = tryGit(cwd, `reset --hard ${q(refSha)}`, { timeout: PULL_TIMEOUT_MS });
        if (reset !== null) {
            log(`[repo-freshness] 🧹 ${cwd}: auto-cleaned superseded dirty tree (was ${n} behind; ${dirtyCount} dirty path(s) already on origin/${branch}) — reset --hard ${refSha.slice(0, 8)}`);
            return report("cleaned-superseded", `behind=${n} dirty=${dirtyCount}`);
          }
          log(`[repo-freshness] ⚠️  ${cwd}: superseded dirty tree but git reset --hard failed — manual triage: bash scripts/stale-main-triage.sh`);
          return report("pull-failed", "reset refused");
        }
        const sample = sup.diverging.slice(0, 3).join(", ") + (sup.diverging.length > 3 ? ", …" : "");
        log(`[repo-freshness] ⚠️  ${cwd}: ${n} behind origin/${branch}, DIRTY tree NOT superseded (${sup.diverging.length} diverging path(s): ${sample}) — never auto-touched. Triage: bash scripts/stale-main-triage.sh`);
        return report("warn-behind", `dirty+diverging=${sup.diverging.length}`);
      }
      log(`[repo-freshness] ⚠️  ${cwd}: could not resolve origin/${branch} — skipping auto-heal (manual triage: bash scripts/stale-main-triage.sh)`);
      return report("warn-behind", "ref-unresolvable");
    }
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
    if (isPrintMode()) return;
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
