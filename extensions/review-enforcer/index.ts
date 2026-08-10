import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import * as fs from "fs";

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
