import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { execSync } from "child_process";
import { isPrintMode } from "../shared/print-mode.js";
import * as fs from "fs";
import * as os from "os";
import { resolve as resolvePath } from "path";
import { appendJsonl, type GateEventName } from "../shared/audit-log.js";

// ── gh invocation seam (testable) ─────────────────────
// ESM named imports of builtin CJS modules (child_process) are not patchable
// from tests, so gh calls route through runGh(). Tests inject a fake via
// _setRunGhOverride() to exercise failure paths deterministically (no real gh).
/** Options for the gh runner (mirrors execSync's opts we use). */
export interface GhRunOpts {
  cwd?: string;
  timeout?: number;
  env?: NodeJS.ProcessEnv;
}

let runGhOverride: ((cmd: string, opts?: GhRunOpts) => string) | null = null;

/** TEST SEAM: replace the gh runner (returns the command's stdout, throws on
 * failure). Pass null to restore the real execSync-backed runner. Honored only
 * under NODE_ENV=test (review #212 security pass) so production code can never
 * accidentally honor a stray override. */
export function _setRunGhOverride(
  fn: ((cmd: string, opts?: GhRunOpts) => string) | null
): void {
  if (process.env.NODE_ENV === "test" || fn === null) runGhOverride = fn;
}

function runGh(cmd: string, opts?: GhRunOpts): string {
  if (runGhOverride !== null) return runGhOverride(cmd, opts);
  return execSync(cmd, { encoding: "utf-8", ...opts });
}

// Dual-support: check AGENT_* first, then ELDATO_* (Phase 1 — #7549)
function _getEnv(name: string): string | undefined {
  return process.env[`AGENT_${name}`] ?? process.env[`ELDATO_${name}`];
}
function _skipReviewGate(): boolean {
  return _getEnv("SKIP_REVIEW_GATE") === "1";
}

// #285 P1-2b: local task-sub-agent discriminator — mirrors verification-gate's
// isTaskSubAgent (TASK_HEARTBEAT=1 ∧ PI_MODE=print, the marker pair BOTH
// dispatchers force on task children). Drift-guarded by the E14-style source
// test in index.test.ts. Env-param seam (same pattern as verification-gate)
// keeps the #228 print-mode wiring gate green.
function isTaskSubAgent(
  env: Record<string, string | undefined> = process.env,
): boolean {
  return env.TASK_HEARTBEAT === "1" && env.PI_MODE === "print";
}
// Namespaced marker files (Phase 1 — #7549)
const ISSUE_COMPLEXITY_FILE = "/tmp/agent-issue-complexity";

// ponytail: binary counter — any task dispatch counts. Simpler than name-matching.
// Gate trusts the agent is well-intentioned but forgetful, not adversarial.

// ── Git operation patterns ────────────────────────────

const GIT_COMMIT_PATTERN = /(^|\s)git\s+(commit|push)(?=\s|$)/;
const GH_PR_PATTERN = /(^|\s)gh\s+pr\s+(create|merge)(?=\s|$)/;

function isGitOp(command: string): boolean {
  return GIT_COMMIT_PATTERN.test(command) || GH_PR_PATTERN.test(command);
}

// ── Merge registry gate (#138) ────────────────────────
// The gate must verify PRs in ANY repo. A previous prototype resolved the repo
// from the pi process cwd, so `gh pr merge <n>` for a PR in repo B — run from a
// session whose cwd is repo A — failed with "Could not resolve to a
// PullRequest with the number of N". Repo context is therefore resolved in
// priority order from the merge command itself, then the review record, with
// the pi cwd as a fail-open fallback (never block on an unresolvable repo).

export interface ReviewRecord {
  pr: number;
  head_sha: string;
  verdict: string;
  reviewed_at?: string;
  repo?: string; // owner/name — written by record-review.sh (optional, older records lack it)
}

/**
 * Registry key (#426): PR numbers collide across repos (a stale DMeer #441
 * record sat in agent-infra's 441.json and blocked its merge). Records are
 * now keyed <owner>-<repo>-<pr>.json when the repo is known. The slug
 * embeds both owner and repo in [A-Za-z0-9_.-]+ form — collision-free within
 * a single owner (a trailing -<pr> split is unambiguous). Two owners whose
 * slugs coincide (a-b/c vs a/b-c → a-b-c) overwrite the SAME file on disk;
 * readReviewRecord defends that class by comparing the record's embedded
 * repo field against the requested repo (P2-1, cycle 2). Legacy <pr>.json
 * stays readable ONLY via the fallback paths below.
 */
export function reviewRecordFile(repo: string | undefined, pr: number): string {
  const dir = reviewsDir();
  return repo
    ? resolvePath(dir, `${repo.replace("/", "-")}-${pr}.json`)
    : resolvePath(dir, `${pr}.json`);
}

function readRecordFile(path: string): ReviewRecord | null {
  try {
    const raw = fs.readFileSync(path, "utf8");
    const rec = JSON.parse(raw) as ReviewRecord;
    if (!rec || typeof rec.head_sha !== "string" || typeof rec.verdict !== "string") return null;
    // Security (#212 review): record.repo is interpolated into shell strings by
    // the gate — enforce the same charset the flag/env sources are validated
    // with. An invalid record is treated as absent (fail-closed).
    if (rec.repo !== undefined && !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(rec.repo)) return null;
    return rec;
  } catch {
    return null; // missing or corrupt record → treated as "no review"
  }
}

