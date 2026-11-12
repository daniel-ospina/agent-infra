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
 *                 (`read` | `undetermined`) on the review-enforcer's `gate_block`, `gate_pass` and
 *                 `phase: "block_recovery"` records (#2204) — the other two pre-flight records
 *                 (`session_start`, `first_push`) carry neither, because no tier was read there;
 *                 `phase` (`session_start` | `first_push` | `block_recovery`), `role` and `send_queued`
 *                 on `reviewer_preflight` (#2148/#2204 — `send_queued`, NOT `delivered`: the SDK's
 *                 `sendMessage` is fire-and-forget, so "handed to the SDK" is the most an extension
 *                 can observe and a `delivered` field would claim more than it can know); and
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

// ⛔ THE LIST IS THE SOURCE OF THE TYPE, NOT A SECOND COPY OF IT (#853 review).
// `GateEventName` used to be a bare type union, and a type is INVISIBLE at runtime — so nothing
// could assert that a name a report reads is a name this repo declares. The reviewer's measured
// mutant: deleting a member reddened NO test, because `appendJsonl` takes `Record<string,
// unknown>` and the suite never referenced the union. Deriving the type from a runtime array makes
// membership assertable (`GATE_EVENT_NAMES`), so the drift the union exists to prevent is now
// caught by a test rather than by the honour system. Add a new event HERE; the type follows.
export const GATE_EVENT_NAMES = [
  "gate_bypass",
  "review_dispatch",
  "merge_gate_block",
  "merge_gate_pass",
  "review_record_collision", // #426: cross-repo PR-number registry collision (readReviewRecord)
  "gate_block", // #516: review-enforcer dispatch-count block at 0 dispatches (uniform ≥1-dispatch floor, #485)
  "gate_pass", // #2204: a command the text POSITIVELY reads as read-only gh work, allowed with ZERO dispatches (the floor covers writes; the reason tag is "read_only_no_dispatch")
  "reviewer_preflight", // #2148: the reviewer requirement disclosed BEFORE the work (session_start → phase:"session_start", first push → phase:"first_push", refused op → phase:"block_recovery")
  "bridge_clear", // #561: scripts/vgate.sh clear — root-scoped bridge rewrite (type-documentation; vgate.sh appends raw JSONL)
  "review_spawn_no_verdict", // #2665: a reviewer spawn returned no verdict (attempt, NOT a dispatch)
  "gate_recovery", // verification-gate: N verified entries were merged for `root` — the root the
  //                   record NAMES, which is the discriminator (not the call site — THREE CALL
  //                   SITES reach the ONE emit site, `index.ts` recoverBridgeForRoot). AT
  //                   `session_start`, when `root` is NOT the session's own root the merge is
  //                   INSPECTION-ONLY and it IS paired with `gate_recovery_foreign_root`; the
  //                   entries are inert for git ops rooted elsewhere. When `root` IS the own root
  //                   there, the merge is LIVE — it is the state that gates the op.
  //                   `session_start` has two call sites, own-root (LIVE) and inspected sibling
  //                   (INSPECTION-ONLY), and at most ONE of them emits: a sibling is only
  //                   inspected when the own root has no entries (`pickVerifiedRoot` returns null
  //                   otherwise).
  //                   The git-op path is a THIRD call site and it emits only the LIVE shape, for
  //                   the op's own resolved cwd — and it is NEVER paired with
  //                   `gate_recovery_foreign_root`, because a hub session running
  //                   `cd <linked-worktree> && git commit` legitimately recovers the worktree's
  //                   entries with `root` != the session's root. So a session-keyed reader must
  //                   NOT infer "inspection only" from `root` != its own root alone: inspection is
  //                   the shape that emits BOTH rows. Read `root`, never the count alone (#1265).
  "gate_recovery_empty", // verification-gate #264/#1265: a task child recovered ZERO entries for its own
  //                          root — every changed-file commit will block. The REMEDY differs by class and
  //                          the row CARRIES the class (`task_capable`, from `argvAllowsTask`), because a
  //                          parent reading this log is deciding exactly one thing — wait, or re-verify and
  //                          re-dispatch. task_capable=true: the child blocks until it dispatches its own
  //                          VGATE verification (in-band). task_capable=false: the block is FINAL and the
  //                          parent must act (#285 P1-A) — "until it self-verifies" is unreachable for it.
  "gate_recovery_foreign_root", // verification-gate #1265: a same-repo sibling's entries were merged for
  //                               INSPECTION only. They carry the sibling's root, so they are inert for
  //                               git ops rooted at the SESSION'S OWN root (`index.ts`'s root filter) — a
  //                               later op that `cd`s into the sibling resolves to the SIBLING's root,
  //                               where those same entries are LIVE (that is the `gate_recovery` shape
  //                               above, not this one). The record exists so the non-adoption is durable and
  //                               parent-readable, not only a child's stdout line
  "gate_root_mismatch", // verification-gate #3255/#1265: a git op resolved to a root the bridge holds no
  //                        entries for while a same-repo sibling has them — their entries are never adopted
  //                        as this op's records (per-path content identity is a separate, matching-only
  //                        rule — #2886's `foreign_root_blob_identical`). The
  //                        block decision is unchanged; this is the durable half of the diagnosis (AC (b))
  // #3297: the argv-level gh shim (#984) was NOT LOADED on this box, so the admin-merge gate
  // refused to certify a merge. Recorded as an EVENT, not only as console prose: row 1 of
  // docs/ops/ACTIVATION-MATRIX.md promises a report can read the degraded state without
  // anyone parsing a log line, and a name outside this union is exactly the "written outside
  // the type a report reads" gap that ships green under `tsx` and reddens the first tree
  // that adds a tsconfig.
  "gh_shim_degraded",
  // #853: the main-worktree guard's own classifier FAILED TO LOAD, so every gate it backs is
  // inert (the bash git guard non-blocking, the write/edit main-checkout gate fail-OPEN — #761).
  // Same reason as `gh_shim_degraded` above: a degraded enforcement layer must be readable by a
  // report, not only by whoever scrolls back through the session prose. This is the ONE surface
  // that knows a session ran unguarded, so it may not be a `console.warn` nobody reads.
  "guard_degraded",
] as const;
export type GateEventName = (typeof GATE_EVENT_NAMES)[number];
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
