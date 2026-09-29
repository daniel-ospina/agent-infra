/**
 * task-cwd-guard — refuses a `task` dispatch whose resolved spawn directory is a
 * SHARED MAIN checkout, and names the worktree remedy (#1240).
 *
 * The policy lives in `./classify-cwd.mjs` (pure, zero-dep, unit-testable); this
 * file is only the wiring: one `tool_call` hook that the pi extension API drives
 * before the `task` tool executes.
 *
 * WHY A `tool_call` HOOK AND NOT A SPAWN-TIME CHECK
 * -------------------------------------------------
 * `event.input` is mutable before execution, and the hook sees the dispatch
 * before `spawnSubAgent` runs — so the refusal lands in the SAME channel the
 * caller already reads (a blocked tool call with a `reason`), and needs no
 * changes to builtin-tools. It also means the guard runs in the PARENT's process,
 * where `process.cwd()` is exactly the frame `resolveTaskCwd` (#1071) uses for an
 * omitted `cwd`.
 *
 * NO AUTO-CREATED PER-CHILD WORKTREE — DELIBERATE (see README.md)
 * --------------------------------------------------------------
 * The issue prefers "default-to-per-child-worktree … where possible". It is not
 * possible here without introducing a worse failure mode: at the measured ~124
 * dispatches/hour, auto-creating a worktree per child mints ~124 admin dirs/hour
 * (the reaper cannot keep up), and the only name-free form is a DETACHED-HEAD
 * worktree — whose commits are unreachable once the worktree is reaped, i.e.
 * exactly the silent-destruction-of-work class this repo treats as P0. The
 * common case needs no caller change where it is SAFE: a parent already in a
 * linked worktree passes it through untouched, and a non-repo target is allowed.
 * Only the shared-main case is refused, and its message carries the one-command
 * remedy.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { GUARD_ENV, GUARD_NAME, decideTaskCwd } from "./classify-cwd.mjs";

/** The `task` tool's input fields this guard reads. */
interface TaskToolInput {
  prompt?: string;
  cwd?: string;
  [key: string]: unknown;
}

/** One-time notice when git itself is unavailable (never per-dispatch spam). */
let warnedGitUnavailable = false;

/** One-time notice when the guard could not evaluate a dispatch (never a per-call spam). */
let warnedGuardError = false;

export default function taskCwdGuard(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event, ctx) => {
    // A throw here would break the tool call itself, so the WHOLE body is
    // fail-open: a guard that cannot evaluate must never refuse a dispatch.
    try {
      if (!isToolCallEventType<"task", TaskToolInput>("task", event)) return undefined;

      // `parentCwd` is deliberately NOT read here — the resolver reads the
      // parent frame lazily and guarded, so a deleted parent cwd (a reaped
      // worktree) cannot throw, and an explicit ABSOLUTE `cwd` never consults
      // it at all.
      const decision = decideTaskCwd({
        cwd: event.input?.cwd,
        env: process.env,
      });

      if (decision.action === "allow") {
        if (decision.gitUnavailable && !warnedGitUnavailable) {
          warnedGitUnavailable = true;
          console.warn(
            `[${GUARD_NAME}] ⚠️ git could not be executed — shared-main-checkout detection is OFF ` +
              `for this session (a target that cannot be classified is allowed).`,
          );
        }
        return undefined;
      }

      if (decision.action === "warn") {
        // Warn posture: an operator-visible notice, never a block.
        try {
          ctx?.ui?.notify?.(decision.message, "warning");
        } catch {
          /* UI unavailable (print/JSON mode) — the stderr line below still lands. */
        }
        console.warn(`[${GUARD_NAME}]\n${decision.message}`);
        return undefined;
      }

      return { block: true, reason: decision.message };
    } catch (err) {
      if (!warnedGuardError) {
        warnedGuardError = true;
        console.warn(
          `[${GUARD_NAME}] ⚠️ could not evaluate a task dispatch — allowing it (fail-open): ` +
            String(err instanceof Error ? err.message : err),
        );
      }
      return undefined;
    }
  });
}

/** Re-exported so the shipped posture is greppable from the extension entry. */
export { GUARD_ENV, GUARD_NAME };
