/**
 * shared/reviewer-preflight.ts — the reviewer requirement, disclosed BEFORE the work (#2148).
 *
 * THE DEFECT. The review-enforcer's ≥1-dispatch rule and the merge-registry gate are both
 * correct, and both spoke ONLY at the finish line. Measured 2026-10-19 on cell-2: three lanes
 * rebased, implemented, tested, pushed and opened their PRs, and were then stopped by
 *
 *   [review-enforcer] 🚫 Blocked — no reviewers dispatched
 *   [review-enforcer] 🚫 Admin-merge evidence gate blocked
 *
 * — a whole lane-run of an 8-CPU box discarded at the last step, with nothing before that point
 * having told them a reviewer was mandatory. The requirement lived in the enforcer's code, not in
 * anything a lane could read before it started, so every new brief author rediscovered it by
 * being blocked.
 *
 * THE FIX, IN THREE PARTS, and this module is the pi-side one:
 *   1. session_start prints the requirement ONCE (console — the lane's log), and the first
 *      before_agent_start INJECTS it into the session (model-visible) — the two channels are
 *      deliberately both used: `pi -p` lanes get their prompt from the brief, so a console-only
 *      disclosure reaches the operator reading the log but not necessarily the model.
 *   2. the first push in a session at 0 dispatches says so AGAIN, while the lane still has
 *      context, instead of waiting for the rail to refuse — and THAT one is delivered as a session
 *      message (`pi.sendMessage … deliverAs:"steer"`), because "the lane can then fix it while it
 *      still has context" is only true if the lane is the reader.
 *   3. the harness prints the same line at lane launch and carries the step in the generated
 *      brief (scripts/orchestrator-harness/reviewer-preflight.sh, lane.sh, templates/LANE-BRIEF.md).
 *
 * ⛔ TWO ROLES, because who dispatches is NOT the same on the two paths — and without this split
 * the disclosure contradicts the brief it accompanies. A `lane.sh` lane is told by its own brief
 * "you have NO task tool — do NOT dispatch … Do NOT merge"; a `self` line in that same context
 * would instruct exactly those two forbidden things. So:
 *   self     a lane (or interactive session) that lands its own PR: dispatch → fix → record at the
 *            CURRENT head → rail.
 *   harness  a worker started by the harness (`KIND=lane|fixer|reviewer`): `merge-one.sh` mints the
 *            attestation, so the lane pushes its FINAL head and NEVER merges.
 *
 * ⛔ ONE WORDING, TWO LANGUAGES, AND A DRIFT PIN. The shell helper cannot import TypeScript, so
 * the requirement sentence and the command strings exist in both copies. That is a drift risk, so
 * reviewer-preflight.test.ts renders BOTH roles through the bash helper and asserts the two lines
 * are byte-identical to this module's. This is the same shape as the #966 command-parser drift pin
 * — one definition, and a test that fails when a second copy separates from it.
 *
 * STATED RESIDUALS (a limit nobody writes down is a limit the next lane rediscovers):
 *   (i) a session that never fires `before_agent_start` (`--mode json` / rpc) gets the console line
 *       only — the log, not the model;
 *   (ii) the first-push notice keys on the COMMAND TEXT, so a head pushed inside a wrapper
 *        (`atomic-land.sh`, a custom script) does not trigger it;
 *   (iii) the rail named is agent-infra's. A repo whose merge authority is its own review gate
 *        merges through that gate instead (merge-one.sh reads `repo-authority.sh` to decide), and
 *        the record command is the same on both paths.
 *
 * ZERO-DEPENDENCY (stdlib and no pi import): CI runs `extensions/shared/*.test.ts` before the
 * extensions' `npm ci`, so this file must stay importable without the pi SDK.
 */

/**
 * The requirement, as ONE sentence. The shell helper embeds this VERBATIM (it prefixes it with
 * "this lane "), so the drift pin can compare a single string rather than reflowed prose.
 */
export const REVIEWER_PREFLIGHT_REQUIREMENT =
  "must dispatch a reviewer and record an attestation at the final head before the rail";

/** The line's machine-greppable prefix — every pre-flight/disclosure line starts with it. */
export const REVIEWER_PREFLIGHT_TAG = "[gate]";

/**
 * Who mints the attestation for this session.
 *   self     the session lands its own PR through the rail
 *   harness  a harness worker (`KIND=lane|fixer|reviewer`); `merge-one.sh` runs the reviewer
 */
export type ReviewerRole = "self" | "harness";

/**
 * The commands, in the order a lane runs them.
 *
 * ⛔ `--evidence` IS PART OF THE COMMAND, not a footnote. Since tortoise#7391 `record-review.sh`
 * REFUSES to mint a FRESH `clean` record without it (exit 3) — a `clean` verdict is a full-review
 * attestation, and naming the current head is not evidence that a review happened. A disclosure
 * that names the invocation without it therefore hands the lane a command that cannot work, and
 * the lane discovers it at the moment it is trying to land. `clean-micro` / `clean-low` do not
 * require it (their guards differ); a lane on those tiers is told so by the refusal it gets.
 */
export const REVIEWER_PREFLIGHT_DISPATCH_CMD =
  "task(prompt='[REVIEW] review the diff of PR <PR> at <HEAD>; return NO ISSUES FOUND or list issues')";
