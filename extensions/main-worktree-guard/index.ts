// See also: pi settings.json PreToolUse hook for Claude Code equivalent.
// This extension is the authoritative definition.
//
// Guards the SHARED main checkout of a project against:
//  1. write/edit tool calls (collision between parallel agents),
//  2. destructive/state-changing git commands via the bash tool (git reset
//     --hard, branch checkout/switch, pull/merge/rebase, clean, force-push,
//     branch -D, restore, stash pop), and
//  3. (#265) cross-session BRANCH OWNERSHIP: the shared checkout is a
//     multi-actor resource — one session's `git checkout` moves the branch
//     under every other session, so commits land on the wrong branch and
//     reviewers read stale heads. A per-session baseline is recorded at
//     session_start; M1 warns on branch deviation (every tool_call), M2
//     blocks commit/push off-baseline, M3 gates branch-state mutations, and
//     an ownership allowance keeps the agent-infra merge ceremony working.
//
// Worktrees are ISOLATED — none of this applies inside a worktree. The only
// escape hatch is AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) or
// the TTL'd file marker (#207) for deliberate solo sessions; under the hatch
// M2/M3 are inactive (escape-hatch contract preserved) but M1 detection stays
// ACTIVE. There is NO auto-bypass: the guard blocks every time, so a
// rogue/parallel agent cannot retry its way past it.
//
// Degradation contract:
//  - classify-git.mjs load failure → bash git guard degrades to warn-only
//    (fail-safe, never false-blocks) while the write/edit guard stays fully
//    enforced.
//  - branch-ownership.mjs load failure → M1/M2/M3 are OFF (one-time warn) and
//    the guard falls back to TODAY's behavior (agent-infra exempt); write/edit
//    never depends on either module.
//  - isWorktreeCwd defaults are SPLIT: the bash path fails OPEN (() => true —
//    a worktree lookalike is treated as isolated), the write/edit path fails
//    CLOSED (() => false — an unverifiable target is treated as main and
//    blocked). This fixes the latent fail-open at the old shared default.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { execSync } from "node:child_process";
import { resolve, dirname, join } from "node:path";
import { mkdirSync, writeFileSync } from "node:fs";
import { isAllowMarkerValid } from "./classify-git.mjs";
import { homedir } from "node:os";
import { realpathSync, existsSync } from "node:fs";
import { isPrintMode } from "../shared/print-mode.js";

// Shared destructive-git rules (also used by test.mjs). If the import ever
// fails (jiti resolution edge case), the bash guard degrades to warn-only
// while write/edit protection stays fully enforced.
let classifyGitCommand: (cmd: string) => string = () => "allow";
let classifyGitCommandDetailed: (cmd: string) => any = () => ({ verdict: "allow" });
let isWorktreeCwd: (cwd: string) => boolean = () => true;      // bash path: fail-open
let isWorktreeCwdWrite: (cwd: string) => boolean = () => false; // write/edit: fail-closed
let extractPushDeleteBranch: (cmd: string) => string[] | null = () => null;
let getWorktreeBranches: () => Map<string, string[]> = () => new Map();
let isBranchInMainCheckout: (branch: string) => boolean = () => false;
let getMainCheckoutBranch: () => string | null = () => null;
let isAgentInfraRepo: (cwd?: string, env?: Record<string, string | undefined>) => boolean = () => false;
let classifierLoaded = false;
try {
  ({ classifyGitCommand, classifyGitCommandDetailed, isWorktreeCwd,
     extractPushDeleteBranch, getWorktreeBranches, isBranchInMainCheckout,
     getMainCheckoutBranch, isAgentInfraRepo } =
    await import("./classify-git.mjs"));
  classifierLoaded = true;
  isWorktreeCwdWrite = isWorktreeCwd; // real function once loaded
} catch (e) {
  console.warn("[main-worktree-guard] ⚠️ classify-git.mjs failed to load — bash git guard DISABLED:", String(e));
}

// #265: branch-ownership sentinel (baseline + M1/M2/M3 decisions + repo lock).
// Try/catch-guarded: load failure → M1/M2/M3 OFF + one-time warn; write/edit
// never depends on it.
let branchOwnership: any = null;
try {
  branchOwnership = await import("../shared/branch-ownership.mjs");
} catch (e) {
  console.warn("[main-worktree-guard] ⚠️ branch-ownership.mjs failed to load — M1/M2/M3 branch-ownership guards DISABLED (falling back to legacy behavior):", String(e));
}

