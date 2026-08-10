import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { execSync } from "child_process";
import * as fs from "fs";
import * as os from "os";
import { resolve as resolvePath } from "path";
import { appendJsonl, type GateEventName } from "../shared/audit-log.js";

// Dual-support: check AGENT_* first, then ELDATO_* (Phase 1 — #7549)
function _getEnv(name: string): string | undefined {
  return process.env[`AGENT_${name}`] ?? process.env[`ELDATO_${name}`];
}
function _skipReviewGate(): boolean {
  return _getEnv("SKIP_REVIEW_GATE") === "1";
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

// Priority 3: `cd <path> &&/; ...` prefix. Equivalent to verification-gate's
// extractCdPath (pi's bash tool keeps process.cwd() unchanged even when the
// shell script starts with "cd /worktree &&"), but takes the LAST cd in a
// chain (`cd /a && cd /b && gh ...` → /b), since that is the effective cwd
// when the gh command runs. Handles cd "path", cd 'path', unquoted, and ; chains.
export function extractCdPath(command: string): string | null {
  const re = /(?:^|\s)cd\s+(['"]?)([^;&|]+?)\1\s*(?:&&|;)/g;
  let m: RegExpExecArray | null;
  let last: RegExpExecArray | null = null;
  while ((m = re.exec(command)) !== null) {
    last = m;
  }
  return last ? resolvePath(last[2]) : null;
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

export function readReviewRecord(pr: number): ReviewRecord | null {
  try {
    const raw = fs.readFileSync(resolvePath(reviewsDir(), `${pr}.json`), "utf8");
    const rec = JSON.parse(raw) as ReviewRecord;
    if (!rec || typeof rec.head_sha !== "string" || typeof rec.verdict !== "string") return null;
    return rec;
  } catch {
    return null; // missing or corrupt record → treated as "no review"
  }
}

// Current PR head via the gate's own gh call, using the resolved repo context
// (cwd for `cd ... &&` prefixes, --repo flag for explicit owner/name). Returns
// null on ANY failure (network, bad repo, gh missing) — the fail-open signal.
export function getPrHeadSha(pr: number, ctx: RepoContext): string | null {
  try {
    const repoArg = ctx.repo ? ` --repo ${ctx.repo}` : "";
    const out = execSync(`gh pr view ${pr} --json headRefOid --jq .headRefOid${repoArg}`, {
      encoding: "utf-8",
      cwd: ctx.cwd,
      timeout: 15000,
    });
    const sha = out.trim();
    return sha || null;
  } catch {
    return null;
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
  ctx: RepoContext
): MergeGateResult {
  if (!record) {
    return {
      status: "block",
      reason: [
        "✅ Review enforcement (merge registry) gate is working correctly.",
        `❌ No review record found for PR #${pr} — the code-review gate has not recorded a clean review.`,
        "   → Run the code-review skill, then record the verdict:",
        "   →   record-review.sh <PR> <head_sha> clean [owner/repo]",
        "   → Emergency: set AGENT_SKIP_REVIEW_GATE=1 (or ELDATO_SKIP_REVIEW_GATE=1) and restart to bypass all gates.",
      ].join("\n"),
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
    // Fail-open with a loud warning: transient gh errors (network etc.) or an
    // unresolvable repo must never strand a cross-repo merge — blocking is
    // exactly the bug #138 fixes. Tell the user how to make it resolvable.
    const advice =
      ctx.source === "fallback"
        ? "The repo could not be resolved (fell back to the pi process cwd). If this PR is in " +
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

const BLOCK_MESSAGE = [
  "✅ Review enforcement gate is working correctly.",
  "❌ No reviewers were dispatched in this session before the git operation.",
  "   → Read operations/skills/code-review/SKILL.md for the review dispatch protocol.",
  "   → Dispatch reviewers via task sub-agents, then retry the git operation.",
  "   → Emergency: set AGENT_SKIP_REVIEW_GATE=1 (or ELDATO_SKIP_REVIEW_GATE=1) and restart to bypass all gates.",
].join("\n");

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
        if (process.env.PI_MODE !== "print") {
          console.log(
            JSON.stringify({
              event: "gate_bypass",
              reason: "escape_hatch",
              timestamp: new Date().toISOString(),
            })
          );
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

    // ── tool_call: block git ops if no reviewers (proportional) ──
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
        const record = readReviewRecord(prNumber);
        const ctx = resolveRepoContext(command, record);
        const currentHead = getPrHeadSha(prNumber, ctx);
        const result = evaluateMergeGate(prNumber, record, currentHead, ctx);
        if (result.status === "block") {
          console.log("[review-enforcer] 🚫 Merge registry gate blocked merge");
          logMergeGateDecision(prNumber, result, record); // #60: durable audit record
          return { block: true, reason: result.reason };
        }
        logMergeGateDecision(prNumber, result, record); // #60: durable audit record (pass or fail-open)
        console.log(result.status === "failopen" ? result.warning : result.message);
        return undefined;
      }

      if (dispatchCount > 0) {
        console.log(
          `[review-enforcer] ✅ ${dispatchCount} reviewer dispatch(es) — allowing git op`
        );
        return undefined;
      }

      // Proportional gate: micro tier → warn only, standard/complex/unset → block
      // Tier is read from marker file (env vars from bash export never reach Node.js)
      let tier = "";
      try {
        if (fs.existsSync(ISSUE_COMPLEXITY_FILE)) {
          tier = fs.readFileSync(ISSUE_COMPLEXITY_FILE, "utf8").trim().toLowerCase();
        }
      } catch (_err) { /* best-effort */ }
      if (tier === "micro") {
        console.log(
          "[review-enforcer] ⚠️  No reviewers dispatched — micro tier allows bypass. " +
          "Dispatch a reviewer sub-agent for non-trivial changes."
        );
        return undefined;
      }

      console.log("[review-enforcer] 🚫 Blocked — no reviewers dispatched");
      return { block: true, reason: BLOCK_MESSAGE };
    });

    // ── tool_result: count task dispatches ─────────
    pi.on("tool_result", async (event, _ctx) => {
      if (event.toolName !== "task") return undefined;
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
    if (process.env.PI_MODE !== "print") {
      console.log("[review-enforcer] ✅ Loaded — binary review dispatch enforcement active");
    }
  } catch (err: any) {
    console.log("[review-enforcer] ❌ Failed to load:", err.message);
  }
}