export const REVIEWER_PREFLIGHT_RECORD_CMD =
  "scripts/record-review.sh <PR> <HEAD> clean [owner/repo] --evidence comment:<review-comment-id>";
export const REVIEWER_PREFLIGHT_RAIL_CMD = "scripts/admin-merge.sh <PR>";

/** The brief template that a controller copies instead of improvising one (#2148 part 2). */
export const REVIEWER_PREFLIGHT_BRIEF_TEMPLATE = "templates/LANE-BRIEF.md";

/** Why the record must be at the CURRENT head — the sentence a lane needs to not waste a re-record. */
const HEAD_BINDING =
  "a record bound to an older head is stale and the rail refuses it, so record AFTER the last push";

/**
 * The tail every self-role line carries: the three commands, plus the ARTIFACT requirement.
 *
 * ⛔ `--evidence comment:<id>` has no referent unless the lane is told to POST the verdict as a PR
 * comment (fresh review of this change, P2). Without that sentence the disclosure hands over a
 * flag whose value the lane must invent, and the missing artifact is discovered from the exit-3
 * refusal at record time — the same "found out at the finish line" shape the issue is about.
 */
const ARTIFACT_RULE =
  "post the reviewer's verdict as a PR comment — that comment IS the --evidence artifact";

/** "…dispatch; …record; …rail; …artifact" — shared by both roles so the lines cannot diverge. */
function commandTrail(): string {
  return (
    `dispatch: ${REVIEWER_PREFLIGHT_DISPATCH_CMD}; ` +
    `record: ${REVIEWER_PREFLIGHT_RECORD_CMD}; ` +
    `rail: ${REVIEWER_PREFLIGHT_RAIL_CMD}; ${ARTIFACT_RULE}`
  );
}

/** The harness role's clause — the LANE does not dispatch, and does not merge. */
const HARNESS_CLAUSE = "the HARNESS reviewer (merge-one.sh) mints it";

/**
 * The up-front disclosure: ONE line, printed once per session at startup.
 *
 * `bypassed` is the honest variant for a session whose dispatch gate is switched off (a harness
 * lane, an operator escape hatch). The gate does not fire there, which is exactly why the line
 * must still appear: a bypassed lane is the one that reaches the rail unimpeded and is refused by
 * the MERGE gate, which no bypass flag unlocks (#285).
 */
export function reviewerPreflightLine(
  opts: { role?: ReviewerRole; bypassed?: boolean } = {},
): string {
  const role = opts.role ?? "self";
  const bypass = opts.bypassed
    ? " [review-gate bypass is set — dispatch enforcement is OFF in this session, but the rail STILL refuses without an attestation]"
    : "";
  if (role === "harness") {
    return (
      `${REVIEWER_PREFLIGHT_TAG} #2148 preflight: ${REVIEWER_PREFLIGHT_REQUIREMENT} — ` +
      `${HARNESS_CLAUSE}: push your FINAL head, do NOT merge. ` +
      `record: ${REVIEWER_PREFLIGHT_RECORD_CMD}; rail: ${REVIEWER_PREFLIGHT_RAIL_CMD}.${bypass}`
    );
  }
  return (
    `${REVIEWER_PREFLIGHT_TAG} #2148 preflight: this lane ${REVIEWER_PREFLIGHT_REQUIREMENT} — ` +
    `${commandTrail()}. ${HEAD_BINDING}.${bypass}`
  );
}

/**
 * The early notice, emitted at the session's FIRST push (or `gh pr create`) when no reviewer has
 * been dispatched. Same requirement, different moment: the lane has just produced the artifact the
 * reviewer will read, so acting on it costs a dispatch instead of a whole re-run.
 */
export function reviewerFirstPushNotice(
  opts: { role?: ReviewerRole; bypassed?: boolean } = {},
): string {
  const role = opts.role ?? "self";
  const bypass = opts.bypassed
    ? " [dispatch enforcement is bypassed here — the rail is not]"
    : "";
  if (role === "harness") {
    return (
      `${REVIEWER_PREFLIGHT_TAG} #2148 first push: no attestation can exist yet — ` +
      `${HARNESS_CLAUSE} at the head you just pushed, so push your FINAL head and do NOT merge. ` +
      `record: ${REVIEWER_PREFLIGHT_RECORD_CMD}; rail: ${REVIEWER_PREFLIGHT_RAIL_CMD}.${bypass}`
    );
  }
  return (
    `${REVIEWER_PREFLIGHT_TAG} #2148 first push: NO reviewer dispatch in this session yet, so the ` +
    `rail will refuse at the finish line. Do it NOW, while the context is live — ` +
    `${commandTrail()}. ${HEAD_BINDING}.${bypass}`
  );
}

/**
 * The same requirement as a session MESSAGE, for `before_agent_start` (and, for the early notice,
 * `pi.sendMessage`).
 *
 * Why a message and not only a console line: a `pi -p` lane's prompt is the brief it was launched
 * with, and a console line written by an extension is not in it. The message is model-visible AND
 * persisted in the session, so a lane that never reads its log still reads this. Returned (not
 * sent) so the caller owns the emit and the tests can assert the shape.
 */
export function reviewerPreflightMessage(opts: { role?: ReviewerRole; bypassed?: boolean } = {}): {
  customType: string;
  content: string;
  display: boolean;
} {
  return {
    customType: "reviewer-preflight",
    content: reviewerPreflightLine(opts),
    display: true,
  };
}
