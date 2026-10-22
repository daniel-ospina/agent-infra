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
 * ⛔ THREE ROLES, because who dispatches is NOT the same on every path — and without this split
 * the disclosure contradicts the brief it accompanies. A `lane.sh` lane is told by its own brief
 * "you have NO task tool — do NOT dispatch … Do NOT merge"; a `self` line in that same context
 * would instruct exactly those two forbidden things. So:
 *   self      a lane (or interactive session) that lands its own PR: dispatch → fix → record at the
 *             CURRENT head → rail. Carries the no-`task`-tool override for a launcher that exports
 *             no `KIND` (see `NO_MARKER_HEDGE`).
 *   harness   a worker that PUSHES CODE (`KIND=lane|fixer|bg`): `merge-one.sh` mints the
 *             attestation, so the worker pushes its FINAL head and NEVER merges.
 *   reviewer  `merge-one.sh`'s own reviewer session (`KIND=reviewer`): it OWNS the verdict comment
 *             and must not push, record or merge — those three are merge-one.sh's.
 *
 * The mapping is `reviewerRoleFor` in extensions/review-enforcer/index.ts, pinned there by tests;
 * the table below is the same mapping, and the two must not be allowed to disagree.
 *
 * ⛔ ONE WORDING, TWO LANGUAGES, AND A DRIFT PIN. The shell helper cannot import TypeScript, so
 * the requirement sentence and the command strings exist in both copies. That is a drift risk, so
 * reviewer-preflight.test.ts renders ALL THREE roles through the bash helper and asserts the lines
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
 * Who mints the attestation for this session — the audience the disclosure is addressed to.
 *   self      the session lands its own PR through the rail: dispatch, record, rail
 *   harness   a harness WORKER (`KIND=lane|fixer|bg`) that pushes code; `merge-one.sh` reviews and
 *             mints the attestation, so the worker's duty is a stable final head and NO merge
 *   reviewer  the harness REVIEWER itself (`KIND=reviewer`, dispatched by `merge-one.sh`). It posts
 *             the verdict as a PR comment and reports `CLEAN <comment-url>`; it must not push, must
 *             not record, must not merge — `merge-one.sh` owns all three.
 *
 * ⛔ THREE audiences, not two (fresh review of #2148, P2). A `reviewer` session is a harness worker
 * by `KIND`, but the harness line's advice ("push your FINAL head, do NOT merge") is addressed to
 * something that pushes CODE — and `merge-one.sh` launches the reviewer with "Report only — do not
 * fix code … Do NOT modify code, commit, or merge." Told both, the reviewer is handed a
 * contradiction of exactly the kind this role split exists to prevent, in a session that is also
 * hatched to write the main checkout.
 */
export type ReviewerRole = "self" | "harness" | "reviewer";

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
// ⛔ THE PATH IS THE HOME COPY, NOT A REPO-RELATIVE ONE (fresh review of #2148, P1). This line is
// printed inside a lane whose cwd is a CONTENT repo (tortoise/eldato), which has no
// `scripts/record-review.sh` — the production copy is farmed into `~/.pi/agent/scripts/`, which is
// where `merge-one.sh` runs it from (`$HOME/.pi/agent/scripts/record-review.sh`) and where both the
// commit-workflow and code-review skills tell lanes to look ("`~/.pi/agent/scripts` is not on
// PATH"). A repo-relative path is correct ONLY in agent-infra's own checkout, so it hands every
// other lane a "No such file or directory" at the moment it tries to land — the same class the
// `--evidence` fix removed, one element over.
export const REVIEWER_PREFLIGHT_RECORD_CMD =
  "~/.pi/agent/scripts/record-review.sh <PR> <HEAD> clean [owner/repo] --evidence comment:<review-comment-id>";
export const REVIEWER_PREFLIGHT_RAIL_CMD = "scripts/admin-merge.sh <PR>";

/**
 * The CARRY, disclosed because the code has supported it all along and the line never said so (#2343).
 *
 * Measured 2026-11-19 on two batch-landing lanes: each held a VALID record whose DIFF was unchanged,
 * read "this lane must dispatch a reviewer" as "pay for a review", and spent 20–40 minutes on one it
 * did not owe — one lane stopped entirely, because the sentence's own escape hatch ("If your brief
 * says you have no `task` tool … do NOT merge") read as "I cannot proceed" with nothing saying the
 * existing record still lands the PR.
 *
 * WHY THIS IS NOT A WEAKENING. `record-review.sh` decides the carry itself — `CARRY_ARM="diff"` when
 * a prior signed diff marker matches the current diff, else `"lane"` when `lane_dimension_carry`
 * holds (`:1942-1946`), writing `"mint":"carried"` (`:2251`); a carry needs no `--evidence` (`:99-103`,
 * and the fresh-mint guard it bypasses is `:2008`), and the merge gate's carry arm allows the merge
 * only when both `diff_sha256` values are full 64-hex and equal (extensions/review-enforcer/index.ts,
 * `record.diff_sha256 === currentDiffHash`). So this sentence names a path the gate ALREADY takes; it
 * changes no decision, and its last clause keeps the requirement intact for every fresh mint.
 *
 * THREE FACTS THE WORDING MUST CARRY, each verified against the script (a first draft got all three
 * wrong and a fresh review caught it — the tests pin PROSE, so they could not):
 *   (i) THE HEAD YOU PASS IS THE RECORDED ONE. The whole carry block sits inside
 *       `elif [ "$CURRENT_HEAD" != "$SHA" ]` (`:1902`), so passing the LIVE head is not a carry — it is
 *       a FRESH mint, refused without `--evidence` (`:2008`, exit 3). Say "the head that record
 *       already names", or the lane is handed a command that cannot work.
 *   (ii) A "BASE-ONLY MOVE" IS A FORWARD MERGE, NOT A REBASE. `lane_dimension_carry` requires the
 *       reviewed head to be an ANCESTOR of the live head (`:1377`: "A rewritten/rebased head is a
 *       DIFFERENT artifact … must never carry this way"), so a rebase does NOT carry.
 *   (iii) THE TARGET HEAD'S HEALTH VETOES (#1575 clause E, `:1951`). An unchanged artifact on a
 *       measurably RED head is refused, so "provably unchanged" alone overclaims.
 */
export const REVIEWER_PREFLIGHT_CARRY_CLAUSE =
  'CARRY — the exception to the stale-head rule above: you do NOT pay for a second review when a VALID record already exists. Pass the head that record already names (the REVIEWED head, not the live one) and record-review.sh re-binds the same verdict onto the live head, writing mint:"carried" with no --evidence and no new reviewer — the script decides the arm itself, so there is no --carry flag. It re-binds when the reviewed artifact is provably unchanged AND the live head is not measurably red: the same PR DIFF, or a forward merge of the new base into your reviewed head (a rebase rewrites the head and does NOT carry). A FRESH mint still requires the dispatched reviewer';

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

/** "…dispatch; …record; …rail; …artifact" — shared by both SELF lines (pre-flight and first push)
 * so those two cannot diverge; the harness and reviewer roles have their own framing. */
function commandTrail(): string {
  return (
    `dispatch: ${REVIEWER_PREFLIGHT_DISPATCH_CMD}; ` +
    `record: ${REVIEWER_PREFLIGHT_RECORD_CMD}; ` +
    `rail: ${REVIEWER_PREFLIGHT_RAIL_CMD}; ${ARTIFACT_RULE}`
  );
}

/**
 * The hedge every SELF line carries, because the role cannot always be known.
 *
 * ⛔ A FOURTH LAUNCHER DOES NOT MARK ITSELF (review of #2148, P1). `KIND` is exported by THIS repo's
 * launchers, but the content-repo copy of the harness (`tortoise/operations/orchestrator-harness/
 * lane.sh`, which the README says the fleet still runs) exports the bypass bundle and no `KIND` —
 * while its brief says "you have NO \"task\" tool — do NOT dispatch. The PARENT runs the review
 * gate." and "Do NOT merge." So that lane resolves to `self` and would be told to dispatch and to
 * run the rail — the contradiction the role split removed for the marked launchers, one launcher
 * over. The fix for the MARKER is a companion change in that repo (filed); until it lands, the line
 * must be true for that lane too, so the self line names the condition under which it does NOT
 * apply. Told the exception explicitly, a lane whose brief says "do not dispatch" is no longer
 * reading two contradictory instructions.
 */
const NO_MARKER_HEDGE =
  "If your brief says you have no `task` tool, that overrides this: do NOT dispatch and do NOT merge — the parent's reviewer mints the attestation.";

/** The harness role's clause — the LANE does not dispatch, and does not merge. */
const HARNESS_CLAUSE = "the HARNESS reviewer (merge-one.sh) mints it";

/** The reviewer's own clause: what it OWNS, and the three things it must not touch. */
const REVIEWER_CLAUSE =
  "you ARE the harness reviewer — post the verdict as a PR comment and report `CLEAN <comment-url>`; " +
  "do NOT push, do NOT record and do NOT merge (merge-one.sh owns the record and the rail)";

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
  if (role === "reviewer") {
    return (
      `${REVIEWER_PREFLIGHT_TAG} #2148 preflight: ${REVIEWER_CLAUSE}. ` +
      `For reference, the record merge-one.sh will mint: ${REVIEWER_PREFLIGHT_RECORD_CMD}.${bypass}`
    );
  }
  if (role === "harness") {
    return (
      `${REVIEWER_PREFLIGHT_TAG} #2148 preflight: ${REVIEWER_PREFLIGHT_REQUIREMENT} — ` +
      `${HARNESS_CLAUSE}: push your FINAL head, do NOT merge. ` +
      `For reference, merge-one.sh runs: record: ${REVIEWER_PREFLIGHT_RECORD_CMD}; ` +
      `then rail: ${REVIEWER_PREFLIGHT_RAIL_CMD}.${bypass}`
    );
  }
  return (
    `${REVIEWER_PREFLIGHT_TAG} #2148 preflight: this lane ${REVIEWER_PREFLIGHT_REQUIREMENT} — ` +
    `${commandTrail()}. ${HEAD_BINDING}. ${REVIEWER_PREFLIGHT_CARRY_CLAUSE}. ${NO_MARKER_HEDGE}${bypass}`
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
  if (role === "reviewer") {
    // The reviewer does not push, so there is no first-push moment to warn it about; what it needs
    // at the same moment is the SAME rule as the pre-flight (it was launched into a fresh session
    // and may be reading nothing else). Reuse the line rather than invent a second wording.
    return reviewerPreflightLine(opts);
  }
  if (role === "harness") {
    return (
      `${REVIEWER_PREFLIGHT_TAG} #2148 first push: no attestation can exist yet — ` +
      `${HARNESS_CLAUSE} at the head you just pushed, so push your FINAL head and do NOT merge. ` +
      `For reference, merge-one.sh runs: record: ${REVIEWER_PREFLIGHT_RECORD_CMD}; ` +
      `then rail: ${REVIEWER_PREFLIGHT_RAIL_CMD}.${bypass}`
    );
  }
  return (
    `${REVIEWER_PREFLIGHT_TAG} #2148 first push: NO reviewer dispatch in this session yet, so the ` +
    `rail will refuse at the finish line UNLESS a valid record already covers this artifact. Do it ` +
    `NOW, while the context is live — ${commandTrail()}. ${HEAD_BINDING}. ` +
    `${REVIEWER_PREFLIGHT_CARRY_CLAUSE}. ${NO_MARKER_HEDGE}${bypass}`
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
