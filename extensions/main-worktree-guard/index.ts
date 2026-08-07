// See also: pi settings.json PreToolUse hook for Claude Code equivalent.
// This extension is the authoritative definition.
//
// Guards the SHARED main checkout of a project against:
//  1. write/edit tool calls (collision between parallel agents), and
//  2. destructive/state-changing git commands via the bash tool (git reset
//     --hard, branch checkout/switch, pull/merge/rebase, clean, force-push,
//     branch -D, restore, stash pop) — which previously bypassed the guard
//     entirely and let one agent yank the working tree out from under another
//     (incident 2026-08-06: `git reset --hard origin/main` mid-PR).
//
// Worktrees are ISOLATED — none of this applies inside a worktree. The only
// escape hatch is AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) for
// deliberate solo sessions. There is NO auto-bypass: the guard blocks every
// time, so a rogue/parallel agent cannot retry its way past it.
// Degradation: if classify-git.mjs fails to load (jiti edge case), the bash
// guard degrades to warn-only (fail-safe, never false-blocks) while the
// write/edit guard stays fully enforced.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { execSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { realpathSync, existsSync } from "node:fs";

// Shared destructive-git rules (also used by test.mjs). If the import ever
// fails (jiti resolution edge case), the bash guard degrades to warn-only
// while write/edit protection stays fully enforced.
let classifyGitCommand: (cmd: string) => string = () => "allow";
let isWorktreeCwd: (cwd: string) => boolean = () => true;
let extractPushDeleteBranch: (cmd: string) => string[] | null = () => null;
let getWorktreeBranches: () => Map<string, string[]> = () => new Map();
let isBranchInMainCheckout: (branch: string) => boolean = () => false;
let getMainCheckoutBranch: () => string | null = () => null;
try {
  ({ classifyGitCommand, isWorktreeCwd, extractPushDeleteBranch,
     getWorktreeBranches, isBranchInMainCheckout, getMainCheckoutBranch } =
    await import("./classify-git.mjs"));
} catch (e) {
  console.warn("[main-worktree-guard] ⚠️ classify-git.mjs failed to load — bash git guard DISABLED:", String(e));
}

// Dual-support: check AGENT_* first, then ELDATO_* (Phase 1 — #7549)
function _getEnv(name: string): string | undefined {
  return process.env[`AGENT_${name}`] ?? process.env[`ELDATO_${name}`];
}
function _isAllowMainEdits(): boolean {
  return _getEnv("ALLOW_MAIN_EDITS") === "1";
}
// Detect if running inside agent-infra's own repo (skip worktree enforcement)
function _isAgentInfraRepo(): boolean {
  const root = process.env.AGENT_INFRA_ROOT;
  if (!root) return false;
  try {
    const topLevel = execSync("git rev-parse --show-toplevel", {
      encoding: "utf-8", cwd: process.cwd(), timeout: 5000,
    }).trim();
    return resolve(topLevel) === resolve(root);
  } catch {
    return false;
  }
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
  "   `git reset --hard origin/main` wiped an in-progress PR mid-review).",
  "   → Work in an isolated worktree: invoke the using-git-worktrees skill.",
  "   → Or set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) for",
  "     deliberate solo sessions.",
].join("\n");

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, _ctx) => {
    const isWrite = isToolCallEventType("write", event);
    const isEdit = isToolCallEventType("edit", event);
    const isBash = isToolCallEventType("bash", event);
    if (!isWrite && !isEdit && !isBash) {
      return undefined;
    }

    if (_isAgentInfraRepo()) {
      return undefined; // agent-infra is a small infra repo — no worktree needed
    }
    if (_isAllowMainEdits()) {
      return undefined;
    }

    // ── bash: block destructive git ──
    if (isBash) {
      const command = (event.input as { command?: string }).command ?? "";
      const verdict = classifyGitCommand(command);
      if (verdict.startsWith("block:")) {
        // ── Coordinated branch deletion (#73): push --delete checked everywhere ──
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
                if (!checkedOutPaths.includes(mainLabel)) {
                  checkedOutPaths.push(mainLabel);
                }
              }
              if (checkedOutPaths.length > 0) {
                blockedBranches.push(
                  `"${branchName}" — checked out in: ${checkedOutPaths.join(", ")}`
                );
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
          // All branches safe to delete — allow
          return undefined;
        }

        // ── Other destructive commands: only block in main checkout ──
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

    // ── write/edit: block edits to the main checkout ──
    const targetPath = (event.input as { path?: string }).path;

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
  if (process.env.PI_MODE !== 'print') {
    console.log("[main-worktree-guard] ✅ Loaded — blocking write/edit + destructive git in main checkout");
  }

  // ── Session-start hub discipline check (#73) ──
  // In the main checkout: warn if on a non-main branch or dirty working tree.
  // Non-blocking — the write/edit guard still protects; this is a discipline prompt.
  if (!_isAgentInfraRepo() && !_isAllowMainEdits()) {
    try {
      const inWorktree = isWorktreeCwd(resolve(process.cwd()));
      if (!inWorktree) {
        const currentBranch = getMainCheckoutBranch();
        const porcelain = execSync("git status --porcelain", {
          encoding: "utf-8", timeout: 5000,
        }).trim();

        const onNonMain = currentBranch &&
          currentBranch !== "main" && currentBranch !== "master";
        const dirty = porcelain.length > 0;

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
      }
    } catch (e) {
      // Degrade silently — this is a non-blocking discipline check
      console.warn("[main-worktree-guard] ⚠️ Hub discipline check failed:", String(e));
    }
  }
}
