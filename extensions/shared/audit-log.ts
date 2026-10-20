/**
 * shared/audit-log.ts — durable JSONL audit append for gate events (#60).
 *
 * Gate bypasses and review-dispatch events get a durable audit trail at
 * ~/.pi/agent/audit/gate-events.jsonl (append-only JSONL). The audit log is
 * a companion to the console messages — escape hatches stay possible, but
 * they become auditable.
 *
 * Schema per line: { ts, event, extension, reason?, session_cwd, ...extra }
 *   ts          — ISO-8601 timestamp (stamped here)
 *   event       — "gate_bypass" | "review_dispatch" | "merge_gate_block" | "merge_gate_pass" | "review_record_collision" | "gate_block" | "gate_pass"
 *   extension   — name of the extension that emitted the event
 *   reason      — short tag (escape_hatch, per_command_escape_hatch, no_review_record, no_reviewers_dispatch, ...)
 *   session_cwd — process.cwd() at emit time (the session's working directory)
 *   ...extra    — per-event fields. The ones a reader will meet today: `tier` + `tier_source`
 *                 (`read` | `undetermined`) on the review-enforcer's `gate_block` / `gate_pass` /
 *                 `reviewer_preflight` records (#2204), `phase` (`session_start` | `first_push` |
 *                 `block_recovery`) and `delivered` on `reviewer_preflight` (#2148/#2204), and
 *                 `command` on every record that can name the refused/allowed command (#1492).
 *                 Fields are ADDITIVE: a reader must tolerate one it does not know, and must
 *                 never infer an absent field (an old line has no `tier_source`).
 *
 * Fail-safe semantics: appendJsonl NEVER throws into the gate path. A write
 * failure (permissions, disk full) is swallowed — auditing must not block or
 * alter gate decisions.
 *
 * ponytail: shared/ has no index.ts, so pi's extension loader skips this
 * directory (same pattern as shared/health.ts, shared/retry.ts — helpers are
 * imported by extensions, never loaded as extensions themselves).
 */

import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export type GateEventName =
  | "gate_bypass"
  | "review_dispatch"
  | "merge_gate_block"
  | "merge_gate_pass"
  | "review_record_collision" // #426: cross-repo PR-number registry collision (readReviewRecord)
  | "gate_block" // #516: review-enforcer dispatch-count block at 0 dispatches (uniform ≥1-dispatch floor, #485)
  | "gate_pass" // #2204: a command the text POSITIVELY reads as read-only gh work, allowed with ZERO dispatches (the floor covers writes; the reason tag is "read_only_no_dispatch")
  | "reviewer_preflight" // #2148: the reviewer requirement disclosed BEFORE the work (session_start → phase:"session_start", first push → phase:"first_push", refused op → phase:"block_recovery")
  | "bridge_clear"; // #561: scripts/vgate.sh clear — root-scoped bridge rewrite (type-documentation; vgate.sh appends raw JSONL)
// Resolved lazily per call (not at module load) so a $HOME change — tests,
// alternate agent dirs — takes effect. Uses os.homedir(); never hardcoded.
export function gateEventsFile(): string {
  return join(homedir(), ".pi", "agent", "audit", "gate-events.jsonl");
}

// Append one JSONL line. Optional `file` override for tests / alternate
// targets. mkdir -p on demand; all errors swallowed (fail-safe).
export function appendJsonl(entry: Record<string, unknown>, file?: string): void {
  try {
    const target = file ?? gateEventsFile();
    mkdirSync(dirname(target), { recursive: true });
    const line = JSON.stringify({ ts: new Date().toISOString(), ...entry }) + "\n";
    appendFileSync(target, line);
  } catch {
    // audit must never break the gate path — swallow all I/O errors
  }
}
