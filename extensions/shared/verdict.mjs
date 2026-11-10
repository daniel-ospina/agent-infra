/**
 * verdict.mjs — ONE attributable verdict line for the zero-dep test harnesses
 * (agent-infra#2723).
 *
 * THE DEFECT THIS EXISTS FOR. The merge rail builds a PR's failing set by
 * parsing each failing run's log for a failure IDENTITY (`scripts/ci_exemption.py`;
 * `admin-merge.sh`'s §"NO parseable failure identity"). A JS/TS harness has no
 * pytest nodeid, so the rail read it through its `runner::<label>` family — and
 * that family is anchored on a LABEL: `❌ <label>: <N> passed, <M> failed`
 * (`_RUNNER_AGG_RE`). A harness that printed the same aggregate WITHOUT a label
 * (`❌ 12 passed, 6 failed`), or without the `❌` marker at all
 * (`12 passed, 6 failed`), or with a count in place of a label
 * (`❌ #755 tripwire: 1 check(s) failed`), therefore yielded NOTHING, and the rail
 * refused the whole PR blind:
 *
 *     ⛔ admin-merge: BLOCKED — 1 of 1 failing PR run(s) yielded NO parseable
 *        failure identity … This is a refusal, not a comparison.
 *
 * Measured on #2667 @ `5e320a09` (run 40110626277): the failing step was
 * `main-worktree-guard sanctioned-script IDENTITY + pin (#2332)`, whose only
 * machine-readable output was `❌ 12 passed, 6 failed` — the counts moved
 * (`12/6`, later `24/0`) and no identity ever appeared. `#1185` closed the same
 * gap for `check-pipeline-compliance.sh`; this closes it for the `verify` job's
 * own harnesses.
 *
 * WHY A SHARED EMITTER AND NOT "just add the label to each file". Sixteen
 * harnesses had hand-rolled the line in five different shapes. Adding a label to
 * each fixes today's sixteen and pins nothing about tomorrow's seventeenth, which
 * is exactly how the gap recurred job-over-job. One emitter, imported by every
 * harness, makes the attributable form the ONLY form — and `test-verdict.mjs`
 * refuses a harness that hand-rolls its own aggregate again.
 *
 * ⛔ THE IDENTITY IS THE LABEL, NEVER THE COUNTS. `runner::<label>` is keyed on
 * the harness's stable name because a count changes with the suite's size, and an
 * identity that tracks a count can never match main's baseline (the #3756
 * rotating-identity class, declared in `ci_exemption.py` beside
 * `_RUNNER_AGG_RE`). Two DIFFERENT shapes of failure inside one harnesses compare
 * as ONE identity — FILE-COARSE, which is that family's own declared residual. So
 * do not "improve" this emitter into per-assertion identities.
 *
 * ⛔ A WHOLE-SUITE SKIP IS A FAILURE, NOT A SKIP. `runner_aggregates()` ignores a
 * line whose `failed` count is 0 ("0 failed is a PASS line; only a failing
 * aggregate is evidence"), so a harness that exits 1 over zero assertions while
 * printing `❌ label: 0 passed, 0 failed, 1 skipped` is STILL unattributable. Two
 * sibling harnesses refuse exactly that vacuous-green shape
 * (`test-unborn-head.mjs`, `test-hub-sweep.mjs`), so `red` exists to let them
 * count the vacuity as the failure it is: `red` forces the `❌` marker AND raises
 * the reported `failed` count to at least 1, keeping the line attributable and
 * keeping the exit code the caller's.
 *
 * PASS `red` ONLY FOR A REAL CONTRACT FAILURE the caller counts outside `fail`.
 * Reporting a red over a green suite would be a false failure identity, which is
 * worse than none: the rail would then compare — and certify — against an
 * identity that names no defect.
 */

/** The parser's own label charset (`_RUNNER_AGG_RE`): anything else never parses. */
const LABEL_RE = /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/;

/**
 * The exact line to print. Split out from {@link reportVerdict} so a test can pin
 * the FORMAT without capturing stdout of a subprocess.
 *
 * @param {string} label  the harness's stable, repo-unique name
 * @param {number} pass   assertions that passed
 * @param {number} fail   assertions that failed
 * @param {{skip?: number, red?: boolean}} [opts]
 * @returns {string} the attributable aggregate line, no trailing newline
 */
export function verdictLine(label, pass, fail, opts = {}) {
  const name = String(label ?? "");
  if (!LABEL_RE.test(name)) {
    // Fail LOUDLY at the producer: a label the parser cannot read is the exact
    // defect this module exists to remove, and a silent `?` would reintroduce it
    // with a green suite around it.
    throw new Error(
      `verdict: label ${JSON.stringify(name)} is not attributable — it must match ` +
        `${LABEL_RE} (the merge rail's _RUNNER_AGG_RE charset)`
    );
  }
  const skipped = Number(opts.skip ?? 0) || 0;
  // A red over zero counted failures still has to LOOK like a failure to the
  // parser, or the vacuous-skip case stays unattributable (see the header).
  const failed = Math.max(Number(fail ?? 0) || 0, opts.red ? 1 : 0);
  const counts =
    `${Number(pass ?? 0) || 0} passed, ${failed} failed` +
    (skipped ? `, ${skipped} skipped` : "");
  const marker = failed === 0 ? "✅" : "❌";
  return `${marker} ${name}: ${counts}`;
}

/**
 * Print the aggregate and RETURN the exit code (the caller still owns
 * `process.exit`, so a harness that has more to say after the verdict can say it).
 *
 * @returns {0|1} 0 when nothing failed
 */
export function reportVerdict(label, pass, fail, opts = {}) {
  const line = verdictLine(label, pass, fail, opts);
  // The leading blank line is the shape every migrated harness already printed
  // (`console.log("\\n…")`); keeping it means the log reads identically.
  console.log(`\n${line}`);
  return line.startsWith("❌") ? 1 : 0;
}
