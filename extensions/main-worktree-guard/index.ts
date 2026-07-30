// See also: pi settings.json PreToolUse hook for Claude Code equivalent.
// This extension is the authoritative definition.

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { isToolCallEventType } from "@mariozechner/pi-coding-agent";
import { execSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { realpathSync, existsSync } from "node:fs";

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

const _blockCounts = new Map<string, number>(); // ponytail: auto-bypass counter (#7417)

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, _ctx) => {
    if (!isToolCallEventType("write", event) && !isToolCallEventType("edit", event)) {
      return undefined;
    }

    if (_isAgentInfraRepo()) {
      return undefined; // agent-infra is a small infra repo — no worktree needed
    }

    if (_isAllowMainEdits()) {
      return undefined;
    }

    const targetPath = (event.input as { path?: string }).path;

    // Compute the project's main checkout root once (#5582)
    let mainTopLevel: string;
    try {
      mainTopLevel = resolve(
        execSync("git rev-parse --show-toplevel", {
          encoding: "utf-8", cwd: resolve(process.cwd()), timeout: 5000,
        }).trim()
      );
    } catch {
      console.warn("[main-worktree-guard] ⚠️ Git unavailable for main repo — warn, not block");
      console.warn("[main-worktree-guard]   Why this guard exists: prevents accidental edits to the main");
      console.warn("[main-worktree-guard]   checkout which would bypass worktree isolation. Changes in main");
      console.warn("[main-worktree-guard]   can collide with other agents and get lost on branch switch.");
      console.warn("[main-worktree-guard]   → Create a worktree: invoke the using-git-worktrees skill.");
      console.warn("[main-worktree-guard]   → Or set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) for read-only sessions.");
      return undefined;
    }

    // If the target is OUTSIDE the project root, it's not a main-checkout edit — allow.
    // Paths like /tmp, ~/.pi are none of this guard's concern (#5582).
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
      console.warn("[main-worktree-guard]   → Create a worktree: invoke the using-git-worktrees skill.");
      console.warn("[main-worktree-guard]   → Or set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) for read-only sessions.");
      return undefined;
    }

    if (topLevel === mainTopLevel) {
      // ponytail: pre-write nudge on first attempt (#7529)
      const blockKey = targetPath ?? resolvedCwd;
      const blocks = _blockCounts.get(blockKey) ?? 0;
      if (blocks === 0) {
        console.warn("[main-worktree-guard] 💡 Heads up: you're about to write to the main checkout.");
        console.warn("[main-worktree-guard]   Why this guard exists: parallel agents editing main can silently");
        console.warn("[main-worktree-guard]   overwrite each other's uncommitted changes. Each agent needs its");
        console.warn("[main-worktree-guard]   own isolated worktree to prevent collisions and data loss.");
        console.warn("[main-worktree-guard]   → Better: create a worktree — invoke the using-git-worktrees skill.");
        console.warn("[main-worktree-guard]   → Or: set AGENT_ALLOW_MAIN_EDITS=1 (or ELDATO_ALLOW_MAIN_EDITS=1) for read-only/reviewer sessions.");
      }
      _blockCounts.set(blockKey, blocks + 1);
      if (blocks >= 2) {
        console.warn(`[main-worktree-guard] ⏩ Auto-bypassed after ${blocks + 1} attempts for ${blockKey}`);
        return undefined;
      }
      console.warn(`[main-worktree-guard] 🚫 Blocked write/edit in main checkout (${blocks + 1}/3)`);
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
    console.log("[main-worktree-guard] ✅ Loaded — blocking write/edit in main checkout");
  }
}