// Dual-support: check AGENT_* first, then ELDATO_* (Phase 1 — #7549)
function _getEnv(name: string): string | undefined {
  return process.env[`AGENT_${name}`] ?? process.env[`ELDATO_${name}`];
}
// ── TTL'd file-based escape marker (#207) ─────────────────────
// The env hatch (AGENT_ALLOW_MAIN_EDITS=1) cannot be set on a RUNNING pi
// process — a stranded main checkout was unrecoverable by agents until a
// human intervened in a terminal. A deliberate solo session can now grant
// itself the same bypass for a bounded window by creating a marker file:
//
//   touch ~/.pi/agent/.allow-main-edits
//
// The marker is TTL'd (default 15 min), re-read on every tool_call (never
// cached), and never applies to parallel sessions automatically. Creation is
// logged with a reason when the reason is provided (marker content = reason).
const ALLOW_MARKER_DEFAULT = join(homedir(), ".pi", "agent", ".allow-main-edits");
const ALLOW_MARKER_TTL_MS = 15 * 60_000;

function _allowMarkerPath(): string {
  return process.env.ALLOW_MAIN_EDITS_MARKER || ALLOW_MARKER_DEFAULT;
}

/** Marker valid when the file exists, is a regular file, and is younger than
 * the TTL. Re-reads on every call — expiry is checked per tool_call, never
 * cached (pure check in classify-git.mjs, shared with test.mjs, #207). */
function _isAllowMarkerValid(): boolean {
  return isAllowMarkerValid(_allowMarkerPath(), Date.now(), ALLOW_MARKER_TTL_MS);
}

/** Marker creation with an audit trail: the marker's content carries the
 * reason; the session log announces it once. Returns the marker path. */
export function createAllowMarker(reason = "deliberate solo session"): string {
  const path = _allowMarkerPath();
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${reason} (${new Date().toISOString()})
`, "utf-8");
  console.log(
    `[main-worktree-guard] ⏳ Escape marker created: ${path} (TTL ${ALLOW_MARKER_TTL_MS / 60_000}min, reason: ${reason})`,
  );
  return path;
}

function _isAllowMainEdits(): boolean {
  return _getEnv("ALLOW_MAIN_EDITS") === "1" || _isAllowMarkerValid();
}

function _mainTopLevel(): string | null {
  try {
    return resolve(
      execSync("git rev-parse --show-toplevel", {
        encoding: "utf-8", cwd: resolve(process.cwd()), timeout: 5000,
      }).trim()
    );
  } catch {
    return null;
  }
}

const WHY = [
  "⛔ Operation blocked in the MAIN checkout.",
  "   Why: the main checkout is SHARED between parallel agents. Branch-state",
  "   changes and hard resets here silently destroy other agents' uncommitted",
  "   work and move branches out from under them (incident 2026-08-06: a",
  "   `git reset --hard origin/main` wiped an in-progress PR mid-review; #265:",
  "   one session's checkout moved every other session's branch).",
  "   → Work in an isolated worktree: invoke the using-git-worktrees skill.",
  "   → Or set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) for",
  "     deliberate solo sessions.",
].join("\n");

// ── #265 per-session baseline state ────────────────────────────────────────
// Keyed by process.pid (one pi process == one session; SessionStartEvent
// carries no sessionId). Baseline = { repoKey, branch, head } of the shared
// MAIN checkout at session_start. M1 dedupe: Set of "from→to" deviations.
const baselines = new Map<number, { repoKey: string; branch: string | null; head: string }>();
const warnedDeviations = new Map<number, Set<string>>();
const pendingBaseline = new Set<number>(); // lock contended at session_start → record on first tool_call

function _recordBaseline(pid: number) {
  if (!branchOwnership) return;
  try {
    const cwd = resolve(process.cwd());
    const state = branchOwnership.readBranchState(cwd);
    if (!state) return;
    const key = branchOwnership.repoKey(cwd);
    if (!key) return;
    if (!baselines.has(pid)) {
      baselines.set(pid, { repoKey: key, branch: state.branch, head: state.head });
    }
  } catch { /* degrade silently — M1/M2 skip without a baseline */ }
}

function _rebaseline(pid: number, branch: string) {
  const baseline = baselines.get(pid);
  if (baseline && branch) {
    baselines.set(pid, { ...baseline, branch }); // head refreshed lazily (unused in decisions)
  }
}

// ── M1: warn on branch deviation (every tool_call, all tool types) ────────
function _m1(pid: number) {
  if (!branchOwnership) return;
  const baseline = baselines.get(pid);
  if (!baseline) return;
  try {
    // P2-B: only warn for the BASELINE repo's MAIN checkout. A session that
    // cd'd into a worktree or another repo gets a spurious (and misleading)
    // "commits are BLOCKED" warning — commits are NOT blocked in a worktree.
    if (isWorktreeCwdWrite(resolve(process.cwd()))) return;
    const keyNow = branchOwnership.repoKey(process.cwd());
    if (!keyNow || keyNow !== baseline.repoKey) return;
    const state = branchOwnership.readBranchState(resolve(process.cwd()));
    if (!state) return;
    const dev = branchOwnership.decideM1(state.branch, baseline.branch);
    if (!dev) return;
    const key = `${dev.from}→${dev.to}`;
    let seen = warnedDeviations.get(pid);
    if (!seen) { seen = new Set(); warnedDeviations.set(pid, seen); }
    if (seen.has(key)) return;
    seen.add(key);
    console.warn(
      `[main-worktree-guard] ⚠️ MAIN CHECKOUT BRANCH CHANGED mid-session (#265): ` +
      `baseline "${dev.from}" → current "${dev.to}". Another session/process switched ` +
      `the shared tree. Commits are BLOCKED until you check out your own branch.`
    );
  } catch { /* warn-only — never blocks reads */ }
}