/**
 * Resolve owner/name from the origin remote of a git worktree — no network.
 * The effective cwd for `gh pr merge` is the LAST cd in the command chain
 * (extractCdPath) else the pi session cwd; the gh CLI itself would infer the
 * repo the same way. #426 review P0-1: plain `gh pr merge N` (no --repo /
 * GH_REPO= / cd) must still hit the repo-qualified registry, so the gate
 * resolves the repo from the merge ENVIRONMENT, not just the command text.
 */
export function repoFromGitRemote(dir: string): string | null {
  try {
    const url = execSync(`git -C "${dir}" config --get remote.origin.url`, {
      timeout: 3000,
      stdio: ["ignore", "pipe", "ignore"],
      encoding: "utf8",
    }).trim();
    const m = url.match(/github\.com[:/]([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+?)(?:\.git)?$/);
    return m ? m[1] : null;
  } catch {
    return null; // not a git dir / no origin / not GitHub → caller falls back
  }
}

export interface RepoContext {
  repo?: string; // owner/name → passed as --repo to the gate's own gh calls
  cwd?: string; // resolved cd path → passed as cwd to the gate's own gh calls
  source: "flag" | "env" | "cd" | "record" | "fallback";
}

// Extract the PR number from `gh pr merge <n>` (matches GH_PR_PATTERN verbs).
export function extractPrNumber(command: string): number | null {
  const m = command.match(/gh\s+pr\s+merge\s+(\d+)/);
  return m ? parseInt(m[1], 10) : null;
}

// Priority 1: explicit --repo owner/name (or -R, or --repo=owner/name) flag.
export function extractRepoFlag(command: string): string | null {
  const m = command.match(/(?:--repo|-R)(?:=|\s+)([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)/);
  return m ? m[1] : null;
}

// Priority 2: GH_REPO=owner/name env assignment prefix in the command.
export function extractGhRepoEnv(command: string): string | null {
  const m = command.match(/(?:^|\s)GH_REPO=([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)/);
  return m ? m[1] : null;
}

/**
 * Repo context is resolved in priority order from the merge command itself
 * (extractRepoFlag, then GH_REPO=, then cd — LAST cd in the chain wins, since
 * that is the effective cwd when the gh command runs), with the pi process
 * cwd as a fail-open fallback (never block on an unresolvable repo).
 *
 * The cd scan is SEGMENT-based (split on &&/;/newline), not a regex over the
 * whole command: prose arguments like `--comment "see; cd /tmp && …"` must
 * never parse as a cd chain (verification-gate fixed this class in #230), and
 * a bash-style newline-separated `cd /x\ngh pr merge` IS a cd chain (#426
 * review cycle 2 P2-2). parseCdChains ALSO reports unattributable cds (cycle
 * 3 P2-1): bash expands `~`, `$VAR`/`$(…)`/backticks and runs subshell
 * `(cd … && …)` — targets the parser cannot resolve statically. When such a cd
 * is present but unparsed, the effective merge cwd is UNKNOWN and the gate
 * must not fall back to the session cwd's repo (that fallback is how a
 * `cd ~/…/DMeer && merge` would get authorized by an agent-infra record —
 * the reverse #426).
 */

/** Expand a cd target the way bash would when statically resolvable.
 * `~`/`~/…` → home; a path still containing $/backtick is unresolvable
 * statically → null (bash WOULD expand it, so callers treat the cwd as
 * unattributable rather than guessing). */
export function expandCdTarget(path: string): string | null {
  if (path === "~") return os.homedir();
  if (path.startsWith("~/")) return resolvePath(os.homedir(), path.slice(2));
  if (/[$`]/.test(path)) return null;
  return resolvePath(path);
}

export interface CdChainInfo {
  last: string | null; // resolved path of the last parseable `cd <path>`
  unattributable: boolean; // a cd bash WILL run but we can't resolve its target
}

export function parseCdChains(command: string): CdChainInfo {
  // Quote-aware scan splitting on &&/;\n OUTSIDE quotes — prose like
  // `--comment "see; cd /tmp && …"` must never parse as a cd chain (#230
  // class). Counts standalone `cd` words outside quotes so unparseable forms
  // (subshell `(cd …`, `cd $VAR`, `cd "$(…)"`) are detected, not silently
  // mis-attributed to the session cwd (cycle 3 P2-1).
  const segments: string[] = [];
  let cur = "", q: string | null = null, esc = false;
  let cdWords = 0;
  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (esc) { cur += c; esc = false; continue; }
    if (q) {
      cur += c;
      if (c === "\\") esc = true;
      else if (c === q) q = null;
      continue;
    }
    if (c === '"' || c === "'") { q = c; cur += c; continue; }
    if (c === "&" && command[i + 1] === "&") { segments.push(cur); cur = ""; i++; continue; }
    if (c === ";" || c === "\n" || c === "|") {
      // `|` (incl. `||`) splits too — the real `cd /x || exit 1` idiom must
      // not capture `|| exit 1` into the cd target (cycle 4 P3).
      if (c === "|" && command[i + 1] === "|") i++;
      segments.push(cur); cur = ""; continue;
    }
    if (c === "c" && command.startsWith("cd", i)) {
      const after = command[i + 2];
      const before = command[i - 1];
      if (
        (after === undefined || /[\s;&|()]/.test(after)) &&
        (before === undefined || /[\s;&|(\n]/.test(before))
      ) {
        cdWords++;
      }
    }
    cur += c;
  }
  segments.push(cur);
  let last: string | null = null;
  for (const seg of segments) {
    const m = seg.match(/^\s*cd\s+(['"]?)(.+?)\1\s*$/);
    if (m) last = m[2];
  }
  if (last !== null) {
    const resolved = expandCdTarget(last.trim());
    return { last: resolved, unattributable: resolved === null };
  }
  // Bare `cd` (no target) → HOME in bash.
  const bare = segments.some((s) => /^\s*cd\s*$/.test(s));
  if (bare) return { last: os.homedir(), unattributable: false };
  // Any OTHER unparsed cd word (subshell `(cd …`, `cd $VAR`, `cd "$(…)"`, …)
  // means the effective cwd is unattributable — say so.
  return { last: null, unattributable: cdWords > 0 };
}

export function extractCdPath(command: string): string | null {
  return parseCdChains(command).last;
}

export function resolveRepoContext(command: string, record: ReviewRecord | null): RepoContext {
  const flag = extractRepoFlag(command);
  if (flag) return { repo: flag, source: "flag" };
  const env = extractGhRepoEnv(command);
  if (env) return { repo: env, source: "env" };
  const cdPath = extractCdPath(command);
  if (cdPath) return { cwd: cdPath, source: "cd" };
  if (record?.repo) return { repo: record.repo, source: "record" };
  return { source: "fallback" };
}

// Review records live at ~/.pi/agent/reviews/<PR>.json (written by record-review.sh).
export function reviewsDir(): string {
  return resolvePath(os.homedir(), ".pi", "agent", "reviews");
}

export function readReviewRecord(pr: number, repo?: string): ReviewRecord | null {
  // #426: repo-qualified lookup when the gate resolved the repo (from the merge
  // command --repo/GH_REPO/cd, or the merge environment's git remote). A record
  // written for ANOTHER repo must never satisfy this repo's gate.
  if (repo) {
    const qualified = readRecordFile(reviewRecordFile(repo, pr));
    if (qualified && qualified.repo !== undefined && qualified.repo !== repo) {
      // The file exists but claims a different repo (identical-slug overwrite
      // across owners, or tampering) — audit + treat as absent (P2-1).
      logGateEvent("review_record_collision", { pr, recordRepo: qualified.repo, gateRepo: repo });
      return null;
    }
    if (qualified) return qualified;
    // Legacy migration fallback: pre-#426 records live at <pr>.json with the
    // repo embedded. Read it ONLY when it belongs to this repo (or predates
    // the repo field entirely) — a cross-repo collision fails closed.
    const legacy = readRecordFile(reviewRecordFile(undefined, pr));
    if (legacy && legacy.repo !== undefined && legacy.repo !== repo) {
      // Real #426 collision (e.g. DMeer#441's record in 441.json while gating
      // agent-infra #441) — audit + treat as absent.
      logGateEvent("review_record_collision", { pr, recordRepo: legacy.repo, gateRepo: repo });
      return null;
    }
    return legacy;
  }
  // No repo context (flag/env/cd/remote all failed — the gh merge itself
  // would run in the session cwd). Trust ONLY records whose key proves their
  // repo:
  //   • a single uniquely-matching qualified file (<owner>-<repo>-<pr>.json),
  //   • a repo-less legacy record (predates the repo field — cannot be foreign).
  // A number-keyed legacy record that EMBEDS a repo is rejected (#426 review
  // P0-2): it may belong to a different repo's PR with the same number, and
  // must not satisfy this merge — nor drive the head lookup for the wrong PR.
  try {
    const dir = reviewsDir();
    const matches = fs
      .readdirSync(dir)
      .filter((f) => new RegExp(`^[A-Za-z0-9_.-]+-[A-Za-z0-9_.-]+-${pr}\.json$`).test(f));
    if (matches.length === 1) {
      const rec = readRecordFile(resolvePath(dir, matches[0]));
      if (rec) return rec;
    } else if (matches.length > 1) {
      logGateEvent("review_record_collision", { pr, ambiguous: matches });
      return null;
    }
  } catch {
    /* reviews dir absent → no qualified files */
  }
  const legacy = readRecordFile(reviewRecordFile(undefined, pr));
  if (legacy && legacy.repo !== undefined) {
    logGateEvent("review_record_collision", { pr, recordRepo: legacy.repo, gateRepo: null });
    return null;
  }
  return legacy;
}

// ── GraphQL rate-limit resilience (#192) ─────────────
// `gh pr view --json …` uses the GraphQL pool, which resets independently of
// the REST pool (`gh api rate_limit` is REST). Parallel sessions can exhaust
// the GraphQL pool while REST stays healthy (observed 2026-08-12, tortoise
// #982: the gate blocked mid-merge on "GraphQL: API rate limit already
// exceeded"). The gate must wait for the reset window and retry — not hard-
// fail the ceremony, and not silently skip head verification (the #138
// fail-open path) when the pool is merely temporarily exhausted.

/** True when a gh error message is the GraphQL rate-limit exhaustion signature.
 * Requires BOTH a rate-limit phrase AND a graphql mention (either order), or
 * the "already exceeded" phrasing — the bare "api rate limit" phrase is NOT
 * enough (REST-pool exhaustion is a different pool whose correct response is
 * not a bounded GraphQL wait; review #212). */
export function isGraphQLRateLimitError(msg: string): boolean {
  const m = msg ?? "";
  const rateLimitPhrase = /rate\s*limit/i.test(m);
  const mentionsGraphQL = /graphql/i.test(m);
  return (mentionsGraphQL && rateLimitPhrase) || /already exceeded/i.test(m);
}

/** Max wall-clock time (ms) the gate waits for the GraphQL reset window (#192).
 * Env-overridable (REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS); default 10 min — the
 * observed recovery was ~5 min; a full 1h window is reachable by raising it. */
export function rateLimitMaxWaitMs(): number {
  const n = parseInt(process.env.REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS ?? "600000", 10);
  return Number.isInteger(n) && n > 0 ? n : 600000;
}

/** Seconds until the GraphQL pool resets, read via the REST rate_limit endpoint
 * (independent pool — healthy when GraphQL is exhausted). null on failure. */
export function graphQLResetInSecs(cwd?: string): number | null {
  try {
    const out = runGh(`gh api rate_limit --jq '.resources.graphql.reset'`, { cwd, timeout: 15000 });
    const reset = parseInt(out.trim(), 10);
    if (!Number.isInteger(reset)) return null;
    return Math.max(0, reset - Math.floor(Date.now() / 1000));
  } catch {
    return null;
  }
}

function sleepAsync(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

/** REST-pool fallback for the PR head (#192): `gh api repos/{owner}/{repo}/pulls/{pr}`
 * uses the REST pool, which resets independently of the GraphQL pool — healthy
 * even when `gh pr view`'s GraphQL pool is exhausted. gh fills the {owner}/{repo}
 * placeholders from the resolved repo context (--repo flag / GH_REPO env / cwd
 * git remote). Returns the head SHA, or null on any failure (network, bad repo,
 * REST pool also rate-limited) — callers then decide wait-for-reset vs fail-open. */
export function getPrHeadShaViaRest(pr: number, ctx: RepoContext): string | null {
  // NOTE: `gh api` does NOT accept --repo (verified gh 2.97.0: "unknown flag") —
  // the repo is injected via GH_REPO env (the documented placeholder source).
  const cmd = `gh api repos/{owner}/{repo}/pulls/${pr} --jq .head.sha`;
  try {
    const out = runGh(cmd, {
      cwd: ctx.cwd,
      timeout: 15000,
      env: ctx.repo ? { ...process.env, GH_REPO: ctx.repo } : undefined,
    });
    const sha = out.trim();
    return sha || null;
  } catch {
    return null;
  }
}

/**
 * Current PR head via the gate's own gh call, using the resolved repo context
 * (cwd for `cd ... &&` prefixes, --repo flag for explicit owner/name). Returns
 * null on ANY non-rate-limit failure (network, bad repo, gh missing) — the
 * #138 fail-open signal. On GraphQL rate-limit exhaustion (#192) it FIRST tries
 * the independent REST pool (`gh api repos/{owner}/{repo}/pulls/{pr}` — instant
 * recovery, observed healthy while GraphQL was 0/5000); only if REST is also
 * unavailable does it wait for the GraphQL reset window (bounded by
 * rateLimitMaxWaitMs, polling `gh api rate_limit`) and retry — so a
 * parallel-session GraphQL burn cannot strand a merge or silently skip head
 * verification.
 */
export async function getPrHeadSha(pr: number, ctx: RepoContext): Promise<string | null> {
  const repoArg = ctx.repo ? ` --repo ${ctx.repo}` : "";
  const deadline = Date.now() + rateLimitMaxWaitMs();
  let attempt = 0;
  for (;;) {
    try {
      const out = runGh(`gh pr view ${pr} --json headRefOid --jq .headRefOid${repoArg}`, {
        cwd: ctx.cwd,
        timeout: 15000,
      });
      const sha = out.trim();
      return sha || null;
    } catch (e: any) {
      const msg = (e?.stderr ?? e?.message ?? "").toString();
      if (!isGraphQLRateLimitError(msg)) return null; // non-rate-limit → fail-open as before
      // #192: GraphQL pool exhausted → the independent REST pool is usually
      // healthy (observed 2026-08-12: REST 4978/5000, GraphQL 0/5000). Resolve
      // the head there INSTANTLY instead of sleeping for the reset window.
      const restSha = getPrHeadShaViaRest(pr, ctx);
      if (restSha !== null) {
        console.warn(
          `[review-enforcer] ♻️ #192: GraphQL rate limit — resolved head via REST ` +
          `(gh api pulls/${pr}) instead of waiting for the reset window`
        );
        return restSha;
      }
      // REST also unavailable (both pools down, network, bad repo) → wait for
      // the GraphQL reset window (bounded) and retry, as before.
      const waitSecs = graphQLResetInSecs(ctx.cwd);
      const remaining = deadline - Date.now();
      const waitMs = waitSecs === null
        ? Math.min(30000, remaining) // cannot read reset → fixed-interval poll
        : Math.min(waitSecs * 1000 + 5000, remaining); // reset + 5s buffer
      if (waitMs <= 0 || waitSecs === null && remaining < 30000) {
        console.warn(
          `[review-enforcer] ⚠️ #192: GraphQL rate limit outlasted the ` +
          `${Math.round(rateLimitMaxWaitMs() / 1000)}s cap — failing open (head verification skipped)`
        );
        return null;
      }
      attempt++;
      console.warn(
        `[review-enforcer] ⏳ #192: GraphQL rate limit (attempt ${attempt}) — ` +
        `waiting ${Math.round(waitMs / 1000)}s for the reset window, then retrying`
      );
      await sleepAsync(waitMs);
    }
  }
}

export type MergeGateResult =
  | { status: "block"; reason: string }
  | { status: "failopen"; warning: string }
  | { status: "allow"; message: string };

// Pure gate decision — separated from I/O so it is unit-testable.
export function evaluateMergeGate(
  pr: number,
  record: ReviewRecord | null,
  currentHead: string | null,
  ctx: RepoContext,
  taskSubAgent: boolean = false,
): MergeGateResult {
  if (!record) {
    // #285 Fix C: the emergency-bypass line is FALSE for task sub-agents — the
    // skip flag is already forced on them (#825) and the merge-registry gate
    // stays ACTIVE (#285 P1-2b), so the line would instruct an action that
    // cannot unlock the merge. Shape-aware: the parent session must record the
    // review instead.
    const lines = taskSubAgent
      ? [
          "✅ Review enforcement (merge registry) gate is working correctly.",
          `❌ No review record found for PR #${pr} — the code-review gate has not recorded a clean review.`,
          "   → The parent session must record the review:",
          "   →   record-review.sh <PR> <head_sha> clean [owner/repo]",
          "   → The bypass flag does NOT unlock sub-agent merges (#285).",
        ]
      : [
          "✅ Review enforcement (merge registry) gate is working correctly.",
          `❌ No review record found for PR #${pr} — the code-review gate has not recorded a clean review.`,
          "   → Run the code-review skill, then record the verdict:",
          "   →   record-review.sh <PR> <head_sha> clean [owner/repo]",
          "   → Emergency: set AGENT_SKIP_REVIEW_GATE=1 (or ELDATO_SKIP_REVIEW_GATE=1) and restart to bypass all gates.",
        ];
    return {
      status: "block",
      reason: lines.join("\n"),
    };
  }
  if (record.verdict !== "clean" && record.verdict !== "clean-micro") {
    return {
      status: "block",
      reason: [
        `❌ Review record for PR #${pr} has verdict "${record.verdict}" — only "clean" or "clean-micro" unlocks a merge.`,
        "   → Re-run the code-review skill on the current head and re-record: record-review.sh <PR> <head_sha> clean [owner/repo]",
      ].join("\n"),
    };
  }
  if (currentHead === null) {
    // #285: FAIL-CLOSED for task sub-agents. The #138 fail-open — "never
    // strand a cross-repo interactive merge" — exists for interactive
    // sessions that can diagnose/resolve a gh failure themselves. A task
    // sub-agent cannot: under the restricted-agent posture an unverifiable
    // head must NOT merge silently. It escalates to the parent session, which
    // runs the merge ceremony interactively (where fail-open still applies).
    if (taskSubAgent) {
      return {
        status: "block",
        reason: [
          "✅ Review enforcement (merge registry) gate is working correctly.",
          `❌ Could not verify head of PR #${pr} via gh (repo context: ${ctx.source}) — head verification is mandatory for sub-agent merges.`,
          "   → The sub-agent cannot complete the merge ceremony here.",
          "   → Return to the parent session: it records the review and runs the merge interactively.",
          "   →   record-review.sh <PR> <head_sha> clean [owner/repo]",
          "   → The #138 fail-open (merge without head verification) is interactive-only; sub-agent merges are fail-closed (#285).",
        ].join("\n"),
      };
    }
    // Fail-open with a loud warning: transient gh errors (network etc.) or an
    // unresolvable repo must never strand a cross-repo merge — blocking is
    // exactly the bug #138 fixes. Tell the user how to make it resolvable.
    const advice =
      ctx.source === "fallback" && !ctx.repo
        ? "The repo could not be resolved (no --repo/GH_REPO/cd, and the session cwd is not a GitHub worktree). If this PR is in " +
          "another repo, re-record with repo info — record-review.sh <PR> <head_sha> clean owner/repo — " +
          "or pass --repo owner/repo to gh pr merge."
        : "If this persists, re-record with repo info — record-review.sh <PR> <head_sha> clean owner/repo — " +
          "or pass --repo owner/repo to gh pr merge.";
    return {
      status: "failopen",
      warning:
        `⚠️  [review-enforcer] Could not verify head of PR #${pr} via gh (repo context: ${ctx.source}). ` +
        `Allowing merge WITHOUT head verification. ${advice}`,
    };
  }
  if (record.head_sha !== currentHead) {
    return {
      status: "block",
      reason: [
        `❌ PR #${pr} head has advanced since the review was recorded.`,
        `   Recorded: ${record.head_sha.slice(0, 12)}   Current: ${currentHead.slice(0, 12)}`,
        "   → The branch moved — re-review the new head and re-record: record-review.sh <PR> <head_sha> clean [owner/repo]",
      ].join("\n"),
    };
  }
  return {
    status: "allow",
    message:
      `[review-enforcer] ✅ Merge registry gate passed for PR #${pr} ` +
      `(clean review, head ${currentHead.slice(0, 12)} matches) — allowing merge`,
  };
}

// ── Durable audit trail (#60) ─────────────────────────
// Every gate bypass and review-dispatch event is appended to
// ~/.pi/agent/audit/gate-events.jsonl (see shared/audit-log.ts). Fail-safe:
// appendJsonl never throws, so auditing can never alter a gate decision.
// Optional `file` override exists for tests (temp log path).

export function logGateEvent(
  event: GateEventName,
  extra: Record<string, unknown> = {},
  file?: string
): void {
  appendJsonl(
    { event, extension: "review-enforcer", ...extra, session_cwd: process.cwd() },
    file
  );
}

// Short tag for merge_gate_block entries — mirrors evaluateMergeGate's
// block branches (no review record / non-clean verdict / head advanced).
export function mergeGateBlockReason(record: ReviewRecord | null): string {
  if (!record) return "no_review_record";
  if (record.verdict !== "clean" && record.verdict !== "clean-micro") return "verdict_not_clean";
  return "head_advanced";
}

// Record the merge-gate decision: block → merge_gate_block with a short
// reason; allow AND fail-open (allow-with-warning) → merge_gate_pass
// (fail-open marked via reason "failopen" so the audit trail shows the merge
// was allowed without head verification).
export function logMergeGateDecision(
  pr: number,
  result: MergeGateResult,
  record: ReviewRecord | null,
  file?: string
): void {
  if (result.status === "block") {
    logGateEvent("merge_gate_block", { pr, reason: mergeGateBlockReason(record) }, file);
  } else {
    logGateEvent(
      "merge_gate_pass",
      { pr, ...(result.status === "failopen" ? { reason: "failopen" } : {}) },
      file
    );
  }
}

// ── Block message ─────────────────────────────────────

// #517: the code-review-skill path is repo-layout-dependent — agent-infra
// keeps skills at skills/, consumer repos sync them to operations/skills/
// (the consumer-repo hardlink location). The extension is repo-agnostic
// (runs in both layouts and in deployed copies), so BLOCK_MESSAGE names BOTH
// layouts rather than doing runtime repo detection: the blocked agent reads
// whichever path exists in their repo. Pinned by index.test.ts #517 + T1b
// (tail-anchored, so the pin survives both forms).
const BLOCK_MESSAGE = [
  "✅ Review enforcement gate is working correctly.",
  "❌ No reviewers were dispatched in this session before the git operation.",
  "   → Read skills/code-review/SKILL.md for the review dispatch protocol (operations/skills/code-review/SKILL.md in consumer repos).",
  "   → Dispatch reviewers via task sub-agents, then retry the git operation.",
  "   → Emergency: set AGENT_SKIP_REVIEW_GATE=1 (or ELDATO_SKIP_REVIEW_GATE=1) and restart to bypass all gates.",
].join("\n");
export { BLOCK_MESSAGE };

// #485: micro is no longer a 0-dispatch pass-through — the VGATE docs/CSS/static
// shape skip (#472) removed the backstop that made that leniency safe (a
// docs-only micro commit at 0 dispatches cleared every enforced gate). Micro now
// BLOCKS at 0 dispatches like every tier. The micro remediation must NOT point
// at the code-review skill: micro skips the multi-agent code-review gate
// (commit-workflow 03-code-review.md), so BLOCK_MESSAGE above would misdirect a
// blocked micro agent.
export const MICRO_BLOCK_MESSAGE = [
  "✅ Review enforcement gate is working correctly.",
  "❌ No reviewers were dispatched in this session before the git operation (micro tier).",
  "   → Micro skips the multi-agent code-review GATE (commit-workflow 03-code-review.md) — the review-enforcer ≥1-dispatch rule still applies (#485).",
  "   → Docs-only sets (VGATE content-shape exempt) need a lightweight reviewer dispatch naming the diff — even a trivial one-line review counts:",
  "   →   task(prompt='[REVIEW] docs-only change — verify claims/consistency against the docs diff; return NO ISSUES FOUND or list issues')",
  "   → Code sets satisfy the dispatch via VGATE: its [VGATE] verification dispatch counts as the required sub-agent dispatch. With VGATE disabled/bypassed, dispatch any lightweight task sub-agent — the gate counts any sub-agent dispatch (the `task` or `subagent` tool).",
  "   → Emergency: set AGENT_SKIP_REVIEW_GATE=1 (or ELDATO_SKIP_REVIEW_GATE=1) and restart to bypass all gates.",
].join("\n");

// #485: uniform ≥1-dispatch policy declaration — every tier blocks at 0
// dispatches. Declarative: consumed by the drift-pin test (fence ↔ export
// compare in index.test.ts T2) only — the block decision is uniform, so no
// production branch consults it; T1/T1b/T3 carry the code↔behavior pins.
// Keys: micro/standard/complex = marker values written by 01-preflight Tier
// Detection; unknown = the literal pre-flight TIER when the issue is
// unlabeled; unlabeled = no marker file present. All map to "block".
export const TIER_RULE = {
  micro: "block",
  standard: "block",
  complex: "block",
  unknown: "block",
  unlabeled: "block",
} as const;

// ── Extension ─────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  try {
    // ── State ──────────────────────────────────────
    let extensionEnabled = true;
    let dispatchCount = 0;

    // ── session_start ──────────────────────────────
    pi.on("session_start", async (_event, _ctx) => {
      dispatchCount = 0;

      // Warn about env vars that never reach Node.js from bash export
      // (these have no effect — tier is read from marker file, skip gate from escape hatch)
      const complexityVar = process.env.AGENT_ISSUE_COMPLEXITY || process.env.ELDATO_ISSUE_COMPLEXITY;
      if (complexityVar) {
        console.log(
          "⚠️  REVIEW-ENFORCER: ISSUE_COMPLEXITY detected in parent shell " +
          `— this has no effect. Tier is read from ${ISSUE_COMPLEXITY_FILE} marker file. ` +
          "Unset this env var to clear the stale state."
        );
      }

      if (_skipReviewGate()) {
        if (isTaskSubAgent()) {
          // #285 P1-2b/P2-a: AGENT_SKIP_REVIEW_GATE=1 is FORCED on task
          // children by both dispatchers (#825) — for them it is NOT a bypass:
          // review DISPATCH stays parent-enforced (the parent runs the review
          // ceremony for the PR as a whole), and the merge-registry gate stays
          // ACTIVE below. Audit the truthful event — gate_bypass/escape_hatch
          // would be a false record for a session that is NOT bypassed.
          extensionEnabled = true;
          console.log(
            "[review-enforcer] review DISPATCH is parent-enforced (#825) — the parent session runs the review ceremony; VGATE + merge-registry gate protect this PR"
          );
          appendJsonl({ event: "review_gate_parent_enforced", extension: "review-enforcer", subagent: true, session_cwd: process.cwd() });
        } else {
          extensionEnabled = false;
          console.log(
            "⚠️  REVIEW GATES DISABLED — all quality checks bypassed.",
            "To re-enable, unset AGENT_SKIP_REVIEW_GATE (or ELDATO_SKIP_REVIEW_GATE) and restart."
          );
          // #60: durable audit record — the console.log JSON below stays, this
          // ADDS the persistent trail (append-only JSONL, fail-safe).
          logGateEvent("gate_bypass", { reason: "escape_hatch" });
          // bypass log — machine-readable JSON. Only emit in interactive mode:
          // in print mode (sub-agents) this bare JSON would land on stderr and
          // contaminate tool-result content, breaking downstream JSON parsers.
          // Same guard as the startup banner below. #133
          if (!isPrintMode()) {
            console.log(
              JSON.stringify({
                event: "gate_bypass",
                reason: "escape_hatch",
                timestamp: new Date().toISOString(),
              })
            );
          }
        }
      } else {
        extensionEnabled = true;
      }
    });

    // ── session_shutdown ───────────────────────────
    pi.on("session_shutdown", async (_event, _ctx) => {
      dispatchCount = 0;
      // Clear marker file to prevent persistent state leakage across sessions
      try {
        if (fs.existsSync(ISSUE_COMPLEXITY_FILE)) {
          fs.unlinkSync(ISSUE_COMPLEXITY_FILE);
          console.log(`[review-enforcer] 🧹 Cleared ${ISSUE_COMPLEXITY_FILE} marker on shutdown`);
        }
      } catch (_err) { /* best-effort cleanup */ }
    });

    // ── tool_call: block git ops if no reviewers (uniform ≥1-dispatch, all tiers) ──
    pi.on("tool_call", async (event, _ctx) => {
      if (!isToolCallEventType("bash", event)) return undefined;
      if (!extensionEnabled) return undefined;

      const command = String(event.input.command ?? "");
      if (!isGitOp(command)) return undefined;

      // #138: merge registry gate runs FIRST for `gh pr merge` commands.
      // A recorded clean review (registry record) IS the evidence — merges do
      // NOT also require dispatchCount > 0. That gate stays for git
      // commit/push and gh pr create, below.
      const prNumber = extractPrNumber(command);
      if (prNumber !== null) {
        // #426: repo resolution is command-first (--repo / GH_REPO / cd), then
        // the merge ENVIRONMENT — git remote of the cd target, else of the pi
        // session cwd — so plain `gh pr merge N` still hits the repo-qualified
        // registry. record.repo is deliberately NOT used to pick the PR for
        // head verification (review P0-2 false-allow: a foreign record must
        // not drive the head lookup for the wrong repo's PR).
        const cmdCtx = resolveRepoContext(command, null);
        const cdInfo = parseCdChains(command);
        // Cycle 4 P1: an unattributable cd (`cd $VAR`, `cd "$(…)"`, subshell
        // `(cd …)`) means the merge runs SOMEWHERE ELSE — but the no-repo read
        // and head-verify machinery below would attribute it to the session
        // cwd's repo (the exact wrong-repo-record allow this PR kills). Such
        // merges are handled here, before any record read or head fetch:
        // sub-agents fail CLOSED; interactive sessions get a VISIBLE fail-open
        // with remediation (consistent with #138's interactive-only fail-open
        // — the external ai-review-gate required check stays the backstop).
        const unattrib = cmdCtx.source === "fallback" && !cmdCtx.repo && cdInfo.unattributable && !cdInfo.last;
        if (unattrib) {
          const advice =
            "The merge command's cd target is not statically resolvable (subshell/$VAR/backtick cd, e.g. `(cd …)`, `cd $X`). " +
            `PR #${prNumber} cannot be attributed to a repo — re-run with an absolute-path cd or pass --repo owner/repo.`;
          if (isTaskSubAgent()) {
            const msg = `[review-enforcer] 🚫 Merge registry gate blocked — ${advice}`;
            logMergeGateDecision(prNumber, { status: "block", reason: msg }, null); // #60
            return { block: true, reason: msg };
          }
          const warn = `⚠️  [review-enforcer] ${advice} Allowing merge WITHOUT repo attribution or review-record check (interactive fail-open).`;
          console.log(warn);
          logMergeGateDecision(prNumber, { status: "failopen", warning: warn }, null); // #60
          return undefined;
        }
        // Session-cwd fallback fires ONLY for commands with NO cd at all (a
        // parsed cd target is resolved above; anything else would authorize a
        // cross-repo merge with the wrong repo's record).
        const cdPath = cmdCtx.source === "cd" ? cmdCtx.cwd : cdInfo.last;
        const envRepo =
          cmdCtx.repo ??
          (cdPath ? repoFromGitRemote(cdPath) : null) ??
          (cmdCtx.source === "fallback" && !cdInfo.unattributable && !cdInfo.last
            ? repoFromGitRemote(process.cwd())
            : null);
        const ctx = envRepo ? { ...cmdCtx, repo: envRepo } : cmdCtx;
        const record = readReviewRecord(prNumber, envRepo ?? undefined);
        const currentHead = await getPrHeadSha(prNumber, ctx);
        // #285 Fix C: the no-record block message is shape-aware (task
        // sub-agents get the "parent must record the review" variant).
        const result = evaluateMergeGate(prNumber, record, currentHead, ctx, isTaskSubAgent());
        if (result.status === "block") {
          console.log("[review-enforcer] 🚫 Merge registry gate blocked merge");
          logMergeGateDecision(prNumber, result, record); // #60: durable audit record
          return { block: true, reason: result.reason };
        }
        logMergeGateDecision(prNumber, result, record); // #60: durable audit record (pass or fail-open)
        console.log(result.status === "failopen" ? result.warning : result.message);
        return undefined;
      }

      // #285 P1-2b: task sub-agents skip the DISPATCH-count gate — review
      // dispatch is parent-enforced (#825) and their own in-band [VGATE]
      // dispatches are never counted (tool_result noise fix below). Only the
      // merge-registry gate above stays ACTIVE for them (fail-closed on
      // missing reviews/<PR>.json).
      const taskSubAgent = isTaskSubAgent();
      if (dispatchCount > 0 || (taskSubAgent && _skipReviewGate())) {
        console.log(
          taskSubAgent && dispatchCount === 0
            ? "[review-enforcer] ✅ Git op allowed — review DISPATCH is parent-enforced for this sub-agent (#825); the merge-registry gate protects merges"
            : `[review-enforcer] ✅ ${dispatchCount} reviewer dispatch(es) — allowing git op`
        );
        return undefined;
      }

      // #485: uniform ≥1-dispatch block — every tier (micro, standard, complex,
      // unlabeled) blocks at 0 dispatches. The tier read survives ONLY for
      // message selection: micro skips the multi-agent code-review gate
      // (03-code-review.md), so its remediation differs from BLOCK_MESSAGE.
      // Pinned by index.test.ts (behavioral T1/T1b + fence drift T2 + source
      // shape T3). The #285 task-sub-agent early return above is untouched.
      let tier = "";
      try {
        if (fs.existsSync(ISSUE_COMPLEXITY_FILE)) {
          tier = fs.readFileSync(ISSUE_COMPLEXITY_FILE, "utf8").trim().toLowerCase();
        }
      } catch (_err) { /* best-effort */ }
      // #516: BOTH block returns below must emit a durable audit entry — the
      // pre-#516 dispatch-count block wrote console only (no appendJsonl),
      // unlike the merge-registry gate's logMergeGateDecision trail, so
      // blocked-op frequency/attribution was unreconstructible from
      // gate-events.jsonl. Emit gate_block + reason no_reviewers_dispatch + the
      // TIER_RULE-vocabulary tier (micro | standard | complex | unknown |
      // unlabeled; marker-absent maps to "unlabeled") so the tier of every
      // blocked op — the docs-only micro class (#485) included — is
      // reconstructible. Pinned by index.test.ts T1 (micro) + T1b (others).
      if (tier === "micro") {
        console.log("[review-enforcer] 🚫 Blocked — no reviewers dispatched (micro tier)");
        logGateEvent("gate_block", { reason: "no_reviewers_dispatch", tier: "micro" }); // #516: durable audit
        return { block: true, reason: MICRO_BLOCK_MESSAGE };
      }

      console.log("[review-enforcer] 🚫 Blocked — no reviewers dispatched");
      logGateEvent("gate_block", { reason: "no_reviewers_dispatch", tier: tier === "" ? "unlabeled" : tier }); // #516: durable audit
      return { block: true, reason: BLOCK_MESSAGE };
    });

    // ── tool_result: count sub-agent dispatches ────
    pi.on("tool_result", async (event, _ctx) => {
      // The gate counts ANY sub-agent dispatch: the `task` tool or the
      // specialized-agent `subagent` tool (extensions/subagent). Both are
      // sub-agent dispatches — the content-free floor (#485 F2) makes no
      // quality distinction, and the #485 second-model gate flagged that a
      // docs-only micro change reviewed via the `subagent` tool must not
      // false-block post-flip (micro relies on this counter as its only gate;
      // VGATE is shape-exempt and code review is skipped at micro).
      if (event.toolName !== "task" && event.toolName !== "subagent") return undefined;
      // #285 P2: task sub-agents never count dispatches — review DISPATCH is
      // parent-enforced (#825), and their own in-band [VGATE] dispatches must
      // not be counted/audited as review dispatches. (Today they never reach
      // this point: extensionEnabled was false; under P1-2b it stays true, so
      // this early return is what keeps the noise out.)
      if (isTaskSubAgent()) return undefined;
      if (!extensionEnabled) return undefined;

      dispatchCount++;
      console.log(
        `[review-enforcer] 📊 Reviewer dispatch counted (total: ${dispatchCount})`
      );
      // #60: durable per-event record — the running total is stamped on each
      // entry so the dispatch count is reconstructible from the audit log.
      logGateEvent("review_dispatch", { dispatch_count: dispatchCount });
      return undefined;
    });

    // ── startup banner ────────────────────────────
    if (!isPrintMode()) {
      console.log("[review-enforcer] ✅ Loaded — binary review dispatch enforcement active");
    }
  } catch (err: any) {
    console.log("[review-enforcer] ❌ Failed to load:", err.message);
  }
}