export default function (pi: ExtensionAPI) {
  // ── Session-start: record the branch-ownership baseline + hub check ──────
  pi.on("session_start", async () => {
    const pid = process.pid;
    if (branchOwnership) {
      try {
        // Only main-checkout sessions get a baseline (worktrees are isolated).
        if (!isWorktreeCwdWrite(resolve(process.cwd()))) {
          const key = branchOwnership.repoKey(process.cwd());
          if (key) {
            // RETRIES (bounded, ~20s ceiling), never skips: a session without a
            // baseline is unguarded. Fallback: record on the first tool_call.
            const lock = branchOwnership.acquireRepoLock(key, pid, { timeoutMs: 20_000, retryMs: 250 });
            if (lock.held) {
              const state = branchOwnership.readBranchState(process.cwd());
              if (state && !baselines.has(pid)) {
                baselines.set(pid, { repoKey: key, branch: state.branch, head: state.head });
              }
              branchOwnership.releaseRepoLock(key, pid);
            } else {
              pendingBaseline.add(pid);
            }
          }
        }
      } catch (e) {
        console.warn("[main-worktree-guard] ⚠️ baseline record failed:", String(e));
      }
    }

    // ── Hub-discipline check (rehomed from extension-init; #73) ──
    // Interactive-only (deliberate sub-agent-noise fix: today print-mode
    // sub-agents DO receive the box) and skipped under the escape hatch.
    if (isPrintMode() || _isAllowMainEdits()) return;
    try {
      const inWorktree = isWorktreeCwdWrite(resolve(process.cwd()));
      if (inWorktree) return;
      const currentBranch = getMainCheckoutBranch();
      const porcelain = execSync("git status --porcelain", {
        encoding: "utf-8", timeout: 5000,
      }).trim();
      const onNonMain = currentBranch && currentBranch !== "main" && currentBranch !== "master";
      const dirty = porcelain.length > 0;

      if (isAgentInfraRepo()) {
        // Downgraded agent-infra variant: branch deviation is the NORM in the
        // infra repo (in-main feature work per #99) — warn on dirty tree only.
        if (dirty) {
          console.warn(`[main-worktree-guard] ⚠️ agent-infra main checkout is DIRTY (${porcelain.split("\n").length} change(s)) — parallel sessions may collide; commit or stash before other agents start.`);
        }
        return;
      }
      if (onNonMain || dirty) {
        const issues: string[] = [];
        if (onNonMain) issues.push(`on branch "${currentBranch}" (not main/master)`);
        if (dirty) issues.push("working tree is dirty (uncommitted changes or untracked files)");

        const lines = [
          "",
          "╔══════════════════════════════════════════════════════════════════╗",
          "║  ⚠️  MAIN CHECKOUT — HUB DISCIPLINE WARNING                      ║",
          "╠══════════════════════════════════════════════════════════════════╣",
        ];
        for (const issue of issues) {
          lines.push(`║  ${issue.padEnd(62)}║`);
        }
        lines.push(
          "║                                                                  ║",
          "║  The main checkout is a shared hub — parallel agents may collide. ║",
          "║  Feature work should happen in isolated worktrees.                ║",
          "║  → Invoke the using-git-worktrees skill to create one.            ║",
          "║  → Set AGENT_ALLOW_MAIN_EDITS=1 to suppress this warning.         ║",
          "╚══════════════════════════════════════════════════════════════════╝",
          "",
        );
        console.warn(lines.join("\n"));
      }
    } catch (e) {
      // Degrade silently — this is a non-blocking discipline check
      console.warn("[main-worktree-guard] ⚠️ Hub discipline check failed:", String(e));
    }
  });

  pi.on("tool_call", async (event, _ctx) => {
    const pid = process.pid;

    // M1 runs on EVERY tool_call (read included — a reviewer whose tree moved
    // mid-review sees the warn before proceeding, AC8). Active under the
    // marker/flag AND in print mode (swarm-style detection, scenario 4).
    if (pendingBaseline.has(pid)) {
      pendingBaseline.delete(pid);
      _recordBaseline(pid); // BEFORE this tool_call's guard evaluation
    }
    _m1(pid);

    const isWrite = isToolCallEventType("write", event);
    const isEdit = isToolCallEventType("edit", event);
    const isBash = isToolCallEventType("bash", event);
    if (!isWrite && !isEdit && !isBash) {
      return undefined;
    }

    // ── bash: branch-ownership + destructive git ──
    if (isBash) {
      const command = (event.input as { command?: string }).command ?? "";

      // ── Degradation fallback (branch-ownership OR detailed classifier
      // unavailable): behave exactly like today — agent-infra exempt,
      // string-verdict destructive blocks for non-infra main, marker bypass. ──
      if (!branchOwnership || !classifierLoaded) {
        if (isAgentInfraRepo()) return undefined;
        if (_isAllowMainEdits()) return undefined;
        const verdict = classifyGitCommand(command);
        if (verdict.startsWith("block:")) {
          if (verdict === "block:push-delete") {
            const branchNames = extractPushDeleteBranch(command);
            if (branchNames && branchNames.length > 0) {
              const worktreeBranches = getWorktreeBranches();
              const blockedBranches: string[] = [];
              for (const branchName of branchNames) {
                const branchRef = `refs/heads/${branchName}`;
                const checkedOutPaths = [...(worktreeBranches.get(branchRef) || [])];
                if (isBranchInMainCheckout(branchName)) {
                  const mainTopLevel = _mainTopLevel();
                  const mainLabel = mainTopLevel || "main checkout";
                  if (!checkedOutPaths.includes(mainLabel)) checkedOutPaths.push(mainLabel);
                }
                if (checkedOutPaths.length > 0) {
                  blockedBranches.push(`"${branchName}" — checked out in: ${checkedOutPaths.join(", ")}`);
                }
              }
              if (blockedBranches.length > 0) {
                return {
                  block: true,
                  reason: [
                    `⛔ Cannot delete — the following branches are currently checked out:`,
                    ...blockedBranches.map((b: string) => `   • ${b}`),
                    "",
                    "   Why: deleting a remote branch while another session has it",
                    "   checked out destroys that session's upstream (incident 2026-08-06).",
                    "   → Switch those worktrees/main to another branch first, then retry.",
                    "   → Or set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) to override.",
                  ].join("\n"),
                };
              }
            }
            return undefined;
          }
          let inWorktree = true;
          try {
            inWorktree = isWorktreeCwd(resolve(process.cwd()));
          } catch (e) {
            console.warn("[main-worktree-guard] ⚠️ isWorktreeCwd threw — blocking (safe default):", String(e));
            inWorktree = false;
          }
          if (!inWorktree) {
            const kind = verdict.slice("block:".length);
            return {
              block: true,
              reason: [
                `⛔ Destructive git command blocked in the main checkout (${kind}).`,
                ...WHY.split("\n").slice(1),
              ].join("\n"),
            };
          }
        }
        return undefined;
      }

      // ── Full branch-ownership path (#265) ──
      const det = classifyGitCommandDetailed(command);
      // P2 (cycle 3): resolve the effective repo against the STATE-mutating
      // invocation — `git -C <wt> status && git checkout main` must gate on the
      // main checkout, not the worktree the first invocation pointed at.
      const eff = branchOwnership.resolveEffectiveRepo(command, process.cwd(), det.stateVerb ?? det.verb);
      const allowActive = _isAllowMainEdits();

      // M3: branch-state gate — applies in ANY main checkout (resolved,
      // target-aware). Worktree-effective commands are exempt (cycle-4
      // verified: -C <wt> --git-dir=<main>/.git checkout operates on MAIN →
      // eff.isWorktree is false → NOT exempt).
      if (det && det.branchState && !allowActive) {
        // P1-A: classify the STATE-mutating invocation (compound commands like
        // `git pull && git checkout main` must gate on the checkout, not the pull).
        const branchOp = branchOwnership.classifyBranchOp(det.stateVerb ?? det.verb, det.stateArgs ?? det.verbArgs);
        if (branchOp && branchOp.op !== "other") {
          if (!eff) {
            return {
              block: true,
              reason: "⛔ Branch-state command blocked — could not resolve the effective repo (fail-closed; #265).",
            };
          }
          if (!eff.isWorktree) {
            const baseline = baselines.get(pid);
            const isInfra = isAgentInfraRepo(eff.effectiveCwd);
            const m3 = branchOwnership.decideM3({
              branchOp, isAgentInfra: isInfra, baseline,
              currentBranch: eff.currentBranch,
            });
            if (m3?.block) return { block: true, reason: m3.reason };
            if (m3?.reBaseline) {
              // Synchronous re-baseline: the allowed carve-out / own rename
              // adopts the new branch NOW — the next tool_call emits ZERO M1
              // warns (AC3).
              _rebaseline(pid, m3.reBaseline);
              return undefined;
            }
          }
        }
      }

      // Under the escape hatch, M2/M3 are inactive (contract preserved) but M1
      // above stays active. Legacy destructive blocks are also bypassed (today's
      // semantics — the hatch is a full bypass).
      if (allowActive) return undefined;

      if (!det || det.verdict === "allow" || det.verdict === "allow-non-git") return undefined;

      // ── Ownership allowance (agent-infra main, own baseline branch) ──
      // Predicate split (plan deviation 7): sync ops (pull/rebase/merge) gate on
      // current-branch == baseline; push/delete/branch -D gate on ALL targets ==
      // baseline (all-targets — a multi-refspec push or mixed delete must never
      // slip a foreign target past the gate).
      const ALLOWANCE: Record<string, string> = {
        "block:pull": "pull",
        "block:merge": "merge",
        "block:rebase": "rebase",
        "block:push": "push",
        "block:force-push": "force-push",
        "block:push-delete": "push-delete",
        "block:branch-force-delete": "branch-force-delete",
      };
      const allowanceKind = ALLOWANCE[det.verdict];
      if (allowanceKind && eff) {
        const baseline = baselines.get(pid);
        const targets = det.pushTargets && det.pushTargets.length > 0
          ? det.pushTargets
          : (det.newBranch ? [det.newBranch] : []);
        if (branchOwnership.ownershipAllowed({
          opKind: allowanceKind,
          currentBranch: eff.currentBranch,
          baselineBranch: baseline?.branch ?? null,
          targets,
          syncSource: det.syncSource,
        })) {
          return undefined;
        }
      }

      // ── push --delete: retained #73 coordinated check (foreign targets) ──
      if (det.verdict === "block:push-delete" && det.pushTargets.length > 0) {
        const worktreeBranches = getWorktreeBranches();
        const blockedBranches: string[] = [];
        for (const branchName of det.pushTargets) {
          const branchRef = `refs/heads/${branchName}`;
          const checkedOutPaths = [...(worktreeBranches.get(branchRef) || [])];
          if (isBranchInMainCheckout(branchName)) {
            const mainTopLevel = _mainTopLevel();
            const mainLabel = mainTopLevel || "main checkout";
            if (!checkedOutPaths.includes(mainLabel)) checkedOutPaths.push(mainLabel);
          }
          if (checkedOutPaths.length > 0) {
            blockedBranches.push(`"${branchName}" — checked out in: ${checkedOutPaths.join(", ")}`);
          }
        }
        if (blockedBranches.length > 0) {
          return {
            block: true,
            reason: [
              `⛔ Cannot delete — the following branches are currently checked out:`,
              ...blockedBranches.map((b: string) => `   • ${b}`),
              "",
              "   Why: deleting a remote branch while another session has it",
              "   checked out destroys that session's upstream (#73 / incident 2026-08-06).",
              "   → Switch those worktrees/main to another branch first, then retry.",
            ].join("\n"),
          };
        }
        return undefined; // foreign deletes with no checked-out targets — allowed (today's behavior)
      }

      // ── M2: commit/push ownership (block off-baseline) ──
      if (det.verdict === "block:commit" || det.verdict === "block:push" || det.verdict === "block:force-push") {
        if (!eff) {
          return {
            block: true,
            reason: "⛔ git commit/push blocked — could not verify repo ownership (git read failed; fail-closed, #265).",
          };
        }
        const baseline = baselines.get(pid);
        const m2 = branchOwnership.decideM2({
          effectiveRepo: eff, baseline, currentBranch: eff.currentBranch,
          pushDst: det.pushDst, pushTargets: det.pushTargets,
          verdict: det.verdict, allowActive: false,
        });
        if (m2?.block) return { block: true, reason: m2.reason };
        return undefined; // on-baseline or unverifiable-but-exempt
      }

      // ── Legacy destructive blocks (main checkout only) ──
      const LEGACY_BLOCK = [
        "block:reset", "block:clean", "block:restore", "block:stash-pop",
        "block:checkout-discard-all", "block:force-checkout", "block:checkout-branch",
        "block:merge", "block:rebase", "block:pull", "block:branch-force-delete",
        "block:force-push",
      ];
      if (LEGACY_BLOCK.includes(det.verdict)) {
        if (eff && eff.isWorktree) return undefined;
        const kind = det.verdict.slice("block:".length);
        return {
          block: true,
          reason: [
            `⛔ Destructive git command blocked in the main checkout (${kind}).`,
            ...WHY.split("\n").slice(1),
          ].join("\n"),
        };
      }
      return undefined;
    }

    // ── write/edit: block edits to the main checkout ──
    // Worktrees are ISOLATED: if the session itself runs in a linked worktree,
    // `git rev-parse --show-toplevel` returns the worktree root for BOTH the
    // session cwd and any target inside it, so the mainTopLevel equality check
    // below would false-positive-block every edit (incident: epic-529 worktree
    // session blocked editing its own isolated worktree). A worktree's working
    // tree is private by construction — allow all edits from a worktree session.
    if (isWorktreeCwdWrite(resolve(process.cwd()))) {
      return undefined;
    }

    const targetPath = (event.input as { path?: string }).path;

    // #99 write/edit exemption for the infra repo itself (retained): agent-infra
    // is where infra fixes land; the branch-ownership gates (M1/M2/M3) now cover
    // its bash git surface instead.
    if (isAgentInfraRepo()) {
      return undefined;
    }
    if (_isAllowMainEdits()) {
      return undefined;
    }

    const mainTopLevel = _mainTopLevel();
    if (!mainTopLevel) {
      console.warn("[main-worktree-guard] ⚠️ Git unavailable for main repo — warn, not block");
      console.warn("[main-worktree-guard]   → Create a worktree: invoke the using-git-worktrees skill.");
      return undefined;
    }

    // If the target is OUTSIDE the project root, it's not a main-checkout edit — allow.
    const resolvedTarget = resolve(process.cwd(), targetPath ?? "");
    const insideProject =
      resolvedTarget === mainTopLevel || resolvedTarget.startsWith(mainTopLevel + "/");
    if (!insideProject) {
      return undefined;
    }

    const targetCwd = targetPath ? dirname(resolvedTarget) : process.cwd();

    // Resolve symlinks to detect nested git repos (#5543)
    let resolvedCwd = targetCwd;
    try {
      if (existsSync(targetCwd)) {
        resolvedCwd = realpathSync(targetCwd);
      }
    } catch { /* keep unresolved if symlink resolution fails */ }

    let topLevel: string;
    try {
      topLevel = execSync("git rev-parse --show-toplevel", {
        encoding: "utf-8", cwd: resolvedCwd, timeout: 5000,
      }).trim();
    } catch {
      console.warn("[main-worktree-guard] ⚠️ Git unavailable for target path — warn, not block");
      console.warn("[main-worktree-guard]   → Target may be a new directory or outside a git repo.");
      return undefined;
    }

    if (topLevel === mainTopLevel) {
      return {
        block: true,
        reason: [
          "⛔ File edits in the main checkout are blocked.",
          "   Why: Parallel agents editing main could silently overwrite each",
          "   other's uncommitted changes. Each agent needs its own branch.",
          "   → Create a worktree: invoke the using-git-worktrees skill.",
          "   → Or set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) to override (solo sessions only).",
        ].join("\n"),
      };
    }

    return undefined;
  });

  // #5672: suppress startup banner in print mode (task sub-agent output)
  if (!isPrintMode()) {
    console.log("[main-worktree-guard] ✅ Loaded — blocking write/edit + destructive git in main checkout");
  }
}
