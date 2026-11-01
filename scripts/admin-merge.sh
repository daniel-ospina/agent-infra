#!/usr/bin/env bash
# admin-merge.sh — the MANDATED safe `--admin` merge (#930).
#
# `gh pr merge --admin` bypasses required checks, so nothing makes it *safe*: it
# cannot tell a check that is already red on main from a NEW failure the PR
# introduces. tortoise #3420 merged at 08:15 carrying
# `tests/test_markers.py::test_no_redirect_stems_registry_exact` — a test NOT in
# main's failing set — and main ratcheted redder.
#
# This script is the chokepoint. It computes the evidence, refuses to merge on a
# genuine new failure, and only then runs `gh pr merge --admin`. The matching
# merge gate (extensions/review-enforcer/) refuses a RAW `gh pr merge … --admin`
# that carries no head-bound evidence comment — so the bypass is safe or it does
# not happen.
#
#   pr-rows.txt    ← scripts/ci-failure-set.sh --commit-rows <head>   # the head
#                    SHA the evidence marker binds to, with each failure's rate
#                    and its stable SIGNATURE
#   main-rates.txt ← scripts/ci-failure-set.sh --main-union-rates N
#   main-sigs.txt  ← scripts/ci-failure-set.sh --main-union-signatures N
#   rotation       ← scripts/ci-failure-set.sh --commit-rows <head> --per-run:
#                    the head's per-run failing-id sets, UNIONED across every
#                    sample of the SAME head (pre- and post-re-run). An id whose
#                    CLASS stays red while the ID moves between samples is
#                    UNATTRIBUTABLE: it is neither PR-unique nor exempt (#3756 E5).
#   residual       ← the EXEMPTION DECISION (scripts/ci_exemption.py decide):
#                    an id is EXEMPT only when it was measured on main over
#                    enough runs WITH a matching signature, and either the PR's
#                    failure RATE is not materially higher or the PR sample was
#                    below min_runs (rate not measurable — exempt on the
#                    attribution evidence alone, stated in the EXEMPT line).
#                    The residual is the decision's BLOCKED ∪ UNATTRIBUTABLE set.
#   residual EMPTY          → post head-bound evidence, then merge
#   residual NON-EMPTY      → re-run the PR's failed jobs ONCE; anything the
#                             decision then finds EXEMPT is flaky, not new
#                             (recorded in the evidence). Residual still
#                             non-empty → BLOCK, print the list, exit non-zero,
#                             NO merge.
#
# WHY NOT `comm -23` (#3756 — CATEGORY A, a false PASS). The old classifier
# decided ownership by MEMBERSHIP in a sample of main:
# `unique = pr-fails − union(main's failing ids over N runs)`. An id that
# appeared even ONCE in main's window was subtracted FOREVER, so a PR that
# genuinely BROKE it was EXCUSED and the gate reported GREEN — the more main
# flaked, the less the gate checked. Presence is never sufficient: main's row must
# be measured over `min_runs` WITH a matching signature, and the PR rate compared
# where it is measurable — below that the exemption rests on that same attribution
# evidence (#5250). The module that makes that decision ships WITH
# THE RAIL (`scripts/ci_exemption.py`, next to this script) and is deliberately
# never read from the repo being merged: a grader drawn from the graded system
# is a bypass.
#
# FOUR PRECONDITIONS THE FAILING SETS ALONE CANNOT EXPRESS:
#   1. THE HEAD MUST HAVE BEEN TESTED. The lane must have at least one TESTED run
#      for this head (a run that finished `success`, `failure` or `timed_out`) and
#      none still running. A queued run — or a run that finished `cancelled`,
#      `skipped` or `startup_failure`, none of which exercises the code — yields an
#      EMPTY failing set, indistinguishable from "green". Without this gate the
#      rail certifies nothing and merges before CI finishes, and the fresh
#      failure lands after the merge. That is the #3420 ratchet this rail exists
#      to stop (review P0 #3; `tested` rather than `completed`: review P1, cycle 2).
#   2. THE HEAD MUST NOT MOVE. The marker binds ONE SHA. The head is re-resolved
#      immediately before the comment and again by GitHub via
#      `--match-head-commit`, so a rebase inside the window cannot land an
#      unanalyzed head behind SHA-bound evidence (review P1).
#   3. THE LANE MUST BASELINE BOTH SIDES. The decision compares the PR's failure
#      RATE and SIGNATURE against main's, so if main's measurement is EMPTY every
#      failure the PR carries reads as new — including ones already red on main,
#      which turns a safe merge into a false block. A lane is therefore usable
#      only if it has TESTED runs on main too (the same `tested` counter as
#      precondition 1). Repos that split their lanes by TRIGGER (a
#      `pull_request`-only lane and a `push`-only lane) have no single --workflow
#      spanning both sides; `--any-workflow` compares against every lane on main
#      (#1003).
#   4. THE TREE MUST BE GREEN WHERE THE RAIL CAN SEE IT. Preconditions 1-3 are
#      all LANE-SCOPED. A lane-scoped comparison is blind to the rest of the
#      tree, and that blindness is a false PASS at the merge level — not a
#      wording problem (#1261, proven twice in one day). See THE PR'S EVALUATED TREE
#      below.
#
# ── THE ONE DECLARED LANE EQUIVALENCE (#2610) ─────────────────────────────
# ONE equivalence, declared once, with its reason and the workflow lines that justify
# it — because a rail that can SEE two lanes running one suite under two names and
# does not say so answers "NO BASE COUNTERPART FOR THIS CHECK" about a red that is
# the base's own, and that false absence is what reads as "unattributable".
#
#   script-validate        (on the BASE — .github/workflows/ci-main.yml)
#     ⊇ bash-suites (<n>)  (on the PR   — .github/workflows/ci.yml)
#
# WHY IT IS TRUE — the repo says it about itself. ⚠️ EVERY ci.yml COORDINATE BELOW IS
# ANCHORED BY ITS QUOTED TEXT, and the quotes are the authority: ci.yml is a busy file
# and line numbers in it ROT (measured: a merge onto main added 49 lines above this
# region and moved the job from :896 to :945, which left an earlier version of this very
# block citing an unrelated `http-pool-hygiene` step — the declaration then looked
# unsubstantiated, i.e. the false absence came back through the citation instead of the
# logic. A later merge onto main moved it AGAIN, :945 -> :970, and the rebase of this
# branch re-created the same rot: the numbers below were re-located by their quotes and
# corrected — which is the rule working, not an exception to it). A THIRD move re-created
# it once more: merging main into this branch pushed the job :970 -> :993 and
# `script-validate` ci-main.yml:376 -> :403, and every coordinate below was re-located by
# its quote again, in the same commit that moved it — because a citation that rots in the
# very commit that moves the lines reads to the next lane as proof the claim is false.
# Re-locate by the quote, and fix the number when you move it. A FOURTH move (the merge that
# resolved this branch's conflicts) pushed every ci.yml coordinate again — +64 for the four job
# coordinates and +11 for the :395 citation — and each was re-located by its quote in that same
# commit; ci-main.yml's coordinates did not move. A FIFTH pass: `ci-main.yml` moved on main AND
# this branch's #3174 `env:` block + comments moved it further (+22 for the five step coordinates,
# +52 for the shard call), while `ci.yml` moved on main independently and left its four citations
# stale — so every number in this block was re-located by its QUOTE, one at a time, and each now
# names the line it claims. Re-locate by the quote; never by arithmetic on the old number.
#   * ci.yml:1160 — the PR lane's job is `bash-suites` (`bash-suites:`), matrix
#     `shard: [1, 2, …]` at :1250, so it PUBLISHES `bash-suites (1)` … `bash-suites (N)`,
#     one check per slice, and each slice's step is `bash scripts/run-bash-shards.sh`
#     (ci.yml:1288, `run: bash scripts/run-bash-shards.sh`);
#   * ci-main.yml:405 — "the main lane runs the SAME sweep as ci.yml's `bash-suites`
#     — this job calls the one runner below, UNSHARDED", and ci-main.yml:528 is that
#     call: `bash scripts/run-bash-shards.sh`; main publishes ONE check named
#     `script-validate` (ci-main.yml:403);
#   * ci.yml:1262 — "ci-main.yml's `script-validate`: one runtime for the list, in
#     both lanes" (also ci.yml:464, "today — ci-main.yml's script-validate job runs bash
#     shards only"). ⛔ NOT ci.yml:1163: that line is the HISTORY of the pre-#1369 split
#     ("while main's `script-validate` ran the bash sweeps + the hermetic suites") and
#     describes a body WIDER than the list, so citing it here would argue AGAINST the
#     containment this pair rests on (review cycle 3).
#   So main's ONE check RUNS the same list the PR slices, one shard at a time: the
#   base reports this program under the other lane's name.
#
# ⛔ CONTAINMENT, NOT EQUALITY — and the difference is load-bearing. Main's
# `script-validate` job has SIX steps, of which FOUR are validation steps (ci-main.yml:466
# `node --check`, :478 the lane-parity guard, :484 its mutation self-test, :528 the shard
# list) and the other two are `actions/checkout` (:451) and `actions/setup-node` (:456) —
# while a `bash-suites (<n>)` slice runs only the shard list. So a red under that name may
# be the shard list's red — or ANY other step's, including the setup ones. The equivalence
# therefore establishes that the base RUNS this program and carries A red under its name;
# it can never establish that the base's red is this suite's. That is why the answer is
# phrased as a candidate (`base-caused via`) and why the paragraph under it says so out
# loud.
#
# WHAT IT DOES NOT BUY, stated here so it cannot be read as more than it is:
#   * it is a NAME-level statement about two LANES, not an identity-level statement
#     about two failures — and, per the containment note above, not even a
#     program-identity statement at job level. It can say the base carries a red
#     under a name that runs this program; it can NEVER say the base's red IS this
#     failure.
#   * it exempts NOTHING. The decision compares failures by IDENTITY, and a shard
#     whose log yielded none still has none — step 1c still refuses. What changes is
#     that the refusal can now NAME what it refused (`base-caused via script-validate
#     ≡ bash-suites (<n>)`) instead of reporting an absence it did not establish.
#   * it applies ONLY on the base side (base -> PR). A PR check with no declared
#     counterpart keeps the unqualified `NO BASE COUNTERPART` answer: this is one
#     pair, not a policy that shell failures are probably fine.
#   * it does not touch §4.5. The PR's own evaluated tree still BLOCKS on a red
#     there, base-shared or not — that gate exists for the repair direction, which
#     requires the red to be GONE from the PR's tree (#1261).
#
# The value lives in `declared_base_equivalent`, its ONE implementation; the ONE
# reader is the step-1c named refusal (`named_unattributable_runs`).
#
# ── THE PR'S EVALUATED TREE (#1261) ───────────────────────────────────────
# The incident, exactly. PR #4589 (commit ebe4e7e8f) landed three ruff
# violations in `tools/embedded_evidence.py`. The ruff gate is the
# `agent-infra-ci / lint` job of `ci.yml`, which runs on the PULL REQUEST MERGE
# REF — so once those bytes were on main, EVERY OPEN PR was lint-red on a diff
# touching neither file. The rail was watching `python-ci.yml`: green on both
# sides, so both failing sets were empty, the vacuous branch merged, and PR
# #4600 then merged onto the same red main. The repair came from a HUMAN
# noticing.
#
# WHY MAIN'S HEAD WAS THE WRONG TREE. The first fix read MAIN'S HEAD surface.
# That catches the incident, but it also refuses the PR that REPAIRS a red
# main — while main is red, the repair is red-looking for as long as it is
# unmerged — so the rail could not land its own recovery and pushed it onto the
# manual `AGENT_ADMIN_MERGE_OVERRIDE=1` escape. The question has to be asked
# about the tree THIS PR PRODUCES, not the tree main is already on.
#
# WHAT CI ACTUALLY EVALUATES (#1261 CORRECTION, VERIFIED — NOT ASSUMED). For an
# open, mergeable PR the `pull_request` event sets `GITHUB_REF` to the merge
# branch and `GITHUB_SHA` to the merge commit
# (docs: Events that trigger workflows → pull_request), and `actions/checkout`
# uses that ref — so the tested TREE IS the merge ref `refs/pull/<N>/merge`.
# Verified on a live run: the job log fetches
# `+67c72331…:refs/remotes/pull/1333/merge` and reports `HEAD is now at 67c7233
# Merge e55b123c… into 59a08fcd…`.
#
# BUT THE CHECK SURFACE IS KEYED TO THE HEAD SHA, NOT TO THE MERGE SHA. GitHub
# attaches the run's check suite to the PR HEAD commit while the runner's
# GITHUB_SHA is the merge commit. Measured: `GET …/commits/<merge-sha>/check-runs`
# returns `total_count: 0` and `…/check-suites` returns `total_count: 0`, while
# the SAME PR's head sha carries the 10 check suites (verified on
# daniel-ospina/agent-infra #1333 — `merge_commit_sha` 67c72331 = the
# `refs/pull/1333/merge` ref sha, zero checks; head e55b123c, 42 check runs —
# and on cli/cli #14485, vitejs/vite #23552, microsoft/TypeScript #64385).
# PROBING `refs/pull/<N>/merge` WOULD THEREFORE READ AN EMPTY SURFACE ON EVERY
# PR, report UNMEASURED and merge — an INERT gate, which is exactly the false
# PASS this rail exists to prevent. So the blocking surface is read from the
# HEAD sha: `GET /repos/{owner}/{repo}/commits/{head}/check-runs` + `/status`.
# That surface IS the merge-ref evaluation (the runs that produced it checked
# out the merge branch), and it is the surface where the incident's inherited
# `lint` red actually appears on a non-repairing PR and is ABSENT on a repair.
#
# WHAT IS REPORTED, AND WHAT BLOCKS. The PR's evaluated-tree surface BLOCKS.
# MAIN'S HEAD SURFACE IS STILL MEASURED AND REPORTED (it is useful context — it
# says whether the base is currently red) but it NEVER blocks: while main is
# red, the repair PR is green on its own tree and must merge. Required checks
# are deliberately NOT the source: this rail merges with `--admin`, which
# BYPASSES required checks, so a check that is not required gates nothing — and
# in the incident the red job was not a required check at all.
#
# THE MERGE REF ITSELF IS RESOLVED AND CHECKED, even though the surface is not
# keyed to it, because its ABSENCE/STALENESS is the thing that makes a surface
# untrustworthy. `GET /repos/{owner}/{repo}/pulls/<N>` gives `merge_commit_sha`
# (the merge ref's sha for an open mergeable PR — verified equal to
# `GET …/git/ref/pull/<N>/merge`, `.object.sha`) plus `mergeable`; `gh pr view
# --json mergeCommit` does NOT work for this (GraphQL `mergeCommit` is null for
# an unmerged PR — verified). A CONFLICTED PR (`mergeable: false`) has a NULL
# `merge_commit_sha` while the ref may still exist with a STALE sha (verified on
# #1161: ref ff2cede's parents are neither the current head 44e5ed1b nor the
# current base 6d734f07) — so it is refused loudly rather than measured. An
# ABSENT ref (fresh PR, `mergeable: null`, bounded re-poll then give up) is also
# refused loudly: a surface we cannot tie to a merge is not a certificate.
#
# CLASSIFICATION — AN ALLOW-LIST OF NON-RED SPELLINGS, NEVER A DENY-LIST. A
# COMPLETED check run is non-red ONLY for a conclusion this line names: `success`;
# `neutral`; `skipped` (a path-gated job legitimately skips — agent-infra's own
# `python-ci / lint` skips); `cancelled` (a superseded run —
# `cancel-in-progress: true` is normal); and `stale`. A legacy commit status is
# non-red ONLY for `success`. EVERY OTHER VALUE IS RED — including a spelling
# this rail has never seen (a vendor adds a conclusion, or GitHub returns a token
# from a newer API), a completed run with a null/empty conclusion, and any
# unrecognised status state. That is the fail-closed direction this repo requires
# ("a guard must fail closed on an unrecognised spelling"): the earlier DENY-list
# named the red tokens, so `mystery_failure` was neither red nor pending and the
# rail merged on it (#1261 fix round). The tokens the old list named —
# `failure`, `timed_out`, `action_required`, `startup_failure`, and the status
# states `failure`/`error` — are red under the allow-list too, because none of
# them is in it. A check still `queued`/`in_progress` is PENDING, never red: main
# always has something running, and refusing on that would block the fleet every
# time a post-merge run starts. The pending COUNT is printed, so an unmeasured
# surface is legible rather than silent.
#
# AND IN-FLIGHT IS AN ALLOW-LIST TOO (#1353). The same deny-list defect lived in
# the STATUS half of that rule: `status != "completed"` was the WHOLE test, so
# ANY spelling this rail had never seen — `completely_finished`, `Completed`, the
# empty string, a vendor's newer token — was filed as PENDING. Pending is never
# red, so the surface still read GREEN and the rail merged a check GitHub had
# already concluded `failure`. PENDING is therefore only for a NAMED in-flight
# spelling (`queued`, `in_progress`, `waiting`, `requested`, `pending`); any
# OTHER non-completed status is classified by its CONCLUSION under the same
# allow-list — RED unless that conclusion is one this line names as non-red. A
# non-completed run is never a MEASUREMENT either, so it cannot set the surface's
# last-production time (the staleness anchor).
#
# AND A COMPLETED RUN THAT MEASURED NOTHING IS NOT A MEASUREMENT EITHER (#1353).
# The anchor used to be set by EVERY completed check — including `skipped`,
# `cancelled`, `neutral` and `stale`, which exercise nothing (the rail's own
# doctrine: "a `skipped` shard is not coverage", #4457). Stamping it with such a
# run moved the surface's last-production time FORWARD past its real evaluation,
# so a base red that began in between compared as already-measured and the stale
# green merged. The predicate is now EXPLICIT, NAMED in ONE place, and used at
# BOTH sites that can set the anchor (check runs AND legacy statuses), so the two
# halves cannot drift apart again.
#
# AND NOTHING IS DROPPED BEFORE CLASSIFICATION (#1353). A check run with an empty
# `name` — or a legacy status with an empty `context` — used to be `continue`d
# away, so a RED on it appeared in NEITHER the red nor the pending list, the
# surface read `unmeasured — 0 failing of 0 measured`, and the rail merged. An
# unnamed check takes a PLACEHOLDER name and is classified by its conclusion like
# any other; an unnamed JOB likewise stays in the re-run bound's shard map (with
# no green sample, so it takes the fail-safe bound — never a too-small one).
#
# AND RED ONLY BLOCKS WHEN IT MEASURES CODE. MAIN's surface is dominated by
# lanes that measure no revision: on tortoise's last eight main commits SEVEN
# carried a failure-like check, and over the repo's last 100 main runs 6 of the
# 12 failure-like runs were `registry-backup-cron` (event `schedule`) and 1 was
# `finding-provenance` (event `issues`). Blocking on those would refuse
# essentially every merge in that repo, so each red is resolved (by the run id in
# its own URL) to the EVENT that produced it: `schedule`/`issues`/`issue_comment`
# are REPORTED but do not block; every other event, and any red whose run cannot
# be resolved, BLOCKS. See MAIN_HEALTH_RUN_MAP_LIMIT.
#
# ON THE PR'S OWN TREE THAT FILTER IS VACUOUS — AND THE EXEMPTION IS NOW SCOPED
# TO THE BASE, THE ONLY SURFACE IT WAS WRITTEN FOR (#1353). A `schedule`/`issues`
# run executes against the DEFAULT BRANCH head, so it can never attach to a PR
# head sha: every red on the PR's surface is a
# `pull_request`/`pull_request_target`/`push` run, i.e. a lane that measures a
# revision, and it BLOCKS. The exemption used to be applied UNCONDITIONALLY, so
# a `schedule`-attributed red on the TREE was routed to the non-blocking list —
# the rail merged the very red this paragraph called "an anomaly". The probe now
# takes the surface EXPLICITLY: the BASE exempts the named non-code events, and
# the TREE treats them as BLOCKING. An unresolved event still fails closed on
# both.
# The run map for a sha is selected by `gh run list --commit <sha>` (a sha is not
# a branch name, so `--branch` cannot be used there as it is for main).
#
# SUPERSEDED RUNS. Re-running a failed check leaves the OLD failing check run in
# place beside the new one — verified on tortoise commit fb27fff: `ai-review-gate`
# failure (id 106676366486) sits beside `ai-review-gate` success (id 106676728197)
# on the same commit. "Any failure-like check run is red" would call that commit
# red and block every merge. The rule is therefore GitHub's own: the LATEST check
# run (highest id) per (app, name) decides. Residual, stated: two DISTINCT
# workflows sharing one job name are conflated by that key — the same conflation
# GitHub's own check rollup makes.
#
# AND THE SUPERSEDED-RUN KEY MUST NOT DISCARD AN UNNAMED RED (#1353). That key is
# correct for an IDENTIFIED entry and is preserved — but EVERY unnamed entry
# shares the placeholder name, so one key let a newer unnamed NON-red supersede
# an older unnamed RED and discard it BEFORE classification: the red vanished,
# the surface read `green — 0 failing of 1 measured`, and the rail merged. A
# check literally NAMED the placeholder collides identically. An unnamed (or
# placeholder-named) entry is therefore keyed by a STABLE PER-ENTRY IDENTITY
# alongside (app, name) — its own check-run id, falling back to its position in
# the payload — so distinct unnamed entries cannot supersede one another. The
# legacy-status half uses the same rule (its per-entry identity is position,
# since a status carries no id).
#
# AN EMPTY SURFACE IS UNMEASURED, NOT GREEN, AND NOT A REFUSAL. Right after a
# merge, main's head has no check runs YET. Refusing there would block the common
# case, and the rail ALREADY refuses when the watched lane never tested main
# (precondition 3) — the lane-scoped half of "I did not look". So a zero-check
# surface prints UNMEASURED and proceeds; what it must never do is pretend the
# surface was read. An UNREADABLE probe (gh error, unparseable body) is a third
# thing again: that is the rail FAILING to look, and it REFUSES, by name.
#
# A PARTIAL READ IS A FAILURE TO LOOK, NOT HALF A CERTIFICATE (#1261 fix round).
# The probe reads TWO endpoints — `/check-runs` and `/status` — and it used to
# return UNREADABLE as soon as EITHER failed. That discarded the other endpoint's
# reds, and on the BASE it silently DISARMED 4.6/4.7: both are gated on the base
# being RED, so a base the rail could not read was treated as a base that is not
# red, and a stale green merged. Now the two endpoints are read independently:
# whatever WAS read is consumed and reported (a red on the readable half is named
# in the refusal), but a read missing one endpoint is a PARTIAL surface and is
# refused outright — on the base and on the tree alike. The endpoint that failed
# may carry a red, and with a COMPLETE read that red would have refused, so a
# partial read must never convert a refusal into a merge. Only BOTH endpoints
# failing is the "never read at all" state.
#
# THE FAILING SET IS COMPLETE OR CLIPPED, AND THE DIFFERENCE IS NAMED (#1353).
# The parser DROPS a `FAILED` token that is not a test id — it never enters the
# set — so `PR failing: 0` has three meanings: "no failures", "not comparable"
# (the lane-parity gate, #1319) and "the failures were DROPPED". The parser names
# every dropped token on its stderr; the rail CAPTURES that stream per call site,
# names the count and the tokens on stderr, and carries BOTH into the posted
# evidence (an `Attribution — FAILED tokens DROPPED…` line with the counts, plus a
# token list that states COMPLETE when empty). In the EVIDENCE the token text is
# rendered with its markdown metacharacters ESCAPED, so #1353's disclosure and
# #3756's "the evidence is inert to a hostile token" hold at once; on STDERR the
# text is verbatim. A run whose failures are ENTIRELY
# unattributable still BLOCKS at step 1c — preserved, and now naming the tokens it
# dropped. A PARTIAL drop does not block: the run yielded ids, and the set is
# merely CLIPPED — which the evidence states rather than leaving to be inferred.
#
# AND THE COMPLETE/CLIPPED CLAIM IS MADE FROM THE COUNT, NOT FROM WHETHER THE
# RENDERED TOKEN LINES ARE BLANK (#1353). A DROPPED line whose TOKEN TEXT is
# empty (a bare `FAILED` / `FAILED ` line) is still a counted drop, but it renders
# nothing — so the token block printed the COMPLETE empty-text body while the
# attribution line one line above stated a positive drop count, and the evidence
# contradicted itself. A positive drop count with no non-blank token text now
# renders a CLIPPED body that NAMES the missing text, instead of a COMPLETE body
# that denies the count.
#
# STALENESS: A RED BASE THE PR HAS NOT MEASURED (#1261, step 4.6). The tree
# surface above reflects the base AS OF THE PR'S LAST RUN, and GitHub does not
# reliably re-run PR workflows when the base moves. So a base red that appeared
# AFTER this PR's checks were produced is invisible to the tree gate: the surface
# is a STALE GREEN and the merge lands a tree the PR never measured. That is the
# incident's shape — #4600 was opened before #4589 made main red and merged
# after. The refusal is RED-RELATIVE, never movement-relative: it runs only when
# the base head carries a CODE-MEASURING red (the same schedule/issues filter as
# the base context), and refuses only when such a red's run STARTED after the PR
# surface was last produced (the max `completed_at` over the PR surface's
# MEASURING completed checks — a PENDING legacy status is not a completed check
# and does NOT set this anchor, and neither does a COMPLETED check that measured
# nothing (`skipped`/`cancelled`/`neutral`/`stale`, or an unrecognised token):
# a pending status's `updated_at` marks when it was last QUEUED or
# re-announced, not when anything was measured, so letting it advance the anchor
# moved the last-production time FORWARD past the PR's real evaluation and made
# a base red that began in between read as "already measured" (#1353)). If the
# base moved and is GREEN there is nothing the PR has
# failed to measure, and it MERGES — refusing on movement alone would refuse
# essentially every open PR, and an over-block is a failure, not safety. The
# repair direction falls out for free: a base red that predates the PR's
# evaluation WAS measured by it, so the PR that repairs the base still lands.
# MEASURED, not assumed: on tortoise, main head 1f5d6efc49 carried `welcome-e2e`
# failure started 2026-09-22T16:13:22Z while open PR 4591's surface was last
# produced 2026-09-22T06:23:46Z (a stale green of ~10h); PR 1153's merge ref was
# recomputed 2026-09-22T14:12:42Z with base 59a08fcd while main had moved — so a
# merge-ref-parent comparison alone would MISS the recomputed-but-unre-run case,
# while the timestamp comparison catches both.
#
# AND THE MERGE REF'S BASE PARENT IS THE SECOND, INDEPENDENT SIGNAL (#1261, step
# 4.7). The timestamp rule above is blind to a base red whose run STARTED BEFORE
# the PR surface was produced but on a base the surface never used; GitHub
# recomputes `refs/pull/<N>/merge` when the base moves and does NOT re-run the
# PR's checks, so a surface can be produced LATER while still evaluating an OLDER
# base. The merge ref is a merge commit whose parents are `[<base>, <head>]`, so
# its FIRST PARENT is the base it was computed against: when that differs from
# the CURRENT base head AND the base carries a blocking red, the PR's green was
# measured against a base that does not contain the red, and the rail refuses —
# naming the base red and the re-run remedy. A lagging ref onto a GREEN base is
# harmless and MERGES (the merge ref lags by a commit or two routinely — measured
# on 12 of 12 open tortoise PRs while main was green — so refusing on movement
# alone would refuse essentially every open PR). MEASURED live 2026-09-22:
# tortoise #4659's merge ref 6f0b119a has base parent 283e919dd1 while main's
# head was 1f5d6efc49 (8 code-measuring reds, `welcome-e2e` started 16:13:22Z),
# and #4659's own surface was last produced 18:41:31Z — so the STARTED-AFTER rule
# did NOT fire, while the merge-ref parent did not contain the red head.
#
# Usage:
#   scripts/admin-merge.sh <PR> [--main-runs N] [--repo owner/repo]
#                              [--workflow <file|name>] [--any-workflow]
#                              [--no-rerun] [--rerun-timeout S] [--dry-run]
#                              [-- <gh pr merge flags>]
#
#   --main-runs N        union over main's last N runs (default 10 — see the
#                        #3469 trap in ci-failure-set.sh; a single run is not a
#                        baseline). BOUNDED at 200: every lane-side run costs one
#                        Jobs API call, and an unbounded window turns a
#                        correctness knob into a cost one. A non-numeric or
#                        non-positive N is refused before any CI work.
#                        For the LANE-COVERAGE gate the raw listing WIDENS while the
#                        window has yielded no shard in the parity FAMILY at all
#                        (doubling, bounded by 200). That is what makes a push burst
#                        harmless (#4844): each push CANCELS its predecessor, leaving
#                        terminal-but-unmeasured (`completed/cancelled`) runs that
#                        used to fill the window and push the last measured run out
#                        of it, refusing every merge on a condition unrelated to the
#                        PR. Such a run is still CONSULTED — it may have executed
#                        shards before it was cancelled, and skipping it would SHRINK
#                        the reference — but it cannot end the search. N is the
#                        STARTING WIDTH, not a stopping rule (#7734): the widening
#                        stops on a family match, on the history being exhausted, or
#                        at the 200-run bound — never merely because N runs finished
#                        a measurement, since under --any-workflow those runs can be
#                        non-code ones that carry no shard (measured: tortoise main
#                        carried 2 distinct executed job names in a 10-run window and
#                        3 in a 20-run one, none named `test*`, where 40 runs wide
#                        carried 17). So N is not a bound on what one pass reads or on
#                        the call budget: a widened pass reads its whole listing (at
#                        most 200 lane runs per side, one Jobs-API call each), and the
#                        posted evidence says when the reference came from a wider
#                        window than N.
#   --workflow <f>       the TEST lane both sides are read from (default
#                        `python-ci.yml`). NOT cosmetic: an unfiltered main
#                        window is dominated by cron/watchdog lanes and can
#                        contain ZERO test runs, so the baseline extracts EMPTY
#                        and every PR failure reads as new — the bogus zero. See
#                        THE BOGUS ZERO in ci-failure-set.sh.
#   --any-workflow       drop the lane filter (opt-out; re-opens the bogus zero).
#                        Written AFTER the `--` separator it is RECOVERED for the
#                        parser (loudly) rather than handed to gh — but the natural
#                        order is: parser flags BEFORE `--`, gh flags after (#4078).
#                        After `--` an argument is NOT a free-form tail: it must be
#                        one of `gh pr merge`'s own flags (or a value one of them
#                        consumes). An unrecognised token, a bare positional, or one
#                        of THIS parser's flags is refused by name before any gh
#                        call. (`--workflow` is recovered the same way, but it needs
#                        a real value — a missing one, or a flag as the value, is
#                        refused rather than silently widening the lane.)
#                        ⛔ THIS IS AN OPT-OUT, NOT THE DEFAULT. The rail does not
#                        widen the lane to make a PR land — #1439 refused exactly
#                        that, because a lane green on both sides while the REAL
#                        red sits on another workflow is the #1261 false PASS. The
#                        ONE case that falls back is measured and printed: if the
#                        watched lane's own `on:` block cannot fire for this PR's
#                        changed set (#1614), the lane is INAPPLICABLE, not
#                        missing, and the rail drops the filter for that run AFTER
#                        saying so — see LANE APPLICABILITY below.
#
#   ── LANE APPLICABILITY (#1614) — the ONE measured fallback ──────────────
#   Precondition 1 requires a TESTED run of the watched lane on the head. A PR
#   that touches no path the lane can trigger on can never satisfy it, so the
#   sanctioned path was a DEAD END for a whole class of diffs (`bin/`,
#   `scripts/`, `extensions/`, `.github/workflows/`, `templates/`, `docs/` —
#   measured live on PR #1596, whose only changed files are non-Python). The two
#   situations the rail used to treat identically are separated by MEASUREMENT:
#     * the lane SHOULD have run and produced no run  -> a real gap  -> REFUSE
#       (steps 1/1b, unchanged — this keeps #1261's protection);
#     * the lane CANNOT run for this diff (no PR trigger, or a `paths:` /
#       `paths-ignore:` filter that excludes every changed file) AND it has no run
#       for the head -> INAPPLICABLE dead end -> drop the lane filter for this run
#       and COMPARE THE EVALUATED SURFACE. Both grounds are required: a lane that
#       matched no trigger path but DID run for the head is not a dead end, so the
#       rail leaves it alone (no gratuitous widening).
#   The fallback is LOUD (stderr block + a line on the evidence) and it is
#   fail-CLOSED: a workflow file that cannot be read, a changed set that cannot
#   be read, or a trigger block the predicate cannot decide leaves applicability
#   UNMEASURED, and the rail then refuses exactly as it did before. The PR's
#   evaluated-tree gate (§4.5) still runs on every path, so the fallback cannot
#   merge a red tree — it removes a refusal, it does not remove a gate.
#   --rerun-timeout S    bound (seconds) on the RE-RUN wait — the wait for a
#                        re-run run to finish. This is an EXPLICIT override;
#                        when absent the bound is DERIVED at rail runtime from a
#                        recent GREEN population's PER-SHARD COMPLETED SUCCESSFUL
#                        job durations (each shard's 2 x max, floored) — never
#                        from the failing run, whose failing shard was truncated
#                        by `pytest -x` (a short sample). There is deliberately NO
#                        GLOBAL constant: B4's population falsifies one —
#                        main-side `test (a)` n=5 median 18.8m / max 24.2m
#                        against `test (b)` n=5 median 46.6m / max 49.9m, so
#                        `test (b)`'s MEDIAN green run is 2.5x `test (a)`'s.
#                        One number is wrong in BOTH directions: it blocks the
#                        slow shard mid-distribution while being far
#                        over-generous for a fast one. For a REMOTE run this
#                        derived bound is the ONLY bound: the run metadata
#                        carries NO within-job activity signal — `updatedAt`
#                        advances on job/step TRANSITIONS, so a single long test
#                        step leaves it frozen for the whole job — and a
#                        separate "no progress" window therefore cannot tell a
#                        healthy long job from a wedged one; it can only fire
#                        EARLY, which is the false STALL this replaces. STALLED
#                        is thus "the run exceeded its own DERIVED per-shard
#                        bound while still non-completed", and the bound is
#                        named (shard, green n, green max) in the message. An
#                        explicit value is a CEILING instead: an operator's cap,
#                        not a claim about the run. See wait_for_run.
#   --no-rerun           skip the flake re-run classification (a non-empty
#                        unique set then blocks immediately). NOTE: the #3715
#                        base reproduction still runs — it is a baseline
#                        MEASUREMENT, not the PR's flake re-run, and it can
#                        still clear a failure main's table has no row for.
#   --print-bounds [<run-id>]
#                        print the re-run bound + per-shard table + source. With NO
#                        run id there is nothing to derive from, so this prints the
#                        FAIL-SAFE (3900s) and makes no gh call at all.
#   --dry-run            compute + print the decision; mutates nothing at all —
#                        no CI re-run, no comment, no merge. On the flake path it
#                        reports and exits 0 (it is an inspection, not a verdict;
#                        a real run would re-run and re-classify). Add --no-rerun
#                        to get the no-reclassification verdict as the exit code.
#   --repo owner/repo    repo for the gh calls. This is the ONLY way to select a
#                        repo: `--repo` and its short `-R` after the `--` separator
#                        are refused by name, because a forwarded repo selector
#                        points the MERGE at a different repo than the analysis and
#                        the head-bound evidence — which stay on the original one.
#                        With no --repo the target is the INVOCATION CHECKOUT's
#                        `origin` remote, and the resolved repo is printed on an
#                        evidence line. ⛔ AN INHERITED `GH_REPO` IS NEVER THE
#                        TARGET (#2235): gh gives it precedence over the checkout for
#                        every call that omits --repo, so a cell exporting it made
#                        this rail report '✅ ALREADY MERGED' for a SEPTEMBER tortoise
#                        PR over an open agent-infra one. If GH_REPO is set and names
#                        a different repo than the resolved target, the rail REFUSES
#                        BEFORE ANY API CALL, naming both repos; if it agrees it is
#                        ignored (the resolved value is exported for the run).
#   Extra flags (`--squash`, `--merge`, `--rebase`, `--delete-branch`, `--auto`,
#   …) are passed through to `gh pr merge` rather than hardcoded — but after `--`
#   the pass-through is an ALLOW-LIST of `gh pr merge`'s own flags, not a free-form
#   tail, and an unrecognised token exits 2 (a new gh flag needs adding here). It
#   is names, not spellings: a COMBINED shorthand like `-sd` is refused, so write
#   `-s -d`. `--admin` is always added by this script; a caller-supplied `--admin`
#   is dropped.
#
#   MERGE METHOD DEFAULT. `gh pr merge` REQUIRES exactly one of
#   `--merge`/`--rebase`/`--squash` when it is NOT interactive; with none it
#   errors and NO-OPs. The passthrough above made that an omission the CALLER
#   could make silently, so the rail posted its head-bound evidence marker and
#   then merged NOTHING — a FALSE PASS by construction (B1 lost #3754/#3755 to
#   exactly this). `--squash` is therefore the DEFAULT whenever the caller
#   supplies no merge method; an explicit `--merge`/`--rebase`/`--squash`
#   overrides it.
#
#   THE MERGE'S EXIT STATUS IS CHECKED. A `gh pr merge` that fails AFTER the
#   evidence marker was posted exits non-zero, prints gh's stderr, and posts a
#   head-bound RETRACTION so the marker can never be read as a successful merge.
#
#   THE THREE WAITS ARE DIFFERENT, AND EACH NAMES ITSELF. Three independent
#   bounded windows gate a merge and must never be mistaken for one another
#   (B7: an operator raised --rerun-timeout and the rail exited INSTANTLY,
#   because a different wait gated first — an ambiguous message made it read as
#   a fresh failure). Each owns its own bound and reports its OWN state when it
#   expires; none may say "would not change this exit":
#     * the FIRST-CHECKS WAIT (`ADMIN_MERGE_FIRST_CHECKS_STALL` /
#       `ADMIN_MERGE_FIRST_CHECKS_CEILING` / the legacy
#       `ADMIN_MERGE_FIRST_CHECKS_WAIT`) — the head's lane runs must APPEAR and
#       reach status=completed BEFORE any comparison (the fresh-PR race, and the
#       #2090 still_in_progress refusal). It says `FIRST-CHECKS wait` and names
#       what it last observed. It is PROGRESS-AWARE (#2481): it keeps waiting
#       while the pending runs' per-job/per-step state advances, and stops on
#       one of three DISTINCT verdicts — STALL (nothing observable changed for
#       the stall period), CEILING (still progressing, out of lane-occupancy
#       room), or the legacy window (no run ever appeared, or the surface could
#       not be read). Every one of them still BLOCKS: an unfinished lane yields
#       an empty failing set, which proves nothing.
#     * the RE-RUN WAIT (`--rerun-timeout` / the DERIVED per-shard bound) — after
#       `gh run rerun`, the SAME run must be observed to START (its run attempt
#       must advance) and then finish. A still-RUNNING job is not a failure
#       inside its bound; on expiry the wait prints the last observed job
#       conclusions and their ages. The same bound is the STALLED threshold; an
#       explicit `--rerun-timeout` is an operator CEILING instead (opposite
#       remedy ordering: investigate vs wait).
#     * the MERGE-REF WAIT (`ADMIN_MERGE_MERGE_REF_WAIT`) — GitHub computes
#       `mergeable`/`refs/pull/<N>/merge` in a background job, so a fresh PR can
#       answer `mergeable: null`. This wait polls THAT question, names itself,
#       and on expiry says the merge ref never appeared (not a CI failure and
#       not a checks-never-started verdict).
#
#   A DRAFT IS REFUSED EARLY. `commit-workflow` opens drafts deliberately and
#   `gh` refuses to merge one ("Pull Request is still a draft"), so this is a
#   systematic collision. The rail reads `isDraft` BEFORE any CI work and
#   refuses with that specific reason (tell the caller to `gh pr ready`) — never
#   a generic merge failure after the evidence marker. ⛔ AN UNREADABLE `isDraft`
#   READ IS A THIRD OUTCOME, NOT `false` (#1750): a failed read used to return
#   the empty string and be read as "not a draft", so the rail PROCEEDED past
#   this refusal. It now refuses by name via `require_draft` with its own
#   machine-readable tag (`[draft_unreadable]`), which the genuine-draft refusal
#   does NOT carry.
#
# Env seams (tests only):
#   ADMIN_MERGE_GH                       the gh command (default: `gh`)
#   ADMIN_MERGE_FAILURE_SET_SH           the parser (default: ./ci-failure-set.sh)
#   ADMIN_MERGE_POLL_INTERVAL            seconds between polls (they pace all three waits)
#   ADMIN_MERGE_FIRST_CHECKS_WAIT        the LEGACY bounded window (seconds,
#                                         default = the derivation fail-safe,
#                                         3900) on the FIRST-CHECKS wait, kept for
#                                         the two states with no progress to
#                                         observe: NO run has appeared at the head
#                                         yet, or the run list cannot be read.
#                                         0 disables the wait (the pre-#2090
#                                         instant refusal) when neither of the
#                                         two progress bounds below is set.
#   ADMIN_MERGE_FIRST_CHECKS_STALL       the STALL period (seconds, default 8760 =
#                                         2 × the longest MEASURED single step,
#                                         4380s): the wait gives up only when
#                                         nothing observable has changed for this
#                                         long. Promoted at runtime to 2 × the
#                                         longest COMPLETED step seen on the runs
#                                         being waited on.
#   ADMIN_MERGE_FIRST_CHECKS_CEILING     the absolute cap (seconds, default 18064
#                                         = 2 × the slowest MEASURED green run,
#                                         9032s). A lane-occupancy bound, NOT a
#                                         stall detector — its verdict says so.
#   ADMIN_MERGE_FIRST_CHECKS_POLL        seconds between FIRST-CHECKS polls
#                                         (default 60; the 10s default of
#                                         ADMIN_MERGE_POLL_INTERVAL paces the OTHER
#                                         waits). One `run list` + one Jobs read
#                                         per pending run per poll.
#   ADMIN_MERGE_MERGE_REF_WAIT           window (seconds, default 90) on the
#                                         MERGE-REF wait: GitHub computes
#                                         mergeable/refs/pull/<N>/merge in a
#                                         background job, so `mergeable: null` is
#                                         re-polled inside this window. 0 = one
#                                         observation, no waiting.
#   ADMIN_MERGE_MERGE_POLL_ATTEMPTS      optional hard cap on MERGE-REF reads
#                                         (default 0 = no cap); the WINDOW above is
#                                         the bound the message reports.
#   ADMIN_MERGE_SELF_EDIT_WAIT           bound (seconds, default 300) on the wait
#                                         for the run generation the rail's OWN
#                                         `[3/4] record` body PATCH created
#                                         (#1417). 0 disables the wait, which
#                                         restores the pre-#1417 refusal
#                                         exactly. The guard legs are small
#                                         (measured ~1 min end to end); on
#                                         timeout the runs are still pending and
#                                         §1b refuses as before, so this knob
#                                         can only remove a FALSE refusal.
#   ADMIN_MERGE_GREEN_RUNS               recent SUCCESSFUL runs sampled per shard
#                                         for the healthy duration (default 5)
#   ADMIN_MERGE_REPRO_CMD                the #3715 base-reproduction command
#                                         (reads refused nodeids on STDIN, writes a
#                                         pytest-shaped capture on stdout). Unset =
#                                         a pristine base worktree + `uv run pytest`.
#   ADMIN_MERGE_REPRO_TIMEOUT            the reproduction's mandatory alarm bound in
#                                         seconds (default 900; a positive integer —
#                                         anything else is refused)
#   ADMIN_MERGE_RERUN_FLOOR              per-shard bound FLOOR (default 1200). A
#                                         floor only ever RAISES the bound, so it
#                                         cannot cause the false block the flat
#                                         no-progress window did; it guards a
#                                         shard whose green sample is a single
#                                         short run.
#   ADMIN_MERGE_RERUN_TIMEOUT_FALLBACK   derivation fail-safe (default 3900)
#   ADMIN_MERGE_LANE_JOB_PREFIX          job-name prefix that identifies a TEST
#                                         shard for the lane-coverage gate
#                                         (default `test`). A repo whose test
#                                         shards are named otherwise must set
#                                         this, or the gate refuses EVERY
#                                         vacuous comparison (fail-closed: an
#                                         unreadable lane is never `the same`).
#                                         A job outside the prefix LEAVES the
#                                         comparison — narrowing it disables the
#                                         gate for the excluded family.
#   ADMIN_MERGE_LANE_PARITY              `require` (default) or `declared-off`.
#                                         BOTH refuse a vacuous comparison whose
#                                         lane parity was not established.
#                                         `declared-off` is retained only so the
#                                         refusal can name the trigger-split case
#                                         precisely (#1349 → #1439): it used to
#                                         certify, but the evidence gate refuses
#                                         a vacuous certificate that lacks
#                                         positive parity, so the certificate
#                                         could never be consumed — see
#                                         AGENT_ADMIN_MERGE_OVERRIDE below. Any
#                                         other value is refused at startup.
#   ADMIN_MERGE_SELECTOR_PYTHON          explicit interpreter for the target
#                                         repo's diff selector, whose declined
#                                         legs the parity gate forgives (#6928).
#                                         Default: resolve
#                                         `$PWD/.venv/bin/python3`, `python3.12`,
#                                         `python3.13`, then `python3`, keeping
#                                         the first that PROVES ≥3.12. When SET
#                                         it is the whole answer: a set-but-
#                                         unusable override fails closed
#                                         (forgiving nothing) instead of falling
#                                         through to another interpreter, so a
#                                         named interpreter that cannot run the
#                                         selector is REPORTED rather than
#                                         silently ignored.

set -uo pipefail

# ⛔ THE RESERVE IS SPENT BY LANDINGS ONLY — AND "THE RESERVE" IS NOT THIS SCRIPT (#2342 review, P1).
# `gh-limit.py` keeps a reserve below `GH_LIMIT_CORE_FLOOR` (default 800) and refuses a core-only read
# that could not be served from GraphQL. This file used to carry a file-scope
# `export GH_LIMIT_ESSENTIAL=1` here, which made EVERY `gh` in this script — and in every child it
# spawns — exempt from that floor. That is the opposite of the policy the layer states
# (`gh-limit.py::essential()`: "A poll is never essential"; docs/ops/gh-rate-limits.md:454): the
# floor's reason to exist is the spend measured on THIS rail's own poll loops, so exempting them left
# the guard unable to fire on its target. ⛔ AND IT BOUGHT THE LANDING'S WRITE NOTHING: `essential()`
# has exactly one call site, on the NON-mutating arm — a write is refused only by the dated-empty
# guard, which never consults it. The one in-tree declaration is therefore per call, on the read a
# landing genuinely cannot do without: `repo-authority.sh::required_checks`
# (`GH_LIMIT_ESSENTIAL=1 "$gh" api …/protection/required_status_checks`).

# File-scope so the EXIT trap can read it after `main` returns (P1-2).
TMP=""
# The stderr-capture file for the two READ PROBES (`resolve_head` / `resolve_draft`).
# File-scope for the same reason as `TMP`: a process-group signal (a terminal Ctrl-C) can
# kill the subshell between create and `rm`, and only the EXIT trap can then clean it. ONE
# global for both, because the two readers never run concurrently — the head read completes
# before the draft probe starts. Empty until a read creates it, so the trap's `rm -f` is a
# no-op on the paths that never read (#1750 review).
READ_ERRTMP=""

GH="${ADMIN_MERGE_GH:-gh}"
# ⛔ THE AMBIENT SELECTOR IS CAPTURED AT STARTUP, BEFORE THIS RAIL OVERWRITES IT.
# `GH_REPO` is gh's own ambient repo selector (below), and #2235 is the defect that
# produced. Two things need the INHERITED value rather than the resolved one:
#   * the refusal in `resolve_rail_repo` — it compares what the environment claimed
#     against what the checkout proves, so it must see the claim, not the answer;
#   * the review-record key list in `pr_review_record_blocks_update` —
#     `record-review.sh` writes the qualified record from the spelling it was handed,
#     and a caller may legitimately have handed it one via `GH_REPO` (tests §69 (n)).
#     Once the rail exports its own resolved slug, that spelling survives ONLY here.
RAIL_AMBIENT_GH_REPO="${GH_REPO:-}"
# The jobs-JSON parse and the ISO-8601 age both need a real JSON/timestamp
# reader. python3 is already a hard dependency of this rail — ci-failure-set.sh
# routes its FAILED-id parsing through ci_exemption.py — so this adds no new
# dependency, and it is the portable reader (`date -d` is GNU-only).
if command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3; else PYTHON_BIN=python; fi
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFS="${ADMIN_MERGE_FAILURE_SET_SH:-$SELF_DIR/ci-failure-set.sh}"
EXEMPTION_PY="$SELF_DIR/ci_exemption.py"
POLL_INTERVAL="${ADMIN_MERGE_POLL_INTERVAL:-10}"
# SELF_EDIT_WAIT — the bound on the #1417 wait for the rail's own body-edit run
# generation. A POLICY bound, not a derived one (the two guard legs are small and
# fixed, unlike a test lane's per-shard spread). See settle_self_edit_generation.
SELF_EDIT_WAIT="${ADMIN_MERGE_SELF_EDIT_WAIT:-300}"

# ── THE HEAD READ'S RETRY BUDGET (#1690) ────────────────────────────────
# Hoisted here so `validate_timing_knobs` can refuse a bad value BY NAME at startup,
# exactly like POLL_INTERVAL — NOT inline in `resolve_head`, which is how the first
# version did it and why `ADMIN_MERGE_HEAD_ATTEMPTS=08` reached the loop: `08` contains
# no non-digit, so an inline `case '' | *[!0-9]*)` guard passes it, and bash ARITHMETIC
# then reads it as an invalid OCTAL and errors. The refusal that followed still carried
# `[head_unreadable]` — so the rail asserted "could not read the head" on a run where
# ZERO reads were attempted. That is #1690's own symptom, machine-readably, on the
# instrument whose job is not to make it.
#
# ⛔ THE WINDOW IS SIZED FOR A BLIP AND THE SIZE IS STATED (#1690 review). The loop sleeps
# `HEAD_READ_SLEEP * attempt` BETWEEN attempts, so the old defaults gave 1s + 2s = 3s — and a
# review measured exactly that, making the point sharply: the incident #1690 reports did not
# clear inside 3s, so the retry as first written would NOT have recovered it. Now 5 attempts
# over 2s + 4s + 6s + 8s = 20s.
#
# The number is deliberately TENS OF SECONDS, not minutes, and that is the judgement rather
# than an oversight: a blip (a dropped connection, a DNS hiccup, a TLS retry) clears in
# seconds, while a rate limit or a credential problem is NOT something to wait out — waiting
# minutes would hang the rail on a condition it cannot fix. The diagnostic channel below is
# what covers that case: the operator is told the actual cause and can act, instead of
# watching a retry exhaust itself against a permanent failure. Both halves are needed;
# neither replaces the other. A caller that does not want the wait sets
# ADMIN_MERGE_HEAD_READ_SLEEP=0 — the rail's own test scenarios do exactly that, so the wider
# default costs the suite no wall-clock time.
HEAD_ATTEMPTS="${ADMIN_MERGE_HEAD_ATTEMPTS:-5}"
HEAD_READ_SLEEP="${ADMIN_MERGE_HEAD_READ_SLEEP:-2}"
# ── THE MERGE-ARTIFACT READ'S RETRY BUDGET (#1298) ──────────────────────
# Hoisted here so `validate_timing_knobs` can refuse a bad value BY NAME at startup,
# exactly like HEAD_ATTEMPTS — and NOT inline in the reader, which is how
# `ADMIN_MERGE_HEAD_ATTEMPTS=08` reached a loop and printed
# `[head_unreadable] — could not READ the head (0 attempts)` on a run where ZERO
# reads were attempted (#1690 review round 4). `poll_merge_artifact` is the SAME
# shape: a `for ((attempt = 1; attempt <= attempts; attempt++))` whose bound is
# supplied by an operator env var, so `08` is invalid OCTAL there and the loop body
# never executes. Validation therefore has to happen BEFORE any arithmetic consumes
# it, on the startup path AND on a sourced path (see `merge_art_knobs_ok`).
VERIFY_ATTEMPTS="${ADMIN_MERGE_VERIFY_ATTEMPTS:-6}"

# ── THE RE-RUN BOUND IS DERIVED PER SHARD, AT RAIL RUNTIME ──────────────
# There is deliberately NO GLOBAL CONSTANT. B4's population falsifies one:
# on main, `test (a)` is n=5 median 18.8m / max 24.2m while `test (b)` is
# n=5 median 46.6m / max 49.9m — so `test (b)`'s MEDIAN green run is 2.5x
# `test (a)`'s. A single number is wrong in BOTH directions: the old
# `observed_slowest_shard` (1563s) bound blocked `test (b)` mid-
# distribution while being many times over-generous for a 1.6m shard.
#
# Per shard s, over a GREEN population — recent COMPLETED SUCCESSFUL jobs of the
# SAME lane, never the failing run:
#     bound(s) = max(FLOOR, 2 * max(D(s)))   # D(s) = a completed SUCCESSFUL job's duration
# The failing shard's job was truncated by `pytest -x`, so a duration read off the
# failing run is a SHORT failure sample: 2 x it can be SMALLER than the healthy
# re-run it must cover — the exact too-tight-bound defect this replaces, in the
# common case (the slow shard is the one that failed). A shard with NO green
# sample takes the FAIL-SAFE, never the truncated failure.
# The run bound C is the max over the shards the rail might still WAIT ON —
# the NOT-completed ones. When every shard is completed (the normal case: the
# run a re-run is about to replace is terminal), C is the max over ALL shards.
#
# FLOOR is load-bearing: a shard's green bound must never be tiny. A shard whose
# green sample is one short run would otherwise get a bound barely above that run,
# and a healthy re-run a little slower than the one observed sample would be
# called STALLED — the too-tight-bound defect by another door. The floor only
# ever RAISES a bound, so it can never cause a false STALL; it bounds how fast a
# wedged FAST shard is noticed, not whether a healthy run is blocked. The
# fail-safe is larger still and applies to ANY derivation failure — a derivation
# that failed must never produce a SMALL bound.
# The floor and the fail-safe are validated by name in validate_timing_knobs.
FAILSAFE_RERUN_TIMEOUT="${ADMIN_MERGE_RERUN_TIMEOUT_FALLBACK:-3900}"
RERUN_FLOOR="${ADMIN_MERGE_RERUN_FLOOR:-1200}"

# ── THE FIRST-CHECKS WAIT IS PROGRESS-AWARE, NOT A FIXED WINDOW (#2481) ──
# The head's lane runs must APPEAR and reach status=completed before §1b may
# compare — the fresh-PR race (no run yet) and the #2090 shape (a run still
# queued/in_progress). The wait used to be ONE fixed window, and #2481 measured
# what that costs:
#
#   8 consecutive GREEN `ci.yml` PR runs (2026-10-22/23):
#     full green run                  6586s … 9032s   (median ≈ 8075s)
#     longest `bash-suites` JOB       5490s … 6660s
#     longest single STEP   3960s / 4020s / 4368s / 4380s  (73.0 min,
#                           "Bash shards — the ONE list both lanes run")
#
# ⇒ the 3900s window this knob used to set is SHORTER THAN ONE GREEN STEP of the
# lane it waits for, and less than half the lane's median RUN. Every landing lane
# therefore burned its budget and refused with a verdict that said nothing about
# the PR: on #2412 the rail printed `the FIRST-CHECKS wait expired … no
# classification attempted` and the PR merged FOUR MINUTES LATER, while
# `bash-suites` was red on 48 of 83 open PRs — the common path.
#
# Raising the number is NOT the fix (that moves the timeout later and keeps
# failing on the same PRs). The wait is now driven by a PROGRESS signal — the
# per-job/per-step `status` of each pending run's Jobs-API listing — so a slow
# run and a wedged run stop being indistinguishable. Three bounds, each DERIVED
# from a measured quantity rather than a round number:
#
#   FIRST_CHECKS_STALL   give up when NOTHING observable has changed for this
#                        long. The finest progress granularity GitHub exposes is
#                        a STEP boundary, and a healthy step was measured silent
#                        for 4380s, so 2 × 4380 = 8760s. ANY bound below one
#                        legitimate step is a GUARANTEED false stall — the exact
#                        defect §39 pins out. It is also PROMOTED at runtime to
#                        2 × the longest COMPLETED step seen on the runs being
#                        waited on: observation, not taste.
#   FIRST_CHECKS_CEILING the absolute cap on lane occupancy: 2 × the slowest
#                        measured green run (2 × 9032 = 18064s). It exists so a
#                        pathological run cannot hold a lane forever; it is NOT a
#                        stall detector and its verdict never claims to be one.
#   FIRST_CHECKS_POLL    seconds between polls, 60. Derived from the CALL budget,
#                        not comfort: a poll is 1 `run list` + 1 Jobs read per
#                        pending run, so the WORST-CASE wait to the ceiling is
#                        301 polls ≈ 600-900 REST calls over five hours
#                        (≈120-180/h) — LESS per hour than the fixed 10s window it
#                        replaces managed (390 calls in 65 min ≈ 360/h) against
#                        the fleet's ONE shared 5000/h bucket.
#
#   FIRST_CHECKS_WAIT    the LEGACY bounded window, kept for the two states that
#                        have no object whose progress could be observed:
#                        `never-started` (no run has appeared at this head) and
#                        `unreadable` (the run list itself cannot be read). Its
#                        default and its meaning are UNCHANGED, so #2465's
#                        inapplicable-lane case behaves exactly as before.
#                        0 is legal and, when no other FIRST_CHECKS bound is set,
#                        disables the wait (the pre-fix behaviour, the suite seam).
FIRST_CHECKS_WAIT="${ADMIN_MERGE_FIRST_CHECKS_WAIT:-$FAILSAFE_RERUN_TIMEOUT}"
FIRST_CHECKS_STALL="${ADMIN_MERGE_FIRST_CHECKS_STALL:-8760}"
FIRST_CHECKS_CEILING="${ADMIN_MERGE_FIRST_CHECKS_CEILING:-18064}"
FIRST_CHECKS_POLL="${ADMIN_MERGE_FIRST_CHECKS_POLL:-60}"
# CHECK_UNRESOLVED_BOUND — the bound on ONE thing the FIRST-CHECKS wait never
# bounded: a check whose NEWEST attempt has no conclusion (`status=queued`/
# `in_progress`, `conclusion=null`) because the job behind it never got a runner.
#
# ⛔ THE MEASURED DEFECT THIS BOUNDS (tortoise#10399). Two lanes railed two
# FULLY GREEN PRs (#10474, #10475) and both HUNG with no decision: `pending=1`
# on a head whose `python-ci-gate` — tortoise's REQUIRED aggregator, "branch
# protection AND the merge queue's only merge_condition" — had no completed
# attempt, because the aggregator cannot start until every `needs:` job has.
# One of those (`ci-introduced-failure`) sat `queued` on run 41279786666 from
# 06:11:08Z to 09:06:39Z — nearly three hours — while its SIBLING jobs kept
# finishing, so the progress fingerprint kept CHANGING and the stall clock could
# never fire. The wait's own ceilings (stall 8760s, ceiling 18064s) are LANE
# OCCUPANCY bounds, not budget bounds: a lane that hits them has spent 2.4-5h
# inside one command and returns, from outside, exactly the artefact of a
# lander that was never running.
#
# So this is a SEPARATE, budget-sized bound on UNRESOLVEDNESS, and it REFUSES BY
# NAME (`check-unresolved:<name>:<status>/<conclusion>`) instead of waiting. It
# is NOT a longer timeout and NOT a shorter stall clock — a run that is queued
# because the whole pool is saturated never stops moving, so no progress-based
# clock can ever reach it. 3600s is the default because it is longer than the
# slowest honest single attempt measured on this fleet and far shorter than the
# occupancy bound it substitutes for; an operator who wants the old behaviour
# sets it to the ceiling.
# ⛔ IT NEVER CONCLUDES GREEN. Expiry is a REFUSAL (exit 1 via
# block_on_first_checks), and a `conclusion` of null/empty is never read as
# `success`/`neutral`/`skipped` — the fleet polarity rule: an unrecognised or
# null conclusion is RED-or-REFUSED, never green.
CHECK_UNRESOLVED_BOUND="${ADMIN_MERGE_CHECK_UNRESOLVED_BOUND:-3600}"

# ── THE CONFIGURED LANE THAT DOES NOT EXIST IN THIS REPO (#2862) ──
# `WORKFLOW` defaults to `python-ci.yml`, a TORTOISE layout. On a repo whose CI
# lives in `.github/workflows/ci.yml` (premise-labs runs its CI in `ci.yml`)
# `gh run list --workflow python-ci.yml` matches NOTHING, and to this wait "no run
# matched the filter" and "the PR was pushed a second ago" are the SAME state — so
# it burned the whole legacy window and then refused with "CI never started" about
# a PR whose checks had all passed (measured 2026-10-26, premise-labs#572: 12
# checks, 0 failing; `--any-workflow` merged it in under two minutes).
#
# A repo needs no configuration to be MERGEABLE: `gh pr checks` resolves the
# surface fine. So the filter is a TORTOSE-SHAPED OPTIMISATION, not a contract,
# and the wait now DROPS it when it is PROVEN to select nothing while the head
# carries checks — re-reading the list the way `--any-workflow` does.
#
# ⛔ AND THAT IS NOT A MERGE-DECISION LOOSENING. §4.5 (`check_surface_probe` on
# the head) grades the evaluated tree across EVERY workflow and is untouched by
# this: a genuinely red required check is refused there whatever lane this wait
# happened to list. The filter only ever chose WHICH runs the wait watched.
#
# The drop is bounded by a COUNT, not a time: it may ATTEMPT the discriminating
# read at most this many times per wait, and an attempt costs ONE tiny
# `check-runs?per_page=1` read (its `total_count` is the whole surface), paid ONLY
# on the broken path — arm (a), a repo that does have the configured workflow,
# never pays it at all because its filtered list is non-empty. All four arms stay
# inside the existing verdict table, so nothing here can outlive the stall/ceiling
# bounds below. Set it to 0 to restore the pre-#2862 hardcoded-lane behaviour.
FIRST_CHECKS_REDERIVE_MAX="${ADMIN_MERGE_FIRST_CHECKS_REDERIVE_MAX:-1}"
# The maximum number of PENDING RUNS whose job lists this wait will fingerprint in
# one poll. Beyond it the read is deliberately NOT attempted, because a partially
# observed surface could show "no change" for a run that is in fact advancing —
# which is a false stall waiting to happen. A head with more concurrent pending
# runs than this is pathological (the lane is one workflow); the wait then reports
# its signal as INCOMPLETE and falls back to the bounded window above.
FIRST_CHECKS_JOBS_MAX=8

# The lane-run projection, mirrored from ci-failure-set.sh's LANE_RUN_JQ, and used
# by BOTH the pending-run diagnostic and lane_shard_set's coverage listing.
#
# DO NOT simplify the `if … == ""` to `//` (#1368). Two facts, both load-bearing:
#
#   1. All three fields must be NON-EMPTY. `lane_shard_set` splits this line with
#      `IFS=$'\t' read`, and TAB is IFS WHITESPACE, so adjacent tabs collapse into
#      one delimiter and the payload shifts into the wrong variable — `id` comes out
#      empty and the guard refuses the listing.
#   2. `(.conclusion // "-")` does NOT fix it: jq's `//` fires only on false/null,
#      and an empty string is neither.
#
# And the sentinel must not be a conclusion token, or the `case "$conclusion"`
# statements in ci-failure-set.sh's collect_union will credit it. `"-"` is not one.
#
# ci-failure-set.sh holds this same expression by design; see its copy for the other
# splitter.
#
# #1358: that script now EMITS these same three fields from a WIDER (raw) listing
# instead of asking gh for them directly, because it drops SUPERSEDED failing runs
# first (`drop_superseded_runs` there). The three fields, their order, their
# separators and the sentinel above are UNCHANGED, so this copy and that emitter
# stay byte-equal — which is why the sentinel is load-bearing on BOTH sides.
#
# The supersede rule is deliberately NOT applied to the copy HERE. This projection
# feeds the pending-run diagnostic and lane_shard_set's coverage listing, and a run
# that EXECUTED a shard is coverage however stale its conclusion — the question
# #1319's parity gate asks, which is a different question from "did this commit
# fail". Dropping such a run here would let a lane look as though it never ran the
# shard at all.
LANE_RUN_JQ='.[] | "\(.status)\t\(if (.conclusion // "") == "" then "-" else .conclusion end)\t\(.headSha):\(.databaseId)"'

# The FIRST-CHECKS projection: state, conclusion, id and creation time, so an
# expired FIRST-CHECKS wait can say what it last observed (and how old it is).
# `createdAt` is empty on an older gh or on a 3-field fixture; the message then
# omits the age rather than inventing one.
FIRST_CHECKS_JQ='.[] | "\(.status)\t\(if (.conclusion // "") == "" then "-" else .conclusion end)\t\(.databaseId)\t\(.createdAt // "")"'

# The GUARD projection (#1417), used ONLY by settle_self_edit_generation: the
# completion state plus the workflow's NORMALIZED DISPLAY NAME — the signal that
# identifies the rail's own body-edit generation on the runs surface.
#
# ⛔ `event` IS DELIBERATELY NOT PROJECTED (review, PR #1640). A workflow RUN's
# `event` field is the WEBHOOK EVENT NAME (`pull_request`, `pull_request_target`,
# `push`, …) — never the pull_request ACTIVITY TYPE (`edited`), which lives in the
# webhook payload and is not exposed on the run object at all. The first version
# of this fix classified on `event == edited`; that value cannot occur, so `self_n`
# was always 0 and the wait was dead code in production. The activity is also not
# what is needed: a `synchronize` run and an `edited` run of one workflow share a
# single `event` value, so no comparison on it can separate them.
#
# The workflow name is matched, not the file name, because
# `gh run list --json workflowName` returns the DISPLAY name and the file name is
# not on that surface. Normalizing to `[a-z0-9]` IN JQ is also the fail-open
# hardening: `ci-failure-set.sh:255` base64-encodes a raw `workflowName` because a
# newline in a workflow `name:` splits the projection, and this projection makes
# that impossible structurally — the field cannot contain TAB or NEWLINE, so it
# can never shift a later column. It carries no `headSha`: the listing is already
# `--commit`-scoped, so the field would be redundant.
LANE_RUN_GUARD_JQ='.[] | "\(.status)\t\(if (.conclusion // "") == "" then "-" else .conclusion end)\t\(.databaseId)\t\((.workflowName // "") | ascii_downcase | gsub("[^a-z0-9]"; ""))"'

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }
say_err() { printf '%s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

# pr_review_record_blocks_update <pr> <expected-head> — 0 when updating would leave a
# review record stale with nothing able to carry it, 1 when the update is safe.
#
# ⛔ THE PATH IS LITERAL, SO THE SLUG MUST BE RESOLVED. `gh` fills `{owner}/{repo}`
# for API calls, but a record is a FILE at `~/.pi/agent/reviews/<owner>-<repo>-<pr>.json`,
# and `record-review.sh` AUTO-DETECTS the repo when none is passed — writing the
# repo-qualified name and deleting the legacy `<pr>.json`. Deriving the path from
# `$REPO` alone therefore read `reviews/--<pr>.json` plus the legacy name the writer
# removes, in the documented invocation that sets no `--repo`: the guard silently
# never fired and the update went ahead. Hence the explicit resolution.
#
# ⛔ A RECORD BOUND TO THE HEAD BLOCKS THE UPDATE, FULL STOP. `atomic-land.sh`'s B5
# permits the update when the PR carries a VERIFIED signed marker — it recomputes
# the HMAC with the gate key, and the carry arm then re-binds the verdict to the new
# head. This rail has no gate-key or `openssl` path, and the PR body is
# attacker-writable, so a shape match is not evidence: a forged or rotated-key
# `sig=` would read as carryable and the guard would wave through the very move it
# exists to stop. Rather than reimplement a cryptographic check here, every bound
# case is refused and the remedy that does not move the head is named. This is
# therefore STRICTER than B5, never looser: the whole cost is re-triggering the PR's
# checks by an event that does not move the head (`gh run rerun` is NOT that event — it
# re-executes the SAME merge commit, so it re-measures the old merge ref).
#
# pr_review_record_blocks_update <pr> <expected-head> — 0 when updating would strand a
# review record, 1 when the update is safe. Prints the specific condition on each block arm.
#
# ⛔ BOTH SPELLINGS OF THE REPO KEY MUST BE CHECKED. A record is a FILE at
# `~/.pi/agent/reviews/<owner>-<repo>-<pr>.json`, and the key is whatever repo string the
# writer was handed: `record-review.sh` uses the `--repo`/positional repo VERBATIM when it is
# given one, and the canonical `gh repo view` slug only when it is not. `gh` itself accepts a
# `--repo` spelling in any case and a PR number with a leading zero, and the merge gate reads
# the record under the spelling the rail forwards — so a guard that checked a single spelling
# would miss the other and let the update strand a record the gate still reads.
#
# ⛔ CHECK EVERY CANDIDATE, NOT THE FIRST THAT EXISTS. `record-review.sh` deletes a legacy
# `<pr>.json` only when its embedded `repo` matches, and a repo-less run can leave a stale
# qualified record beside a fresh legacy one — reading only the first that exists lets the
# fresh one be shadowed. The legacy name is shared between repos, so it is honoured only when
# it names no repo or THIS repo, mirroring `atomic-land.sh`'s `read_record` (#426).
#
# ⛔ FAIL CLOSED WHEN A RECORD CANNOT BE INTERPRETED. No file at all is genuinely safe. A file
# that EXISTS whose `head_sha` is missing, unreadable, non-hex or too short is not: the guard
# cannot tell whether it is bound to this head, and the sibling `atomic-land.sh` refuses on
# exactly that condition (`stop "the record … carries no usable head_sha"`).
#
# Reads records with `$PYTHON_BIN` rather than a new `jq` dependency: every other JSON read in
# this script goes through it, and a missing `jq` would make the guard fail OPEN behind a
# `2>/dev/null || true`.
pr_review_record_blocks_update() {
  local pr="$1" expected="$2"
  local rargs=() slug="" cands=() f="" rec_head="" rec_repo="" rec_bound=0
  [ -n "${REPO:-}" ] && rargs=(--repo "$REPO")
  slug="$($GH repo view ${rargs[@]+"${rargs[@]}"} --json nameWithOwner \
      --jq .nameWithOwner 2>/dev/null || true)"
  # ⛔ AN UNRESOLVED IDENTITY IS NOT A REASON TO SKIP THE CHECK. Both record paths are
  # named after the canonical slug, so failing to resolve it would leave the qualified
  # file unchecked and let the update strand the record this guard exists to protect.
  # Refuse instead: the cost is one re-run, and every other step of this rail needs a
  # working `gh` against this repo anyway.
  if [ -z "$slug" ]; then
    say_err "   ⛔ the repo identity could not be resolved ('gh repo view' returned nothing),"
    say_err "      so an existing review record cannot be ruled out — refusing to move the head."
    return 0
  fi
  # — THE NUMBER IS KEPT AS GIVEN *AND* STRIPPED. `record-review.sh` names the file with
  # `$PR` VERBATIM (it only validates `^[0-9]+$`), so a record written for `01631` lives at
  # `…-01631.json`, while this rail accepts `01631` as the PR argument because GitHub does.
  # Normalizing in one direction only would read a path the writer never wrote.
  local nums=("${pr:-0}") n="" keys=("$slug") k=""
  [ -n "${nums[0]}" ] || nums[0]="0"
  n="${nums[0]#"${nums[0]%%[!0]*}"}"
  [ -n "$n" ] || n="0"
  [ "$n" != "${nums[0]}" ] && nums+=("$n")
  # ...and the spelling the caller gave, which `record-review.sh` writes verbatim
  [ -n "${REPO:-}" ] && keys+=("$REPO")
  # `record-review.sh` also writes the qualified name from `GH_REPO` (that is its repo
  # resolution), and the merge gate resolves the record through `GH_REPO` as well — so an
  # environment-only spelling is a real key, exactly like `--repo`.
  [ -n "${GH_REPO:-}" ] && keys+=("$GH_REPO")
  # ⛔ AND THE SPELLING THE CALLER INHERITED (#2235). The line above now reads the
  # RESOLVED value this rail exported (`resolve_rail_repo`), so on its own it would stop
  # covering the environment-only spelling that the writer may have been handed — the
  # coverage tests §69 (n) pins. The inherited value is kept beside it, never instead of
  # it: a record can exist under either spelling, and only checking one strands the other.
  [ -n "${RAIL_AMBIENT_GH_REPO:-}" ] && [ "$RAIL_AMBIENT_GH_REPO" != "${GH_REPO:-}" ] \
    && keys+=("$RAIL_AMBIENT_GH_REPO")
  for k in "${keys[@]}"; do
    for n in "${nums[@]}"; do
      cands+=("$HOME/.pi/agent/reviews/${k%/*}-${k#*/}-$n.json")
    done
  done
  for n in "${nums[@]}"; do
    cands+=("$HOME/.pi/agent/reviews/$n.json")
  done
  expected="$(printf '%s' "$expected" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"

  # ⛔ A STORE — OR ANY ANCESTOR OF IT — THAT CANNOT BE SEARCHED IS NOT AN ABSENT STORE.
  # `stat` fails with EACCES when a path component denies search, so every candidate below
  # would look absent and the update would strand a record the rail never saw. The walk is
  # over the components: hardening only the store's own bits still reads as "no store at
  # all" when `~/.pi` or `~/.pi/agent` is what denies search.
  local rdir="$HOME/.pi/agent/reviews" anc=""
  for anc in "$HOME" "$HOME/.pi" "$HOME/.pi/agent"; do
    if [ -d "$anc" ] && [ ! -x "$anc" ]; then
      say_err "   ⛔ the path to the review store cannot be searched ($anc) — refusing,"
      say_err "      because a record bound to this head cannot be ruled out."
      return 0
    fi
    if [ -L "$anc" ] && [ ! -e "$anc" ]; then
      say_err "   ⛔ the path to the review store runs through a dangling symlink ($anc) — refusing."
      return 0
    fi
  done
  if [ -d "$rdir" ]; then
    # Only SEARCH is required: the candidates are read by name, so the store need not be
    # listable (mode 111 is enough). Requiring read made an unlistable-but-searchable
    # store a refusal for a condition that is false.
    if [ ! -x "$rdir" ]; then
      say_err "   ⛔ the review store at $rdir exists but cannot be searched — refusing,"
      say_err "      because a record bound to this head cannot be ruled out."
      return 0
    fi
  elif [ -e "$rdir" ] || [ -L "$rdir" ]; then
    say_err "   ⛔ a path exists at $rdir but it is not a directory — refusing, because a"
    say_err "      record store cannot be read through it."
    return 0
  fi
  for f in "${cands[@]}"; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    # ⛔ "EXISTS BUT IS NOT A READABLE REGULAR FILE" IS NOT "NO RECORD". A directory, a
    # dangling symlink, or a record store this process cannot read would otherwise make
    # `-f` false and be read as an absent record — the fail-open this guard exists to stop.
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then
      say_err "   ⛔ a path exists at $f but it is not a readable regular file — refusing,"
      say_err "      because the rail cannot tell whether a record is bound to this head."
      return 0
    fi
    rec_bound=0
    case "${f##*/}" in
      *-*) : ;;                        # qualified name: the repo is in the FILENAME
      *)                               # bare <pr>.json: the repo is a FIELD, so check it
        rec_repo="$($PYTHON_BIN -c 'import json,sys;print(json.load(open(sys.argv[1])).get("repo") or "")' "$f" 2>/dev/null || true)"
        rec_repo="$(printf '%s' "$rec_repo" | tr 'A-Z' 'a-z')"
        if [ -n "$rec_repo" ] \
           && [ "$rec_repo" != "$(printf '%s' "$slug" | tr 'A-Z' 'a-z')" ] \
           && { [ -z "${REPO:-}" ] \
                || [ "$rec_repo" != "$(printf '%s' "$REPO" | tr 'A-Z' 'a-z')" ]; }; then
          continue                      # a different repo's PR of the same number
        fi ;;
    esac
    rec_head="$($PYTHON_BIN -c 'import json,sys;print(json.load(open(sys.argv[1])).get("head_sha") or "")' "$f" 2>/dev/null || true)"
    rec_head="$(printf '%s' "$rec_head" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
    if [ -z "$rec_head" ]; then
      say_err "   ⛔ a review record exists at $f and its head could not be read — refusing,"
      say_err "      because the rail cannot tell whether it is bound to this head."
      return 0
    fi
    case "$rec_head" in
      *[!0-9a-f]*)
        say_err "   ⛔ a review record exists at $f but its head_sha is not a usable commit sha —"
        say_err "      refusing, because the rail cannot tell what it attests."
        return 0 ;;
    esac
    if [ "${#rec_head}" -lt 7 ]; then
      say_err "   ⛔ a review record exists at $f but its head_sha is too short to identify a commit."
      return 0
    fi
    case "$expected" in "$rec_head"*) rec_bound=1 ;; esac
    case "$rec_head" in "$expected"*) rec_bound=1 ;; esac
    if [ "$rec_bound" -eq 1 ]; then
      # ⛔ STATE THE CONDITION. The caller's refusal points at "the ⛔ line above", so
      # every arm that blocks must print one — including this, the commonest arm.
      say_err "   ⛔ a review record exists at $f and is bound to the head an update would move"
      say_err "      ($rec_head), so the branch is not moved out from under it."
      return 0
    fi
  done
  return 1
}

# ── refresh_pr_branch <pr> <expected-head> ──────────────────────────────────
# Ask GitHub to bring the PR's head up to date with its base.
#
# WHY THE RAIL PERFORMS THE REMEDY IT PRINTS (#4764). Steps 4.6 and 4.7 both
# refuse because the PR's checks were produced against a base that is not the
# current one, and both name "update the branch / push an empty commit" as the
# remedy. That is a fully-specified, mechanical operation handed to whoever runs
# the rail at the exact moment the rail has already PROVEN it is needed. Doing it
# here removes the round trip and certifies nothing: the refreshed head carries
# no completed check, so THIS invocation still refuses exactly as before and the
# lane re-runs once CI has measured the new head. The refusal is a re-measurement
# request, and this is the re-measurement.
#
# THE GREEN-BASE CASE IS DELIBERATELY NOT REFRESHED. Step 4.7 refuses a lagging
# merge ref ONLY when the base is red, because a lag onto a green base has
# nothing the PR failed to measure and refusing on movement alone would refuse
# essentially every open PR (its comment measures 12 of 12 open tortoise PRs
# lagging while main was green). A refresh re-runs every check, so performing one
# where the rail has already decided the lag is harmless would buy nothing and
# cost a full CI cycle. It is called only where the rail refuses BECAUSE of the
# lag.
#
# `expected_head_sha` is pinned to the head THIS refusal was computed against: a
# concurrent push makes GitHub refuse the call rather than silently folding a
# commit nobody analysed into the branch that is about to be merged.
#
# Returns 0 when GitHub accepted the request (the new head appears
# asynchronously, so the caller must NOT report a sha it has not read), 1 when it
# did not — in which case the printed manual remedy still stands.
refresh_pr_branch() {
  local pr="$1" expected="$2"
  local slug
  if [ -n "${REPO:-}" ]; then slug="repos/$REPO"; else slug="repos/{owner}/{repo}"; fi

  if pr_review_record_blocks_update "$pr" "$expected"; then
    say_err "   ⛔ NOT updating: the branch is not moved while a review record could be stranded"
    say_err "      (the ⛔ line above states the condition found). This rail does not verify carry"
    say_err "      markers (atomic-land.sh does, with the gate key), so it will not move a head out"
    say_err "      from under an attestation."
    say_err "      Clearing this refusal depends on the ⛔ line: for a record BOUND to this head,"
    say_err "      re-review and re-record at a new head, or re-trigger this PR's checks by an"
    say_err "      event that does not move it — a re-run re-executes the SAME merge commit, and an"
    say_err "      update or empty commit moves the head and strands the record. For a store, path or"
    say_err "      JSON the rail could not read, repair that first: neither action above clears it."
    return 1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "admin-merge: would bring the branch up to date with its base (--dry-run mutates nothing)."
    return 1
  fi
  local out
  out="$($GH api -X PUT "$slug/pulls/$pr/update-branch" \
            -f "expected_head_sha=$expected" 2>&1)" || {
    say_err "   (the rail asked GitHub to bring the branch up to date and the call did not succeed:"
    say_err "    $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-240))"
    say_err "   The manual remedy below still applies."
    return 1
  }
  info "admin-merge: ⇡ the rail asked GitHub to bring the branch up to date with its base."
  info "   GitHub recomputes the merge-ref evaluation from this, which is a full check"
  info "   re-run on the new head. Re-run this rail once those checks complete — the update"
  info "   itself certifies nothing."
  return 0
}

# ── write_merge_retraction <pr> <head> <reason> <detail-file> <detail-label> ──
#
# CORRECT THE MARKER. A posted evidence marker must never be left standing over
# an unmerged PR, so a head-bound RETRACTION is posted (best effort) stating that
# the merge did NOT happen and the evidence above is not a successful merge.
#
# The retraction is deliberately NOT a certificate — it carries no
# `unique to this PR: 0` line — so the merge gate will not accept it in place of
# the evidence.
#
# Factored into ONE function because there are now TWO ways for a merge to fail
# AFTER the marker is posted (#1359): the command exits non-zero, or it exits ZERO
# while the artifact (state=MERGED) was never observed. Two copies of a retraction
# body would drift, and the drift would be invisible in exactly the situation it
# exists for.
#
# ⛔ A RETRACTION IS A CLAIM, SO IT MAY ONLY BE POSTED ON EVIDENCE THAT SUPPORTS ONE
# (#1298). "the merge did NOT happen" is a statement about the REPOSITORY, and the
# ONLY thing that licenses it is a read of the repository that says so — a state of
# `OPEN`/`CLOSED` from `poll_merge_artifact`. A non-zero `gh pr merge` exit does NOT
# license it (that is a lost read, ambiguous about the mutation by definition), and
# neither does an unreadable artifact read: this comment is durable and cannot be
# un-posted, so a retraction posted over an UNKNOWN state annotates a possibly-MERGED
# PR forever. Callers must branch on `MERGE_ART_VERDICT` and call this function ONLY
# on `not_merged`. There is no third caller to write here — the undeterminable case
# posts NOTHING and says exactly that on stderr.
write_merge_retraction() {
  local pr="$1" head="$2" reason="$3" detail="$4" label="$5"
  {
    printf '<!-- admin-merge-retraction: %s -->\n' "$head"
    printf '⚠️ RETRACTED — the admin merge of head `%s` FAILED and did NOT happen.\n\n' "$head"
    printf 'The evidence comment above (`admin-merge-safety: %s`) records that the safety\n' "$head"
    printf 'comparison passed and the evidence was posted. It does NOT mean this PR merged:\n'
    printf '%s\n\n' "$reason"
    if [ -n "$detail" ] && [ -s "$detail" ]; then
      printf '%s\n\n' "$label"
      # Indented, never fenced: this body is machine-read too, and a fence is a
      # parser with state.
      sed 's/^/    /' "$detail"
      printf '\n'
    fi
    printf 'Re-run the rail once the cause is fixed; the evidence above is still head-bound to `%s`.\n' "$head"
  } > "$TMP/retraction.md"
  # shellcheck disable=SC2086
  if ! $GH pr comment "$pr" ${repo_args[@]+"${repo_args[@]}"} --body-file "$TMP/retraction.md" >/dev/null 2>&1; then
    say_err "   (could not post the retraction comment — the FAILED merge above still stands)"
  fi
}

count_lines() { wc -l < "$1" | tr -d ' '; }

# report_value <report-file> <key> → the numeric value, or empty.
report_value() {
  [ -n "$1" ] && [ -r "$1" ] || { printf ''; return 0; }
  awk -F= -v k="$2" '$1 == k { print $2 }' "$1"
}

# ── THE ATTRIBUTION HALF (#1353) — a CLIPPED set is not an EMPTY one ──────
# The parser DROPS a `FAILED` token that is not a test id: it never enters the
# failure set, so `PR failing: 0` can mean "no failures", "not comparable" (the
# lane-parity gate, #1319) OR "the failures were DROPPED". The parser NAMES every
# dropped token on its stderr; the rail CAPTURES that stream per call site (it
# used to be inherited and lost) so the count and the tokens can be reported and
# put in the POSTED EVIDENCE. The wording follows the parity gate rather than
# inventing a competing vocabulary: a set with drops is NOT COMPARABLE to a
# measured zero.
#
# FAIL CLOSED ON THE COUNT. The parser's own `unattributable=N` summaries are
# SUMMED and the DROPPED token lines are counted; `unattributable_count` reports
# the LARGER, so a renamed/missing summary line cannot make a clipped set read as
# complete, and a summary with no token text cannot make the drops vanish.
# THE SUMMARY MATCH IS ANCHORED TO ITS OWN LINE PREFIX (#1353). The greedy
# `.*unattributable=` also matched the TOKEN TEXT of a DROPPED line, so a dropped
# token that literally contained `unattributable=7` reported 8 for ONE drop. The
# summary line is `ci-exemption: ids=N unattributable=M`; matching from the line
# START means a DROPPED line — which begins `ci-exemption: UNATTRIBUTABLE: …` —
# cannot match it, while a format drift simply yields 0 from this side and the
# DROPPED-line count still reports the drops.
unattributable_count() {
  local f="${1:-}" reported named n
  [ -n "$f" ] && [ -s "$f" ] || { printf '0'; return 0; }
  reported="$(sed -n 's/^ci-exemption: ids=[0-9][0-9]*[[:space:]]*unattributable=\([0-9][0-9]*\).*/\1/p' "$f" | awk '{s += $1} END {print s + 0}')"
  counter_is_number "$reported" || reported=0
  named="$(grep -c 'DROPPED (never in the failure set):' "$f" 2>/dev/null || true)"; named="${named:-0}"
  counter_is_number "$named" || named=0
  if counter_exceeds_max "$reported" "$named"; then n="$reported"; else n="$named"; fi
  printf '%s' "$n"
}

# unattributable_tokens <parser-stderr-file> → the dropped tokens, one per line.
unattributable_tokens() {
  local f="${1:-}"
  [ -n "$f" ] && [ -s "$f" ] || return 0
  sed -n 's/.*DROPPED (never in the failure set): //p' "$f"
  return 0
}

# unattributable_count_of <file>... → the counts of several collections, summed.
unattributable_count_of() {
  local f c n=0
  for f in "$@"; do
    c="$(unattributable_count "$f")"
    counter_is_number "$c" || c=0
    n=$((n + c))
  done
  printf '%s' "$n"
}

# unattributable_tokens_of <file>... → the DISTINCT dropped tokens, one per line.
unattributable_tokens_of() {
  local f
  for f in "$@"; do unattributable_tokens "$f"; done | sort -u
  return 0
}

# fetch_run_failed_job_names <run-id> — one FAILED job NAME per line.
#
# The NAMING sibling of `run_failed_job_ids` in scripts/ci-failure-set.sh, and it
# carries the same jq projection on purpose: the Jobs API is the only place a run's
# check NAMES are readable when its log yields no failure identity, and one
# projection in two files is a convention, not a second implementation (the two
# consumers of that projection are different programs, and #3756's one-parser rule
# is about the FAILURE-IDENTITY parse, which stays in ci-failure-set.sh alone).
#
# The exit status is gh's: an unreadable job list is NOT an empty one, and the
# caller must say which of the two it has.
# shellcheck disable=SC2086
fetch_run_failed_job_names() {
  local run_id="$1" slug
  if [ -n "$REPO" ]; then
    slug="repos/$REPO/actions/runs/$run_id/jobs?per_page=100"
  else
    slug="repos/{owner}/{repo}/actions/runs/$run_id/jobs?per_page=100"
  fi
  $GH api "$slug" --paginate \
    --jq '.jobs[] | select(.conclusion != null and .conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped" and .conclusion != "cancelled" and .conclusion != "stale") | .name'
}
# ⛔ THE PREDICATE IS AN ALLOW-LIST, NOT A DENY-LIST (review, P3-9). `run_failed_job_ids`
# in ci-failure-set.sh names three conclusions and misses the rest, but the rail's own
# polarity (NON_RED_CONC in this file) is the opposite: a completed check with an
# UNRECOGNISED conclusion is RED. A deny-list here would silently drop such a job — and
# the arm would then print "no job reports a failure conclusion", which is a FALSE
# statement about a job that plainly failed. `null` is excluded because a job list is
# only read for a run already known to be failed, where an unfinished job is not the
# failure the log was fetched for; every NAMED non-red is excluded for the same reason.

# declared_base_equivalent <pr-check-name> — THE DECLARED LANE EQUIVALENCE (#2610):
# print the BASE-side check NAME this PR-side check is equivalent to, or nothing when
# there is none. The pair, its reason and its citations are in the header ("THE ONE
# DECLARED LANE EQUIVALENCE"); this is the ONE implementation and
# `named_unattributable_runs` is its ONLY reader.
#
# ⛔ STRUCTURAL, NOT A PREFIX, AND DELIBERATELY NARROW. Every arm is a specific,
# cited pair. A rule that read "a shell suite failed" as an equivalence would make
# every shell red base-caused — the blanket excuse the mapping's own requirements
# forbid. A name not named here returns NOTHING and keeps the unqualified
# "NO BASE COUNTERPART" answer.
#
# ⛔ THE MATCH REQUIRES exactly `<spaces>(<digits>)` — the matrix axis. It does not
# bound the digits: the matrix's `/N` denominator is DERIVED from
# `strategy.job-total` (ci.yml's shard comment), so a hard-coded 1..8 here would go
# stale the day the matrix widens. A shard number that does not exist cannot appear
# on any surface, so the un-bounded form cannot manufacture a counterpart.
#
# ⚠️ THE `bash-suites-gate` RESIDUAL, STATED RATHER THAN IMPLIED. Main has NO
# `bash-suites-gate` JOB (`grep -c bash-suites-gate ci-main.yml` = 0): on main the two
# programs that PR job runs — the lane-parity guard and its mutation self-test — are
# STEPS inside `script-validate` (ci-main.yml:478, :484). So a `bash-suites-gate` red
# ALSO has a base counterpart under that name, and this ONE pair does not map it: that
# refusal keeps today's unqualified absence answer, which is a KNOWN RESIDUAL (a
# scoping decision recorded on #2610), NOT a claim that the programs differ. Mapping
# it would be a second pair with its own fixture, and the brief for this change is
# explicitly one pair.
#
# No exit status is used to mean "no equivalence": an empty stdout is the answer, so a
# caller can never mistake "not mapped" for a failure of the mapping.
declared_base_equivalent() {
  local name="${1:-}" shard
  case "$name" in
    'bash-suites ('*')')
      shard="${name#bash-suites (}"
      shard="${shard%)}"
      case "$shard" in
        ''|*[!0-9]*) return 0 ;;
      esac
      printf '%s\n' 'script-validate'
      ;;
  esac
  return 0
}

# named_unattributable_runs <unattributed-file> <base-ref> <expected-count> — THE NAMED
# REFUSAL (#2610). `<unattributed-file>` is the collector's `--unattributed` output, NOT
# `--provenance`: see the ⛔ note above the body.
#
# WHY THIS EXISTS. The step-1c refusal (a failing run whose log yielded no failure
# identity) used to report a COUNT — "2 of 2 failing PR run(s) yielded NO parseable
# failure identity" — and name NOTHING: not the run, not the check that failed in it,
# and not what the base carries under that name. Measured on agent-infra 2026-10-24:
# three rails (#2430, #2608, #2623) refused with exactly that line for a head whose
# surface was red on `bash-suites (1)/(2)/(3)/(5)/(7)`, and the subject of the refusal
# had to be reconstructed by hand from `gh api`. A refusal that cannot name what it
# refused reads as "unattributable" — the one conclusion this rail must never deliver
# without evidence — and it is why the fleet re-runs the rail instead of fixing the
# cause.
#
# WHAT IT ASKS, AND WHAT IT DOES NOT CLAIM. For each failed check it answers ONE
# question: does the BASE's own measured surface carry a RED check of the same NAME, and
# was that red BLOCKING or EXEMPTED there? Both kinds are reported, from
# `MAIN_HEALTH_ALL_REDS` — `MAIN_HEALTH_RED_TS` holds only the blocking ones, so a
# reader built on it would answer "no such red" about the one red agent-infra's main
# actually carries (`script-validate` on a `push` run of ci-main.yml: measured, and
# correctly exempted as not-PR-evaluable).
# It does NOT claim a name match makes a red exempt: the EXEMPTION DECISION compares
# failures by IDENTITY, so a same-named red is reported as context and an absent one is
# reported as an absent NAME — never as "this red is the PR's". (The rail's only
# NAME-keyed comparison is the lane-coverage gate, and it selects the `test*` job family,
# which neither surface's suite name is in.) The two questions are stated apart on
# purpose: conflating them is how "no base counterpart" would become a silent exemption.
#
# A refusal whose only fact is a count is unfalsifiable from the operator's side; a
# refusal that names its runs, its checks and its base answer can be checked, fixed,
# or escalated. Costs one base-surface probe, on a path that terminates the run.
#
# ⛔ THE INPUT IS THE COLLECTOR'S `--unattributed` FILE, NOT `--provenance` (#2610 review,
# P1-2). `--provenance` holds EVERY examined failing run, including the ones that DID
# yield ids — so naming from it would label a contributing run as unattributable. The
# subset is written by `collect_union_rows`, the one place that decides `extracted`.
named_unattributable_runs() {
  local unattributed="${1:-}" base="${2:-}" expected="${3:-}" line runref run_id names name kind
  local mapped mapped_kind base_reds base_status base_total red_names named_count
  local kind_rc mapped_rc
  # ⛔ NO EARLY `-s` RETURN HERE (#2610 review, cycle 6). It used to sit above, and it
  # answered the ONE anomaly the completeness cross-check below exists to catch with total
  # silence: this function is only reachable from `pr_extracted < pr_examined`, so
  # `expected >= 1` on every call — an absent or empty subset file therefore means the named
  # list is MISSING ENTIRELY, and returning early printed nothing instead of
  # "the collector published 0 … where the refusal counted N — this list is INCOMPLETE".
  # An empty `grep -c` on a missing file is `0`, so the cross-check fires first and the
  # `named_count -eq 0` return BELOW is the silent path (nothing to name, count agrees).
  # ⛔ `grep -c` PRINTS `0` AND EXITS 1 on no match, so a `|| printf '0'` fallback makes the
  # count the two-line string `0\n0` — and a `0\n0` header is not a count (#2610 review). The
  # fallback is only for grep being unavailable; the default covers the no-match case. The
  # predicate matches the loop's guard exactly, so the header cannot disagree with the body:
  # the loop skips a line with no NON-SPACE character, and so does this count.
  # ⛔ A COUNT THAT COULD NOT BE MADE IS NOT ZERO (#2610 review, round 5). `|| true` collapsed
  # grep's exit 2/127 (unreadable / grep broken) into the same empty capture as a legitimate
  # no-match, so the header could assert `NAMED (0)` while the loop below — whose guard is shell
  # pattern matching, not grep — still printed runs underneath it. That is the one unmeasurable
  # arm in this function that answered AFFIRMATIVELY; it now says the count is UNKNOWN.
  # `$?` is captured BEFORE the case: inside a branch it is the case's own status, not grep's,
  # and a diagnostic that names the wrong exit code is a claim about the instrument that is false.
  named_count="$(grep -c '[^[:space:]]' "$unattributed")"
  local count_rc=$?
  case "$count_rc" in
    0) ;;
    1) named_count=0 ;;
    *) named_count="?"
       say_err "   ⚠️  the unattributable list could not be COUNTED (grep exit ${count_rc}) — the"
       say_err "   count is UNKNOWN, not zero; the runs named below are still real" ;;
  esac
  # The base's own surface, through the ONE probe (#1261) — never a second reader. A base
  # ref that could NOT be resolved is not a ref to probe: passing '' would have made the
  # reader assert "'X' IS red on ''" about a branch nobody resolved, so the ref is checked
  # and the UNANSWERED arm (below) is what speaks.
  base_status=""
  base_total=""
  base_reds=""
  if [ -n "$base" ]; then
    check_surface_probe "$base" "the base branch '$base'" 1
    base_status="${MAIN_HEALTH_STATUS:-}"
    base_total="${MAIN_HEALTH_TOTAL:-}"
    # `<name>\t<classification>` for every red the base's surface carried.
    base_reds="$(printf '%s\n' "${MAIN_HEALTH_ALL_REDS:-}" | sed '/^$/d' | sort -u)"
  fi
  # THE COUNT IS CROSS-CHECKED, never assumed (#2610 review, P3-5): the refusal above prints
  # `N of M`, and this list is the SUBJECT of that count. A subset that is short of it would
  # otherwise read as a complete account of the unattributable runs.
  if [ -n "$expected" ] && [ "$named_count" != "?" ] && [ "$named_count" != "$expected" ]; then
    say_err "   ⚠️  the collector published $named_count unattributable run(s) where the refusal"
    say_err "   counted ${expected} — this list is INCOMPLETE, so read it as a sample, not as the set"
  fi
  # Nothing to name. Only silent when the count AGREES with the refusal (the cross-check
  # above has already spoken for the disagreement case, which is the one that matters).
  # ⛔ A STRING test, not `-eq`: the count is `?` when grep could not be made to count
  # (#2610 review, round 5), and `[ "?" -eq 0 ]` is an integer-expression error — which would
  # both print a spurious diagnostic and take the wrong branch on the one arm that is already
  # unmeasurable. `named_count` is a digit run or `?`, so `= "0"` is the same test safely.
  if [ "$named_count" = "0" ]; then return 0; fi
  if [ "$named_count" = "?" ]; then
    say_err "   The failing run(s), NAMED — each check below is one whose failed-step"
  else
    say_err "   The failing run(s), NAMED (${named_count}) — each check below is one whose failed-step"
  fi
  # ⛔ TWO REASONS, ONE LIST (agent-infra#3174). Since #3174 a run whose shard runner was KILLED
  # mid-list is named here too: its ids exist but were REFUSED (the set is a truncated sample), so
  # the list is no longer exclusively "yielded no identity". Naming only the old reason would send
  # the operator to hunt a parser bug for a window whose remedy is a wider read.
  say_err "   log yielded no failure identity, OR its shard recap was INCOMPLETE (the shard step was"
  say_err "   killed mid-list, #3174 — those ids exist and were refused as a truncated SAMPLE) — so it"
  say_err "   entered NEITHER side of the comparison:"
  while IFS= read -r line; do
    [ -n "${line//[[:space:]]/}" ] || continue
    runref="${line##*$'\t'}"
    run_id="${runref##*:}"
    if ! names="$(fetch_run_failed_job_names "$run_id" 2>/dev/null)"; then
      say_err "   • run $run_id — its JOB LIST could not be read (a read failure, which is not"
      say_err "       an absence of checks; re-run the rail, and if it persists the API is the cause)"
      continue
    fi
    if [ -z "$names" ]; then
      say_err "   • run $run_id — the API reports NO failed job: either the run was never"
      say_err "       expanded into jobs (#1623), or it failed before/without a job (a startup or"
      say_err "       annotation failure). Two different causes, both unattributable here."
      continue
    fi
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      say_err "   • run $run_id — check '${name}' — no parseable failure identity in its log"
      case "$base_status" in
        "") 
          say_err "       base: the base ref could NOT be resolved, so the counterpart question is"
          say_err "       UNANSWERED, not answered 'no'"
          ;;
        green|red)
          # `kind` is the classification the probe already made, so an EXEMPTED base red
          # is reported as the red it is — with the reason it did not block there.
          # ⛔ THE NAME GOES OUT OF BAND (#2610 review, P3-3): `awk -v n="$name"` processes
          # backslash escapes in the assignment, so a check named `win\build` would be
          # compared as `winbuild` and answered "no counterpart" when the base carries it.
          # ⛔ A HERE-STRING, NOT `printf | awk` (#2610 review, cycle 7, P2). Under this
          # file's `set -uo pipefail` (line 660), `awk` exits at its FIRST match, the `printf`
          # upstream takes SIGPIPE, and `pipefail` makes the whole substitution return **141**
          # — so a lookup that SUCCEEDED was reported as a READ FAILURE and its correct answer
          # thrown away (measured: `run1 rc=141 kind=[blocking: failure]` over 20k red lines).
          # That is the banned `printf | quiet-consumer` idiom (#841/#864); a here-string has
          # no upstream process to signal, so the status is awk's alone.
          kind_rc=0
          kind="$(NR_NAME="$name" awk -F'\t' '$1 == ENVIRON["NR_NAME"] { print $2; exit }' <<< "$base_reds")" || kind_rc=$?
          # ⛔ THE NON-EMPTY ANSWER WINS OVER THE STATUS (#2610 review, cycle 7). A read that
          # produced output DID read, whatever awk's exit status says afterwards; the failure
          # arm is only for the case where the lookup came back EMPTY *and* said so.
          if [ -n "$kind" ]; then
            say_err "       base: '${name}' IS red on '${base}' (${kind}) — the same check NAME fails on"
            say_err "       both surfaces; the decision still compares IDENTITIES, and this run has none"
          elif [ "$kind_rc" -ne 0 ]; then
            # ⛔ A FAILED LOOKUP IS NOT "no counterpart" (#2610 review, cycle 6). An empty
            # `kind` from a DEAD lookup renders as the exact false absence this whole change
            # exists to abolish. Note what is — and is not — claimed here: `$base_reds` is a
            # SHELL VARIABLE, so this is NOT a failed read of the base (that is `base_status`
            # = unreadable, the `*)` arm); it is the comparison over it that did not run.
            say_err "       base: the lookup over the base's red list FAILED (awk exit ${kind_rc}) — a"
            say_err "       failure, not an absence: the counterpart question is UNANSWERED here"
          else
            # ── THE DECLARED LANE EQUIVALENCE (#2610) ──────────────────────────
            # The base's counterpart red can sit under a DIFFERENT NAME for the SAME
            # suite: `script-validate` on main is `bash-suites (<n>)` on a PR. Without
            # this arm the answer below is a FALSE ABSENCE — "not among the checks the
            # base reports" — about the base's OWN red, and a false absence is the one
            # thing this refusal must never print.
            # ⛔ THE MAPPED NAME GOES OUT OF BAND TOO (same reason as P3-3 above): it is
            # a constant today, but a future pair must not inherit an `awk -v` hole.
            mapped="$(declared_base_equivalent "$name")"
            mapped_kind=""
            mapped_rc=0
            if [ -n "$mapped" ]; then
              # Same here-string reason as the same-name lookup above (cycle 7, P2).
              mapped_kind="$(NR_NAME="$mapped" awk -F'\t' '$1 == ENVIRON["NR_NAME"] { print $2; exit }' <<< "$base_reds")" || mapped_rc=$?
            fi
            if [ -n "$mapped_kind" ]; then
              say_err "       base: base-caused via ${mapped} ≡ ${name} (${mapped_kind})"
              say_err "       DECLARED LANE EQUIVALENCE, not an identity and not an exemption: the two"
              say_err "       lanes run ONE list under TWO names — main's '${mapped}' calls"
              say_err "       scripts/run-bash-shards.sh UNSHARDED as ONE of its steps"
              say_err "       (.github/workflows/ci-main.yml:528), and '${name}' is one shard of that same"
              say_err "       list on a PR (.github/workflows/ci.yml:1160/1288), one runtime in both lanes"
              say_err "       (ci.yml:1262). The base therefore carries a red under a name that RUNS this"
              say_err "       list — but that job has FIVE other steps (node --check :466, the lane-parity"
              say_err "       guard :478, its self-test :484, plus checkout :451 and setup-node :456), so the"
              say_err "       base's red may be this suite's or any of theirs. A CANDIDATE counterpart, not"
              say_err "       an established identity: no identity was produced, so nothing here is"
              say_err "       comparable yet"
            elif [ "$mapped_rc" -ne 0 ]; then
              # Same non-empty-wins ordering as the same-name lookup above (cycle 7): a failed
              # lookup must not be narrated as "no counterpart" — that is the false absence.
              say_err "       base: the lookup over the base's red list FAILED while testing the declared"
              say_err "       equivalence (awk exit ${mapped_rc}) — UNANSWERED, not 'no counterpart'"
            else
              say_err "       base: NO BASE COUNTERPART FOR THIS CHECK — '${name}' is not among the"
              say_err "       ${base_total:-?} check(s) the base surface reports, of which these NAME(s) are"
              # ⛔ `paste` emits NO line for zero input lines, so a `sed 's/^$/none/'` AFTER it is
              # dead code — the empty base (a GREEN base, the common case) printed `red: ` and
              # nothing (#2610 review, P2-1). Default the CAPTURE, and print the whole answer on
              # one line so neither half can be missing while the other is present.
              red_names="$(printf '%s\n' "$base_reds" | cut -f1 | sed '/^$/d' | paste -sd, -)"
              say_err "       red: ${red_names:-none}"
            fi
          fi
          ;;
        *)
          say_err "       base: the base surface ('${base}') reads '${base_status:-unmeasured}' — the"
          say_err "       counterpart question is UNANSWERED, not answered 'no'"
          ;;
      esac
    done <<< "$names"
  done < "$unattributed"
  say_err "   The EXEMPTION DECISION compares failures by FAILURE IDENTITY, not by check name: an"
  say_err "   identity is what makes a red comparable to the base, and (with a matching signature)"
  say_err "   exempt. NONE of the runs above yielded one, so nothing about them is comparable yet —"
  say_err "   a name answer alone cannot exempt a red, and an absent name is not a verdict."
  say_err "   A DECLARED LANE EQUIVALENCE is the same kind of answer: it names the base red this"
  say_err "   check corresponds to under the other lane's name, and exempts NOTHING."
  say_err "   Remedy: make the failing step print a parseable identity — a"
  say_err "   '::error::<message>' annotation or a 'FAILED <nodeid>' line — then re-run the rail."
  return 0
}

# report_unattributable <parser-stderr-file> <label> — NAME the drops on stderr.
# Returns 0 when nothing was dropped, 1 when anything was.
report_unattributable() {
  local f="${1:-}" label="${2:-a failing set}" n tokens
  n="$(unattributable_count "$f")"
  tokens="$(unattributable_tokens "$f")"
  if counter_is_zero "$n" && [ -z "$tokens" ]; then return 0; fi
  say_err "admin-merge: ⚠️  $label — $n FAILED token(s) were DROPPED by the parser: they are not"
  say_err "   test ids, so they are NOT in the failing set. The set is CLIPPED, not empty, and a"
  say_err "   CLIPPED set is NOT COMPARABLE to a measured zero (the lane-parity gate's"
  say_err "   vocabulary, #1319). The tokens are named here and carried in the posted evidence."
  if [ -n "$tokens" ]; then
    printf '%s\n' "$tokens" | sed 's/^/      DROPPED: /' >&2
  else
    say_err "      (the parser reported $n drop(s) but named no token text in its diagnostics)"
  fi
  return 1
}

# Counter predicates — and why they are written this way.
#
# A counter that is NOT A NUMBER answers nothing: `[ "$x" -eq 0 ]` (and `-gt 0`)
# returns 2 on such a value, and under `set -uo pipefail` (no `-e`) the `if` body
# is SKIPPED — so a guard written as `[ "$x" -eq 0 ]` fails OPEN on a malformed
# report. Both predicates therefore return FALSE for an unreadable counter, and
# every caller must BLOCK unless its condition is AFFIRMATIVELY true (`!`) — never
# "unless it evaluated false".
#
# check-lane-tested.sh refuses the same values for the detector (a fail-open in
# the guard itself, cycle-5 review P2); the two consumers must agree on the
# report contract.
counter_is_zero() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -eq 0 ]
}
counter_is_positive() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -gt 0 ]
}
# TRUE only for a counter that is a readable non-negative integer. A caller that must
# COMPARE two counters uses this instead of a bare `-lt`, which returns 2 on garbage —
# and under `set -uo pipefail` (no `-e`) that SKIPS the guard rather than failing it.
counter_is_number() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}
# TRUE only for an all-digit value STRICTLY GREATER than <max>, for a value of ANY
# length. `counter_is_number` alone is not enough: it accepts a run of digits too
# long for the shell's 64-bit integers, and such a value breaks the guard two ways.
# A value PAST int64max makes the `-lt`/`-ge` comparisons that consume it ERROR
# (test returns 2, so the `if` body is SKIPPED) — a silent fail-OPEN in the very
# guard that exists to fail closed. A value at int64max in a `$((… + step))`
# WRAPS negative, so a comparison consuming it PASSES for a bound that is really
# absurd. The comparison is therefore done by DIGIT COUNT first, so a 30-digit
# string never reaches a `-gt` or a `$((…))` that would error or wrap; equal
# lengths compare lexicographically, which for all-digit strings is numeric.
counter_exceeds_max() {
  local v="${1:-}" max="${2:-}"
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  case "$max" in ''|*[!0-9]*) return 1 ;; esac
  v="${v#"${v%%[!0]*}"}"; [ -n "$v" ] || v=0
  [ "${#v}" -gt "${#max}" ] && return 0
  [ "${#v}" -lt "${#max}" ] && return 1
  [ "$v" \> "$max" ]
}
# TRUE for an all-digit value carrying a LEADING ZERO (`0100`, `08`, `0008`) — the
# one numeric spelling the shell does NOT read uniformly. bash ARITHMETIC reads it
# as OCTAL, while the `test` builtin, `sleep`, and the counter predicates above all
# read it as DECIMAL. `POLL_INTERVAL=010` is the live case: `10#$step` advances the
# wait's clock by 10 while `sleep "$POLL_INTERVAL"` sleeps 10 — the same number only
# because a `10#` guards that site; drop it and the interval is accounted as 8.
# `08`/`0999` are not valid octal at all and error such a site outright. Refusing
# the spelling on every timing knob gives one spelling one meaning; `10#` at the
# arithmetic sites is defence in depth.
counter_has_leading_zero() {
  case "${1:-}" in 0[0-9]*) return 0 ;; esac
  return 1
}

# TIMING_KNOB_MAX — the largest value any timing knob may take. NOT a policy bound:
# an ARITHMETIC one. Nine digits is ~31 years, far beyond any usable bound and
# comfortably inside the range these comparisons can hold, so a value above it is
# nonsense AND unsafe (see counter_exceeds_max).
TIMING_KNOB_MAX=999999999
# POLL_INTERVAL_MAX — a tighter, POLICY bound. The poll interval PACES the bound
# detection, so an hour between polls is already useless; more to the point, an
# all-digit giant that `sleep` cannot take (BSD `sleep` rejects it with a usage
# error) made EVERY poll's sleep fail, turning a 600s window into a tight gh BUSY
# SPIN — measured at 201 `gh run view` calls in 11s. 0 stays LEGAL: it is the
# deterministic TEST SEAM (no real sleeping), not an interval.
POLL_INTERVAL_MAX=3600
# MAIN_RUNS_MAX — the largest `--main-runs` window. A POLICY bound like
# POLL_INTERVAL_MAX, and for a cost reason, not a correctness one: the #3469
# union is already saturated long before this, while the lane-coverage gate
# fetches ONE Jobs API listing per run on EACH side — so this is also that gate's
# CALL budget, since a burst of terminal-but-unmeasured runs can push its search
# for a reference past `--main-runs` (#4844). 200 runs is far beyond any baseline
# that would change a verdict.
MAIN_RUNS_MAX=200

# validate_timing_knobs — REFUSE a timing knob that is not a positive integer.
# A comparison against a non-numeric value returns 2, and under `set -uo pipefail`
# (no `-e`) the `if` body is SKIPPED: a bad value silently stops the guard from
# gating. The floor, the fail-safe and the poll interval all feed `-ge`/`-lt`, so a
# `10m` value can make a guard's comparison error out — which SKIPS it instead of
# failing it — and a `10m` poll interval also makes every `sleep` fail, turning the
# wait into a tight gh BUSY SPIN.
#
# There is no longer an ORDERING to enforce between a stall window and a bound:
# they are the SAME derived bound (see wait_for_run). STALLED is that derived bound
# being exceeded; CEILING is an explicit `--rerun-timeout` being exceeded — a
# provenance distinction, not a race between two windows.
#
# POLL_INTERVAL is validated too, and in two stages: a NON-NUMERIC value makes
# `[ "$step" -gt 0 ]` error (step falls back to 1) while `sleep "$POLL_INTERVAL"`
# then fails EVERY iteration; and a numeric value `sleep` cannot take does the
# same thing — "all digits" is not the same as "usable". 0 stays LEGAL: it is the
# deterministic TEST SEAM (no real sleeping), never refused.
#
# LEADING ZEROS are refused on EVERY timing knob, before any arithmetic. bash reads
# `0100` as OCTAL 64 in `$((…))` but as DECIMAL 100 in `test`/`sleep`, so one
# spelling could mean two numbers across the clock the wait advances and the clock
# it sleeps. `08`/`0999` are not even valid octal and error such a site. One
# spelling, one meaning: refuse the zeros.
#
# Named, at startup, before any CI work.
validate_timing_knobs() {
  local bad=0
  if counter_has_leading_zero "$RERUN_FLOOR"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_RERUN_FLOOR='${RERUN_FLOOR}' — a LEADING ZERO is ambiguous:"
    say_err "   bash ARITHMETIC reads it as OCTAL while the 'test' comparisons that gate the wait read it"
    say_err "   as DECIMAL, so the floor and the wait would disagree about the same value."
    say_err "   Write it without the leading zero (e.g. '1200', not '01200')."
  elif ! counter_is_positive "$RERUN_FLOOR"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_RERUN_FLOOR='${RERUN_FLOOR}' — the per-shard bound"
    say_err "   floor must be a POSITIVE integer number of seconds."
  elif counter_exceeds_max "$RERUN_FLOOR" "$TIMING_KNOB_MAX"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_RERUN_FLOOR='${RERUN_FLOOR}' — beyond the usable range"
    say_err "   (max ${TIMING_KNOB_MAX}s). An all-digit value past the shell's integer range makes the"
    say_err "   bound comparison error out, which SKIPS it instead of failing it."
  fi
  if counter_has_leading_zero "$FAILSAFE_RERUN_TIMEOUT"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_RERUN_TIMEOUT_FALLBACK='${FAILSAFE_RERUN_TIMEOUT}' — a LEADING"
    say_err "   ZERO is ambiguous: bash ARITHMETIC reads it as OCTAL while the comparisons that gate the"
    say_err "   wait read it as DECIMAL. Write it without the leading zero (e.g. '3900', not '03900')."
  elif ! counter_is_positive "$FAILSAFE_RERUN_TIMEOUT"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_RERUN_TIMEOUT_FALLBACK='${FAILSAFE_RERUN_TIMEOUT}' — the"
    say_err "   derivation fail-safe must be a POSITIVE integer number of seconds."
  elif counter_exceeds_max "$FAILSAFE_RERUN_TIMEOUT" "$TIMING_KNOB_MAX"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_RERUN_TIMEOUT_FALLBACK='${FAILSAFE_RERUN_TIMEOUT}' — beyond"
    say_err "   the usable range (max ${TIMING_KNOB_MAX}s)."
  fi
  if counter_has_leading_zero "$POLL_INTERVAL"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_POLL_INTERVAL='${POLL_INTERVAL}' — a LEADING ZERO is"
    say_err "   ambiguous and changes the PACING: bash ARITHMETIC accounts '010' as octal 8 while"
    say_err "   'sleep' sleeps 10s, so the clock the wait advances and the clock it sleeps disagree."
    say_err "   Write it without the leading zero (e.g. '10', not '010')."
  elif ! counter_is_number "$POLL_INTERVAL"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_POLL_INTERVAL='${POLL_INTERVAL}' — the poll interval must be"
    say_err "   a NON-NEGATIVE integer number of seconds (0 is legal: the test seam). A non-numeric"
    say_err "   value makes the step guard error and every 'sleep' fail, turning the wait into a tight"
    say_err "   BUSY SPIN of gh calls instead of a paced poll."
  elif counter_exceeds_max "$POLL_INTERVAL" "$POLL_INTERVAL_MAX"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_POLL_INTERVAL='${POLL_INTERVAL}' — beyond the usable range"
    say_err "   (max ${POLL_INTERVAL_MAX}s). 'all digits' is not enough: a value 'sleep' cannot take fails"
    say_err "   on EVERY poll, so the wait becomes a tight BUSY SPIN of gh calls instead of a paced"
    say_err "   poll — and an interval beyond an hour paces nothing."
  fi
  # #1417's wait bound. Same two-stage discipline as POLL_INTERVAL: a non-numeric
  # value makes the bound comparison ERROR (test returns 2, the body is SKIPPED),
  # and a skipped check inside a wait loop is exactly the fail-open this rail
  # refuses elsewhere. 0 stays LEGAL and means "do not wait" — the test seam, and
  # the pre-#1417 behaviour.
  if counter_has_leading_zero "$SELF_EDIT_WAIT"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_SELF_EDIT_WAIT='${SELF_EDIT_WAIT}' — a LEADING ZERO is"
    say_err "   ambiguous: bash ARITHMETIC reads it as OCTAL while the bound comparison reads it as"
    say_err "   DECIMAL. Write it without the leading zero (e.g. '300', not '0300')."
  elif ! counter_is_number "$SELF_EDIT_WAIT"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_SELF_EDIT_WAIT='${SELF_EDIT_WAIT}' — the wait bound must be"
    say_err "   a NON-NEGATIVE integer number of seconds (0 is legal: it disables the wait)."
  elif counter_exceeds_max "$SELF_EDIT_WAIT" "$POLL_INTERVAL_MAX"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_SELF_EDIT_WAIT='${SELF_EDIT_WAIT}' — beyond the usable range"
    say_err "   (max ${POLL_INTERVAL_MAX}s). The other timing knobs are bounded only by the ARITHMETIC"
    say_err "   maximum ${TIMING_KNOB_MAX}s; this one is a POLICY bound, because a typo such as 300000"
    say_err "   would otherwise hold the merge rail for days."
  fi
  # The FIRST-CHECKS window (the fresh-PR race / #2090). 0 is legal and means
  # "one observation, no waiting". Same two-stage discipline as every knob.
  if counter_has_leading_zero "$FIRST_CHECKS_WAIT"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_FIRST_CHECKS_WAIT='${FIRST_CHECKS_WAIT}' — a LEADING "
    say_err "   ZERO is ambiguous: bash ARITHMETIC reads it as OCTAL while the bound comparison reads it"
    say_err "   as DECIMAL. Write it without the leading zero (e.g. '3900', not '03900')."
  elif ! counter_is_number "$FIRST_CHECKS_WAIT"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_FIRST_CHECKS_WAIT='${FIRST_CHECKS_WAIT}' — the window must be"
    say_err "   a NON-NEGATIVE integer number of seconds (0 is legal: it disables the wait)."
  elif counter_exceeds_max "$FIRST_CHECKS_WAIT" "$TIMING_KNOB_MAX"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_FIRST_CHECKS_WAIT='${FIRST_CHECKS_WAIT}' — beyond the usable"
    say_err "   range (max ${TIMING_KNOB_MAX}s)."
  fi
  # #2481's progress-aware bounds. A non-numeric value would make the `-ge` that
  # TRIGGERS a stall (or the ceiling) error out, and under `set -uo pipefail` the
  # body is then SKIPPED — i.e. the bound silently stops bounding, which for the
  # STALL is a wait that can hold a lane forever. So: positive, decimal, in range.
  if counter_has_leading_zero "$FIRST_CHECKS_STALL"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_FIRST_CHECKS_STALL='${FIRST_CHECKS_STALL}' — a LEADING"
    say_err "   ZERO is ambiguous: bash ARITHMETIC reads it as OCTAL while the comparison that"
    say_err "   triggers the STALL verdict reads it as DECIMAL. Write it without the leading zero."
  elif ! counter_is_positive "$FIRST_CHECKS_STALL"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_FIRST_CHECKS_STALL='${FIRST_CHECKS_STALL}' — the stall"
    say_err "   period must be a POSITIVE integer number of seconds."
  elif counter_exceeds_max "$FIRST_CHECKS_STALL" "$TIMING_KNOB_MAX"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_FIRST_CHECKS_STALL='${FIRST_CHECKS_STALL}' — beyond the"
    say_err "   usable range (max ${TIMING_KNOB_MAX}s)."
  fi
  if counter_has_leading_zero "$FIRST_CHECKS_CEILING"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_FIRST_CHECKS_CEILING='${FIRST_CHECKS_CEILING}' — a LEADING"
    say_err "   ZERO is ambiguous: bash ARITHMETIC reads it as OCTAL while the comparison that"
    say_err "   triggers the CEILING verdict reads it as DECIMAL. Write it without the leading zero."
  elif ! counter_is_positive "$FIRST_CHECKS_CEILING"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_FIRST_CHECKS_CEILING='${FIRST_CHECKS_CEILING}' — the"
    say_err "   absolute ceiling must be a POSITIVE integer number of seconds."
  elif counter_exceeds_max "$FIRST_CHECKS_CEILING" "$TIMING_KNOB_MAX"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_FIRST_CHECKS_CEILING='${FIRST_CHECKS_CEILING}' — beyond the"
    say_err "   usable range (max ${TIMING_KNOB_MAX}s)."
  fi
  # A ceiling BELOW the stall period is legal (the rail's own suite uses it to
  # exercise the timeout arm in seconds), but it means the wait can never claim a
  # stall — say so once, at startup, so nobody reads that combination as "stall
  # detection is broken". Not a refusal: the ceiling is the operator's bound.
  if counter_is_positive "$FIRST_CHECKS_CEILING" && counter_is_positive "$FIRST_CHECKS_STALL" \
     && [ "$((10#$FIRST_CHECKS_CEILING))" -lt "$((10#$FIRST_CHECKS_STALL))" ]; then
    say_err "admin-merge: note — ADMIN_MERGE_FIRST_CHECKS_CEILING (${FIRST_CHECKS_CEILING}s) is below"
    say_err "   ADMIN_MERGE_FIRST_CHECKS_STALL (${FIRST_CHECKS_STALL}s), so the CEILING decides every wait and no"
    say_err "   STALL verdict can be reached. Legal, and what the rail's own suite uses."
  fi
  # CHECK_UNRESOLVED_BOUND — the same three checks as every other timing knob. A
  # value the shell cannot compare must REFUSE at startup: `-ge` on '1h' makes `[`
  # return 2, the arm is SKIPPED, and a typo silently restores the very hang this
  # bound exists to end.
  if counter_has_leading_zero "$CHECK_UNRESOLVED_BOUND"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_CHECK_UNRESOLVED_BOUND='${CHECK_UNRESOLVED_BOUND}' — a"
    say_err "   LEADING ZERO is ambiguous: bash ARITHMETIC reads it as OCTAL while the comparison that"
    say_err "   triggers the refusal reads it as DECIMAL. Write it without the leading zero."
  elif ! counter_is_positive "$CHECK_UNRESOLVED_BOUND"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_CHECK_UNRESOLVED_BOUND='${CHECK_UNRESOLVED_BOUND}' — the"
    say_err "   unresolved-check bound must be a POSITIVE integer number of seconds."
  elif counter_exceeds_max "$CHECK_UNRESOLVED_BOUND" "$TIMING_KNOB_MAX"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_CHECK_UNRESOLVED_BOUND='${CHECK_UNRESOLVED_BOUND}' — beyond"
    say_err "   the usable range (max ${TIMING_KNOB_MAX}s)."
  fi
  if counter_has_leading_zero "$FIRST_CHECKS_POLL"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_FIRST_CHECKS_POLL='${FIRST_CHECKS_POLL}' — a LEADING ZERO is"
    say_err "   ambiguous: bash ARITHMETIC reads it as OCTAL while 'sleep' sleeps it as DECIMAL."
  elif ! counter_is_positive "$FIRST_CHECKS_POLL"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_FIRST_CHECKS_POLL='${FIRST_CHECKS_POLL}' — the poll interval"
    say_err "   must be a POSITIVE integer number of seconds (the FIRST-CHECKS wait's 0 seam is"
    say_err "   ADMIN_MERGE_FIRST_CHECKS_WAIT, not this knob)."
  elif counter_exceeds_max "$FIRST_CHECKS_POLL" "$POLL_INTERVAL_MAX"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_FIRST_CHECKS_POLL='${FIRST_CHECKS_POLL}' — beyond the usable"
    say_err "   range (max ${POLL_INTERVAL_MAX}s)."
  fi
  # The MERGE-REF window. 0 is legal and means "one observation, no waiting".
  if counter_has_leading_zero "$MERGE_REF_WAIT"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_MERGE_REF_WAIT='${MERGE_REF_WAIT}' — a LEADING ZERO is"
    say_err "   ambiguous: bash ARITHMETIC reads it as OCTAL while the bound comparison reads it as"
    say_err "   DECIMAL. Write it without the leading zero (e.g. '90', not '090')."
  elif ! counter_is_number "$MERGE_REF_WAIT"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_MERGE_REF_WAIT='${MERGE_REF_WAIT}' — the window must be a"
    say_err "   NON-NEGATIVE integer number of seconds (0 is legal: one observation, no waiting)."
  elif counter_exceeds_max "$MERGE_REF_WAIT" "$TIMING_KNOB_MAX"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_MERGE_REF_WAIT='${MERGE_REF_WAIT}' — beyond the usable range"
    say_err "   (max ${TIMING_KNOB_MAX}s)."
  fi
  if counter_has_leading_zero "$HEAD_ATTEMPTS"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_HEAD_ATTEMPTS='${HEAD_ATTEMPTS}' — a LEADING ZERO is"
    say_err "   ambiguous: bash ARITHMETIC reads it as OCTAL, so '08' is not 8 but an ERROR that"
    say_err "   aborts the loop body. The rail would then refuse the PR while reporting that it"
    say_err "   could not READ the head — a claim about the instrument on a run where the instrument"
    say_err "   never ran. Write it without the leading zero (e.g. '3')."
  elif ! counter_is_positive "$HEAD_ATTEMPTS"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_HEAD_ATTEMPTS='${HEAD_ATTEMPTS}' — the head-read retry"
    say_err "   budget must be a POSITIVE integer. A non-numeric value errors the loop's arithmetic,"
    say_err "   and a non-positive one attempts no read at all before refusing."
  elif counter_exceeds_max "$HEAD_ATTEMPTS" "$TIMING_KNOB_MAX"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_HEAD_ATTEMPTS='${HEAD_ATTEMPTS}' — beyond the usable range"
    say_err "   (max ${TIMING_KNOB_MAX})."
  fi
  if counter_has_leading_zero "$HEAD_READ_SLEEP"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_HEAD_READ_SLEEP='${HEAD_READ_SLEEP}' — a LEADING ZERO is"
    say_err "   ambiguous: arithmetic reads it as OCTAL while 'sleep' sleeps the decimal value."
  elif ! counter_is_number "$HEAD_READ_SLEEP"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_HEAD_READ_SLEEP='${HEAD_READ_SLEEP}' — the backoff base"
    say_err "   must be a NON-NEGATIVE integer number of seconds (0 is legal: the test seam)."
  elif counter_exceeds_max "$HEAD_READ_SLEEP" "$TIMING_KNOB_MAX"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_HEAD_READ_SLEEP='${HEAD_READ_SLEEP}' — beyond the usable"
    say_err "   range (max ${TIMING_KNOB_MAX}s)."
  fi
  # The merge-artifact read's bound is the SAME class as the head read's (#1298), and
  # it was the last knob still carrying a bare `case … attempts=6` default: an
  # all-digit value with a LEADING ZERO passes that guard and is invalid octal to bash
  # ARITHMETIC, so the loop body never ran and the rail printed
  # `[merge_unreadable] — could NOT be READ (08 attempt(s))` — a claim about the
  # instrument on a run where the instrument never ran. Refuse it BY NAME instead.
  if counter_has_leading_zero "$VERIFY_ATTEMPTS"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_VERIFY_ATTEMPTS='${VERIFY_ATTEMPTS}' — a LEADING ZERO is"
    say_err "   ambiguous: bash ARITHMETIC reads it as OCTAL, so '08' is not 8 but an ERROR that aborts"
    say_err "   the merge-artifact read's loop body. The rail would then report that it could not read"
    say_err "   whether PR merged while attempting ZERO reads. Write it without the leading zero."
  elif ! counter_is_positive "$VERIFY_ATTEMPTS"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_VERIFY_ATTEMPTS='${VERIFY_ATTEMPTS}' — the merge-artifact"
    say_err "   read's retry budget must be a POSITIVE integer: a non-numeric value errors the loop's"
    say_err "   arithmetic, and a non-positive one attempts no read at all."
  elif counter_exceeds_max "$VERIFY_ATTEMPTS" "$TIMING_KNOB_MAX"; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_VERIFY_ATTEMPTS='${VERIFY_ATTEMPTS}' — beyond the usable"
    say_err "   range (max ${TIMING_KNOB_MAX})."
  fi
  # Not a timing knob, but the same startup-refusal discipline and the same
  # reason: an unrecognised value must not silently behave like a recognised one.
  # `ADMIN_MERGE_LANE_PARITY=declared_of` (a typo) or `Declared-Off` would have
  # been read as the `declared-off` branch and its refusal message would then
  # describe a trigger-split repo that made no such declaration. Compare
  # literally, refuse the rest.
  if [ "$LANE_PARITY_MODE" != "require" ] && [ "$LANE_PARITY_MODE" != "declared-off" ]; then
    bad=1
    say_err "admin-merge: ✗ refusing ADMIN_MERGE_LANE_PARITY='${LANE_PARITY_MODE}' — the lane-coverage"
    say_err "   gate accepts exactly 'require' (default) or 'declared-off' (a trigger-split repo's"
    say_err "   spelling for the SAME refusal, named so the message can say why — see #1349, #1439)."
    say_err "   Any other value would silently read as a recognised mode and carry its meaning into"
    say_err "   a refusal that never diagnosed the situation."
  fi
  [ "$bad" -eq 0 ] || { say_err "   These are operator knobs; fix the value and re-run the rail."; return 1; }
  return 0
}

# ── THE HEAD READ'S KNOB INVARIANT BELONGS TO THE READ (#1690 review rounds 4-5) ─────
# `validate_timing_knobs` runs only inside `main()`, so ANY path that sources the rail bypassed
# it — the unit suite's `_drive`, the rail suite's `sed '$d'` loader — and then the arithmetic
# read an unvalidated global. Measured on the sourced path with the guard absent:
#   ADMIN_MERGE_HEAD_ATTEMPTS=0   → the loop body never executes: ZERO reads, yet the rail
#                                    printed `[head_unreadable] — could not READ the head (0 attempts)`;
#   ADMIN_MERGE_HEAD_ATTEMPTS=08  → `value too great for base`, then the same tag;
#   ADMIN_MERGE_HEAD_READ_SLEEP=abc → `abc: unbound variable` inside the arithmetic;
#   ADMIN_MERGE_HEAD_READ_SLEEP=010 → slept 8 (OCTAL) instead of 10.
# Round 4 guarded `require_head` only, which left `resolve_head` — the function that OWNS the
# arithmetic — still unguarded for a direct caller. One helper, called by BOTH, so the invariant
# cannot be bypassed by choosing a different way in. It REJECTS rather than defaulting: the old
# inline `case …) attempts=3` defaulted, which silently turned a typo into a different budget.
head_read_knobs_ok() {
  counter_is_positive "$HEAD_ATTEMPTS" \
    && ! counter_has_leading_zero "$HEAD_ATTEMPTS" \
    && ! counter_exceeds_max "$HEAD_ATTEMPTS" "$TIMING_KNOB_MAX" \
    && counter_is_number "$HEAD_READ_SLEEP" \
    && ! counter_has_leading_zero "$HEAD_READ_SLEEP" \
    && ! counter_exceeds_max "$HEAD_READ_SLEEP" "$TIMING_KNOB_MAX"
}

# refuse_bad_head_knobs -> 1 (having said why) when either knob is unusable.
refuse_bad_head_knobs() {
  say_err "admin-merge: ✗ refusing a bad head-read knob (ADMIN_MERGE_HEAD_ATTEMPTS='${HEAD_ATTEMPTS}',"
  say_err "   ADMIN_MERGE_HEAD_READ_SLEEP='${HEAD_READ_SLEEP}') — refusing to report on a head read"
  say_err "   whose retry budget is not a validated positive integer. Fix the value and re-run."
  return 1
}

# ── THE MERGE-ARTIFACT READ'S KNOB INVARIANT BELONGS TO THE READ (#1298) ─
# Same reason as `head_read_knobs_ok` (#1690 review rounds 4-5): `validate_timing_knobs`
# runs only inside `main()`, so ANY path that SOURCES the rail bypasses it — and this
# read OWNS the arithmetic that consumes the knob, so it is where the invariant has to
# hold. It REJECTS rather than defaulting: the pre-refactor inline `case …) attempts=6`
# silently turned a typo into a different budget, and (measured, #1690 review round 4)
# a leading-zero value left the loop body never running while the refusal still printed
# an attempt count.
merge_art_knobs_ok() {
  counter_is_positive "$VERIFY_ATTEMPTS" \
    && ! counter_has_leading_zero "$VERIFY_ATTEMPTS" \
    && ! counter_exceeds_max "$VERIFY_ATTEMPTS" "$TIMING_KNOB_MAX"
}

# refuse_bad_merge_art_attempts_override <value> -> 1 (having said why) when the
# SINGLE-SHOT override is unusable. The override is a CALLER's
# arithmetic bound on the one door, so it gets the knob's own three refusals, named —
# rather than the silent substitution that would reproduce #1690's defaulting.
refuse_bad_merge_art_attempts_override() {
  say_err "admin-merge: ✗ refusing a bad merge-artifact attempts override ('${1:-}')"
  say_err "   — the single-shot pre-check's bound must be a POSITIVE integer without a leading"
  say_err "   zero (max ${TIMING_KNOB_MAX}): a leading zero is octal to the loop's arithmetic, a"
  say_err "   non-positive value attempts no read, and a larger one is a bound the arithmetic"
  say_err "   cannot hold. Fix the caller — this is not defaulted."
  return 1
}

# refuse_bad_merge_art_knobs -> 1 (having said why) when the bound is unusable.
refuse_bad_merge_art_knobs() {
  say_err "admin-merge: ✗ refusing a bad merge-artifact knob (ADMIN_MERGE_VERIFY_ATTEMPTS='${VERIFY_ATTEMPTS}')"
  say_err "   — refusing to report on whether the PR merged with a retry budget that is not a validated"
  say_err "   positive integer without a leading zero (max ${TIMING_KNOB_MAX}). Fix the value and re-run."
  return 1
}

resolve_head() {
  local pr="$1"; shift
  # ⛔ BEFORE ANY ARITHMETIC (#1690 review round 5). This is the function that evaluates the
  # knobs, so it is where the invariant has to hold — a caller cannot reach the loop without
  # passing this.
  head_read_knobs_ok || { refuse_bad_head_knobs; return 1; }
  # ⛔ A FAILED READ MUST BE ABLE TO FAIL (#1690). This was a bare
  # `$GH pr view … 2>/dev/null`, so a transient failure (network, TLS, rate limit)
  # returned the EMPTY STRING, and §4 then read that as "the head moved to ``" — a
  # confident claim about reality derived from a read that failed. It blocked a
  # fully-attested PR that had not moved; the identical command re-run landed it.
  #
  # Two changes, and both are needed:
  #   1. RETRY. A transient read must have at least one retry before it is believed.
  #   2. VALIDATE THE SHAPE. A commit SHA is 40 hex chars. A truncated or garbled
  #      read is exactly as unusable as an empty one, and ONLY a shape check catches
  #      that — `[ -n "$out" ]` would happily accept a half-read sha.
  #
  # On persistent failure this prints NOTHING and returns NON-ZERO, so no caller can
  # mistake it for a value. ⛔ Callers must use `require_head` below, never this
  # directly: the whole defect was a caller that could not tell "empty" from "absent".
  local attempt out rc errtmp err
  # ⛔ THE READ'S DIAGNOSTIC IS NOT DISCARDED (#1690 review). `2>/dev/null` was the
  # defect's own shape: it is why a transient blip and a permanent cause (bad
  # credentials, wrong `--repo`, PR not found) produced the SAME refusal, with a
  # remedy ("re-run") that can never help the permanent ones. The last attempt's
  # stderr is kept here and quoted by `require_head`, so the operator can tell a
  # re-runnable transient from a configuration error. It is a GLOBAL, not a local,
  # because `resolve_head` must still print NOTHING on failure — the value channel
  # stays empty and the diagnostic travels on its own channel.
  HEAD_READ_DIAG=""
  # ⛔ THE ERR FILE IS CREATED WITH `mktemp`, NOT A PREDICTABLE PATH (#1750 review). The name
  # used to be `${TMPDIR:-/tmp}/admin-merge-head.$$.err`, and `2>"$path"` FOLLOWS a symlink
  # — so with `TMPDIR` unset (cron/launchd/`env -i`) the `${TMPDIR:-/tmp}` fallback is a
  # world-writable /tmp, and a same-box attacker who can predict the PID could have the rail
  # truncate any file the operator can write (CWE-377/CWE-59). MEASURED: on this box `TMPDIR`
  # is a mode-0700 per-user directory, and the abuse cases were fail-CLOSED (the redirect
  # failed and the read refused) — so this is a truncation primitive under an unset `TMPDIR`,
  # never a fail-open. `mktemp` uses O_EXCL, so the name cannot pre-exist as anyone else's
  # symlink. A total `mktemp` failure (no writable temp dir) leaves the path empty, the
  # redirect then fails, and the read refuses — fail-closed, the direction this change is
  # about.
  #
  # ⛔ AND THE FILE MUST BE THE PARENT'S (#1750 review). These resolvers run inside command
  # substitutions at the real call sites, so a `mktemp` performed here would put the path in
  # a SUBSHELL that the EXIT trap — which runs in `main`, the parent — can never see; a
  # Ctrl-C between create and `rm` would then leak an unpredictably-named file, a small
  # regression against the #1690 trap. `main` creates ONE such file up front, in the parent,
  # and the sourced path (the unit suite, the rail suite's `sed '$d'` loader, which have no
  # `main`) falls back to creating its own here.
  errtmp="${READ_ERRTMP:-}"
  [ -n "$errtmp" ] || errtmp="$(mktemp "${TMPDIR:-/tmp}/admin-merge-head.XXXXXX" 2>/dev/null)"
  # ⛔ THE RETRY BUDGET IS A VALIDATED STARTUP KNOB, NOT AN INLINE `case` (#1690 review).
  # `HEAD_ATTEMPTS` / `HEAD_READ_SLEEP` are checked by `validate_timing_knobs` before any
  # CI work, with the rail's own primitives (leading-zero, positive, range) — see their
  # declaration site and that function. Inline validation here was WRONG, not merely
  # redundant: it accepted `08`, which bash arithmetic then errors on.
  for ((attempt = 1; attempt <= HEAD_ATTEMPTS; attempt++)); do
    # shellcheck disable=SC2086
    out="$($GH pr view "$pr" "$@" --json headRefOid --jq .headRefOid 2>"$errtmp")" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
      # ⛔ VALIDATE THE WHOLE VALUE, NOT A LINE OF IT (#1690 review). The first version of
      # this check was `printf '%s' "$out" | grep -qE '^[0-9a-fA-F]{40}$'`, wrong twice:
      #   * `grep` is an ANY-LINE test — a read that returned a good sha AND a trailing junk
      #     line PASSED it, and `printf '%s\n' "$out"` then emitted BOTH, so the
      #     "caller gets a KNOWN-GOOD head" contract stated below was not established by
      #     the code. A multi-line head then reaches the comparisons, the evidence body and
      #     `--match-head-commit`.
      #   * the `writer | grep` shape is the SIGPIPE idiom banned repo-wide (#841): under
      #     `set -uo pipefail` a writer killed by SIGPIPE makes the pipeline non-zero, which
      #     classifies a VALID head as UNREADABLE — a false refusal inside the rail itself.
      # An embedded newline is not a hex character, so rejecting every non-hex character
      # rejects the multi-line case BY CONSTRUCTION, and needs no pipe at all.
      case "$out" in
        "" | *[!0-9a-fA-F]*) ;;   # empty, or anything that is not pure hex
        *) [ "${#out}" -eq 40 ] && { rm -f "$errtmp"; printf '%s\n' "$out"; return 0; } ;;
      esac
    fi
    # Keep the LAST attempt's diagnostic (one line, bounded): a later attempt's error
    # is the one closest to the refusal the operator actually reads.
    err="$(tail -n 1 "$errtmp" 2>/dev/null)"
    [ -n "$err" ] && HEAD_READ_DIAG="${err:0:200}"
    if [ "$attempt" -lt "$HEAD_ATTEMPTS" ]; then
      sleep "$((HEAD_READ_SLEEP * attempt))"
    fi
  done
  rm -f "$errtmp"
  return 1
}

# ── IS THIS FAILURE THE ACCOUNT'S RATE LIMIT? (#1910) ─────────────────────────
# GitHub's SECONDARY limit is a CONCURRENCY limit shared by the whole account, and
# `GET /rate_limit` does not report it — so a refusal can arrive while the primary counter
# reads healthy. This rail could not tell that apart from an unreadable read: it printed
# `[head_unreadable]` and then "check credentials, --repo, and the PR number". MEASURED
# 2026-10-17 (issue #1910, PR #1934): two rail runs failed at the final merge call with
# `GraphQL: API rate limit already exceeded`, surfaced as `head_unreadable` /
# `merged_precheck_unreadable`, and the hint sent the operator to the credential — while
# `gh api rate_limit` read 4625 of 5000 remaining. The cause was neither the token nor the
# PR number, and the "remedy" that followed was a raw REST merge that BYPASSED this rail.
#
# So the refusal NAMES the cause it read instead of prescribing a remedy it cannot know
# applies. Deliberately NOT "any 403": a permissions 403 is a different cause with a
# different remedy, and a mutating command must not be retried on it.
#
# ⛔ ONE VOCABULARY, TWO LAYERS. These patterns are the gh shim's own retry predicate
# (`scripts/gh-shim/gh::rate_limited`), and `tests/admin-merge` §13h drives BOTH from one
# fixture so a change to what GitHub prints cannot be recognised in one layer and missed in
# the other without a test going red.
diag_is_rate_limit() {
  local t
  [ -n "${1:-}" ] || return 1
  # No `| grep` (SIGPIPE under `pipefail`, #841): `tr` reads its input to EOF, so there is
  # no early-exiting consumer to kill the writer, and the match is a `case` on the result.
  t="$(printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$t" in
    *'api rate limit'*|*'secondary rate limit'*|*'abuse detection'*|*'http 429'*) return 0 ;;
    *'status code'*429*|*'retry-after'*) return 0 ;;
  esac
  return 1
}

# Was EITHER of the last observations a rate-limit refusal? <file-or-empty> <text>
# The two channels a read's own words travel on: a captured stderr FILE (the merge's, the
# state read's) and a DIAGNOSTIC variable. Both are checked because either may carry it.
observed_rate_limit() {
  local f="${1:-}" t="${2:-}"
  if [ -n "$f" ] && [ -s "$f" ] && diag_is_rate_limit "$(tail -n 5 "$f" 2>/dev/null)"; then
    return 0
  fi
  diag_is_rate_limit "$t"
}

# Say, in ONE place, what a rate-limit refusal does and does not mean (#1910). Prose that
# exists in three copies drifts into three different claims; this one is stated once.
say_rate_limit_note() {
  say_err "   ⚠️  [rate_limited] GitHub REFUSED THE CALL on its rate limit. This is NOT a claim"
  say_err "   about the credential, the --repo or the PR number, and it is NOT evidence that the"
  say_err "   PR is unreadable: the secondary/concurrency limit is shared across the whole account"
  say_err "   and is NOT visible in 'gh api rate_limit', so a healthy counter there is not evidence"
  say_err "   to the contrary. IF the gh shim is in your PATH it already paced this call and"
  say_err "   waited out its budget before giving up (AGENT_GH_GATE_MAX_ATTEMPTS), so the window"
  say_err "   outlasted that budget; if it is NOT in your PATH (a human shell, launchd, a caller that"
  say_err "   set GH_LIMIT_NO_WAIT) this call was NOT paced and the window may simply be long."
  say_err "   A rate-limited call is RETRYABLE: re-run the rail once the limit has cleared, and do"
  say_err "   NOT switch to a raw merge — that bypasses this rail rather than the rate limit."
}

# ── THE ONE DOOR FOR READING THE HEAD (#1690) ──────────────────────────────────
# ⛔ THERE IS EXACTLY ONE REASON TO READ THE HEAD, SO THERE IS EXACTLY ONE PLACE
# THAT FAILS TO. THREE call sites read the head — §4 during-re-run, §4 before-evidence,
# and the opening read — and TWO of them, the two §4 comparison sites, rendered a failed
# read as "head moved". (The opening read had a pre-existing emptiness guard and refused
# with "could not resolve the head", which is precisely why #1690's operator saw the wrong
# message at one site and not the others.) Fixing only the read would leave three copies
# of "is this failure a moved head or an unread one?" free to drift apart — the same
# duplication defect #1684 fixed on the DO list. So the discrimination lives HERE, once,
# and a caller that gets a value has a KNOWN-GOOD 40-hex head.
#
# ⛔ THE TWO REFUSALS ARE DIFFERENT SPEECH ACTS AND MUST NOT SHARE A MESSAGE.
#   * an UNREADABLE head is NOT a claim about reality — it says the instrument
#     could not answer, and the remedy is to retry the rail;
#   * a MOVED head IS a claim about reality — the evidence is SHA-bound and void,
#     and the remedy is to re-run the rail for the new head.
# Rendering the first as the second is precisely #1690.
require_head() {
  local pr="$1"; shift
  # ⛔ NO `local out` ANY MORE (#1690 review): the head is no longer captured and reprinted —
  # `resolve_head`'s stdout IS the return value now (see the note at the call below).
  # ⛔ THE INVARIANT TRAVELS WITH THE FUNCTION, NOT THE ENTRY POINT (#1690 review round 4).
  # `validate_timing_knobs` runs only inside `main()`, so anything that SOURCES the rail — the
  # unit suite's `_drive`, the rail suite's `sed '$d'` loader — bypassed it entirely. (Round 5
  # additionally guards `resolve_head`, which owns the arithmetic; this one is kept because
  # `require_head` also FORMATS the attempt count into its refusal, so it must not build a
  # message from an unvalidated value either.) Rejecting, never defaulting.
  head_read_knobs_ok || { refuse_bad_head_knobs; return 1; }
  # ⛔ NO COMMAND SUBSTITUTION AROUND THIS CALL (#1690 review). The first version read
  # `out="$(resolve_head "$pr" "$@")"`, and a variable assigned inside `$( )` is assigned in a
  # SUBSHELL and destroyed with it — so `HEAD_READ_DIAG` never reached this function, the
  # refusal always took its "no diagnostic" branch, and the two tests asserting the diagnostic
  # is QUOTED failed while the two asserting its ABSENCE passed VACUOUSLY (the channel was dead
  # on every path, including success). Calling it directly keeps the diagnostic in THIS shell,
  # and `resolve_head`'s stdout — the head, and nothing else — passes straight through to our
  # caller, which is exactly what the old capture-then-reprint did.
  if resolve_head "$pr" "$@"; then
    return 0
  fi
  # ⛔ A MACHINE-READABLE TOKEN, NOT JUST PROSE (#1690 review). The rail separated the two
  # speech acts by WORDING alone, so any consumer had to parse prose — and any future
  # rewording would silently destroy the distinction (nothing pinned the PRESENCE of a
  # stable marker, only the absence of a phrase). `extensions/review-enforcer` already models
  # the right answer: `reasonTag: base_unverifiable` vs `head_advanced`, recorded in
  # `gate-events.jsonl` so block rates can be reconstructed BY REASON. `[head_unreadable]` is
  # the tag the moved-head refusals do NOT carry, so `grep -F '[head_unreadable]'` answers
  # "could the instrument read the head?" without depending on how the sentence is worded.
  # ⛔ A RATE-LIMIT REFUSAL GETS ITS OWN TOKEN, NOT ONLY ITS OWN PROSE (#1910). Word
  # alone is what let a consumer classify a burst refusal as an unreadable head; the tag
  # is `[rate_limited]`, and `[head_unreadable]` is KEPT on the same line so every existing
  # consumer of that tag still matches.
  local limit_tag=""
  diag_is_rate_limit "${HEAD_READ_DIAG:-}" && limit_tag=" [rate_limited]"
  say_err "admin-merge: ✗ BLOCK [head_unreadable]${limit_tag} — could not READ the head of PR #$pr (${HEAD_ATTEMPTS} attempts)."
  say_err "   This is NOT a claim that the branch tip changed: the read failed, or returned"
  say_err "   something that is not a commit SHA. Nothing was merged."
  # ⛔ A REFUSAL MUST NOT PRESCRIBE A REMEDY IT CANNOT KNOW APPLIES (#1690 review).
  # "Re-run the rail" is right for a transient blip and useless for a permanent
  # cause; without the read's own words the two were indistinguishable here. So the
  # diagnostic is QUOTED when there is one, and its absence is stated rather than
  # papered over — the operator learns which case they are in, or that we cannot say.
  if [ -n "${HEAD_READ_DIAG:-}" ]; then
    say_err "   the read reported: ${HEAD_READ_DIAG}"
    # ⛔ NAME THE CAUSE INSTEAD OF THE ONE IT CANNOT BE (#1910). The credentials hint
    # below is actively misleading here: it points at the token, the repo and the PR
    # number, none of which a rate-limit refusal is about.
    if [ -n "$limit_tag" ]; then
      say_rate_limit_note
    else
      say_err "   Re-run the rail if that looks transient; if it repeats, the cause above is"
      say_err "   probably not transient — check credentials, --repo, and the PR number."
    fi
  else
    say_err "   the read produced no diagnostic (gh exited 0 with an unusable value, or wrote"
    say_err "   nothing to stderr). Re-run the rail."
  fi
  return 1
}

# resolve_draft <pr> → the PR's `isDraft` flag on stdout: EXACTLY `true` or `false`.
# `commit-workflow` opens drafts on purpose, and `gh pr merge` refuses a draft with
# "Pull Request is still a draft" — so the rail probes this BEFORE any CI work and
# refuses early with THAT reason, rather than surfacing it late as a generic merge
# failure once the head-bound evidence marker has already been posted.
#
# ⛔ A FAILED READ MUST BE ABLE TO FAIL (#1750). This was a bare
# `$GH pr view … --jq .isDraft 2>/dev/null`, and its only caller ASSIGNED the output
# and discarded the status. A failed read then returned the EMPTY STRING, and the
# caller's `[ "$is_draft" = "true" ]` read that as "not a draft" and PROCEEDED — past
# the early refusal this probe exists to make. Same root as #1690 ("a read that failed
# is rendered as a value"), opposite side of the falsifier: #1690 was a false REFUSAL,
# this was a false PERMISSION. Fail-open is the worse direction, so this one is the
# strict shape.
#
# The shape follows #1690's landed answer, and each clause is load-bearing:
#   * VALIDATE THE WHOLE VALUE. `isDraft` is a BOOLEAN, so it has exactly two readings.
#     Anything that is not `true` or `false` — empty, `yes`, a multi-line read — is
#     UNREADABLE, never `false`. A `case` on the whole value rejects an embedded newline
#     by construction, so no pipe is needed (the `writer | grep` shape is banned
#     repo-wide, #841: under `set -uo pipefail` a writer killed by SIGPIPE makes the
#     pipeline non-zero, which would classify a VALID value as unreadable).
#   * ON ANY UNUSABLE READ, PRINT NOTHING AND RETURN NON-ZERO, so no caller can mistake
#     the absence for a value.
#   * THE READ'S OWN WORDS TRAVEL ON A SEPARATE CHANNEL (a global, not the value
#     channel), so the refusal can tell a transient blip from a permanent cause instead
#     of prescribing a remedy that cannot help. `resolve_draft` is called DIRECTLY by
#     `require_draft`, never through a command substitution, so the global is not lost to
#     a subshell — the same trap #1690's review found with `HEAD_READ_DIAG`.
# ⛔ Callers must use `require_draft` below, never this directly: the whole defect was a
# caller that could not tell "empty" from "the PR is not a draft".
resolve_draft() {
  local pr="$1"; shift
  local out rc errtmp err
  DRAFT_READ_DIAG=""
  # The same O_EXCL creation, and the same parent-owns-the-file rule, as the head read above
  # (#1750 review); the two probes never run concurrently and share the one file.
  errtmp="${READ_ERRTMP:-}"
  [ -n "$errtmp" ] || errtmp="$(mktemp "${TMPDIR:-/tmp}/admin-merge-draft.XXXXXX" 2>/dev/null)"
  # shellcheck disable=SC2086
  out="$($GH pr view "$pr" "$@" --json isDraft --jq .isDraft 2>"$errtmp")" && rc=0 || rc=$?
  err="$(tail -n 1 "$errtmp" 2>/dev/null)"
  [ -n "$err" ] && DRAFT_READ_DIAG="${err:0:200}"
  rm -f "$errtmp"
  [ "$rc" -eq 0 ] || return 1
  case "$out" in
    true | false) printf '%s\n' "$out"; return 0 ;;
  esac
  return 1
}

# ── THE ONE DOOR FOR THE DRAFT PROBE (#1750) ───────────────────────────────────
# ⛔ THERE IS EXACTLY ONE REASON TO READ `isDraft`, SO THERE IS EXACTLY ONE PLACE THAT
# FAILS TO. The discrimination between "the instrument could not answer" and "this PR is
# a draft" lives HERE, once — a caller that gets a value has a KNOWN-GOOD boolean.
#
# ⛔ THE TWO REFUSALS ARE DIFFERENT SPEECH ACTS AND MUST NOT SHARE A MESSAGE.
#   * an UNREADABLE draft flag is NOT a claim about the PR — it says the instrument could
#     not answer, and the remedy is to retry the rail;
#   * "the PR IS A DRAFT" IS a claim about the PR — it voids the merge, and the remedy is
#     `gh pr ready`.
# Rendering the first as the second is bad; rendering it as NOTHING AT ALL — which is what
# the bare read did — is #1750, and it is the failure this door exists to make impossible.
require_draft() {
  local pr="$1"; shift
  if resolve_draft "$pr" "$@"; then
    return 0
  fi
  # ⛔ A MACHINE-READABLE TOKEN, NOT JUST PROSE — the answer #1690 reached for the head
  # read. `[draft_unreadable]` is the tag the genuine draft refusal does NOT carry, so
  # `grep -F '[draft_unreadable]'` answers "could the instrument read the draft flag?"
  # without depending on how the sentence is worded. The refusal deliberately does NOT
  # contain the phrase "is a DRAFT" or the remedy `gh pr ready`, so a log scraper matching
  # the GENUINE draft refusal cannot match this one by phrasing either.
  say_err "admin-merge: ✗ BLOCK [draft_unreadable] — could not READ the isDraft flag of PR #$pr."
  say_err "   This is NOT a claim about the PR, and NOT a CI-failure verdict: the read"
  say_err "   failed, or returned something other than exactly 'true' or 'false'."
  say_err "   Nothing was merged and no evidence was posted."
  # ⛔ A REFUSAL MUST NOT PRESCRIBE A REMEDY IT CANNOT KNOW APPLIES (#1690 review, whose
  # finding applies verbatim here). "Re-run the rail" is right for a transient blip and
  # useless for a permanent cause; without the read's own words the two are the same
  # refusal. Quoted when there is one; the absence is STATED rather than papered over.
  if [ -n "${DRAFT_READ_DIAG:-}" ]; then
    say_err "   the read reported: ${DRAFT_READ_DIAG}"
    say_err "   Re-run the rail if that looks transient; if it repeats, the cause above is"
    say_err "   probably not transient — check credentials, --repo, and the PR number."
  else
    say_err "   the read produced no diagnostic (gh exited 0 with an unusable value, or wrote"
    say_err "   nothing to stderr). Re-run the rail."
  fi
  return 1
}

# ── THE ONE DOOR FOR READING THE MERGE ARTIFACT (#1298) ────────────────────────
#
# `gh pr merge`'s EXIT STATUS is a statement about the SEND. The PR's STATE is the
# statement about the ARTIFACT. The two disagree in BOTH directions, and each
# direction costs something real:
#
#   * exit 0 while the PR is still OPEN — a queued `--auto`, or a merge not yet
#     reflected. The success marker then stands over an unmerged PR (#1359).
#   * exit NON-ZERO while the PR is MERGED — GitHub PROCESSED the merge and the
#     RESPONSE READ failed (a network timeout; tortoise #4413 shows the exact
#     `Post "https://api.github.com/graphql": read tcp …: operation timed out`).
#     A lost answer to a MUTATION is ambiguous BY DEFINITION about whether the
#     mutation ran, so the exit status CANNOT tell a refused merge from an
#     answered-and-lost one. The rail rendered the second as "the merge did NOT
#     happen" and posted a durable retraction over a MERGED PR (#1298).
#
# BOTH arms therefore ask THE REPOSITORY, through THIS function, and neither infers
# the artifact from the exit status. One door, for the same reason `require_head`
# and `require_draft` are one door: two copies of "did it happen?" drift, and the
# drift is invisible in exactly the situation the guard exists for.
#
# ⛔ THE OUTCOMES ARE THREE, NOT TWO. A read that FAILED is not a claim about the
#    PR, so it is rendered as neither "merged" nor "not merged". Rendering a failed
#    read as the second is #1298; #1690 fixed the same shape one arm over, and the
#    rule it established applies verbatim to the highest-consequence instance.
#
# Nothing travels on stdout — the verdict and the observation travel in the globals
# below, so no caller can read the empty stream as a value (the #1690/#1750 shape):
#   MERGE_ART_VERDICT    merged | not_merged | unreadable
#   MERGE_ART_STATE      the observed state, or `<unreadable>`
#   MERGE_ART_MERGED_AT  the observed mergedAt, or `<unreadable>`
#   MERGE_ART_ATTEMPTS   the bound actually used (formatted into the callers' messages), or
#                        `0` on the two paths that read nothing: a refused knob, or a
#                        rejected attempts override (`return 1` on both)
#   MERGE_ART_DIAG       the DECIDING (last) attempt's last NON-BLANK stderr line (one
#                        bounded line), empty when that attempt wrote none — never an
#                        earlier attempt's text
poll_merge_artifact() { # <pr> [attempts-override]
  # ⛔ THE OPTIONAL SECOND ARG IS #1709 rec 7's SINGLE-SHOT PRE-CHECK, and it is an
  # override ON THIS DOOR rather than a second state reader. The pre-check asks "is this
  # PR ALREADY merged?" — a SNAPSHOT, where the two in-rail callers ask "did the merge I
  # just issued land?" — a bounded WAIT. Running the WAIT at the top of every merge would
  # idle 6 attempts × 2s on every healthy (unmerged) PR, so the pre-check needs ONE shot;
  # the polarity, the projection and the three-outcome contract must nevertheless stay
  # ONE implementation, which is why the override lives here and not in a copy. ABSENT
  # (`''`) is the optional-arg contract and keeps the configured window — both in-rail
  # callers pass no override. A PRESENT value is a CALLER's arithmetic bound, so it is
  # REFUSED BY NAME unless it is a validated positive integer within TIMING_KNOB_MAX
  # (refuse_bad_merge_art_attempts_override) — never silently defaulted. Defaulting is
  # #1690's failure one arm over: a present-but-unvalidated override would have `… 08`
  # quietly poll the configured window, and `… 1000000000` — one past TIMING_KNOB_MAX —
  # become a bound the loop's arithmetic cannot hold, the very symptom this block exists to
  # prevent. A caller's typo must be LOUD, not silently substituted.
  # (Pinned by tests/admin-merge/run.sh's `override-probe` block.)
  local pr="$1" attempts_override="${2:-}"
  MERGE_ART_VERDICT="unreadable"
  MERGE_ART_STATE="<unreadable>"
  MERGE_ART_MERGED_AT="<unreadable>"
  # ⛔ EVERY EXIT PATH SETS EVERY GLOBAL (#1298 review). The knob refusal below returns
  # BEFORE the loop, so leaving this unset made the callers' `(${MERGE_ART_ATTEMPTS}
  # attempt(s))` an unbound-variable ABORT under `set -u` — the rail would die with a
  # shell error instead of printing the refusal it had just composed. `0` is also the
  # TRUE count on that path (zero reads ran), which is the distinction #1690 was about.
  MERGE_ART_ATTEMPTS="0"
  MERGE_ART_DIAG=""
  local attempts="$VERIFY_ATTEMPTS"
  # ⛔ ABSENT keeps the window (optional arg); PRESENT is VALIDATED, NOT DEFAULTED. The
  # three refusals below are the same three the knob itself is refused for, so no path can
  # put an arithmetic bound in here that `merge_art_knobs_ok` would have rejected had it
  # been the knob. `return 1` here is the same shape as the knob refusal below: the globals
  # are already set (MERGE_ART_ATTEMPTS is the TRUE `0`, i.e. zero reads ran), so no caller
  # can hit an unbound-variable abort under `set -u` and the count they report is true. The
  # refusal is distinguished from a failed read by the STATUS, not by the verdict — the
  # step-0a caller checks it, so a caller typo is never re-narrated as an unreadable read.
  if [ -n "$attempts_override" ]; then
    if counter_has_leading_zero "$attempts_override" \
       || ! counter_is_positive "$attempts_override" \
       || counter_exceeds_max "$attempts_override" "$TIMING_KNOB_MAX"; then
      refuse_bad_merge_art_attempts_override "$attempts_override"
      return 1
    fi
    attempts="$attempts_override"
  fi
  # ⛔ THE KNOB IS VALIDATED, NOT DEFAULTED, AND THE INVARIANT TRAVELS WITH THE FUNCTION.
  # The pre-refactor inline `case …) attempts=6` DEFAULTED (silently substituting a
  # different budget for a typo) and — measured — a leading-zero value reached this
  # arithmetic site, where `attempt <= 08` errors and the loop body NEVER RUNS: the rail
  # then prints `[merge_unreadable] … (08 attempt(s))` on a run where ZERO reads were
  # attempted, which is #1690's symptom one arm over. The STARTUP path refuses the same
  # three classes BY NAME before any CI work, through `validate_timing_knobs`' own inline
  # checks (which can name WHICH class was bad, as its per-cause messages do); this helper
  # exists for the paths that never reach it, because ANY path that SOURCES the rail
  # bypasses `main` — and that is where the arithmetic lives.
  merge_art_knobs_ok || { refuse_bad_merge_art_knobs; return 1; }
  MERGE_ART_ATTEMPTS="$attempts"
  local attempt=0 rc=0 observed="" state_part="" rest="" err=""
  local errtmp outtmp
  # The same O_EXCL creation and the same parent-owns-the-file rule as the head and
  # draft reads (#1690/#1750 review): the file is `mktemp`-generated, read from the
  # file-scope `READ_ERRTMP` so the EXIT trap can remove it, and created here only on
  # a path with no `main` (the suites that source the rail).
  errtmp="${READ_ERRTMP:-}"
  [ -n "$errtmp" ] || errtmp="$(mktemp "${TMPDIR:-/tmp}/admin-merge-art.XXXXXX" 2>/dev/null)"
  # ⛔ THE READ IS CAPTURED TO A FILE, NOT STRAIGHT INTO A VARIABLE (#1298 review). A bash
  # string CANNOT hold a NUL byte: `$(...)` deletes NULs silently, with no error and no
  # warning, so a producer emitting `MER<NUL>GED` would be read as `MERGED` — a value
  # GitHub did not say, rendered as a MERGE, which is the one direction that cannot be
  # walked back (the evidence marker is standing and no retraction is posted). GitHub's
  # `state` is an enum and cannot carry a NUL, so this was LATENT — but this guard must not
  # rest on the producer's output shape, which is the same reason the `sed`-over-JSON
  # projection above was rejected. The file is inside the per-run `$TMP` when there is one
  # (so the EXIT trap removes it wholesale) and `mktemp`-generated otherwise, exactly like
  # `errtmp` — never a FIXED name, which two concurrent runs would share.
  outtmp="${TMP:+$TMP/merge-art.out}"
  [ -n "$outtmp" ] || outtmp="$(mktemp "${TMPDIR:-/tmp}/admin-merge-art-out.XXXXXX" 2>/dev/null)"
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    # ASK FOR EXACTLY WHAT WE MEAN and let the producer project it. A `sed` over the
    # whole JSON takes the LAST `"state"` anywhere in the output, so a nested or
    # repeated object could be read as the merge state while the TOP-LEVEL state said
    # OPEN (adversarial cycle 1 — LATENT: real `gh pr view --json state,mergedAt` emits
    # only those two keys, so it was not reachable today, but this guard's correctness
    # must not rest on the producer's output shape). `--jq` reads the TOP-LEVEL fields:
    # one tab-separated `<state>\t<mergedAt>`, mergedAt sentineled because it is null
    # for an unmerged PR.
    # shellcheck disable=SC2086
    if $GH pr view "$pr" ${repo_args[@]+"${repo_args[@]}"} \
        --json state,mergedAt --jq '[.state, (.mergedAt // "-")] | @tsv' \
        >"$outtmp" 2>"$errtmp"; then
      rc=0
    else
      rc=$?
    fi
    # ⛔ THE WHOLE VALUE, NOT A LINE OF IT (#1690's review, applied to this read). The
    # version this replaces took `head -1` and `${x%%$'\t'*}`, which are an ANY-FIRST-LINE
    # test and an ANY-SEPARATOR test: a read that answered the projection AND a trailing
    # junk line passed the first, and the mergedAt half could itself carry a tab. `@tsv`
    # emits exactly ONE line with exactly ONE separator, so anything else — an INTERNAL
    # newline, a second separator, a value that is not the projection — is UNREADABLE by
    # construction. A `case` on the whole value needs no pipe, so the `writer | grep -q`
    # idiom banned repo-wide (#841) is not reintroduced either — and that matters here:
    # under `set -uo pipefail` a SIGPIPE-killed writer makes the pipeline non-zero, which
    # would classify a VALID read as unreadable.
    #
    # ⛔ WHAT THIS DOES *NOT* RE-DERIVE, stated rather than implied: `$(...)` strips ALL
    # trailing newlines, so a value whose extra lines are all BLANK past the first (and
    # gh's own output ends in one newline, which is why the raw byte count cannot simply
    # be `lines == 1`) is read as the single line it reduces to. That cannot change a
    # verdict — a token still has to be exactly `MERGED`/`OPEN`/`CLOSED` — so it is a
    # narrower guard, not a fail-open, and it is left deliberately (see the PR's limits).
    #
    # ⛔ AND A NUL IS TESTED AT THE BYTE LEVEL, because no bash string can carry one. The
    # read above is a FILE, so the test is exact: `tr -d '\000'` applied to the file equals
    # the file IFF it held no NUL. A missing or unreadable file makes `cmp` exit 2, which is
    # not "equal", so this test fails CLOSED (unreadable) rather than open.
    #
    # ⛔ AND THE VALUE IS BOUNDED, because the two parameter EXPANSIONS below
    # (`${observed%%$'\t'*}` and `${observed#*$'\t'}`) are what is O(n²) in the value's
    # length — measured on this box: 80 KB ≈ 7 s and ≈ 18 s for the two expansions, 160 KB
    # ≈ 25 s and ≈ 58 s — so a producer emitting a large body HANGED the rail instead of
    # answering it. (The `case` tests themselves are linear; the cost is in the removals.)
    # The projection is a fixed, tiny shape (real `gh` output for these two fields is 28
    # bytes), so a generous 4 KiB ceiling costs nothing real and keeps those expansions from
    # ever seeing an oversized value.
    state_part=""; rest=""
    if [ "$rc" -eq 0 ] && [ "$(wc -c < "$outtmp")" -le 4096 ] \
       && cmp -s "$outtmp" <(tr -d '\000' < "$outtmp"); then
      observed="$(cat "$outtmp")"
      case "$observed" in
        *$'\n'*)       : ;;                  # more than one line: not the projection
        *$'\t'*$'\t'*) : ;;                  # more than one separator: not the projection
        *$'\t'*)       state_part="${observed%%$'\t'*}"
                       rest="${observed#*$'\t'}" ;;
      esac
    fi
    # ⛔ THE ANSWER IS AN ALLOW-LIST, NOT "ANYTHING THAT IS NOT MERGED". GitHub reports a
    # PR state as exactly one of MERGED / OPEN / CLOSED, and only MERGED means the merge
    # happened. ANY other value — empty, a state GitHub has not documented, a mis-shaped
    # read — is UNREADABLE, never `not_merged`, so a garbage read cannot manufacture a
    # retraction. This is the polarity the merge rail's own check-run reader adopted
    # ("EVERY OTHER CONCLUSION IS RED — including one GitHub has not documented yet, and
    # a null one"): an unnamed value must never fall through a gap.
    case "$state_part" in
      MERGED)      MERGE_ART_STATE="MERGED"
                   MERGE_ART_MERGED_AT="${rest:-<unreadable>}" ;;
      OPEN|CLOSED) MERGE_ART_STATE="$state_part"
                   MERGE_ART_MERGED_AT="${rest:-<unreadable>}" ;;
      *)           MERGE_ART_STATE="<unreadable>"
                   MERGE_ART_MERGED_AT="<unreadable>" ;;
    esac
    # ⛔ THE DIAGNOSTIC BELONGS TO THE ATTEMPT THAT DECIDED (#1298 review). This kept the
    # last NON-EMPTY stderr, so when the deciding attempt wrote none — a real `gh` shape:
    # exit 0 with a non-projected answer and empty stderr — the callers printed an EARLIER
    # attempt's transient error as "the state read reported: …". That names the wrong cause
    # (a timeout, remedy: re-run) for a different one (the producer's shape changed), and it
    # is the one thing that separates a blip from a config error. Assigning unconditionally
    # lets the callers' `if [ -n … ]` / else-arm tell the truth about the deciding read.
    #
    # ⛔ THE LAST *NON-BLANK* LINE, not the last line (#1298 delta review): a multiline error
    # ending in a blank line — `boom\n\n` — made `tail -n 1` return the EMPTY string, so a
    # real message was reported as "produced no diagnostic". `awk` keeps the last line that
    # has content and ignores the padding, with no pipe to SIGPIPE.
    err="$(awk 'NF { last = $0 } END { print last }' "$errtmp" 2>/dev/null)"
    MERGE_ART_DIAG="${err:0:200}"
    if [ "$MERGE_ART_STATE" = "MERGED" ]; then
      break
    fi
    # A well-formed read that is NOT merged keeps polling: the merge may still be
    # landing (#1359). Only the LAST attempt's observation decides the verdict, so a
    # readable OPEN followed by an unreadable final attempt is UNREADABLE — the state at
    # the END is unknown, and an earlier observation cannot stand in for it.
    [ "$attempt" -ge "$attempts" ] && break
    sleep "${ADMIN_MERGE_VERIFY_POLL:-2}"
  done
  rm -f "$errtmp" "$outtmp"
  case "$MERGE_ART_STATE" in
    MERGED)      MERGE_ART_VERDICT="merged" ;;
    OPEN|CLOSED) MERGE_ART_VERDICT="not_merged" ;;
    *)           MERGE_ART_VERDICT="unreadable"
                 MERGE_ART_STATE="<unreadable>"
                 MERGE_ART_MERGED_AT="<unreadable>" ;;
  esac
}

# resolve_base_ref <pr> → the PR's TARGET branch (`baseRefName`). The base branch's
# head surface is measured for CONTEXT ONLY (it says whether main is currently
# red); the tree that GATES the merge is the PR's own evaluated tree (#1261).
# An unreadable or empty answer is not fatal, and each caller decides what to do with it
# (#2610 review, cycle 6): the §2c tree call site (`base_ref="$(resolve_base_ref …)"` followed
# by `|| base_ref=main`) defaults to `main`, which every repo in this fleet uses, while the
# step-1c NAMING caller deliberately does NOT (see the call site and its comment) — it hands
# the empty string to the refusal's UNANSWERED arm, because asserting a red is "on main"
# about a ref the rail never resolved is a claim about reality it did not measure.
# The root cause for the default: a PR can target a non-default branch, so the answer is
# preferred when it exists.
resolve_base_ref() {
  local pr="$1"; shift
  # shellcheck disable=SC2086
  $GH pr view "$pr" "$@" --json baseRefName --jq .baseRefName 2>/dev/null
}

# rail_pr_url_names <pr> <owner/repo> — does the PR's OWN url name THIS repo and THIS
# number? rc 0 = yes · rc 1 = it names something else · rc 2 = the identity could not be
# read (which is never a yes).
#
# ⛔ WHY A URL AND NOT A TITLE OR A BRANCH NAME (#2235 review). The defect this guards
# is that a BARE NUMBER identifies nothing: PR #2234 exists in both
# `daniel-ospina/tortoise` (merged in September) and `daniel-ospina/agent-infra` (open).
# A title/branch comparison proves only that some PR has that title; the url is the one
# field GitHub emits that carries the repo+number PAIR as data, so it settles the question
# the number cannot. The url is read WITH `--repo`, so a wrong ambient selector cannot
# make this read answer for the other repo.
#
# ⛔ A SUFFIX TEST IS NOT ENOUGH. `*/owner/name/pull/42` also matches
# `…/evil/owner/name/pull/42`, reading a foreign owner's repository as ours (the same
# wrong-repo fail-open `atomic-land.sh`'s `drift_safe_of` documents at length). So the
# PATH IS SPLIT INTO SEGMENTS and must be EXACTLY [owner, name, "pull", <number>]; a
# host, scheme, query, fragment or extra segment makes it a non-match rather than a match.
rail_pr_url_names() {
  local pr="$1" want="$2" url="" rest path a="" b="" c="" d="" extra="" url_host=""
  [ -n "$pr" ] && [ -n "$want" ] || return 2
  # shellcheck disable=SC2086
  url="$($GH pr view "$pr" --repo "$want" --json url --jq .url 2>/dev/null)" || url=""
  url="$(printf '%s' "$url" | tr -d '[:space:]')"
  case "$url" in
    *://*) : ;;
    *) return 2 ;;                       # not a url: nothing to prove
  esac
  rest="${url#*://}"                    # host/owner/name/pull/N
  # ⛔ THE HOST IS COMPARED WHEN THE CHECKOUT NAMES ONE (#2235 review P2). Without this the
  # proof was host-BLIND: `https://evil.example.com/daniel-ospina/agent-infra/pull/42` returned
  # rc 0, so a same-owner/name PR on a MIRROR or another host (`GH_HOST` set to a GHE instance)
  # would certify this repo's no-op. When the checkout's remote is scp-like or local there is no
  # host to compare — that case is STATED here rather than left as a silent pass.
  case "$rest" in
    */*) : ;;
    *) return 2 ;;
  esac
  url_host="${rest%%/*}"; url_host="${url_host#*@}"; url_host="${url_host%%:*}"
  if [ -n "${RAIL_CHECKOUT_HOST:-}" ] \
     && [ "$(rail_lc "$url_host")" != "$RAIL_CHECKOUT_HOST" ]; then
    return 1
  fi
  case "$rest" in
    */*) path="${rest#*/}" ;;
    *) return 2 ;;
  esac
  case "$path" in
    *\?*|*\#*) return 1 ;;               # a query/fragment is not a PR path
  esac
  # ⛔ THE 5TH FIELD IS NAMED `extra`, NOT `_`: `$_` is a BASH-MAINTAINED variable holding the
  # last argument of the previous command, so `[ -z "$_" ]` was testing that (always `]` right
  # after the `[ -n … ]` tests above) and returned 1 UNCONDITIONALLY — the rail refused every
  # healthy url, exit 2 on PRs that were genuinely already merged (§2235 review round 2: caught
  # by §70(f), §70(l) and #1709 rec 7, six red assertions).
  IFS='/' read -r a b c d extra <<<"$path"
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] || return 1
  [ -z "$extra" ] || return 1            # EXACTLY [owner, name, pull, N] — no `/files`, no suffix
  [ "$c" = "pull" ] || return 1
  # ⛔ NUMERICALLY, because this rail ACCEPTS a zero-padded PR (`01631`, see the argv note): gh
  # parses `0042` as 42 and echoes `…/pull/42`, so a string compare refused a PR that IS this
  # one and exited 2 — a false block on the no-op path (§2235 review P2).
  case "$pr" in ''|*[!0-9]*) return 1 ;; esac
  case "$d"  in ''|*[!0-9]*) return 1 ;; esac
  [ "${d#"${d%%[!0]*}"}" = "${pr#"${pr%%[!0]*}"}" ] || return 1
  [ "$(rail_lc "$a/$b")" = "$(rail_lc "$want")" ] || return 1
  return 0
}

# resolve_merge_ref <pr> — resolve the PR's MERGE REF identity, and stop loudly
# when it cannot be trusted. Sets:
#   MERGE_REF_STATUS   ok | conflicted | absent | unreadable
#   MERGE_REF_SHA      the merge ref's sha (empty unless ok)
#   MERGE_REF_SUMMARY  ONE legible line naming what was found
#
# WHY THIS IS READ AT ALL when the check surface is keyed to the head sha: the
# merge ref's own state is the only way to tell a real evaluated tree from a
# stale one. A CONFLICTED PR has `mergeable: false` and a NULL `merge_commit_sha`,
# and `refs/pull/<N>/merge` — if it exists at all — is a STALE leftover from the
# last time the PR was mergeable (verified: PR #1161's ref ff2cede has parents
# that are neither the current head nor the current base). A FRESH PR has no
# computed merge ref yet (`mergeable: null`). Both are refused LOUDLY rather
# than measured: GitHub cannot merge a conflicted PR anyway, and a surface we
# cannot tie to a merge is not a certificate.
#
# THE SOURCE IS THE REST PR OBJECT, NOT `gh pr view --json mergeCommit`: GraphQL
# `mergeCommit` is NULL for any unmerged PR (verified on an open PR whose REST
# `merge_commit_sha` was populated), so the GraphQL field would read as
# "absent" for every PR the rail ever handles. The REST `merge_commit_sha` was
# verified equal to the `refs/pull/<N>/merge` ref sha for open mergeable PRs.
#
# `mergeable: null` means GitHub has not finished computing mergeability
# (documented: a background job starts and the value is null until it
# completes), so it is RE-POLLED inside a bounded window before giving up —
# the documented remedy, not a workaround. `MERGE_REF_WAIT` is that window and
# the number the message reports; POLL_INTERVAL paces it (0 in the harness).
# The WINDOW is the bound an operator reasons about; MERGE_POLL_ATTEMPTS is an
# optional hard cap on the number of reads (0 = no cap).
MERGE_REF_WAIT="${ADMIN_MERGE_MERGE_REF_WAIT:-90}"
MERGE_POLL_ATTEMPTS="${ADMIN_MERGE_MERGE_POLL_ATTEMPTS:-0}"
MERGE_REF_WAITED=0
MERGE_REF_ATTEMPTS=0
MERGE_REF_LAST=""
resolve_merge_ref() {
  local pr="$1"
  local slug line attempt=0 state waited=0 step adv
  MERGE_REF_STATUS=""; MERGE_REF_SHA=""; MERGE_REF_SUMMARY=""
  MERGE_REF_WAITED=0; MERGE_REF_ATTEMPTS=0; MERGE_REF_LAST=""
  step="$POLL_INTERVAL"; [ "$step" -gt 0 ] 2>/dev/null || step=1
  if [ -n "${REPO:-}" ]; then slug="repos/$REPO"; else slug="repos/{owner}/{repo}"; fi
  while :; do
    # ONE call: mergeability and the merge ref sha together. `--jq` is real gh's
    # projection; the harness stub answers with the already-projected line.
    line="$($GH api "$slug/pulls/$pr" --jq '"\(.mergeable)" + "\t" + (.merge_commit_sha // "")' 2>/dev/null || true)"
    attempt=$((attempt + 1)); MERGE_REF_ATTEMPTS=$attempt
    if [ -z "$line" ]; then
      MERGE_REF_STATUS="unreadable"
      MERGE_REF_SUMMARY="UNREADABLE — 'gh api .../pulls/$pr' failed: the PR's mergeability and merge ref were never read"
      return 0
    fi
    state="${line%%$'\t'*}"
    MERGE_REF_SHA="${line#*$'\t'}"
    [ "$state" = "$line" ] && MERGE_REF_SHA=""
    case "$state" in
      true|false) break ;;
    esac
    MERGE_REF_LAST="mergeable=${state:-<empty>}"
    MERGE_REF_WAITED=$waited
    # `null` (still computing) or an unrecognised token: re-poll inside the
    # MERGE-REF window, then give up LOUDLY. Never guess a tree.
    if [ "$waited" -ge "$MERGE_REF_WAIT" ] \
       || { [ "$MERGE_POLL_ATTEMPTS" -gt 0 ] && [ "$attempt" -ge "$MERGE_POLL_ATTEMPTS" ]; }; then
      break
    fi
    info "admin-merge: … MERGE-REF wait: GitHub is still computing mergeability (mergeable=${state:-<empty>}; ${waited}s of the ${MERGE_REF_WAIT}s window, attempt $attempt) — waiting."
    adv=$((10#$step))
    [ "$adv" -gt $((MERGE_REF_WAIT - waited)) ] && adv=$((MERGE_REF_WAIT - waited))
    [ "$adv" -gt 0 ] && sleep "$adv"
    waited=$((waited + adv))
  done
  MERGE_REF_WAITED=$waited
  case "$state" in
    false)
      MERGE_REF_STATUS="conflicted"
      MERGE_REF_SUMMARY="CONFLICTED — GitHub cannot compute a merge of head into the base (mergeable=false), so refs/pull/$pr/merge is ABSENT or STALE: there is no evaluated tree to measure and no merge to make"
      return 0 ;;
    true)
      if [ -n "$MERGE_REF_SHA" ] && [ "$MERGE_REF_SHA" != "null" ]; then
        MERGE_REF_STATUS="ok"
        MERGE_REF_SUMMARY="merge ref refs/pull/$pr/merge = $MERGE_REF_SHA"
      else
        MERGE_REF_STATUS="absent"
        MERGE_REF_SUMMARY="ABSENT — mergeable=true but GitHub returned NO merge_commit_sha: the evaluated tree cannot be named yet"
      fi
      return 0 ;;
    *)
      MERGE_REF_STATUS="absent"
      MERGE_REF_SUMMARY="ABSENT — the MERGE-REF wait closed after ${MERGE_REF_WAITED}s (${attempt} attempt(s), window ${MERGE_REF_WAIT}s) and GitHub has not computed mergeability/merge ref for PR #$pr (last observed mergeable=${state:-<empty>}): no merge ref exists yet, so no CI has evaluated a merge of this PR"
      return 0 ;;
  esac
}

# resolve_merge_base_parent <merge-sha> — the FIRST PARENT of the PR's merge ref,
# i.e. the BASE commit that merge ref was computed against. Prints the sha, or
# EMPTY when it cannot be read (the caller fails closed: see step 4.7).
#
# WHY parents[0] IS THE BASE, AND THAT IT IS NOT ASSUMED. GitHub's
# `refs/pull/<N>/merge` is a merge commit whose parents are `[<base>, <head>]` —
# the job log in the header shows `Merge e55b123c… into 59a08fcd…`. Verified on
# live data 2026-09-22 across three repos (agent-infra, tortoise, premise-labs):
# on every open PR measured, `parents[1]` equalled the PR head sha and
# `parents[0]` equalled the base the merge ref was computed against — e.g.
# agent-infra #1153 merge d61a3411 parents [59a08fcd, cfad4a5f]; premise-labs #309
# merge 7b4356a4 parents [0fd0f714, 39ca23bd]; tortoise #4659 merge 6f0b119a
# parents [73acefdd, ad324fdc].
resolve_merge_base_parent() {
  local sha="$1" slug
  [ -n "$sha" ] || { printf ''; return 0; }
  if [ -n "${REPO:-}" ]; then slug="repos/$REPO"; else slug="repos/{owner}/{repo}"; fi
  # shellcheck disable=SC2086
  $GH api "$slug/commits/$sha" --jq '.parents[0].sha' 2>/dev/null || true
}

# run_failure_set <mode...> — invoke the shared parser, splitting its stdout
# into the set (stdout) while surfacing an EXTRACTION FAILURE as our own exit 1.
# An extraction error must never be read as "no unique failures" — that is the
# vacuous pass this rail exists to prevent.
run_failure_set() {
  # shellcheck disable=SC2086
  "$BASH" "$CFS" "$@"
}

# is_run_id — a GitHub run id is decimal. Used to accept the OPTIONAL
# `--print-bounds <run-id>` argument without swallowing the next flag.
is_run_id() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# is_full_sha — a pinned 40-hex commit OID, and NOT a branch/tag ref name. Used
# by the #3715 base reproduction: a REF resolved locally can be stale, and a
# stale base must never certify a failure as pre-existing.
is_full_sha() {
  case "${1:-}" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq 40 ]
}

# fail_safe_rerun_timeout <reason> — install the fail-safe and say WHY, loudly.
# NEVER small: the whole defect this replaces was a bound that was too tight.
fail_safe_rerun_timeout() {
  local reason="$1"
  DERIVED_RERUN_TIMEOUT="$FAILSAFE_RERUN_TIMEOUT"
  DERIVED_RERUN_SOURCE="fail-safe ${FAILSAFE_RERUN_TIMEOUT}s — derivation unavailable (${reason})"
  DERIVED_TABLE=""
  say_err "admin-merge: derivation unavailable (${reason}) — using the fail-safe ${FAILSAFE_RERUN_TIMEOUT}s (never a small bound)"
}

# fetch_run_jobs <run-id> → the raw jobs JSON on stdout. The API rather than
# `gh run view --json jobs`, because only the API carries `started_at` /
# `completed_at` per job. It goes through $GH so the harness can stub it — no new
# network path. `{owner}/{repo}` is gh's own placeholder, used only when --repo
# was not supplied. $GH is expanded UNQUOTED, like every other call site in this
# rail: the seam is a COMMAND (the presence check reads `${GH%% *}`), so
# `ADMIN_MERGE_GH="gh --hostname h"` must word-split into a command and its
# flags — a quoted "$GH" ran a file literally named `gh --hostname h`.
# shellcheck disable=SC2086
fetch_run_jobs() {
  local run_id="$1" slug
  if [ -n "$REPO" ]; then
    slug="repos/$REPO/actions/runs/$run_id/jobs?per_page=100"
  else
    slug="repos/{owner}/{repo}/actions/runs/$run_id/jobs?per_page=100"
  fi
  $GH api "$slug" --paginate
}

# ── THE GREEN POPULATION ────────────────────────────────────────────────
# D(s) is sampled from recent COMPLETED SUCCESSFUL jobs of the SAME lane —
# NEVER from the run about to be re-run. On that run the shard that failed was
# truncated by `pytest -x`, so its completed duration is a SHORT failure sample
# and `2 x` it can be SMALLER than the healthy re-run it must cover. That is the
# too-tight-bound defect this derivation replaces, and it fires in the COMMON
# case (the slow shard is the one that failed). `gh run list` is already on this
# rail's network surface (the FIRST-CHECKS wait uses it); the jobs fetch is the
# Jobs API fetch_run_jobs already uses.
GREEN_RUNS="${ADMIN_MERGE_GREEN_RUNS:-5}"

# ── LANE COVERAGE — the vacuity gate (#1319) ────────────────────────────
# `PR failing: 0 | main failing: 0` is an ABSENCE of a measurement, not a clean
# one. Those two zeros mean "the lanes were green" ONLY if both sides ran the
# SAME lane. On 2026-09-21 the rail printed exactly this line and merged tortoise
# #4263, whose tier-2 PR lane had SKIPPED shards main's push lane runs — so the
# failure lived in a shard the PR never executed, could appear in NEITHER
# collected set, and the merge reddened main's required check for the whole fleet
# (tortoise #4457). An absent measurement is a BLOCK everywhere else in this
# framework; it is one here too. The vacuous pass is therefore REFUSED unless the
# PR side demonstrably EXECUTED every test shard main's lane EXECUTED — and it
# fails CLOSED: a side whose shard list cannot be read is never read as "the
# same", because an unreadable list is not an empty one.
#
# The parity key is the SHARD NAME OBSERVED IN THE JOB LIST — the only lane
# identity GitHub exposes for a run. Two consequences, both stated rather than
# hidden:
#   * a job name is compared VERBATIM (only the reusable-workflow caller prefix
#     is stripped). The re-run derivation deliberately reduces a name to its
#     FIRST matrix axis so it can group shards across runs; parity must NOT —
#     `test (a, docker)` and `test (a, embedded)` are DIFFERENT lanes, and
#     collapsing them is precisely the surface-blindness this gate removes.
#   * a repo that varies the TEST SELECTION *within* one shard name (files
#     chosen per-diff inside `test (a)`) is outside what a job list can show.
#     That residual is #1319's option-3 shape (a selection attestation) and is
#     DECLARED and TRACKED as agent-infra #1350 — not a silent gap.
#   * the parity key is ONE job-name FAMILY, selected by $LANE_JOB_PREFIX. A job
#     outside the prefix LEAVES the comparison, so narrowing the prefix to
#     silence a refusal removes that family from the gate — which is why the
#     refusal names the prefix and the evidence states it.
#   * a comparison can only be as complete as the window it samples. Both sides
#     are read over the SAME window: the PR's lane runs for the head, main's last
#     $MAIN_RUNS lane runs. A shard main executed only OUTSIDE that window is
#     unobserved. Sampling FEWER runs than the baseline window was a cycle-1
#     fail-open (a shard present only in an older run vanished from the
#     reference), so there is no independent sampling cap any more — instead the
#     window itself is BOUNDED and validated (--main-runs, $MAIN_RUNS_MAX).
#     A run that did not finish a measurement must not END the search (#4844). A
#     push burst cancels its own predecessors, and a cancelled run is `completed` —
#     terminal, but measured nothing; charging the operator's window for it pushed
#     the last usable reference out of a window they asked for. It is still
#     CONSULTED (a cancelled run may have executed shards before it was cancelled,
#     and dropping those would SHRINK the reference — the #1319 fail-open), and the
#     listing widens while the window holds no shard in the parity FAMILY
#     (bounded by $MAIN_RUNS_MAX). The evidence SAYS SO — a reference drawn from a
#     wider window than requested is disclosed, never implied. DECLARED RESIDUAL: a run still IN FLIGHT is not
#     consulted, so a shard such a run has ALREADY executed is unobserved until it
#     concludes. Consulting a still-changing job list instead would make main's
#     mid-flight lane block every merge — the failure this change removes.
#   * the family must actually MEASURE something. A prefix is a family selector,
#     not a family EXCLUDER: `ADMIN_MERGE_LANE_JOB_PREFIX=c` matches `changes`
#     and would compare the workflow's bookkeeping while main's `test-slow (a)`
#     sits outside the gate. A family whose every member is a LIFECYCLE job is
#     refused ($LANE_LIFECYCLE_JOBS) — the knob exists for test shards named
#     unexpectedly, never for excluding the test family (cycle-2 review).
LANE_JOB_PREFIX="${ADMIN_MERGE_LANE_JOB_PREFIX:-test}"
# The workflow LIFECYCLE vocabulary: job names that exist on EVERY run and
# exercise no test. A parity family consisting only of these measured nothing, so
# it is refused rather than certified. Kept deliberately short and unambiguous —
# names that could plausibly BE a test shard (`verify`, `lint`, `typecheck`) are
# NOT listed: over-listing would refuse a legitimate family, and disclosure (the
# evidence names the family) already makes an odd one legible.
LANE_LIFECYCLE_JOBS="changes
python-ci-gate
manifest-integrity
surface-guard
canary-streak
drift-check
setup-suite
actionlint-gate"
# require (default) | declared-off. BOTH refuse a vacuous comparison without
# positive lane parity; `declared-off` exists ONLY to name that refusal precisely.
# It was the audited escape for a repo whose PR lane legitimately CANNOT run a
# shard main's push lane runs (a trigger-split repo — agent-infra itself: main's
# push calls the reusable python-ci.yml and no PR lane does; see #1349), but it
# certified evidence the gate refuses (#1439): a vacuous body needs the positive
# `lane parity: PR ⊇ main` line, which a comparison that established no parity
# cannot honestly state. Rather than post evidence the next layer refuses, the rail
# stops here and names AGENT_ADMIN_MERGE_OVERRIDE=1 — the route that bypasses the
# certificate instead of faking one. There is no silent third value: any other
# value is refused at startup.
LANE_PARITY_MODE="${ADMIN_MERGE_LANE_PARITY:-require}"

# green_run_ids — recent COMPLETED SUCCESSFUL run ids for the selected lane, one
# per line. `--any-workflow` is a PARSER flag, not a `gh run list` flag, so it is
# deliberately NOT forwarded (real gh rejects it, and `2>/dev/null || true` would
# hide that — the WAIT-vs-STALLED diagnostic would be silently dead).
green_run_ids() {
  local args=()
  [ -n "${REPO:-}" ] && args+=(--repo "$REPO")
  if [ "${ANY_WORKFLOW:-0}" -ne 1 ] && [ -n "${WORKFLOW:-}" ]; then
    args+=(--workflow "$WORKFLOW")
  fi
  # shellcheck disable=SC2086
  $GH run list --status success --limit "$GREEN_RUNS" \
    ${args[@]+"${args[@]}"} \
    --json databaseId --jq '.[].databaseId' 2>/dev/null || true
}

# lane_run_ids <flag> <value> <limit> — the side's lane runs on stdout as
# `<status>\t<conclusion>\t<sha>:<id>` (LANE_RUN_JQ interpolates headSha; the
# suite's fixtures serve the same shape, and every consumer takes `${line##*:}`,
# so both read identically). ONLY gh-native flags are forwarded: the parser's
# `--any-workflow` opt-out is NOT a `gh run list` flag, real gh rejects it, and
# forwarding it would silently empty every lane query and take the coverage gate
# down with it. The gh EXIT STATUS is returned, never swallowed: an auth/network
# failure must read as "could not list", not as "no runs" — those have opposite
# remedies, and reading the first as the second charges the PR for the outage.
lane_run_ids() {
  local flag="$1" value="$2" limit="$3" args=()
  [ -n "${REPO:-}" ] && args+=(--repo "$REPO")
  if [ "${ANY_WORKFLOW:-0}" -ne 1 ] && [ -n "${WORKFLOW:-}" ]; then
    args+=(--workflow "$WORKFLOW")
  fi
  # shellcheck disable=SC2086
  $GH run list "$flag" "$value" --limit "$limit" \
    ${args[@]+"${args[@]}"} \
    --json databaseId,status,conclusion,headSha --jq "$LANE_RUN_JQ" 2>/dev/null
}

# lane_count <file> — how many REAL shard names a shard-set file holds. NOT
# `wc -l` and NOT `[ -s ]`: a set with no names must count ZERO, and the two
# failure modes that make a non-empty file hold no names (a stray blank line, a
# whitespace-only line) must not read as one shard. This is the difference
# between "no shard was observed" and "one shard was observed" — the whole gate
# turns on it (#1319 cycle-1 review: a blank line certified an EMPTY lane).
lane_count() {
  local n
  n="$(grep -c '[^[:space:]]' "$1" 2>/dev/null)"
  printf '%s' "${n:-0}"
}

# lane_job_sample <all-names-file> [<max>] — a bounded, ` | `-separated rendering
# of the executed job names a lane window carried. This is what lets a family
# refusal NAME the names it saw (#7734): the COUNT alone cannot distinguish "the
# shards are named differently" (remedy: ADMIN_MERGE_LANE_JOB_PREFIX) from "the
# window held no run of a code lane at all" (remedy: name the lane with
# --workflow), and a refusal that cannot be acted on is the defect this exists to
# remove. The separator is ` | ` and NOT a comma because a GitHub job NAME may
# contain one — this repo's own vocabulary includes `test (a, docker)`, which a
# comma-joined sample would render as two names. Bounded because a wide window
# can carry dozens of names and the refusal is read by a human; the overflow is
# COUNTED rather than dropped silently. Prints nothing for an empty set, never a
# blank line (the empty-stream rule that `lane_count` and `lane_shards` obey).
lane_job_sample() {
  local f="$1" max="${2:-12}" total="" sample=""
  [ -f "$f" ] || return 0
  total="$(sort -u "$f" 2>/dev/null | grep -c '[^[:space:]]' || true)"; total="${total:-0}"
  [ "$total" -gt 0 ] || return 0
  sample="$(sort -u "$f" | grep '[^[:space:]]' | head -n "$max" \
    | awk 'BEGIN{ORS=""} {if (n++) printf " | "; printf "%s", $0}')"
  if [ "$total" -gt "$max" ]; then
    printf '%s (+%s more)' "$sample" "$((total - max))"
  else
    printf '%s' "$sample"
  fi
}

# lane_shards <run-id> <all-names-out> — the TEST shards this run EXECUTED, one
# name per line on stdout.
#   * TEST shard: the job name (caller prefix stripped) begins with
#     $LANE_JOB_PREFIX. The workflow's bookkeeping/gate jobs (`changes`,
#     `manifest-integrity`, `python-ci-gate`, `surface-guard`, `canary-streak`, …)
#     are not the lane's coverage and must not enter the comparison.
#   * EXECUTED: conclusion success|failure|timed_out — the SAME doctrine as the
#     parser's `tested` counter. A `skipped` shard exercised NOTHING, so it is
#     not coverage; that distinction IS the gate (a PR that skipped a shard main
#     ran has not measured what main measures).
# NO OUTPUT when the run executed no matching shard: an empty set must be an
# EMPTY stream, never a blank line. `printf '%s\n' ""` emits one newline, which
# makes the file non-empty, defeats every `[ -s ]` guard downstream, and matches
# the empty pattern under `grep -xF` — i.e. it turns "nothing was observed" into
# "no difference". Returns 1 when the job list cannot be READ (gh error, empty,
# unparsable): an unreadable shard list is NEVER an empty one.
#
# EVERY executed job name it saw is APPENDED to <all-names-out>, PREFIX-AGNOSTIC
# (a job the family filter excluded is still recorded). That union is what lets
# an empty reference say WHY it is empty (#4844): a window whose runs carry no
# executed job at all (purged, zero-job, not yet served) is a different
# condition, with a different remedy, from one whose jobs simply are not named
# `test*` — and the two sets alone cannot tell them apart. Passing `/dev/null`
# disables the record.
lane_shards() {
  local run_id="$1" allnames="${2:-/dev/null}" json_file out rc=0
  json_file="$(mktemp "${TMPDIR:-/tmp}/admin-merge-lane.XXXXXX")"
  if ! fetch_run_jobs "$run_id" > "$json_file" 2>/dev/null || [ ! -s "$json_file" ]; then
    rm -f "$json_file"
    return 1
  fi
  # shellcheck disable=SC2016
  out="$("$PYTHON_BIN" -c 'import json, sys
path, prefix, allpath = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(path, "r", encoding="utf-8", errors="replace").read()
dec, i, docs = json.JSONDecoder(), 0, []
while i < len(raw):
    while i < len(raw) and raw[i] in " \t\r\n":
        i += 1
    if i >= len(raw):
        break
    try:
        obj, i = dec.raw_decode(raw, i)
    except ValueError:
        raise SystemExit(2)
    docs.append(obj)
saw = False
names = set()
allnames = set()
for d in docs:
    if not isinstance(d, dict) or not isinstance(d.get("jobs"), list):
        continue
    saw = True
    for j in d["jobs"]:
        if not isinstance(j, dict):
            continue
        if (j.get("conclusion") or "") not in ("success", "failure", "timed_out"):
            continue
        n = (j.get("name") or "").strip()
        if " / " in n:
            n = n.rsplit(" / ", 1)[1].strip()
        if n:
            allnames.add(n)
        if prefix and not n.startswith(prefix):
            continue
        if n:
            names.add(n)
if not saw:
    raise SystemExit(2)
if allpath != "/dev/null":
    with open(allpath, "a", encoding="utf-8") as fh:
        for n in sorted(allnames):
            fh.write(n + "\n")
for n in sorted(names):
    print(n)' "$json_file" "$LANE_JOB_PREFIX" "$allnames")" || rc=$?
  rm -f "$json_file"
  [ "$rc" -eq 0 ] || return 1
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
  return 0
}

# The two run-state predicates the pairing below turns on. They are DIFFERENT
# questions and the gate needs both (#4844):
#
#   lane_run_in_flight — is this run still RUNNING? Only a NAMED in-flight
#     spelling counts (see the allow-list note below). An in-flight run is NOT
#     CONSULTED — its job list is still changing, so the lane's shard set is not
#     settled (the declared residual above) — and it is counted, so a refusal can
#     say how much of the window was mid-run.
#
#   lane_run_measured — did this run FINISH a measurement? A `completed` run may
#     still be `cancelled`, `skipped`, `stale`, `neutral` or `startup_failure`;
#     those measured nothing, and a push burst leaves a window FULL of them (each
#     push cancels its predecessor, and a cancelled run is `completed`). It is
#     the parser's own vocabulary (`success|failure|timed_out` credit `tested`),
#     not a new one — and since #7734 it is a DIAGNOSTIC only: it is reported in
#     the refusal, and it no longer stops the widening.
#
# CONSULTING is therefore governed by the in-flight allow-list ALONE: a cancelled
# or otherwise unmeasured run is still consulted (it may have executed shards
# before it was cancelled, and dropping those would SHRINK the reference — the
# #1319 fail-open).
#
# A NON-FINISHED RUN IS TRUSTED TO BE IN FLIGHT ONLY FOR A NAMED SPELLING. The
# polarity is an ALLOW-list, the same one the check-run surface uses (#1353: as a
# deny-list, a spelling the rail had never seen read as non-red there). "Not a
# known in-flight status" is NOT evidence that nothing settled: if the run HAD
# finished, its shards belong in the reference, and skipping it would SHRINK it.
# An unknown status is therefore CONSULTED when its line addresses a run id, and
# REFUSED when it does not — never silently skipped.
IN_FLIGHT_RUN_STATUS=" queued in_progress waiting requested pending "
lane_run_in_flight() {
  case "$IN_FLIGHT_RUN_STATUS" in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
lane_run_measured() {
  [ "$1" = "completed" ] || return 1
  case "$2" in success|failure|timed_out) return 0 ;; *) return 1 ;; esac
}

# lane_shard_set <flag> <value> <list-limit> <out-file> — the union of EXECUTED
# test shards across the side's lane runs, for the SAME window the operator's
# comparison uses. There is deliberately NO independent sampling cap: sampling
# fewer runs than the window the baseline was drawn from lets a shard main
# executed go unobserved and certifies a PR that skipped it (cycle-1 review,
# reproduced). A run whose jobs cannot be read — or a run LISTING that fails —
# makes the WHOLE side unreadable (return 1): partial coverage silently read as
# full is the fail-open this gate prevents. No name is written for an empty
# shard set.
#
# #4844 — a terminal run that MEASURED NOTHING must not end the search.
#
#   * The id guard failed the WHOLE side for a line whose run could not be
#     addressed — including a run that had not finished. Refusing on a
#     not-yet-finished run blocked every merge for a reason unrelated to the PR,
#     and reading its still-changing job list instead would block every merge
#     while main's lane runs (the declared residual above). So the guard is now
#     POLARITY-AWARE: an unaddressable run that is NOT a named in-flight spelling
#     is a hard refusal (it may well be finished, and its shards would then be
#     lost); an unaddressable named-in-flight one is skipped and counted.
#   * `--limit` named a RAW window, so a push burst — each push cancelling its
#     predecessor, leaving `completed/cancelled` runs that are terminal but
#     MEASURED NOTHING — filled it and pushed the last usable reference OUT of
#     it. The gate then refused every PR, naming a shard family when the missing
#     thing was the reference. Now the listing WIDENS (doubling, bounded by
#     $MAIN_RUNS_MAX) while the window has yielded no FAMILY shard, so such a run
#     cannot end the search, and the loop stops on a family match, on the history
#     being exhausted, or at the bound. CONSULTATION is a SEPARATE question and
#     `lane_run_in_flight` is its ONLY filter: a terminal-but-unmeasured run is
#     still fully consulted (it may have executed shards before it was cancelled,
#     and skipping it would SHRINK the reference). The ordinary path is unchanged
#     — widening happens only where the old code refused.
#
#   * ⛔ `--main-runs` IS THE STARTING WIDTH, NOT THE STOPPING RULE, AND ONLY THREE
#     CONDITIONS STOP THE WIDENING (#7734). `--main-runs` USED to stop it too:
#     the loop broke as soon as `$limit` runs that had FINISHED A MEASUREMENT
#     were counted. Under `--any-workflow` that counter is not a statement about
#     the LANE at all — an `issue_comment` run of a reporting workflow is
#     `completed/success`, so it SPENT the budget while contributing no test
#     shard. Measured on the target repo (tortoise main, `--any-workflow`, the
#     rail's default `--main-runs 10`): the 10-run window carried 2 distinct
#     executed job names and the widened 20-run window 3, NONE of them `test*`,
#     so the widening stopped on the spent budget with the family still EMPTY and
#     refused with "the shard FAMILY selects nothing on main"; the SAME listing
#     read 40 runs wide carried 36 distinct names, 17 of them `test*`. The code
#     lane was one doubling away the whole time, and the refusal's remedy
#     (`ADMIN_MERGE_LANE_JOB_PREFIX`) could never have reached it. The loop now
#     stops ONLY on a family match, on the history being exhausted, or at
#     $MAIN_RUNS_MAX. The direction is fail-safe, and NOT because a wider window
#     is unconditionally stricter — the two sides differ, so say which. MAIN's
#     reference can only GROW, so the demanded set grows: strictly stricter. The
#     PR side's set grows too, which SHRINKS the reported gap (the looser
#     direction) — sound only because every run consulted on that side carries
#     THIS head's sha, so every name added was genuinely executed by the head in
#     question; the certificate's claim ("PR ⊆ main" is not the claim — "main's
#     shards ⊆ the PR's executed set" is) becomes more true, never less.
#
# The Jobs-API cost does NOT track the operator's window on the widening path,
# and that is a deliberate trade. A widened pass consults its whole listing, so
# the runs read CAN exceed $limit — and so can the measured runs counted — bounded
# by $MAIN_RUNS_MAX per side, which is the call budget, because every CONSULTED run
# costs one job-list read. Dropping the budget break means the widening is no
# longer stopped by the measurement count, so a window FULL of measuring,
# non-family runs continues to the bound — or to the end of the history, whichever
# comes first. That is not a new ceiling: an operator who passed `--main-runs 200`
# already pays it, and the all-non-measuring path already reached it under the old
# code (#4844's `vacuouswidenbound` pinned `--limit 200` before this change). It is
# paid only where the REQUESTED window carried no family shard — the same path on
# which the old code could refuse with a remedy the operator could not act on. The
# LANE_SET_* globals report what the window actually held — including a bounded
# SAMPLE of the executed job names, so a refusal can NAME what it saw instead of
# only what it did not (#7734).
lane_shard_set() {
  local flag="$1" value="$2" limit="$3" out="$4"
  local listing="$TMP/lane-runs.tmp" shards="$TMP/lane-shards.tmp"
  local consulted="$TMP/lane-consulted.tmp" allnames="$out.alljobs"
  local status conclusion id rc=0 listed parsed=0
  local raw="$limit" consulted_n=0 measured=0 nonmeas=0
  : > "$out"
  : > "$consulted"
  : > "$allnames"
  LANE_SET_LISTED=0; LANE_SET_WINDOW="$limit"; LANE_SET_CONSULTED=0
  LANE_SET_MEASURED=0; LANE_SET_NONMEASURING=0; LANE_SET_JOBS=0
  LANE_SET_JOB_SAMPLE=""; LANE_SET_EMPTY_STOP=""; LANE_SET_ALLNAMES=""
  while :; do
    if ! lane_run_ids "$flag" "$value" "$raw" > "$listing"; then
      say_err "admin-merge: ✗ could not list the lane runs for $flag $value — lane coverage unverifiable"
      return 1
    fi
    # EVERY non-blank line of the listing must be ACCOUNTED FOR. A listing that is
    # only PARTLY readable is unreadable, not a thinner lane (cycle-2 P1): a line
    # that does not parse into a run id used to be `continue`d away, which quietly
    # SHRANK the reference set — so a truncated listing read as "main ran fewer
    # shards" and the gate certified on it. The `|| [ -n "$status" ]` also keeps a
    # FINAL line with no trailing newline in scope instead of dropping it.
    #
    # #4844 keeps that invariant while removing the FALSE refusal: every non-blank
    # line increments $parsed exactly once — consulted, skipped as a NAMED in-flight
    # run, or re-listed from an earlier pass. The invariant that replaces "fail on
    # any line we cannot address" is "fail on every unaddressable line EXCEPT a
    # named in-flight one" — that single skip is the declared residual above, not a
    # claim that the skipped run contributed nothing.
    listed="$(grep -c '[^[:space:]]' "$listing" 2>/dev/null || true)"; listed="${listed:-0}"
    parsed=0; consulted_n=0; measured=0; nonmeas=0
    while IFS=$'\t' read -r status conclusion id || [ -n "${status:-}" ]; do
      [ -n "$status" ] || continue
      parsed=$((parsed + 1))
      id="${id##*:}"
      if [ -z "$id" ]; then
        if lane_run_in_flight "$status"; then
          nonmeas=$((nonmeas + 1))
          continue
        fi
        say_err "admin-merge: ✗ unparsable lane-run listing line ('${status}') for $flag $value — '${status}' is not a named in-flight status and the line addresses no run id, so the run's shard list cannot be read; lane coverage unverifiable"
        return 1
      fi
      if lane_run_in_flight "$status"; then
        # In flight: not read at all (the declared residual above). Counted so the
        # refusal can say how much of the window was mid-run rather than implying
        # the lane was empty.
        nonmeas=$((nonmeas + 1))
        continue
      fi
      consulted_n=$((consulted_n + 1))
      lane_run_measured "$status" "$conclusion" && measured=$((measured + 1))
      grep -qxF "$id" "$consulted" 2>/dev/null && continue
      printf '%s\n' "$id" >> "$consulted"
      rc=0
      lane_shards "$id" "$allnames" > "$shards" || rc=$?
      if [ "$rc" -ne 0 ]; then
        say_err "admin-merge: ✗ could not read the job list of lane run $id — lane coverage unverifiable"
        return 1
      fi
      if [ -s "$shards" ]; then cat "$shards" >> "$out"; fi
    done < "$listing"
    if [ "$parsed" -ne "$listed" ]; then
      say_err "admin-merge: ✗ the lane-run listing for $flag $value did not parse in full ($parsed of $listed lines) — lane coverage unverifiable"
      return 1
    fi
    LANE_SET_LISTED="$listed"
    # The window the gate ACTUALLY read: a listing SHORTER than the request (the
    # branch has fewer runs than N) must not be reported as the requested width —
    # this number is what the operator audits and what the widening disclosure is
    # decided on.
    LANE_SET_WINDOW="$raw"
    [ "$listed" -lt "$raw" ] && LANE_SET_WINDOW="$listed"
    LANE_SET_CONSULTED="$consulted_n"; LANE_SET_MEASURED="$measured"
    LANE_SET_NONMEASURING="$nonmeas"
    # Widen while the window has produced no FAMILY shard: an empty reference is
    # the one condition more runs can repair. The three stops below are the ONLY
    # ones — see the `--main-runs` bullet above `lane_shard_set` for why the
    # `measured >= limit` budget break that used to sit among them is gone, and
    # for why dropping it is fail-safe rather than permissive (#7734).
    [ -s "$out" ] && break
    [ "$listed" -lt "$raw" ] && { LANE_SET_EMPTY_STOP="history"; break; }
    [ "$raw" -ge "$MAIN_RUNS_MAX" ] && { LANE_SET_EMPTY_STOP="bound"; break; }
    raw=$((raw * 2))
    [ "$raw" -gt "$MAIN_RUNS_MAX" ] && raw="$MAIN_RUNS_MAX"
  done
  # The distinct executed job names the window ACTUALLY carried, over ALL passes
  # (the accumulator is a union, so a run consulted in an earlier pass is not
  # double-counted and not dropped).
  LANE_SET_JOBS="$(sort -u "$allnames" 2>/dev/null | grep -c '[^[:space:]]' || true)"
  LANE_SET_JOBS="${LANE_SET_JOBS:-0}"
  # A bounded SAMPLE of those names, rendered for the refusal (#7734). The count
  # alone cannot tell "this lane's shards are named differently" from "no run of a
  # code lane was in the window at all", and those two have opposite remedies —
  # so the refusal NAMES what it saw. Read BEFORE the accumulator is removed.
  LANE_SET_JOB_SAMPLE="$(lane_job_sample "$allnames")"
  # #2842: the RAW executed names of this side, not only the rendered sample. A
  # refusal whose remedy is "set the prefix" has to be able to name a prefix that
  # WORKS for the names this window carried — and the sample is a RENDERING
  # (` | `-joined, truncated, with a `(+N more)` tail), so parsing a rendering
  # back is not a datum. Read BEFORE the accumulator is removed.
  LANE_SET_ALLNAMES="$(sort -u "$allnames" 2>/dev/null | grep '[^[:space:]]' || true)"
  rm -f "$allnames"
  # Drop any blank line before the union: a single blank entry would be counted
  # as a shard by `wc -l` and would match the empty pattern under `grep -xF`.
  if [ -s "$out" ]; then
    grep '[^[:space:]]' "$out" > "$TMP/lane-set.tmp" || true
    mv "$TMP/lane-set.tmp" "$out"
    sort -u -o "$out" "$out"
  fi
  return 0
}

# lane_has_test_shard <file> — does this shard set hold any name that is NOT a
# workflow LIFECYCLE job? A family whose every member is bookkeeping measured no
# test, so certifying on it is certifying on nothing (cycle-2 P1).
lane_has_test_shard() {
  local f="$1" remaining=""
  [ -s "$f" ] || return 1
  printf '%s\n' "$LANE_LIFECYCLE_JOBS" > "$TMP/lane-lifecycle.txt"
  # NO PIPE. A quiet grep downstream of any still-writing producer is the SIGPIPE
  # class of #864, not only the builtin-writer form of #841: grep exits at its FIRST
  # match, the upstream grep takes SIGPIPE (141), and under `pipefail` that status
  # wins — so this function returns NON-ZERO for a set that HAS a non-lifecycle name,
  # and the caller at the lane-parity check reads non-zero as "only lifecycle jobs"
  # and returns 2, refusing the merge: a FALSE BLOCK (fail-closed), pinned by
  # tests/admin-merge/run.sh "a parity family of ONLY lifecycle jobs → BLOCK".
  # Capture first, then classify in the SHELL: a `case` needs no second process at
  # all — there is no pipe to lose a status to, which is the same remedy the
  # head/verdict resolvers above use.
  remaining="$(grep -vxF -f "$TMP/lane-lifecycle.txt" "$f" || true)"
  case "$remaining" in
    *[![:space:]]*) return 0 ;;
  esac
  return 1
}

# ── #6928: A SHARD THE DIFF SELECTOR *DECLINED* IS NOT A COVERAGE GAP ─────
# The lane-parity gate demands the PR lane execute every shard main's lane
# executed. For a repo whose PR lane is DIFF-SELECTED that is unsatisfiable BY
# CONSTRUCTION: the target's `tools/ci_selection.py` turns `slow_run` /
# `carve_out_run` off for a docs-only diff, so the `test-slow (a)`,
# `test-slow (b)` and `test-carve-out` jobs skip on their own `if:` triggers,
# while main is ALWAYS FULL (`_full_selection()` runs the whole matrix plus both
# diff-gated legs, so the trunk can never lose that coverage). Every docs-only /
# website-only PR was therefore unlandable behind a refusal no re-run can clear
# (measured: 0 docs-only commits in the last 60 of tortoise main). The blast
# radius is docs/website-only diffs — NOT `config/**`: the selector's own comment
# says `config/* is NOT a docs-only path`, and measured at tortoise 6bd2f41 a
# `config/ci-surfaces.yml` diff selects BOTH legs (`slow_run=true,
# carve_out_run=true`), so a config-only PR never had this shape.
#
# THE RULE IS FORGIVENESS, NOT EXEMPTION — and it is the CI's own rule, pinned by
# tortoise's `tests/test_ci_selection.py`: "a `skipped` leg is forgiven only when
# the selector DECLINED it". This removes ONLY the shards the target's selector
# declined for THIS head's diff; every other shard main executed is still
# demanded, which is why a non-declined leg deliberately carries no event filter.
#
# lane_declined_shards <head> <out-file> — ask the TARGET repo's selector which
# of the two diff-gated legs it declined for <head>'s diff, and write those shard
# names (one per line) to <out-file>. Returns 0 when the selector ANSWERED (the
# file may then be empty), non-zero when it did not, setting LANE_DECLINED_REASON.
#
# ⛔ FAIL CLOSED. No runnable ≥3.12 interpreter, an unreadable changed-file list,
# a selector that could not be FETCHED AT THIS HEAD, a non-zero exit, empty output,
# or an answer that does not carry BOTH booleans AS BOOLEANS forgives NOTHING, and
# the caller then refuses the raw gap exactly as it does today. A missing selector
# answer is NOT a declined leg: "I could not ask" is the opposite of "the selector
# declined it", and a PARTIAL answer is treated as no answer, because a leg whose
# boolean is missing was never shown to be declined.
#
# ── #6928 P1-1: WHICH INTERPRETER RUNS THE SELECTOR ───────────────────────
# The rail's own `$PYTHON_BIN` is whatever `python3` is first on PATH. On this
# fleet that is 3.9.6, and a DIFF-GATED target's selector REFUSES an interpreter
# below 3.12 at its own module level (tortoise `tools/ci_selection.py:44-49`
# exits 1 with "requires Python >= 3.12 … run it as `uv run python …`"). Its
# workflow only succeeds because `actions/setup-python` pins 3.12; the rail pins
# nothing, so running the selector under `$PYTHON_BIN` made the whole forgiveness
# path refuse on the INTERPRETER — safe, and useless (measured on this machine:
# the rail exited 1 with "the target-repo diff selector failed (exit 1 …)").
#
# `lane_selector_python` resolves one and sets the global `LANE_SELECTOR_PYTHON`,
# in this order:
#   1. `$ADMIN_MERGE_SELECTOR_PYTHON` — an explicit override. When set it is the
#      WHOLE answer: a set-but-unusable override fails closed rather than silently
#      falling through to a different interpreter, so an operator who named one is
#      TOLD it was wrong. (This is also the suite's hermetic test seam.)
#   2. `$PWD/.venv/bin/python3` — a project venv at the rail's INVOCATION
#      directory, where a repo that runs `uv run python tools/ci_selection.py`
#      keeps its 3.12. ⛔ `$PWD` is the directory the RAIL was invoked from, NOT
#      the `--repo` target's checkout (the rail is routinely invoked from
#      elsewhere). That is safe precisely because this candidate is used ONLY as
#      an INTERPRETER, never as evidence about the head: the selector ENGINE and
#      the RULES it reads are both fetched PINNED TO THE HEAD (see below), so
#      which checkout `$PWD` happens to be cannot influence the answer.
#   3. `python3.12`, then `python3.13` — an explicitly versioned interpreter.
#   4. `python3` — ONLY when it actually reports ≥3.12 (it usually does not).
# EVERY candidate must PROVE ≥3.12 by EXECUTING and asking the interpreter ITSELF
# for `sys.version_info` — never by parsing a `--version` banner, which a wrapper
# or shim prints and which names a version the process need not be. If none
# qualifies the answer is UNAVAILABLE and the reason NAMES the ≥3.12 requirement,
# so the operator is told what to install rather than merely that a step failed.
LANE_SELECTOR_PYTHON=""
lane_selector_python_ok() {
  local cand="${1:-}"
  [ -n "$cand" ] || return 1
  if [ ! -x "$cand" ]; then
    command -v "$cand" >/dev/null 2>&1 || return 1
  fi
  "$cand" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' \
    >/dev/null 2>&1
}
lane_selector_python() {
  LANE_SELECTOR_PYTHON=""
  local cand
  if [ -n "${ADMIN_MERGE_SELECTOR_PYTHON:-}" ]; then
    if lane_selector_python_ok "$ADMIN_MERGE_SELECTOR_PYTHON"; then
      LANE_SELECTOR_PYTHON="$ADMIN_MERGE_SELECTOR_PYTHON"
      return 0
    fi
    return 1
  fi
  for cand in "$PWD/.venv/bin/python3" python3.12 python3.13 python3; do
    if lane_selector_python_ok "$cand"; then
      LANE_SELECTOR_PYTHON="$cand"
      return 0
    fi
  done
  return 1
}

lane_declined_shards() {
  local head="$1" out="$2"
  local slug changed changed_names json verdict rc=0 sp cp
  local selector_root selector_body manifest_body
  LANE_DECLINED_REASON=""
  LANE_PARITY_SELECTOR_VERDICT=""
  : > "$out"
  # 1. An interpreter that can actually run the target's selector (P1-1).
  if ! lane_selector_python; then
    if [ -n "${ADMIN_MERGE_SELECTOR_PYTHON:-}" ]; then
      LANE_DECLINED_REASON="the interpreter named by ADMIN_MERGE_SELECTOR_PYTHON ($ADMIN_MERGE_SELECTOR_PYTHON) is not a Python >= 3.12, which the target repo's diff selector requires — so the selector cannot be run"
    else
      LANE_DECLINED_REASON="no Python >= 3.12 interpreter was found for the target repo's diff selector, which refuses to run below 3.12 (tried ADMIN_MERGE_SELECTOR_PYTHON, ./.venv/bin/python3, python3.12, python3.13, python3)"
    fi
    return 1
  fi
  # The changed-file list is fetched HERE rather than read from
  # WF_PR_CHANGED_PATHS. That global is populated only as a LAZY SIDE EFFECT of
  # the base-surface probe's workflow fetch (#1542), so it is empty whenever no
  # base red needed a PR-evaluability verdict — the common case — and reading it
  # would then fail closed on most merges for a reason unrelated to the diff.
  # This fetch is written in that site's own style.
  if [ -n "${REPO:-}" ]; then slug="repos/$REPO"; else slug="repos/{owner}/{repo}"; fi
  changed="$($GH api "$slug/pulls/$PR/files?per_page=100" --paginate --jq '.[].filename' 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    LANE_DECLINED_REASON="the PR's changed-file list could not be read ($slug/pulls/$PR/files)"
    return 1
  fi
  # AN EMPTY LIST IS UNAVAILABLE — and #6928 P2: so is a WHITESPACE-ONLY one.
  # `[ -z ]` catches only a zero-byte answer; a SUCCESSFUL read whose body holds
  # no filename but some spaces passes it, and the real tortoise selector MEASURED
  # on such input answers `slow_run=false carve_out_run=false` — i.e. it would
  # forgive ALL THREE diff-gated legs on a read that returned no filename at all.
  # A PR always has at least one changed file, so "no real filename" is an
  # unavailable answer, never "no files changed". This is `lane_count`'s own
  # idiom (a set with no names counts ZERO) AND its `${n:-0}` normalisation,
  # applied to a string: `grep -c` prints `0` on no-match and the preceding rc
  # check already excludes the empty case, so this read is DEFENSIVE — but the
  # direction it protects is the fail-open one, so it is guarded rather than
  # reasoned about.
  changed_names="$(printf '%s' "$changed" | grep -c '[^[:space:]]')"
  if [ "${changed_names:-0}" -eq 0 ]; then
    LANE_DECLINED_REASON="the PR's changed-file list came back EMPTY ($slug/pulls/$PR/files) — an unavailable answer, not a diff with no files"
    return 1
  fi
  # 2. THE SELECTOR AND ITS MANIFEST, FETCHED PINNED TO THIS HEAD (#6928 P1-2).
  # Reading the selector from the CALLER'S working tree — which is what this did —
  # has no revision pin and no check that the checkout is the `--repo` target at
  # this head: it would forgive against rules that never governed this head, and a
  # same-contract copy in a different repo would be believed. The codebase's own
  # precedent is `workflow_pr_evaluable`, which pins its file BY REF THROUGH THE
  # API for exactly this fail-open. The manifest is fetched at the same ref for
  # the same reason: the selector derives its data root from `__file__` and reads
  # `config/ci-surfaces.yml` from there, so pinning the engine while reading the
  # rules off the local disk would leave the same hole one level down. The only
  # thing `$PWD` contributes here is an INTERPRETER (candidate 2 above); the
  # selector ENGINE and its RULES both come from these head-pinned fetches, so a
  # `$PWD` that is not the target checkout — even one that is an unrelated repo —
  # cannot influence the selector's answer.
  selector_body="$($GH api "$slug/contents/tools/ci_selection.py" -X GET -f "ref=$head" \
                     -H 'Accept: application/vnd.github.raw' 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$selector_body" ]; then
    LANE_DECLINED_REASON="the target repo's diff selector could not be FETCHED AT THIS HEAD ($slug/contents/tools/ci_selection.py?ref=$head) — a selector read from the caller's tree is not evidence about this head"
    return 1
  fi
  manifest_body="$($GH api "$slug/contents/config/ci-surfaces.yml" -X GET -f "ref=$head" \
                     -H 'Accept: application/vnd.github.raw' 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$manifest_body" ]; then
    LANE_DECLINED_REASON="the target repo's CI surface manifest could not be FETCHED AT THIS HEAD ($slug/contents/config/ci-surfaces.yml?ref=$head), which its diff selector reads"
    return 1
  fi
  # The selector runs EXACTLY as the workflow runs it
  # (`.github/workflows/python-ci.yml:234`):
  #   printf '%s\n' "$CHANGED" | python3 tools/ci_selection.py --changed-files - --event pull_request
  # It resolves its repo root from `__file__` (`REPO = Path(__file__).resolve().parent.parent`),
  # so the fetched pair is laid out in the shape the selector expects, under the
  # rail's own TMP — the caller's tree is never touched.
  selector_root="$(mktemp -d "${TMP:-/tmp}/admin-merge-selector.XXXXXX" 2>/dev/null || true)"
  if [ -z "$selector_root" ] || ! mkdir -p "$selector_root/tools" "$selector_root/config"; then
    LANE_DECLINED_REASON="could not stage the fetched diff selector for execution (no writable temp directory)"
    return 1
  fi
  if ! printf '%s\n' "$selector_body" > "$selector_root/tools/ci_selection.py" \
     || ! printf '%s\n' "$manifest_body" > "$selector_root/config/ci-surfaces.yml"; then
    LANE_DECLINED_REASON="could not stage the fetched diff selector for execution (write failed under ${TMP:-/tmp})"
    return 1
  fi
  json="$(printf '%s\n' "$changed" | "$LANE_SELECTOR_PYTHON" \
            "$selector_root/tools/ci_selection.py" --changed-files - --event pull_request 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    LANE_DECLINED_REASON="the target repo's diff selector failed (exit $rc running it under $LANE_SELECTOR_PYTHON)"
    return 1
  fi
  if [ -z "$json" ]; then
    LANE_DECLINED_REASON="the target repo's diff selector emitted nothing ($selector_root/tools/ci_selection.py)"
    return 1
  fi
  # BOTH booleans, as BOOLEANS. `json.loads` accepts anything, so the isinstance
  # check is what makes a partial or mistyped answer a REFUSAL rather than a
  # silent "true": a MISSING key would otherwise read as falsy and FORGIVE the
  # leg — the one direction that must never happen.
  verdict="$(printf '%s' "$json" | "$PYTHON_BIN" -c '
import json, sys
try:
    d = json.load(sys.stdin)
    s = d.get("slow_run"); c = d.get("carve_out_run")
    ok = isinstance(s, bool) and isinstance(c, bool)
except Exception:
    ok = False
if not ok:
    sys.exit(1)
print("true" if s else "false")
print("true" if c else "false")
' 2>/dev/null)"
  rc=$?
  sp="$(printf '%s\n' "$verdict" | sed -n '1p')"
  cp="$(printf '%s\n' "$verdict" | sed -n '2p')"
  if [ "$rc" -ne 0 ] || [ -z "$verdict" ] \
     || { [ "$sp" != "true" ] && [ "$sp" != "false" ]; } \
     || { [ "$cp" != "true" ] && [ "$cp" != "false" ]; }; then
    LANE_DECLINED_REASON="the target repo's diff selector's answer carried no parseable slow_run/carve_out_run"
    return 1
  fi
  LANE_PARITY_SELECTOR_VERDICT="slow_run=$sp, carve_out_run=$cp"
  # The workflow's OWN shard names for the two diff-gated legs. Forgiving by EXACT
  # name (never by pattern) keeps the rule narrow: a repo whose legs are named
  # differently simply is not forgiven, which is the fail-closed direction.
  if [ "$sp" = "false" ]; then
    printf '%s\n' 'test-slow (a)' 'test-slow (b)' >> "$out"
  fi
  if [ "$cp" = "false" ]; then
    # The carve-out job's name template is `test-carve-out${{ matrix.suffix }}`
    # (tortoise `.github/workflows/python-ci.yml`), and shard 0's suffix is EMPTY,
    # so ONE declined leg yields THREE job names. Listing only the bare one forgave
    # a third of the leg and left the other two permanently demanded (#1584). The
    # slow leg above lists both of its expansions for the same reason.
    printf '%s\n' 'test-carve-out' 'test-carve-out (b)' 'test-carve-out (c)' >> "$out"
  fi
  return 0
}

# lane_prefix_candidates <names-file> <out-file> [<max>] — the exact, copy-pasteable
# retry values for a parity FAMILY that selected nothing (#2842).
#
# The refusal has named ADMIN_MERGE_LANE_JOB_PREFIX since #4844 and the executed job
# names the window carried since #7734 — and a lane still paid a whole extra cycle,
# because a knob plus a name list leaves the operator to GUESS the value and the
# obvious guess is wrong: the family match is a case-SENSITIVE prefix (`lane_shards`
# compares with Python `startswith`), so the lowercase `unit` the rail's own example
# teaches selects NOTHING in a repo whose job is `Unit tests`. The operator follows
# the printed remedy, is refused a second time, and the only remaining door the same
# message names is the override — which is the steer #2842 reports.
#
# So this DERIVES the value instead of describing it. A job NAME is trivially a
# prefix that selects itself (`'Unit tests'.startswith('Unit tests')`), so the
# suggestion cannot be wrong about the name it came from; WHICH name is the test
# shard stays the operator's decision, and the evidence states the family, so a
# narrowed family is disclosed rather than silent. Auto-deriving the family instead
# (the issue's first suggestion) is deliberately NOT done here: the rail cannot know
# which executed names are test shards, and a family derived from the WRONG names
# would quietly take a real shard out of the comparison — a fail-open in the gate
# this file exists to be.
#
# LIFECYCLE names are excluded: `lane_has_test_shard` refuses a family made only of
# bookkeeping jobs, so suggesting one would hand the operator a value that lands on a
# DIFFERENT refusal. Blank lines are dropped for the same reason `lane_count` drops
# them (a blank entry is a name that measures nothing), and the overflow is COUNTED,
# never dropped silently.
lane_prefix_candidates() {
  local f="$1" out="$2" max="${3:-6}"
  # The scan file MUST NOT be the caller's output path: the `rm -f` below would
  # then delete the very answer this function just wrote — which is exactly the bug
  # a first run of it had (the file was created, filled and removed in one call).
  local lifecycle="$TMP/lane-lifecycle-cand.txt" list="$TMP/lane-candidate-scan.tmp"
  local total="" name="" quoted=""
  : > "$out"
  [ -f "$f" ] || return 0
  printf '%s\n' "$LANE_LIFECYCLE_JOBS" > "$lifecycle"
  # NO `grep -c` UPSTREAM OF A QUIET CONSUMER (#864): every stage here reads its
  # input to EOF, so no writer takes SIGPIPE under `pipefail`.
  grep '[^[:space:]]' "$f" 2>/dev/null | sort -u | grep -vxF -f "$lifecycle" > "$list" || true
  total="$(grep -c '[^[:space:]]' "$list" 2>/dev/null || true)"; total="${total:-0}"
  [ "$total" -gt 0 ] || { rm -f "$list"; return 0; }
  sed -n "1,${max}p" "$list" | {
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      # POSIX single-quote escaping, so a name holding a quote is still copy-pasteable.
      quoted="$(printf '%s' "$name" | sed "s/'/'\\\\''/g")"
      printf "ADMIN_MERGE_LANE_JOB_PREFIX='%s'\n" "$quoted"
    done
  } >> "$out"
  if [ "$total" -gt "$max" ]; then
    printf '(… +%s more executed job name(s) not listed here)\n' "$((total - max))" >> "$out"
  fi
  rm -f "$list"
  return 0
}

# lane_parity_check <head> <main-run-limit> — decide whether the two sides are
# comparable AT ALL, and leave both named shard sets behind so the evidence and
# the refusal can state the lanes instead of asserting a bare `0 | 0`.
# On every non-zero return it sets $LANE_PARITY_REASON to a one-line,
# operator-readable account of WHY. The caller must use it rather than infer: a
# note that reads "main showed 0 shard(s)" about a side that was never consulted
# is a claim about an absence, which is the defect this whole gate exists for.
#   0  parity holds — the PR executed every test shard main's lane executed.
#   1  parity FAILS   — a shard main executed was not executed by the PR.
#   2  NOT ESTABLISHED — a side's shard list could not be read or listed, or
#                        EITHER side observed no test shard at all (main's
#                        reference is unobserved, or the PR's set is empty because
#                        the prefix matches nothing it ran, or the "family" is
#                        only lifecycle jobs). Fail CLOSED: a comparison against
#                        an unobserved reference certifies nothing, and an empty
#                        set means EVERY shard is missing — never "no difference".
LANE_PARITY_REASON=""
# #2842: WHICH condition left the reference EMPTY, when that condition is not an
# unreadable list. The refusal used to assert ONE cause for every empty reference
# ("the shard lists are not readable"), which is FALSE — and misleading in a
# specific direction — when the job lists WERE readable and the family simply
# matched none of them: the operator is told the coverage was unmeasurable when in
# fact it was measured and MISNAMED.
#   "family"    — readable job lists, and none of the executed names matches the family
#   "lifecycle" — the family matches, but only workflow BOOKKEEPING jobs
#   ""          — no such claim holds (unreadable/unobserved reference), so the
#                 generic wording — which IS accurate there — is kept verbatim.
LANE_PARITY_EMPTY_KIND=""
# #6928: the diff-gated shards the target's selector DECLINED for this head, and
# the verdict it answered. Set by lane_parity_check on the forgiveness path; read
# by the evidence builder so a certified `PR ⊇ main` line is DISCLOSED as resting
# on the selector's own decision rather than standing as a bare assertion. Empty
# when nothing was forgiven.
LANE_PARITY_FORGIVEN=""
LANE_PARITY_SELECTOR_VERDICT=""
# The window MAIN's reference was actually drawn from (#4844). Set by
# lane_parity_check so the evidence can DISCLOSE a widened reference rather than
# let `--main-runs` describe a window the gate did not read. The reader defaults
# it (`:-0`); it is set on every path that reaches the evidence, which lies behind
# a rc==0 parity result.
lane_parity_check() {
  local head="$1" main_runs="$2" rc=0
  local LANE_PR_FROZEN="" LANE_MAIN_FROZEN="" LANE_DECLINED_FROZEN=""
  LANE_PARITY_REASON=""
  LANE_PARITY_EMPTY_KIND=""
  if [ -z "${TMP:-}" ] || [ ! -d "${TMP:-}" ]; then
    say_err "admin-merge: ✗ internal error — lane parity called without a TMP directory"
    LANE_PARITY_REASON="the rail's own working directory is missing"
    return 2
  fi
  : > "$TMP/lane-pr.txt"
  : > "$TMP/lane-main.txt"
  : > "$TMP/lane-missing.txt"
  # ── THE TWO REFERENCES MUST BE DISTINCT FILES THIS GATE CREATED (#1439) ────
  # Everything below, and the certificate itself, reads these two files, and this
  # function writes them. If one is a symlink/hard link onto the other (or onto
  # any other scratch file), the gate's OWN writes corrupt the references the
  # comparison is made of, and no comparison of the files can detect it. So state
  # the invariant instead of discovering it: both must be regular files, and they
  # must not be the same file.
  if [ -L "$TMP/lane-pr.txt" ] || [ -L "$TMP/lane-main.txt" ] \
     || [ "$TMP/lane-pr.txt" -ef "$TMP/lane-main.txt" ]; then
    say_err "admin-merge: ✗ the lane references are not two distinct regular files — lane coverage unverifiable (a scratch path is a symlink or is aliased onto another)"
    LANE_PARITY_REASON="the lane references are aliased onto each other, so this gate's own writes would corrupt what it compares"
    return 2
  fi
  if ! lane_shard_set --commit "$head" 100 "$TMP/lane-pr.txt"; then
    LANE_PARITY_REASON="the PR head's lane runs could not be listed or read"
    return 2
  fi
  # #2842: the PR window's RAW executed names, frozen here — the refusal that names
  # the prefix knob reads them when this head's family selected nothing of its own.
  printf '%s\n' "${LANE_SET_ALLNAMES:-}" > "$TMP/lane-pr-alljobs.txt"
  # ── FREEZE EACH REFERENCE AS SOON AS ITS OWN FETCH RETURNS (#1439) ──────────
  # freezing BOTH after both fetches is not enough, because a cross-alias makes the
  # second fetch OVERWRITE the first reference: with `lane-main.txt` a symlink to
  # `lane-pr.txt`, main's fetch (`: > "$out"` + append) truncates and refills the PR
  # file, so a freeze taken afterwards records MAIN's set as BOTH references — the
  # integrity check below then has nothing to catch, the subtraction compares main
  # with itself, and the rail certifies `PR ⊇ main` for a head that ran a fraction of
  # main's lane. Freezing each side the moment it is fetched keeps the two snapshots
  # the two different lanes, so any such overwrite shows up as a MOVED input.
  # (The identity check above catches the alias directly; this catches the class of
  # writes that arrive through any OTHER scratch name.)
  LANE_PR_FROZEN="$(cat "$TMP/lane-pr.txt")"
  if ! lane_shard_set --branch main "$main_runs" "$TMP/lane-main.txt"; then
    LANE_PARITY_REASON="main's lane runs could not be listed or read"
    return 2
  fi
  # #2842: main's RAW executed names, frozen for the refusal's derived retry value.
  # Read here, not later: the scratch dir is shared and a later write could alias it.
  printf '%s\n' "${LANE_SET_ALLNAMES:-}" > "$TMP/lane-main-alljobs.txt"
  LANE_MAIN_FROZEN="$(cat "$TMP/lane-main.txt")"
  # Capture MAIN's window accounting NOW: the LANE_SET_* globals are overwritten
  # by every lane_shard_set call, and the reason below is a claim about MAIN.
  local main_listed="$LANE_SET_LISTED" main_window="$LANE_SET_WINDOW"
  local main_consulted="$LANE_SET_CONSULTED" main_nonmeas="$LANE_SET_NONMEASURING"
  local main_measured="$LANE_SET_MEASURED"
  local main_jobs="$LANE_SET_JOBS"
  # #7734: WHY the widening stopped, and WHAT the window actually carried. Both
  # belong in the refusal — the count alone cannot be acted on, and "the family
  # is named differently" versus "no code-lane run was in this window" have
  # opposite remedies.
  local main_job_sample="$LANE_SET_JOB_SAMPLE" main_empty_stop="$LANE_SET_EMPTY_STOP"
  local main_stop_note=""
  case "$main_empty_stop" in
    history) main_stop_note="and the LANE's run history was read IN FULL (the listing returned fewer runs than were asked for) without finding one" ;;
    bound)
      # `--main-runs` may BE the bound, in which case no widening happened and a
      # note claiming one would be false — so the two cases are stated apart.
      if [ "$main_window" -gt "$MAIN_RUNS" ]; then
        main_stop_note="and the listing was widened to the policy bound of ${MAIN_RUNS_MAX} runs and STILL selected nothing"
      else
        main_stop_note="and the listing was read at the policy bound of ${MAIN_RUNS_MAX} runs — the requested width WAS the bound, so nothing was widened — and STILL selected nothing"
      fi ;;
    *)       main_stop_note="and no run in that window executed a job in the family" ;;
  esac
  LANE_PARITY_MAIN_WINDOW="$main_window"
  # Decide on NAMES, never on file size (see lane_count).
  if [ "$(lane_count "$TMP/lane-main.txt")" -eq 0 ]; then
    # #4844 — NAME THE CONDITION, NOT A NEIGHBOURING ONE. "no EXECUTED test shard
    # matching 'test*'" reads like a COVERAGE gap in the PR and sends the reader
    # after ADMIN_MERGE_LANE_JOB_PREFIX, when what is missing is the REFERENCE: no
    # completed run in the window EXECUTED a job, either because its job list is
    # unreadable (purged, zero-job, not yet served) or because no job it lists
    # carries an executed conclusion (skipped, cancelled, neutral, stale, …). A
    # lane that never TESTED main does not reach here
    # at all: step 2b blocks it first, which is why this branch does not offer
    # "retry once main's lane settles".
    # LANE_SET_JOBS is PREFIX-AGNOSTIC, so "no job list was readable at all" and
    # "job lists that do not match the family" are separable, and they have
    # different remedies: a stale/empty reference is a window or lane-selection
    # question; a non-matching family is a PREFIX question. The window actually
    # read is STATED either way, because "widened past --main-runs" is a fact the
    # operator must be able to audit.
    if [ "$main_jobs" -eq 0 ]; then
      LANE_PARITY_REASON="main's lane window yielded NO EXECUTED job — ${main_consulted} completed run(s) consulted (${main_measured} a finished measurement, $((main_consulted - main_measured)) that measured nothing) out of ${main_listed} listed over a ${main_window}-run window, ${main_nonmeas} of the listed runs not yet finished, ${main_stop_note}. An EXECUTED job is one whose conclusion is success, failure or timed_out, so either the completed runs hold no readable job list (purged, zero-job, or not yet served — check the lane selector: --workflow, or --any-workflow for a trigger-split repo) or none of the jobs they list carries one (skipped, cancelled, neutral, stale, …). Either way the REFERENCE is what is missing and the shard family '${LANE_JOB_PREFIX}*' selected nothing, so this is NOT a coverage gap in this PR"
    else
      # #2842: the lists WERE readable — this is a NAMING mismatch, and the refusal
      # must say so rather than borrow the unreadable-list wording above.
      LANE_PARITY_EMPTY_KIND="family"
      LANE_PARITY_REASON="main's lane runs executed ${main_jobs} distinct job name(s) across a ${main_window}-run window (${main_consulted} completed run(s) consulted, ${main_measured} a finished measurement, ${main_nonmeas} non-completed), ${main_stop_note}, but NONE is named '${LANE_JOB_PREFIX}*' — so the shard FAMILY selects nothing on main. The executed job name(s) this window DID carry were: ${main_job_sample:-(none)}. If this lane's test shards are named differently, set ADMIN_MERGE_LANE_JOB_PREFIX to the prefix they use — the family is a PREFIX match, so ADMIN_MERGE_LANE_JOB_PREFIX=unit selects a shard named 'unit (a)'. If instead NONE of the names above is a test shard, then no run of a CODE lane READ in this window executed one — its shards were skipped, cancelled, neutral, stale or otherwise not executed here, or the lane is not in the window at all — and the fix is to NAME the lane whose test shards run on BOTH push and pull_request: --workflow <file>. --any-workflow widens the reference to EVERY workflow on main — event-driven ones (issue_comment, schedule, issues) that run no test included — which is how a window fills with non-code runs (tortoise #7734)"
    fi
    return 2
  fi
  if ! lane_has_test_shard "$TMP/lane-main.txt"; then
    LANE_PARITY_EMPTY_KIND="lifecycle"
    LANE_PARITY_REASON="the shard family '${LANE_JOB_PREFIX}*' matched ONLY lifecycle jobs on main ($(tr '\n' ' ' < "$TMP/lane-main.txt" | sed 's/ $//')) — a bookkeeping family measures no test"
    return 2
  fi
  if [ "$(lane_count "$TMP/lane-pr.txt")" -gt 0 ]; then
    # The subtraction is deliberately NOT `comm -23`: the one `comm` in this rail
    # belongs to the parser's `--diff`, and a second one here is the shape the
    # suite's PARITY test forbids (a reader must not confuse a coverage
    # subtraction with the exemption comparison).
    grep -vxF -f "$TMP/lane-pr.txt" "$TMP/lane-main.txt" > "$TMP/lane-missing.txt"
    rc=$?
    # 0 = differences found (refuse); 1 = no differences (parity holds). Any
    # other status is a grep ERROR, and reading it as "no differences" is the
    # fail-open this gate exists to prevent.
    if [ "$rc" -gt 1 ]; then
      say_err "admin-merge: ✗ the lane-coverage subtraction failed (grep rc $rc) — lane coverage unverifiable"
      LANE_PARITY_REASON="the lane-coverage subtraction itself failed (grep rc $rc)"
      return 2
    fi
  else
    # The PR executed NOTHING while main's lane is real, so the whole of main's
    # lane IS the gap. This copy is the same class of step as the `grep`
    # subtractions above, and it is checked for the same reason: `lane-missing.txt`
    # is created EMPTY at function entry, so an unchecked failure here leaves it
    # empty, the `[ -s … ]` test below reads that as "no shard is missing", and the
    # function returns 0 — parity "established" for a head that compared NOTHING.
    # Unlike every other route into that state, the resulting certificate is one the
    # evidence gate ACCEPTS (`PR ⊇ main … 0 shard(s) on the PR side, N on main`), so
    # it reaches a real merge: a failed write is not an empty gap. Reproduced by
    # shadowing `cp` on PATH — scenario (j3) in tests/admin-merge/run.sh.
    if ! cp "$TMP/lane-main.txt" "$TMP/lane-missing.txt"; then
      say_err "admin-merge: ✗ the lane-coverage copy failed — lane coverage unverifiable"
      LANE_PARITY_REASON="the lane-coverage listing could not be copied into the gap (the lane-coverage copy failed)"
      return 2
    fi
  fi
  # ── #6928: FORGIVE THE LEGS THE TARGET'S DIFF SELECTOR *DECLINED* ──────
  # Computed ONLY when the raw subtraction left a shard to explain, so a repo
  # with no diff-gated legs and no selector pays nothing and refuses exactly as
  # it did before. See the block above `lane_declined_shards` for the rule and its
  # fail-closed boundary.
  LANE_PARITY_FORGIVEN=""
  LANE_PARITY_SELECTOR_VERDICT=""
  if [ "$(lane_count "$TMP/lane-missing.txt")" -gt 0 ]; then
    if lane_declined_shards "$head" "$TMP/lane-declined.txt"; then
      if [ "$(lane_count "$TMP/lane-declined.txt")" -gt 0 ]; then
        # Freeze the DECLINED listing too, before the forgiveness writes below: it
        # is an INPUT of the union claim, and one of those writes could otherwise be
        # redirected onto it (a symlink on `lane-kept.txt` is enough to rewrite it).
        LANE_DECLINED_FROZEN="$(cat "$TMP/lane-declined.txt")"
        # The shards ACTUALLY in this head's gap that the selector DECLINED — the
        # INTERSECTION, so the disclosure names only legs this head really did not
        # run. Same subtraction shape as the coverage gap above, same fail-CLOSED
        # reading of grep's status: 0 = some matched, 1 = none (nothing to
        # forgive), >1 = a grep ERROR, which is never "nothing to forgive".
        grep -xF -f "$TMP/lane-declined.txt" "$TMP/lane-missing.txt" > "$TMP/lane-forgiven.txt"
        rc=$?
        if [ "$rc" -gt 1 ]; then
          say_err "admin-merge: ✗ the declined-leg subtraction failed (grep rc $rc) — lane coverage unverifiable"
          LANE_PARITY_REASON="the declined-leg subtraction itself failed (grep rc $rc)"
          return 2
        fi
        if [ "$rc" -eq 0 ]; then
          # The declined shards are IN the gap, so removing them is exactly the
          # change; `lane-forgiven.txt` is what the disclosure names.
          grep -vxF -f "$TMP/lane-forgiven.txt" "$TMP/lane-missing.txt" > "$TMP/lane-kept.txt"
          rc=$?
          if [ "$rc" -gt 1 ]; then
            say_err "admin-merge: ✗ the declined-leg subtraction failed (grep rc $rc) — lane coverage unverifiable"
            LANE_PARITY_REASON="the declined-leg subtraction itself failed (grep rc $rc)"
            return 2
          fi
          mv "$TMP/lane-kept.txt" "$TMP/lane-missing.txt"
          LANE_PARITY_FORGIVEN="$(cat "$TMP/lane-forgiven.txt")"
          # DISCLOSE, on the path that CERTIFIES and on the path that still
          # refuses: an operator reading either one must be able to see why a
          # shard was not required.
          say_err "admin-merge: ⚠️  lane-coverage forgiveness (#6928) — $(lane_count "$TMP/lane-forgiven.txt") shard(s) this head did not run were DECLINED by its diff selector and are NOT required of it: $(tr '\n' ' ' < "$TMP/lane-forgiven.txt")[selector: ${LANE_PARITY_SELECTOR_VERDICT}]"
        fi
      fi
    else
      # FAIL CLOSED: an unavailable answer forgives NOTHING, and the raw gap is
      # refused exactly as it is today — with the reason the selector was not
      # consulted to close it, so a missing answer is never read as a declined leg.
      say_err "admin-merge: ⚠️  lane-coverage forgiveness (#6928) NOT applied — ${LANE_DECLINED_REASON}; refusing on the raw gap (a missing selector answer is not a declined leg)"
    fi
  fi
  # ── THE DECISION IS THE CLAIM, RE-DERIVED FROM THE INPUT LISTS (#1439) ──────
  # The certificate asserts exactly one claim — "main's lane ⊆ the PR's executed set",
  # or, when forgiveness was applied, "… ⊆ the PR's set ∪ the shards the selector
  # DECLINED" — so that claim is re-derived from the INPUTS here, at the single point
  # that decides, and the gap FILE is required not to contradict it. Reading the answer
  # off the file is what failed, three times over: a failed subtraction REDIRECT reports
  # grep's own "no differences" status (1), which no status test can tell from a
  # genuinely empty gap; a destination that is not a regular file swallows the write;
  # and the FORGIVENESS rewrite (`> lane-kept.txt` then `mv`) can be swallowed the same
  # way AFTER any earlier check has passed. Each left the file EMPTY while a shard was
  # missing, and the rail certified `PR ⊇ main` — once with `EXCEPT the N shard(s) its
  # diff selector DECLINED … every shard the selector did not decline still had to be
  # executed, and was`, which was FALSE — for a head that compared nothing: a body the
  # evidence gate ACCEPTS. A COUNT is not a substitute either: equal counts with
  # disjoint members certified (cycle-3 review).
  # WHY THE UNION IS CONDITIONAL: the declined set may only be credited when
  # forgiveness was ACTUALLY applied, because that is what the certificate then says.
  # Crediting it otherwise would accept `main={a,b}` against `pr={a}` with `b` merely
  # declined — a claim no certificate on that path makes. Both passes write to
  # /dev/null, so their redirects cannot fail and the status is grep's ALONE; lane files
  # are DEDUPED SETS (`lane_shard_set` ends with `sort -u`), so "nothing was printed"
  # ⟺ the claim above holds, EXACTLY.
  # (The gate trusts the TOOLS it calls. A PATH `grep` that lied about the answer, or a
  # planted destination whose CONTENT is crafted, would defeat a check that consults
  # them — a hostile host, out of the threat model, which is a bad PR and a FAILED
  # WRITE. The suite's shims model failed writes.)
  # ── THE INPUTS THE DECISION READS MUST NOT HAVE MOVED (#1439 cycle-5) ───────
  # The claim below is a claim about the frozen lists, so it is only sound if the
  # FILES still hold them. This function writes into its own scratch directory, and
  # a write that is ALIASED onto an input rewrites that input — the subtraction's
  # redirect onto `lane-main.txt` is the cheapest form (see the freeze above). It is
  # caught here, before anything is decided, and refused as unverifiable rather than
  # compared. (`cat` of a dangling symlink yields the empty string, which differs
  # from any non-empty frozen list, so a DELETED reference is caught too.)
  local inputs_moved=0
  if [ "$(cat "$TMP/lane-pr.txt" 2>/dev/null)" != "$LANE_PR_FROZEN" ]; then inputs_moved=1; fi
  if [ "$(cat "$TMP/lane-main.txt" 2>/dev/null)" != "$LANE_MAIN_FROZEN" ]; then inputs_moved=1; fi
  if [ -n "$LANE_PARITY_FORGIVEN" ] \
     && [ "$(cat "$TMP/lane-declined.txt" 2>/dev/null)" != "$LANE_DECLINED_FROZEN" ]; then inputs_moved=1; fi
  if [ "$inputs_moved" -eq 1 ]; then
    say_err "admin-merge: ✗ a lane reference CHANGED while parity was being decided — lane coverage unverifiable (a write in this gate's own scratch directory was aliased onto an input the decision reads)"
    LANE_PARITY_REASON="a lane reference changed while parity was being decided, so the comparison cannot be trusted"
    return 2
  fi
  local covered_rc=0
  if [ -n "$LANE_PARITY_FORGIVEN" ]; then
    grep -vxF -f "$TMP/lane-pr.txt" -f "$TMP/lane-declined.txt" "$TMP/lane-main.txt" > /dev/null || covered_rc=$?
  else
    grep -vxF -f "$TMP/lane-pr.txt" "$TMP/lane-main.txt" > /dev/null || covered_rc=$?
  fi
  if [ "$covered_rc" -gt 1 ]; then
    say_err "admin-merge: ✗ the lane-coverage re-check failed (grep rc $covered_rc) — lane coverage unverifiable"
    LANE_PARITY_REASON="the lane-coverage membership re-check itself failed (grep rc $covered_rc)"
    return 2
  fi
  if [ "$covered_rc" -eq 0 ] && [ "$(lane_count "$TMP/lane-missing.txt")" -eq 0 ]; then
    if [ -n "$LANE_PARITY_FORGIVEN" ]; then
      say_err "admin-merge: ✗ the lane-coverage gap came back EMPTY although main's lane holds a shard that is neither in the PR's executed set nor among the shards this head's diff selector DECLINED. An empty gap would mean main's lane was fully covered, and the lists say it was not — so the listing that records the gap could not be written."
      LANE_PARITY_REASON="the lane-coverage gap came back EMPTY although main's lane holds a shard the PR did not run and its diff selector did not decline, so the gap listing could not be written"
    else
      say_err "admin-merge: ✗ the lane-coverage gap came back EMPTY although main's lane holds a shard the PR's executed set does not. An empty gap would mean the PR ran every shard main ran, and the lists say it did not — so the listing that records the gap could not be written."
      LANE_PARITY_REASON="the lane-coverage gap came back EMPTY although main's lane holds a shard the PR did not run, so the gap listing could not be written"
    fi
    return 2
  fi
  [ -s "$TMP/lane-missing.txt" ] && return 1
  return 0
}

# derive_rerun_timeout <run-id> — set DERIVED_RERUN_TIMEOUT / _SOURCE / _TABLE
# from a GREEN population's observed per-shard job durations. NEVER fails the
# caller: every failure path installs the fail-safe and says so loudly.
#
# The TARGET run supplies only the shard SET and which shards are unfinished (the
# pool the rail might wait on). Its own durations are deliberately NOT used — a
# failure-truncated sample must never stand in for a shard's healthy duration, and
# a shard with no green sample takes the FAIL-SAFE.
#
# Shard normalisation: a job name is (1) stripped of a reusable-workflow caller
# prefix (`<caller> / <called>`, which gh renders for a `workflow_call` job) and
# (2) reduced to its FIRST matrix axis (`test (a, docker)` → `test (a)`), then
# left verbatim. That is the shard identity the workflow's own `name:` template
# produces — `test (a)`, `test (b)`, `test-slow (b)`, `test-carve-out` — so the
# grouping survives the two things that actually vary between runs (the caller
# prefix and extra matrix axes) without inventing a grouping key that is not the
# shard.
derive_rerun_timeout() {
  local run_id="$1" json_file="" green_file="" gids="" gid="" out="" rc=0 line tag name n maxd ceil unfin sample
  local green_files=()
  DERIVED_RERUN_TIMEOUT="$FAILSAFE_RERUN_TIMEOUT"
  DERIVED_RERUN_SOURCE=""
  DERIVED_TABLE=""
  [ -n "$run_id" ] || { fail_safe_rerun_timeout "no run id"; return 0; }
  command -v "${GH%% *}" >/dev/null 2>&1 || { fail_safe_rerun_timeout "gh absent"; return 0; }
  json_file="$(mktemp "${TMPDIR:-/tmp}/admin-merge-jobs.XXXXXX")"
  if ! fetch_run_jobs "$run_id" > "$json_file" 2>/dev/null; then
    rm -f "$json_file"
    fail_safe_rerun_timeout "jobs API error"
    return 0
  fi
  if [ ! -s "$json_file" ]; then
    rm -f "$json_file"
    fail_safe_rerun_timeout "empty jobs response"
    return 0
  fi
  # The GREEN population: the failing run is the SHARD MAP, never the sample.
  gids="$(green_run_ids)"
  if [ -n "$gids" ]; then
    while IFS= read -r gid; do
      [ -n "$gid" ] || continue
      green_file="$(mktemp "${TMPDIR:-/tmp}/admin-merge-green.XXXXXX")"
      if fetch_run_jobs "$gid" > "$green_file" 2>/dev/null && [ -s "$green_file" ]; then
        green_files+=("$green_file")
      else
        rm -f "$green_file"
      fi
    done <<< "$gids"
  fi
  out="$("$PYTHON_BIN" -c 'import datetime, json, re, sys
floor, failsafe, tpath = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
gpaths = sys.argv[4:]
def norm(name):
    s = (name or "").strip()
    if " / " in s:
        s = s.rsplit(" / ", 1)[1].strip()
    m = re.match(r"^(.*?)\s*\((.*)\)\s*$", s)
    if m and m.group(1).strip():
        s = "%s (%s)" % (m.group(1).strip(), m.group(2).split(",")[0].strip())
    return s
def ts(raw):
    if not raw:
        return None
    try:
        d = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return d
def secs(job):
    a, b = ts(job.get("started_at")), ts(job.get("completed_at"))
    if a is None or b is None:
        return None
    n = int((b - a).total_seconds())
    return n if n >= 0 else None
def jobs_of(path):
    raw = open(path, "r", encoding="utf-8", errors="replace").read()
    docs = []
    dec = json.JSONDecoder()
    i = 0
    while i < len(raw):
        while i < len(raw) and raw[i] in " \t\r\n":
            i += 1
        if i >= len(raw):
            break
        try:
            obj, i = dec.raw_decode(raw, i)
        except ValueError:
            return None
        docs.append(obj)
    jobs = []
    saw = False
    for d in docs:
        if isinstance(d, dict) and isinstance(d.get("jobs"), list):
            saw = True
            jobs.extend(j for j in d["jobs"] if isinstance(j, dict))
    return jobs if saw else None
target = jobs_of(tpath)
if target is None:
    raise SystemExit(2)
shards = {}
target_completed = 0
for job in target:
    # An unnamed JOB is not dropped either (#1353): a name-less shard must not
    # vanish from the shard map, or an UNFINISHED one disappears from the bound
    # pool and the bound is derived from a set that excludes it. The
    # placeholder has no green sample, so it takes the FAIL-SAFE bound — the
    # direction that can never make a bound too small.
    name = norm(job.get("name")) or "(unnamed job)"
    rec = shards.setdefault(name, {"unfinished": False})
    if job.get("status") and job.get("status") != "completed":
        rec["unfinished"] = True
    if secs(job) is not None:
        target_completed += 1
if target_completed == 0:
    raise SystemExit(3)
green = {}
for path in gpaths:
    jobs = jobs_of(path)
    if jobs is None:
        continue
    for job in jobs:
        if job.get("conclusion") != "success":
            continue
        name = norm(job.get("name")) or "(unnamed job)"
        secs_n = secs(job)
        if secs_n is None:
            continue
        rec = green.setdefault(name, {"n": 0, "max": 0})
        rec["n"] += 1
        if secs_n > rec["max"]:
            rec["max"] = secs_n
if not green:
    raise SystemExit(4)
def shard_ceiling(name):
    rec = green.get(name)
    if rec is None:
        return failsafe
    return max(floor, 2 * rec["max"])
for name in sorted(shards):
    rec = green.get(name)
    if rec is None:
        n, mx, sample = 0, 0, "none"
    else:
        n, mx, sample = rec["n"], rec["max"], "green"
    print("SHARD\t%s\t%d\t%d\t%d\t%d\t%s" % (name, n, mx, shard_ceiling(name), 1 if shards[name]["unfinished"] else 0, sample))
unfinished = [s for s in shards if shards[s]["unfinished"]]
if unfinished:
    pool, reason = unfinished, "slowest unfinished shard"
else:
    pool, reason = list(shards), "slowest shard (every shard completed)"
win = max(sorted(pool), key=shard_ceiling)
rec = green.get(win)
wn, wmax = (0, 0) if rec is None else (rec["n"], rec["max"])
print("C\t%d\t%s\t%d\t%d\t%s" % (shard_ceiling(win), win, wn, wmax, reason))' "$RERUN_FLOOR" "$FAILSAFE_RERUN_TIMEOUT" "$json_file" ${green_files[@]+"${green_files[@]}"} 2>/dev/null)"
  rc=$?
  rm -f "$json_file" ${green_files[@]+"${green_files[@]}"}
  case "$rc" in
    0) [ -n "$out" ] || { fail_safe_rerun_timeout "unparsable jobs response"; return 0; } ;;
    3) fail_safe_rerun_timeout "no job durations observed"; return 0 ;;
    4) fail_safe_rerun_timeout "no completed SUCCESSFUL job observed for the lane"; return 0 ;;
    *) fail_safe_rerun_timeout "unparsable jobs response"; return 0 ;;
  esac
  local table="" c_line="" c="" win="" winn="" winmax="" wreason="" state max_disp
  while IFS= read -r line; do
    case "$line" in
      C$'\t'*) c_line="$line" ;;
      SHARD$'\t'*)
        IFS=$'\t' read -r tag name n maxd ceil unfin sample <<< "$line"
        state="finished"
        [ "$unfin" = "1" ] && state="unfinished"
        if [ "$sample" = "green" ]; then max_disp="${maxd}s"; else max_disp="--"; fi
        table="${table}shard ${name}	n=${n}	max=${max_disp}	bound=${ceil}s	state=${state}	sample=${sample}"$'\n'
        ;;
    esac
  done <<< "$out"
  DERIVED_TABLE="${table%$'\n'}"
  IFS=$'\t' read -r tag c win winn winmax wreason <<< "$c_line"
  counter_is_number "$c" || { fail_safe_rerun_timeout "unparsable jobs response"; return 0; }
  DERIVED_RERUN_TIMEOUT="$c"
  DERIVED_RERUN_SOURCE="derived per-shard green bound ${c}s (${wreason}: ${win}, green n=${winn}, green max=${winmax}s)"
}

# ── THE FIRST-CHECKS WAIT — PROGRESS-AWARE, never a fixed window (#2481) ────
#
# MEASURED DEFECT #2090 (the 2026-10-21 rail log for #2233/#2234): the rail
# printed `precondition unmet: run still in_progress` and exited INSTANTLY while
# a lane run was queued/in_progress — then explained itself with a line about
# `--rerun-timeout`, a DIFFERENT wait that had never started. A lane that pushes
# on every review round therefore holds its own PR unlandable.
#
# MEASURED DEFECT #2481 (the 2026-10-23 logs for #2412/#2414): the wait that fix
# added is ONE FIXED WINDOW, and that window is SHORTER THAN ONE GREEN STEP of the
# lane it waits for. Measured on this repo's own green `ci.yml` PR runs (8
# consecutive successes, 2026-10-22/23):
#
#     full green run                  6586s … 9032s   (median ≈ 8075s)
#     longest `bash-suites` JOB       5490s … 6660s
#     longest single STEP   3960s / 4020s / 4368s / 4380s  (73.0 min,
#                           "Bash shards — the ONE list both lanes run")
#
# The window was 3900s. So a healthy lane could not clear it, and on #2412 the
# rail refused with `the FIRST-CHECKS wait expired … no classification attempted`
# while the PR **merged 4 minutes later**. `bash-suites` was red on 48 of 83 open
# PRs: the common path, not an edge case. A bigger number is not the fix — that
# moves the timeout later and keeps failing on the same PRs.
#
# THE WAIT WAS ALSO BLIND, which is WHY it had to choose a number at all: its
# only clock was `waited`, and it never compared one poll's observation with the
# last, so an ADVANCING run and a WEDGED one were indistinguishable BY
# CONSTRUCTION. It now fingerprints the per-JOB `status`/`conclusion` and the
# per-STEP `number`/`status` of every pending run, one Jobs-API read per run per
# poll (verified live 2026-10-23 on run 39959046444: `bash-suites` in_progress at
# step 5/8, `admin-merge` at 3/8), and treats a CHANGED fingerprint as progress:
#
#   run:<id>:<status>  job:<name>:<status>:<conclusion>:<steps-done>/<n>:<current-step#>
#
# ⛔ THIS IS NOT `updatedAt`, and it must never become it. A run's `updatedAt`
# freezes for the whole of one long step, and a bound built on that produced a
# false STALLED verdict the rail had to retract (#1167 follow-on; §39 pins it
# out). A STEP BOUNDARY is real evidence; the silence between two of them is not
# evidence of anything — which is why the stall period is derived from the
# longest MEASURED step rather than from a round number.
#
# THE THREE BOUNDS (documented with their derivations at the knobs, above):
#   * STALL    — no observable change for 2 × 4380s (the measured longest step),
#                promoted at runtime to 2 × the longest COMPLETED step seen on the
#                runs being waited on. Below one legitimate step it would be a
#                guaranteed false stall.
#   * CEILING  — 2 × the slowest measured green run (18064s): a lane-occupancy
#                cap, NOT a stall detector, and its verdict never claims to be.
#   * WINDOW   — the legacy bound, kept for the two states with no object whose
#                progress could be observed: `never-started` (no run has appeared
#                at this head — the fresh-PR race, and #2465's inapplicable-lane
#                case) and `unreadable` (the run list cannot be read at all).
#
# ⛔ THE FAILURE MODE OF PROGRESS-AWARE WAITING IS A MISSING SIGNAL — the one that
# turns "slow" into "everything looks stuck". If a pending run's jobs cannot be
# read, "no change" is not evidence of a stall, it is evidence of NOTHING. So that
# poll does NOT advance the stall clock; the wait reports the signal as
# incomplete, and if the Jobs surface stays unreadable for the legacy window it
# refuses with its own `unobservable` verdict — exactly the timing this wait had
# before, so a broken instrument can neither manufacture a stall nor extend a wait.
#
# ⛔ WHAT IS NOT CHANGED. Nothing about WHAT the rail requires. The wait only
# holds the rail until there is something to MEASURE; §1b still classifies the
# terminal surface and still refuses a red. An elapsed time can never turn a red
# check green, no check is skipped, and every non-terminal exit still BLOCKS with
# no evidence posted and nothing merged.
FIRST_CHECKS_WAITED=0
FIRST_CHECKS_QUIET=0
FIRST_CHECKS_OUTCOME=""
FIRST_CHECKS_OBSERVED=""
FIRST_CHECKS_STATE=""
FIRST_CHECKS_LAST_CHANGE=""
FIRST_CHECKS_TRANSITIONS=0
FIRST_CHECKS_FINGERPRINT=""
FIRST_CHECKS_STALL_BOUND=0
FIRST_CHECKS_CEILING_BOUND=0
FIRST_CHECKS_MISSING=0
FIRST_CHECKS_MISSING_STREAK=0

# first_checks_digest <jobs-json-file>... — ONE python pass over the pending runs'
# job listings, emitting ONE line per input, in argv order:
#
#     <jobs>\t<max-completed-step-secs>\t<fingerprint>\t<summary>
#
# `<jobs>` is the count the listing PROVES, or `unknown` when the document could
# not be read or parsed. `unknown` is never 0: #1623's exclusion needs PROOF that a
# run has zero jobs, and the progress clock needs PROOF that nothing changed —
# neither may be inferred from a failure. The first three fields never contain a
# TAB or a NEWLINE (job/step names are scrubbed), so the caller's split is exact
# and the human summary is the LAST field, free to contain anything.
#
# The listing is `--paginate`d upstream, so several JSON objects can arrive back
# to back; they are decoded one after another and their `jobs` lists concatenated,
# which is the same reading `fetch_run_jobs`' one-object-per-page callers do.
first_checks_digest() {
  "$PYTHON_BIN" - "$@" <<'PY' 2>/dev/null || true
import datetime, json, sys

def clean(s):
    return " ".join(str(s).split())

def ts(s):
    try:
        return datetime.datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except Exception:
        return None

for path in sys.argv[1:]:
    try:
        raw = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        print("unknown\t0\t\t")
        continue
    dec = json.JSONDecoder()
    i = 0
    saw = False
    bad = False
    jobs = []
    while i < len(raw):
        while i < len(raw) and raw[i] in " \t\r\n":
            i += 1
        if i >= len(raw):
            break
        try:
            obj, i = dec.raw_decode(raw, i)
        except ValueError:
            bad = True
            break
        if isinstance(obj, dict) and isinstance(obj.get("jobs"), list):
            saw = True
            jobs.extend(obj["jobs"])
    if bad or not saw:
        print("unknown\t0\t\t")
        continue
    max_step = 0
    fp_parts = []
    done_jobs = 0
    live = []
    for j in jobs:
        if not isinstance(j, dict):
            continue
        name = clean(j.get("name") or "-")
        st = clean(j.get("status") or "-")
        conc = clean(j.get("conclusion") or "-")
        steps = j.get("steps") or []
        total = len(steps)
        done = 0
        cur = 0
        curname = ""
        for s in steps:
            if not isinstance(s, dict):
                continue
            if s.get("status") == "completed":
                done += 1
                a, b = ts(s.get("started_at") or ""), ts(s.get("completed_at") or "")
                if a and b:
                    secs = int((b - a).total_seconds())
                    if secs > max_step:
                        max_step = secs
            elif s.get("status") == "in_progress":
                try:
                    cur = int(s.get("number") or 0)
                except (TypeError, ValueError):
                    cur = 0
                curname = clean(s.get("name") or "")
        if st == "completed":
            done_jobs += 1
        else:
            live.append((name, "%s %s step %d/%d%s" % (
                name, st, cur, total, (" '" + curname + "'") if curname else "")))
        fp_parts.append((name, "%s:%s:%s:%d/%d:%d" % (name, st, conc, done, total, cur)))
    # ORDER-INDEPENDENT ON PURPOSE. The Jobs API's job order is not a contract and
    # was observed to differ between two reads of the same surface, so a
    # positional fingerprint would report a spurious "change" on every poll —
    # resetting the stall clock forever and hiding a real stall behind the
    # ceiling. Sorting makes the fingerprint a statement about STATE, which is the
    # only thing that counts as progress.
    fp_parts.sort(key=lambda p: p[0])
    live.sort(key=lambda p: p[0])
    fp = "; ".join(p[1] for p in fp_parts)
    live = [p[1] for p in live]
    if live:
        summary = "%d job(s): %d completed, %d not — %s" % (
            len(jobs), done_jobs, len(jobs) - done_jobs, "; ".join(live[:4]))
        if len(live) > 4:
            summary += "; … +%d more" % (len(live) - 4)
    else:
        summary = "%d job(s): all completed (the RUN itself is not yet)" % len(jobs)
    print("%d\t%d\t%s\t%s" % (len(jobs), max_step, fp, summary))
PY
}

# first_checks_head_check_count <head> → the number of check-runs GitHub holds for
# this head ACROSS EVERY WORKFLOW, and rc 0 when that surface was READ; rc 1 when
# it could not be read at all.
#
# ⛔ A READ THAT FAILED IS NOT A ZERO, and the caller must not collapse them: 0 is
# the evidence that NOTHING exists at this head yet (arm (d) — an empty surface,
# which the wait may only report as "no run has appeared"), while an unreadable
# surface is evidence of NOTHING and must never license the same sentence.
#
# `per_page=1` is deliberate: `total_count` on the first page IS the whole
# surface, so the probe cannot be expensive enough to matter inside a poll. The
# value is read with sed rather than jq/python because it must survive the cell's
# transport-controlled gh chain, which is not guaranteed to serve `--jq`.
first_checks_head_check_count() {
  local head="$1" slug body n
  if [ -n "${REPO:-}" ]; then slug="repos/$REPO"; else slug="repos/{owner}/{repo}"; fi
  body="$TMP/fc-head-checks.json"
  if ! $GH api "$slug/commits/$head/check-runs?per_page=1" > "$body" 2>/dev/null; then
    return 1
  fi
  n="$(sed -n 's/.*"total_count"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$body" | head -1)"
  [ -n "$n" ] || return 1
  printf '%s\n' "$n"
}

# check_unresolved_scan <check-runs-json> → one `check-unresolved:<name>:
# <status>/<conclusion>` line per check whose NEWEST attempt (highest id per
# (app slug, name)) is NOT `completed`. rc 0 when at least one is unresolved,
# rc 1 when every newest attempt concluded.
#
# ⛔ WHY A SEPARATE SCAN AND NOT THE AGGREGATE. A check-run ROLLUP is not a
# verdict: GitHub keeps every ATTEMPT, so one head carries BOTH a `failure` and a
# `success` for the same job name, and the newest is the only one that describes
# the tree. Measured on tortoise #10475 (head 3b4a8096): `python-ci-gate` holds
# id 124783536754 `completed/failure` (07:32:42Z) AND id 124788856867
# `completed/success` (07:58:49Z) — same name, same head, opposite verdicts. A
# scan that took the first, or the worst, would refuse a green head; one that
# took a rollup state would read the aggregate, not the check.
#
# ⛔ AND `conclusion` IS PRINTED, NEVER INTERPRETED. `null` becomes `-` (the same
# sentinel the rest of this file uses), and `-` is NOT in any non-red set: the
# caller's refusal carries it verbatim so the next reader sees WHICH empty shape
# it was. The four shapes have four different fixes, and collapsing them into
# "pending" is how the empty state became invisible in the first place.
CHECK_UNRESOLVED_Q=''
check_unresolved_scan() {
  local body="$1"
  "$PYTHON_BIN" - "$body" <<'PY'
import json, sys

path = sys.argv[1]
try:
    with open(path, "rb") as fh:
        raw = fh.read().decode("utf-8", "replace")
except OSError:
    sys.exit(2)

runs = []
docs = []
idx = 0
while idx < len(raw):
    while idx < len(raw) and raw[idx] in " \t\r\n":
        idx += 1
    if idx >= len(raw):
        break
    try:
        obj, end = json.JSONDecoder().raw_decode(raw, idx)
    except ValueError:
        sys.exit(2)
    idx = end
    docs.append(obj)
for d in docs:
    if isinstance(d, dict) and isinstance(d.get("check_runs"), list):
        runs.extend(x for x in d["check_runs"] if isinstance(x, dict))
if not runs:
    # An EMPTY surface is not an absence of unresolved checks - it is an absence
    # of a MEASUREMENT, and the caller must not read it as "nothing pending".
    sys.exit(2)

best = {}
for pos, r in enumerate(runs):
    name = str(r.get("name") or "")
    if not name:
        name = "(unnamed check)"
    app = str(((r.get("app") or {}).get("slug")) or "")
    # Newest attempt per (app, name) ordered by ID - never by started_at, which is
    # nullable for a queued attempt and would sort an unresolved one first.
    rid = r.get("id")
    rid = rid if isinstance(rid, int) else -pos
    key = (app, name)
    if key not in best or rid > best[key][0]:
        best[key] = (rid, r)

unresolved = 0
for (app, name) in sorted(best):
    r = best[(app, name)][1]
    status = str(r.get("status") or "")
    concl = r.get("conclusion")
    concl = "-" if concl in (None, "") else str(concl)
    if status == "completed":
        continue
    unresolved += 1
    print("check-unresolved:%s:%s/%s" % (name, status or "-", concl))
sys.exit(0 if unresolved else 1)
PY
}

# wait_for_first_checks <head> → 0 the lane is terminal at this head (there is
# something to compare), 1 it is not (and FIRST_CHECKS_* say which way).
#
# Every poll is ONE `gh run list` plus ONE Jobs read per pending run. The stall
# clock (`quiet`) advances ONLY on a poll whose fingerprint was OBSERVED and did
# not change — a poll where the instrument failed or no run existed yet advances
# the `missing` budget INSTEAD, never `quiet`: an unobservable interval is not
# evidence of no progress, and counting it as such lets a 3900s-broken instrument
# manufacture a "no observable change for Ns" STALL (a false block on a healthy
# run, and a message that is untrue about most of its own seconds). All clocks are
# `$SECONDS` deltas, not sleep counters, because a counter is not a clock (the
# #1395 lesson: a rail that outlived its own reported bound).
wait_for_first_checks() {
  local head="$1" waited=0 quiet=0 missing=0 missing_streak=0 total=0 pending=0 rc=0 out="" line status conclusion id created obs
  local now last_clock dt fp summary max_step digest jobs cr_slug scan_rc scan_out
  local max_step_run fp_run summary_run read_ok n_lines idx
  local stall_bound ceiling_bound signal_ok poll_step remaining adv wait_word expired
  local rederive_left lane_filter_active head_checks
  local -a jobs_files=() pending_ids=()
  FIRST_CHECKS_WAITED=0; FIRST_CHECKS_QUIET=0; FIRST_CHECKS_OUTCOME=""; FIRST_CHECKS_OBSERVED=""
  FIRST_CHECKS_REDERIVED=""; FIRST_CHECKS_HEAD_CHECKS=""
  FIRST_CHECKS_STATE=""; FIRST_CHECKS_LAST_CHANGE=""; FIRST_CHECKS_TRANSITIONS=0
  FIRST_CHECKS_FINGERPRINT=""; FIRST_CHECKS_MISSING=0; FIRST_CHECKS_MISSING_STREAK=0
  FIRST_CHECKS_UNRESOLVED=""; FIRST_CHECKS_UNRESOLVED_UNREADABLE=0
  stall_bound="$FIRST_CHECKS_STALL"
  ceiling_bound="$FIRST_CHECKS_CEILING"
  FIRST_CHECKS_STALL_BOUND="$stall_bound"; FIRST_CHECKS_CEILING_BOUND="$ceiling_bound"
  poll_step="$FIRST_CHECKS_POLL"
  [ "$poll_step" -gt 0 ] 2>/dev/null || poll_step=1
  poll_step=$((10#$poll_step))
  # ── THE 0 SEAM. `ADMIN_MERGE_FIRST_CHECKS_WAIT=0` means "one observation, no
  # waiting" (the pre-#2090 instant refusal, and the rail suite's default). It
  # keeps that meaning for the WHOLE wait: when the legacy window is 0 AND no
  # progress bound was set explicitly, the wait takes exactly one observation and
  # returns — it does not silently become a five-hour wait bounded by a ceiling
  # nobody asked for. An explicit STALL/CEILING re-enables it (that is how the
  # suite drives the new arms in seconds), which is why the test for the seam is
  # "0 and nothing else set", not "0".
  local wait_enabled=1
  if [ "$((10#$FIRST_CHECKS_WAIT))" -eq 0 ] \
     && [ -z "${ADMIN_MERGE_FIRST_CHECKS_STALL:-}" ] \
     && [ -z "${ADMIN_MERGE_FIRST_CHECKS_CEILING:-}" ]; then
    wait_enabled=0
  fi
  local args=()
  [ -n "${REPO:-}" ] && args+=(--repo "$REPO")
  # ONLY gh-native flags. `--any-workflow` is the PARSER's opt-out: real gh
  # rejects it (`unknown flag`), and `2>/dev/null || true` hid that, so a
  # diagnostic built on it was silently dead for the very invocation
  # commit-workflow's own docs prescribe.
  #
  # The filter lives in `lane_filter_active`, NOT in `$ANY_WORKFLOW`: dropping it
  # is a decision about THIS WAIT only (#2862). `ANY_WORKFLOW` also steers the
  # failure-set lane and the base-window messages further down, so reusing it here
  # would silently widen surfaces this fix has no business touching.
  lane_filter_active=0
  if [ "${ANY_WORKFLOW:-0}" -ne 1 ] && [ -n "${WORKFLOW:-}" ]; then
    lane_filter_active=1
    args+=(--workflow "$WORKFLOW")
  fi
  rederive_left="$FIRST_CHECKS_REDERIVE_MAX"
  case "$rederive_left" in ''|*[!0-9]*) rederive_left=1 ;; esac
  last_clock="$SECONDS"
  while :; do
    # shellcheck disable=SC2086
    out="$($GH run list --commit "$head" --limit 100 ${args[@]+"${args[@]}"} \
        --json databaseId,status,conclusion,createdAt --jq "$FIRST_CHECKS_JQ" 2>/dev/null)"; rc=$?
    total=0; obs=""
    pending_ids=()
    if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
      # NORMALISE THE SEPARATOR BEFORE SPLITTING. TAB is IFS WHITESPACE, so an
      # EMPTY field (a non-completed run has no conclusion) collapses adjacent
      # tabs and shifts every later field one place left — the same trap the
      # LANE_RUN_JQ sentinel documents. awk preserves empty fields; a non-IFS
      # separator then makes the split exact.
      while IFS='|' read -r status conclusion id created; do
        [ -n "$status" ] || continue
        id="${id##*:}"
        total=$((total + 1))
        [ "$status" = "completed" ] && continue
        pending_ids+=("$id")
        [ -n "$obs" ] && obs="$obs; "
        obs="${obs}run ${id} status=${status} conclusion=${conclusion:--}${created:+ created=${created}}"
      done < <(printf '%s\n' "$out" | awk -F'\t' '{ printf "%s|%s|%s|%s\n", $1, $2, $3, $4 }')
    fi

    # ── THE CONFIGURED LANE THAT SELECTS NOTHING HERE (#2862) ─────────────
    # An EMPTY filtered list is ambiguous, and the ambiguity is what hung
    # premise-labs#572: it means "this repo's CI is named otherwise" just as
    # readily as "the PR was pushed a second ago", and the old wait could only
    # read it the second way — so a misconfiguration was paid for with the whole
    # window and reported as "CI never started" about a green PR.
    #
    # The discriminator costs one read: if the HEAD carries check-runs, they come
    # from workflows whose names this repo actually has, so the configured name is
    # NOT one of them and the filter is dropped. If the head carries NONE, the
    # empty list was TRUE (nothing exists yet) and arm (d) reports it as such.
    # ⛔ An UNREADABLE count drops nothing: an unread instrument is not a
    # misconfiguration, and guessing it here would be the same class of error as
    # reading it as "no runs".
    #
    # ⚠️ NO CLOCK ADVANCES on the re-derive poll. It is an immediate retry that
    # answered nothing about the lane, so charging it to `missing` would let a
    # misconfiguration eat the window one read at a time — the defect, not the fix.
    if [ "$rc" -eq 0 ] && [ "$total" -eq 0 ] && [ "$lane_filter_active" -eq 1 ] \
       && [ "$rederive_left" -gt 0 ]; then
      # ⚠️ THE BUDGET IS SPENT ON THE ATTEMPT, NOT ON THE OUTCOME. Charging it only
      # on a successful drop would make an UNREADABLE probe retry on every poll —
      # one REST call per poll, forever, on the very path whose defect is "this wait
      # burns its budget". One attempt per wait is the bound; a probe that fails
      # leaves the pre-existing behaviour (the bounded legacy window) in place, and
      # the message names the operator's escape.
      rederive_left=$((rederive_left - 1))
      if head_checks="$(first_checks_head_check_count "$head")"; then
        # The count is recorded either way: a PROVEN-EMPTY head is a different
        # state from an unread one, and the refusal must be able to say which.
        FIRST_CHECKS_HEAD_CHECKS="$head_checks"
        if [ "$head_checks" -gt 0 ]; then
          lane_filter_active=0
          args=()
          [ -n "${REPO:-}" ] && args+=(--repo "$REPO")
          FIRST_CHECKS_REDERIVED="$WORKFLOW"
          info "admin-merge: … FIRST-CHECKS wait: the configured lane '$WORKFLOW' has NO run at head $head, but this head carries $head_checks check-run(s) across every workflow — so '$WORKFLOW' is not this repo's CI (it is the TORTOISE default; a repo may name its CI anything, premise-labs uses ci.yml). DROPPING the lane filter for this wait and re-reading the head unfiltered. The merge decision is NOT loosened: §4.5 grades the head's evaluated tree across EVERY workflow, so a red required check is refused there exactly as before."
          continue
        fi
      else
        # An unreadable count is NOT evidence of a misconfiguration, and it must not
        # be turned into one. Fail CLOSED — keep the filter, keep the window — but
        # say so, because the alternative reading ("this repo's CI is elsewhere") is
        # the exact ambiguity #2862 is about.
        info "admin-merge: … FIRST-CHECKS wait: the configured lane '$WORKFLOW' has NO run at head $head, and the head's check-runs could not be READ — so 'this workflow is named differently here' and 'nothing has started yet' remain indistinguishable. KEEPING the filter and the bounded window (${FIRST_CHECKS_WAIT}s). If this repo's CI is named differently, pass --any-workflow."
      fi
    fi

    # ── THE PROGRESS OBSERVATION ──────────────────────────────────────────
    # One Jobs read per pending run (bounded — see FIRST_CHECKS_JOBS_MAX). A run
    # GitHub never expanded into a job is NOT in flight (#1623) and is excluded
    # here, from the SAME read that supplies the progress signal, so the two can
    # never disagree about what counts as pending.
    signal_ok=0
    pending=0
    fp=""
    summary=""
    max_step=0
    if [ "$total" -gt 0 ]; then
      if [ "${#pending_ids[@]}" -gt 0 ] && [ "${#pending_ids[@]}" -le "$FIRST_CHECKS_JOBS_MAX" ]; then
        jobs_files=()
        read_ok=1
        for id in "${pending_ids[@]}"; do
          if fetch_run_jobs "$id" > "$TMP/fc-jobs-$id.json" 2>/dev/null && [ -s "$TMP/fc-jobs-$id.json" ]; then
            jobs_files+=("$TMP/fc-jobs-$id.json")
          else
            rm -f "$TMP/fc-jobs-$id.json"
            read_ok=0
          fi
        done
        # ⛔ A FAILED JOBS READ IS NOT "NO PENDING RUNS". Every run stays pending
        # (fail-closed, as before) and the signal is marked missing, so the state
        # below can never fall through to `pending == 0` and CLEAR the wait on an
        # unreadable surface.
        [ "$read_ok" -eq 1 ] || pending="${#pending_ids[@]}"
        if [ "$read_ok" -eq 1 ]; then
          digest="$(first_checks_digest "${jobs_files[@]}")"
          n_lines="$(printf '%s\n' "$digest" | grep -c . || true)"
          if [ "$n_lines" -eq "${#pending_ids[@]}" ]; then
            signal_ok=1
            idx=0
            for id in "${pending_ids[@]}"; do
              idx=$((idx + 1))
              line="$(printf '%s\n' "$digest" | sed -n "${idx}p")"
              IFS=$'\t' read -r jobs max_step_run fp_run summary_run <<< "$line"
              jobs="${jobs:-unknown}"
              max_step_run="${max_step_run:-0}"
              case "$max_step_run" in ''|*[!0-9]*) max_step_run=0 ;; esac
              # A run PROVEN to have zero jobs is not in flight (#1623): GitHub
              # never expanded it, so it must not hold this wait. An UNREADABLE
              # count is not zero — it stays pending, fail-closed.
              [ "$jobs" = "0" ] && continue
              [ "$jobs" = "unknown" ] && signal_ok=0
              pending=$((pending + 1))
              [ "$max_step_run" -gt "$max_step" ] && max_step="$max_step_run"
              [ -n "$fp" ] && fp="$fp || "
              fp="${fp}run:${id} ${fp_run}"
              [ -n "$summary" ] && summary="$summary | "
              summary="${summary}run ${id}: ${summary_run}"
            done
          else
            # ⛔ A SHORT (or empty) DIGEST IS NOT "NO PENDING RUNS" EITHER. The
            # guarantee two lines up — an unreadable surface can never fall
            # through to `pending == 0` and CLEAR the wait — has to hold for the
            # digest as well as for the fetch, because `first_checks_digest` is
            # `… 2>/dev/null || true`: a parser that dies mid-list (an
            # unparseable step number the inner handlers do not catch, an
            # interpreter that cannot run) leaves PARTIAL stdout and no error
            # anyone sees. Counting that against `pending` read it as "every run
            # terminal", cleared the wait, and §1b then refused with a false
            # diagnosis ("the wait CLEARED (the lane was terminal), but a NEW run
            # appeared") — the pre-#2481 "gave up before classifying" shape.
            # Same remedy as the failed-read arm: every run stays pending and the
            # signal is marked missing.
            pending="${#pending_ids[@]}"
            signal_ok=0
          fi
        fi
      elif [ "${#pending_ids[@]}" -gt "$FIRST_CHECKS_JOBS_MAX" ]; then
        pending="${#pending_ids[@]}"
        signal_ok=0
        summary="${#pending_ids[@]} run(s) still pending — more than the ${FIRST_CHECKS_JOBS_MAX} this wait observes"
      fi
    fi

    # ── CLOCKS (a counter is not a clock — #1395) ─────────────────────────
    now="$SECONDS"
    dt=$((now - last_clock))
    [ "$dt" -lt 0 ] && dt=0
    last_clock="$now"
    waited=$((waited + dt))

    # ── THE OBSERVED STATE ────────────────────────────────────────────────
    if [ "$rc" -ne 0 ]; then
      # A RUN LIST THAT CANNOT BE READ IS NOT "NO RUNS YET" — checked FIRST, so a
      # NON-ZERO exit whose partial stdout happens to contain only terminal lines
      # cannot clear the wait.
      FIRST_CHECKS_STATE="unreadable"
      [ -n "$obs" ] || obs="the head's run list could not be read (gh error)"
      missing=$((missing + dt)); missing_streak=$((missing_streak + dt))
    elif [ "$total" -gt 0 ] && [ "$pending" -eq 0 ]; then
      # A TERMINAL LISTING WITH AT LEAST ONE RUN CLEARS THE WAIT.
      FIRST_CHECKS_WAITED="$waited"
      return 0
    elif [ "$total" -eq 0 ]; then
      FIRST_CHECKS_STATE="never-started"
      missing=$((missing + dt)); missing_streak=$((missing_streak + dt))
    elif [ "$signal_ok" -ne 1 ]; then
      # ⛔ A MISSING SIGNAL IS NOT A STALL. The stall clock does NOT advance: the
      # absence of an observation is the absence of evidence, and reading it as
      # "no progress" is exactly how a progress-aware wait turns into a false
      # stall. The legacy window bounds how long an unreadable instrument may
      # hold the lane — the same bound this wait had before, no worse.
      FIRST_CHECKS_STATE="unobservable"
      missing=$((missing + dt)); missing_streak=$((missing_streak + dt))
    else
      FIRST_CHECKS_STATE="still-running"
      missing_streak=0
      # PROMOTE the stall period from what these runs have actually shown: half of
      # a step that already took longer than the derived stall period would be a
      # false stall on a run that has demonstrably run that long.
      [ $((max_step * 2)) -gt "$stall_bound" ] && stall_bound=$((max_step * 2))
      FIRST_CHECKS_STALL_BOUND="$stall_bound"
      if [ -z "$FIRST_CHECKS_FINGERPRINT" ]; then
        FIRST_CHECKS_FINGERPRINT="$fp"
        FIRST_CHECKS_LAST_CHANGE="$summary"
      elif [ "$fp" != "$FIRST_CHECKS_FINGERPRINT" ]; then
        FIRST_CHECKS_FINGERPRINT="$fp"
        FIRST_CHECKS_TRANSITIONS=$((FIRST_CHECKS_TRANSITIONS + 1))
        FIRST_CHECKS_LAST_CHANGE="$summary (at ${waited}s)"
        quiet=0
      else
        quiet=$((quiet + dt))
      fi
    fi

    FIRST_CHECKS_WAITED="$waited"
    FIRST_CHECKS_QUIET="$quiet"
    FIRST_CHECKS_MISSING="$missing"
    FIRST_CHECKS_MISSING_STREAK="$missing_streak"
    FIRST_CHECKS_OBSERVED="${obs:-no run has appeared for this head yet}"

    # ── THE VERDICT ───────────────────────────────────────────────────────
    if [ "$wait_enabled" -eq 0 ]; then
      # The 0 seam: one observation, no waiting (see the note at the top of this
      # function). The state is still reported, so the refusal names what it saw.
      FIRST_CHECKS_OUTCOME="$FIRST_CHECKS_STATE"
      return 1
    fi
    # ── THE VERDICT ───────────────────────────────────────────────────────
    # ⛔ THE EXPIRING POLL STILL REPORTS (#2862 CI regression). The verdict used to
    # `return 1` from inside this table, i.e. BEFORE the report below — so the ONE
    # poll an operator most needs to read (the one that ended the wait) was the only
    # one that printed nothing about what it had observed. That is not a cosmetic
    # gap: `$SECONDS` is a whole-second clock, so any poll whose work straddles a
    # second boundary charges 1s, and a wait whose window IS 1s therefore expired on
    # its FIRST observation whenever that happened — ~1 poll in 5 on a loaded runner.
    # Measured: run 41110313398, job 124250724527 reddened `tests/admin-merge/run.sh`
    # with "✗ BLOCK — the FIRST-CHECKS wait expired after 1s (ceiling 1s)" and NO
    # report line above it, on a total wall clock of 226ms. Every fixture that
    # asserts on a report line was therefore a coin flip, and the shard reddened
    # every PR. Setting `expired` and reporting before returning makes the observation
    # deterministic WITHOUT loosening a bound: the same verdict, the same instant, one
    # more line — and the wait still sleeps zero additional seconds.
    expired=0
    case "$FIRST_CHECKS_STATE" in
      still-running)
        if [ "$quiet" -ge "$stall_bound" ]; then
          FIRST_CHECKS_OUTCOME="stalled"
          expired=1
        elif [ "$waited" -ge "$ceiling_bound" ]; then
          FIRST_CHECKS_OUTCOME="ceiling"
          expired=1
        fi ;;
      never-started|unreadable)
        if [ "$waited" -ge "$FIRST_CHECKS_WAIT" ]; then
          FIRST_CHECKS_OUTCOME="$FIRST_CHECKS_STATE"
          expired=1
        fi ;;
      unobservable)
        if [ "$missing" -ge "$FIRST_CHECKS_WAIT" ] || [ "$waited" -ge "$ceiling_bound" ]; then
          FIRST_CHECKS_OUTCOME="unobservable"
          expired=1
        fi ;;
    esac
    # ── THE UNRESOLVED-CHECK BOUND (tortoise#10399) ───────────────────────
    # Checked AFTER the table above and OVERRIDING it, on purpose: the states the
    # table bounds are all "a run is moving" or "nothing is observable", and the
    # defect is the third case — a REQUIRED check whose job never got a runner so
    # its newest attempt has NO conclusion, on a run that keeps producing job
    # transitions and therefore never trips a progress clock. A wait that is
    # still holding a head with an unresolved check after this bound REFUSES BY
    # NAME rather than occupying the lane any longer.
    # ⛔ The bound is not applied to `never-started`/`unreadable` (their own window
    # already governs, and neither has a check NAME to report) nor when the lane
    # is terminal (that returns above).
    case "$FIRST_CHECKS_STATE" in
      still-running)
        if [ "$expired" -ne 1 ] && [ "$waited" -ge "$CHECK_UNRESOLVED_BOUND" ]; then
          # ONE read, and only at the bound, so the ordinary merge path pays
          # nothing. An unreadable scan does NOT clear the refusal: it keeps the
          # outcome and says the names could not be read — failing to look is
          # never a green.
          if [ -n "${REPO:-}" ]; then cr_slug="repos/$REPO"; else cr_slug="repos/{owner}/{repo}"; fi
          FIRST_CHECKS_UNRESOLVED=""
          if $GH api "$cr_slug/commits/$head/check-runs?per_page=100&filter=all" --paginate \
               > "$TMP/fc-unresolved.json" 2>/dev/null; then
            # ⛔ THE SCAN'S EXIT STATUS IS THE DECISION — never "did it print
            # anything". rc 2 means the surface was EMPTY or UNREADABLE, which
            # prints nothing; reading that as "nothing unresolved" would leave
            # `expired` at 0 and send the wait straight back into the hang this
            # branch exists to end (and pay one extra read per poll forever).
            scan_rc=0
            scan_out="$(check_unresolved_scan "$TMP/fc-unresolved.json" 2>/dev/null)" || scan_rc=$?
            case "$scan_rc" in
              0) FIRST_CHECKS_UNRESOLVED="$scan_out"
                 FIRST_CHECKS_OUTCOME="check-unresolved"
                 expired=1 ;;
              1) : ;;   # every newest attempt concluded — the wait keeps its bounds
              *) FIRST_CHECKS_OUTCOME="check-unresolved"
                 FIRST_CHECKS_UNRESOLVED=""
                 FIRST_CHECKS_UNRESOLVED_UNREADABLE=1
                 expired=1 ;;
            esac
          else
            FIRST_CHECKS_OUTCOME="check-unresolved"
            FIRST_CHECKS_UNRESOLVED=""
            FIRST_CHECKS_UNRESOLVED_UNREADABLE=1
            expired=1
          fi
        fi ;;
    esac

    # ── THE REPORT (patience, not a hang: say WHAT was observed) ──────────
    # ⛔ A REPORT PRINTED ON THE POLL THAT ENDS THE WAIT MAY NOT SAY IT IS STILL
    # WAITING. The observation is the same either way; only the tense changes, and a
    # line that says "waiting" one line above a refusal that says "the window is
    # spent" is the kind of message this repo treats as a defect, not a nicety.
    wait_word="— waiting."
    [ "$expired" -eq 1 ] && wait_word="— the bound is now spent, so this is the CLOSING observation."
    case "$FIRST_CHECKS_STATE" in
      never-started)
        info "admin-merge: … FIRST-CHECKS wait: no run has appeared for head $head yet (${waited}s of the ${FIRST_CHECKS_WAIT}s window) $wait_word" ;;
      unreadable)
        info "admin-merge: … FIRST-CHECKS wait: the head's run list could not be read (${waited}s of the ${FIRST_CHECKS_WAIT}s window) $wait_word unreachable is not empty." ;;
      unobservable)
        info "admin-merge: … FIRST-CHECKS wait: $pending run(s) still queued/in progress, and the PROGRESS SIGNAL is unavailable (Jobs API unreadable for ${missing}s of the ${FIRST_CHECKS_WAIT}s fallback window in total, ${missing_streak}s consecutively) $wait_word This wait does NOT call it a stall: an unread instrument is not a stalled run." ;;
      *)
        if [ "$FIRST_CHECKS_TRANSITIONS" -eq 0 ]; then
          info "admin-merge: … FIRST-CHECKS wait: $pending run(s) still queued/in progress, no change observed yet (${waited}s of the ${ceiling_bound}s ceiling; stall bound ${stall_bound}s) $wait_word first observation: $summary"
        elif [ "$quiet" -eq 0 ]; then
          info "admin-merge: … FIRST-CHECKS wait: still RUNNING and PROGRESSING — change #${FIRST_CHECKS_TRANSITIONS} observed at ${waited}s (${pending} run(s) pending, stall bound ${stall_bound}s, ceiling ${ceiling_bound}s): $summary $wait_word"
        else
          info "admin-merge: … FIRST-CHECKS wait: still RUNNING, no change for ${quiet}s of the ${stall_bound}s stall bound (${waited}s of the ${ceiling_bound}s ceiling, ${FIRST_CHECKS_TRANSITIONS} change(s) so far) — last: $FIRST_CHECKS_LAST_CHANGE $wait_word"
        fi ;;
    esac

    # CLAMP THE SLEEP TO THE REMAINING ROOM, so the wait cannot overshoot the very
    # bound it reports (the #1395 lesson again). The room is whichever verdict is
    # next: the stall clock for an observed surface, the legacy window for an
    # unobserved one, and the ceiling always.
    # ⛔ AN EXPIRED WAIT DOES NOT SLEEP: the report above was the last thing it owed.
    if [ "$expired" -eq 1 ]; then
      return 1
    fi
    remaining=$((ceiling_bound - waited))
    case "$FIRST_CHECKS_STATE" in
      still-running) [ $((stall_bound - quiet)) -lt "$remaining" ] && remaining=$((stall_bound - quiet)) ;;
      unobservable)  [ $((FIRST_CHECKS_WAIT - missing)) -lt "$remaining" ] && remaining=$((FIRST_CHECKS_WAIT - missing)) ;;
      *)             [ $((FIRST_CHECKS_WAIT - waited)) -lt "$remaining" ] && remaining=$((FIRST_CHECKS_WAIT - waited)) ;;
    esac
    adv="$poll_step"
    [ "$adv" -gt "$remaining" ] && adv="$remaining"
    # A non-positive remaining is a BUG in the verdict table above, not a reason to
    # spin: floor it at one second (the loop's own bound still applies next poll).
    [ "$adv" -gt 0 ] || adv=1
    sleep "$adv"
  done
}

# block_on_first_checks <head> — the wait closed without a terminal lane. Names
# THIS wait, WHICH verdict it reached, what it last observed, and the next action;
# it never borrows the RE-RUN wait's bound or wording.
#
# ⛔ A STALL AND A TIMEOUT ARE DIFFERENT VERDICTS AND MUST READ DIFFERENTLY. A
# stall says "nothing moved for the stall period — the run is wedged"; a timeout
# says "it was still moving, but the ceiling is where this lane stops waiting".
# They recommend opposite things to the next reader (escalate vs re-run), and a
# single "expired" would throw that distinction away — which is the whole point of
# the progress signal.
block_on_first_checks() {
  local head="$1" one_line
  case "${FIRST_CHECKS_OUTCOME:-}" in
    check-unresolved)
      # ⛔ THE NAMED REFUSAL (tortoise#10399). Reached when a check's NEWEST attempt
      # has no conclusion after CHECK_UNRESOLVED_BOUND seconds: the lane gets its
      # budget back WITH the reason recorded, instead of a silent multi-hour wait.
      # It can never be green — `conclusion: null` prints as `-` and `-` is not in
      # any non-red set.
      say_err "admin-merge: ✗ BLOCK — REFUSED(check-unresolved) after ${FIRST_CHECKS_WAITED}s"
      say_err "   (bound ADMIN_MERGE_CHECK_UNRESOLVED_BOUND=${CHECK_UNRESOLVED_BOUND}s) — a check on"
      say_err "   head $head still has NO CONCLUSION, and an unresolved check is not a pass."
      if [ "${FIRST_CHECKS_UNRESOLVED:-}" != "" ]; then
        while IFS= read -r one_line; do
          [ -n "$one_line" ] || continue
          say_err "   REFUSED(${one_line})"
        done <<< "$FIRST_CHECKS_UNRESOLVED"
      elif [ "${FIRST_CHECKS_UNRESOLVED_UNREADABLE:-0}" -eq 1 ]; then
        say_err "   REFUSED(check-unresolved:<names-unreadable>): the head's check-runs could not be"
        say_err "   READ, so the unresolved check cannot be named — an unread surface is never a green."
      else
        say_err "   REFUSED(check-unresolved:<names-unavailable>): the lane reports pending runs but the"
        say_err "   head's check surface names no unresolved attempt — the two disagree. The refusal"
        say_err "   stands: the rail will not merge on a surface it cannot show is RESOLVED."
      fi
      say_err "   last observed: ${FIRST_CHECKS_OBSERVED:-nothing readable}"
      say_err "   what was missing: this is NOT a stall and NOT a slow run. A stall means nothing moved;"
      say_err "   here the run KEEPS moving (job transitions advance the fingerprint, so no progress clock"
      say_err "   can ever fire) while ONE check never produces a conclusion — typically a required"
      say_err "   aggregator whose own jobs are queued behind a saturated runner pool and so cannot start."
      say_err "   Next: read the run named above; if a job is queued with no runner, free capacity or"
      say_err "   re-run it. Nothing was compared, no evidence was posted and nothing was merged." ;;
    stalled)
      say_err "admin-merge: ✗ BLOCK — the FIRST-CHECKS wait STALLED: NO observable change for ${FIRST_CHECKS_QUIET}s"
      say_err "   (stall ${FIRST_CHECKS_STALL_BOUND}s, derived from the measured longest green step; waited ${FIRST_CHECKS_WAITED}s"
      say_err "   of the ${FIRST_CHECKS_CEILING_BOUND}s ceiling) — a STALL verdict, NOT a timeout, and no classification attempted."
      say_err "   waited for: the lane's runs on head $head to APPEAR and reach status=completed"
      say_err "   last observed: ${FIRST_CHECKS_OBSERVED:-nothing readable}"
      say_err "   last observed TRANSITION (${FIRST_CHECKS_TRANSITIONS} change(s) before it): ${FIRST_CHECKS_LAST_CHANGE:-none — the surface never changed}"
      say_err "   what was missing: the run is in flight and NOTHING about it advanced — not its status,"
      say_err "   not any job's status, not any job's current step — for the whole stall period. That is a"
      say_err "   wedged run (a hung shard, an unreachable runner), not a slow one."
      say_err "   Next: look at the run named above; it will not finish on its own. Re-run the failed jobs"
      say_err "   or cancel the run, then re-run the rail. Nothing was compared, no evidence was posted"
      say_err "   and nothing was merged." ;;
    ceiling)
      say_err "admin-merge: ✗ BLOCK — the FIRST-CHECKS wait expired after ${FIRST_CHECKS_WAITED}s (ceiling"
      say_err "   ${FIRST_CHECKS_CEILING_BOUND}s) — a TIMEOUT, not a stall: no classification attempted."
      say_err "   waited for: the lane's runs on head $head to APPEAR and reach status=completed"
      say_err "   last observed: ${FIRST_CHECKS_OBSERVED:-nothing readable}"
      if [ "${FIRST_CHECKS_TRANSITIONS:-0}" -gt 0 ]; then
        say_err "   it WAS PROGRESSING — ${FIRST_CHECKS_TRANSITIONS} observable change(s), so the run is alive and"
        say_err "   merely slower than the ceiling, which is a lane-occupancy bound and not a stall detector."
        say_err "   last observed TRANSITION: ${FIRST_CHECKS_LAST_CHANGE:-unknown}"
      else
        say_err "   no observable change was seen inside the ceiling, which is BELOW the stall bound"
        say_err "   (${FIRST_CHECKS_STALL_BOUND}s), so this wait could not tell slow from wedged at all —"
        say_err "   it ran out of room, and a running job is not a failure."
      fi
      say_err "   Next: re-run the rail once those checks complete, or raise"
      say_err "   ADMIN_MERGE_FIRST_CHECKS_CEILING (currently ${FIRST_CHECKS_CEILING_BOUND}s)."
      say_err "   Nothing was compared, no evidence was posted and nothing was merged." ;;
    never-started)
      say_err "admin-merge: ✗ BLOCK — the FIRST-CHECKS wait expired after ${FIRST_CHECKS_WAITED}s (window ${FIRST_CHECKS_WAIT}s) — no classification attempted."
      say_err "   waited for: the lane's runs on head $head to APPEAR and reach status=completed"
      say_err "   last observed: ${FIRST_CHECKS_OBSERVED:-nothing readable}"
      if [ -n "${FIRST_CHECKS_REDERIVED:-}" ]; then
        # The discriminating read DID fire and found nothing at all — so the
        # configured name is not the whole story, and saying "the lane did not
        # trigger on pull_request" would be a guess this wait cannot support.
        say_err "   what was missing: NO run attached to this head in the configured lane"
        say_err "   ('${FIRST_CHECKS_REDERIVED}'), AND the filter was DROPPED (that name selects nothing here)"
        say_err "   and the UNFILTERED read still returned nothing, AND the head carries no check-run"
        say_err "   at all. So this is a genuinely empty surface at this head — not a lane-name mismatch."
      elif [ "${FIRST_CHECKS_HEAD_CHECKS:-}" = "0" ]; then
        # The probe READ the head and found ZERO checks under EVERY workflow. The
        # empty list was TRUE, so the "does not trigger on pull_request" guess the
        # old text offered is unnecessary — and it would have been wrong: the
        # configured lane name was never the question.
        say_err "   what was missing: NOTHING has attached to this head at all — a check-runs read at"
        say_err "   this head returned total_count 0 ACROSS EVERY WORKFLOW, so the head carries no check-run"
        say_err "   at all and the configured lane ('${WORKFLOW:-}<none>') never even came into it."
        say_err "   An EMPTY surface is not a wrong lane name: nothing has started yet."
      else
        say_err "   what was missing: NO run of the lane ever attached to this head. This is the"
        say_err "   fresh-PR race (or the lane does not trigger on pull requests), not a failure."
      fi
      say_err "   There is no run whose progress could be observed, so this wait keeps the LEGACY"
      say_err "   bounded window rather than a stall bound."
      say_err "   An unfinished (or absent) lane yields an EMPTY failing set, which proves nothing,"
      say_err "   so nothing was compared, no evidence was posted and nothing was merged."
      say_err "   Next: if the checks are still starting, re-run the rail in a minute; if they"
      say_err "   never appear, the lane does not run on pull_request for this diff. Raise"
      say_err "   ADMIN_MERGE_FIRST_CHECKS_WAIT (currently ${FIRST_CHECKS_WAIT}s) only if the lane is"
      say_err "   known to attach late." ;;
    unreadable)
      say_err "admin-merge: ✗ BLOCK — the FIRST-CHECKS wait expired after ${FIRST_CHECKS_WAITED}s (window ${FIRST_CHECKS_WAIT}s) — no classification attempted."
      say_err "   waited for: the lane's runs on head $head to APPEAR and reach status=completed"
      say_err "   last observed: ${FIRST_CHECKS_OBSERVED:-nothing readable}"
      say_err "   what was missing: the run state never became readable, so the lane's state was"
      say_err "   never observed (gh auth/network/--repo). This is NOT a stall and not a CI verdict."
      say_err "   An unfinished (or absent) lane yields an EMPTY failing set, which proves nothing,"
      say_err "   so nothing was compared, no evidence was posted and nothing was merged."
      say_err "   Next: check gh auth/--repo/network, then re-run the rail." ;;
    *)
      # still-running, with the Jobs surface unreadable for the legacy window.
      say_err "admin-merge: ✗ BLOCK — the FIRST-CHECKS wait expired after ${FIRST_CHECKS_WAITED}s (window ${FIRST_CHECKS_WAIT}s) — no classification attempted."
      say_err "   waited for: the lane's runs on head $head to APPEAR and reach status=completed"
      say_err "   last observed: ${FIRST_CHECKS_OBSERVED:-nothing readable}"
      say_err "   what was missing: the lane's checks were still queued/in progress when the window"
      say_err "   closed, and their per-job/per-step PROGRESS could not be read (the Jobs API did not"
      say_err "   answer for ${FIRST_CHECKS_MISSING}s in total, ${FIRST_CHECKS_MISSING_STREAK}s consecutively), so slow and wedged could not be told apart."
      say_err "   A running job is not a failure, and this is NOT a stall claim: an unread instrument"
      say_err "   is not a stalled run."
      say_err "   An unfinished (or absent) lane yields an EMPTY failing set, which proves nothing,"
      say_err "   so nothing was compared, no evidence was posted and nothing was merged."
      say_err "   Next: re-run the rail once those checks complete (its progress signal is re-read then),"
      say_err "   or raise ADMIN_MERGE_FIRST_CHECKS_WAIT (currently ${FIRST_CHECKS_WAIT}s)." ;;
  esac
}


# ── THE RAIL'S OWN BODY-EDIT RUN GENERATION (#1417) ─────────────────────────
#
# THE MEASURED DEFECT (agent-infra#1417, comment 6057991604; reproduced on
# #1495 @ 1f92b609 and #1633 @ 8e8b7cbb). The rail's four steps are:
#   [2/4] verify  — waits for the head's CHECK-RUNS to be terminal (atomic-land),
#   [3/4] record  — `record-review.sh` PATCHes the review marker into the PR BODY,
#   [4/4] land    — admin-merge, whose §1b reads the WORKFLOW RUNS surface.
# The body PATCH is an `edited` pull_request activity, and exactly TWO
# NON-code-measuring workflows declare that trigger:
#   * `pipeline-compliance` — #513's verdict binding, deliberately re-run so a
#     forged `verdict=...` marker cannot ride a stale green check;
#   * `workflow-lock`.
# So [3/4] creates two fresh runs 11-87s AFTER [2/4] returned — a generation [2/4]
# could not have seen on ANY surface, which is why polling the runs surface in
# [2/4] does not close this. [4/4] then refused with `run still in_progress`
# against the rail's own work, costing a whole extra rail round ([2/4] is bounded
# at 5400s).
#
# ⛔ THIS IS NOT AN EXCLUSION, AND IT MUST NEVER BECOME ONE. The generation is
# WAITED FOR, and the WHOLE surface is then RE-READ (main, the #1417 loop) so the
# guard runs enter the SAME failure-set comparison as every other run. A guard
# run that FAILS — `pipeline-compliance` whose entire #513 purpose is to be able
# to fail here — is therefore in the re-read failing set and BLOCKS. What is
# deferred is only the §1b refusal on an UNFINISHED run set; no failure is ever
# ignored.
#
# ⛔ WHY THE WORKFLOW NAME, AND NOT `event == edited` (review, PR #1640). The
# first version classified a run as "ours" only when `gh run list --json event`
# was the literal `edited`. That value does not exist on the runs surface: a
# run's `event` is the WEBHOOK EVENT NAME (`pull_request`, `pull_request_target`,
# `push`, …), never the activity type (`edited`), which lives in the webhook
# payload and is not exposed on the run object at all. `self_n` was therefore
# always 0 and the wait was dead code — `event` cannot carry this distinction,
# and a corrected spelling would not help either, because a `synchronize` (push)
# and an `edited` run of one workflow report the SAME event value.
#
# The guard WORKFLOW NAME is the signal that does exist. Over-matching is
# harmless by construction: a matched run is only WAITED FOR and then
# re-evaluated, never dropped, so a name that is not really a guard leg costs the
# wait and nothing else — and waiting for a guard run started by a push is
# correct, not a hazard.
#
# ⛔ COMPLETENESS IS PART OF THE PREDICATE (review P1, PR #1640). "The pending set
# is a subset of ours" has no completeness test, and an ABSENT leg is not a
# foreign leg. The two guard legs come from two DIFFERENT workflows created with
# an 11-87s spread, so leg A can finish before leg B exists; a subset-only
# predicate then sees an empty pending set and SETTLES — a merge the pre-#1417
# rail refused. The wait therefore settles only after it has observed AT LEAST
# ONE RUN FOR EVERY known guard workflow at this head — pending OR already
# terminal, because an already-green leg proves the workflow ran and an ABSENT
# one does not; a partial generation keeps waiting (to $SELF_EDIT_WAIT) for the
# missing leg rather than settling.
#
# A TERMINAL LEG SATISFIES COMPLETENESS (review P2, PR #1640). A leg that
# finished before the first probe read is still an observed leg; requiring that
# it was seen PENDING made the predicate unsatisfiable for that shape, so the
# probe ran to $SELF_EDIT_WAIT and returned 1 — the pre-#1417 refusal #1417
# exists to remove.
#
# FAILURE POLARITY. Every unreadable path here (a failed listing, a nonexistent
# field, an empty selection) leaves the parser's `pending` counter untouched, so
# §1b refuses exactly as it did before this change. The wait can only remove a
# FALSE refusal; it can never produce a merge on its own.

# The NON-code-measuring guard workflows whose PR triggers declare `edited`, and
# whose runs a body PATCH therefore creates. Keys are the NORMALIZED display
# names (lowercase, [a-z0-9] only) that LANE_RUN_GUARD_JQ emits — the real names
# are prose (`Pipeline Compliance`, `Workflow lock (base-branch checker)`) and
# either casing/spacing may change. Adding a guard workflow means adding its key
# here; guard_generation_complete then waits for it too.
GUARD_WORKFLOW_KEYS="pipelinecompliance workflowlock"

# guard_workflow_key <normalized-workflow-name> — print the matching known guard
# key, or return 1. Matched by SUBSTRING so a suffix (`… (fork)`) still matches:
# over-matching is harmless (see the set description above). Under-matching falls
# through to the unchanged §1b refusal.
guard_workflow_key() {
  local norm="${1:-}" k
  for k in $GUARD_WORKFLOW_KEYS; do
    case "$norm" in *"$k"*) printf '%s' "$k"; return 0 ;; esac
  done
  return 1
}

# guard_generation_complete <seen-key-list> — TRUE when EVERY known guard
# workflow has been observed AT THIS HEAD at least once — pending OR already
# terminal (a green leg still proves the workflow ran; see the block comment).
# The list is space-delimited with a leading AND trailing space, so the `case`
# glob cannot match a key that is merely a prefix of a longer one.
guard_generation_complete() {
  local seen="${1:- }" k
  for k in $GUARD_WORKFLOW_KEYS; do
    case "$seen" in *" $k "*) ;; *) return 1 ;; esac
  done
  return 0
}

# settle_self_edit_generation <head> — hold the rail until the run generation
# its OWN `[3/4]` body edit created has finished, so §1b's re-read sees it.
#
# Return 0 ONLY when this head's unfinished set was EXACTLY that generation, EVERY
# known guard workflow was observed at this head — pending or terminal
# (completeness — see the block comment) — and it has now completed (so the caller
# re-reads the surface).
# Return 1 in every other case — a pending run that is NOT ours, nothing pending
# at all, an unreadable listing, a partial generation at the bound, or the
# generation still pending at $SELF_EDIT_WAIT — and the caller then falls through
# to the UNCHANGED §1b refusal on the surface the parser already read. There is no
# third state and no "proceed anyway".
settle_self_edit_generation() {
  local head="$1"
  # A disabled/absent bound is the pre-#1417 behaviour, byte for byte.
  counter_is_positive "$SELF_EDIT_WAIT" || return 1
  local args=()
  [ -n "${REPO:-}" ] && args+=(--repo "$REPO")
  # The SAME lane scope §1b's parser was invoked with: a guard run outside the
  # watched lane can never make §1b refuse, so waiting for it would be gratuitous
  # (and a guard run INSIDE it is exactly the set this exists for).
  if [ "${ANY_WORKFLOW:-0}" -ne 1 ] && [ -n "${WORKFLOW:-}" ]; then
    args+=(--workflow "$WORKFLOW")
  fi
  local waited=0 step saw=0 status conclusion id key gk self_n foreign_n missing
  local seen_keys=" "
  while :; do
    self_n=0; foreign_n=0
    # shellcheck disable=SC2086
    while IFS=$'\t' read -r status conclusion id key; do
      [ -n "$status" ] || continue
      # ⛔ CLASSIFY BEFORE THE COMPLETED SKIP (review P2, PR #1640). A guard leg
      # that is ALREADY TERMINAL is still an observed leg at this head, so it is
      # recorded and satisfies completeness; it just does not count as pending.
      # Only a leg never seen at this head is unobserved, and that alone keeps
      # the wait going. (Recording only PENDING legs made the predicate
      # unsatisfiable when one guard leg finished before the first read — the
      # probe then ran to the bound and produced the pre-#1417 refusal.)
      if gk="$(guard_workflow_key "$key")"; then
        case "$seen_keys" in *" $gk "*) ;; *) seen_keys="$seen_keys$gk " ;; esac
        [ "$status" = "completed" ] && continue
        self_n=$((self_n + 1))
      else
        [ "$status" = "completed" ] && continue
        foreign_n=$((foreign_n + 1))
      fi
    done < <($GH run list --commit "$head" --limit 100 \
        ${args[@]+"${args[@]}"} \
        --json databaseId,status,conclusion,workflowName --jq "$LANE_RUN_GUARD_JQ" 2>/dev/null || true)
    # SOMETHING THAT IS NOT OURS IS PENDING. The §1b refusal owns the decision on
    # the surface the parser read, and this function must not paper over it.
    if [ "$foreign_n" -ne 0 ]; then
      say_err "admin-merge: · the head's unfinished set is NOT only the rail's own body-edit run generation — $foreign_n run(s) belong to the lane's own CI; §1b's lane-terminal precondition decides (unchanged)."
      return 1
    fi
    if [ "$self_n" -eq 0 ]; then
      # Nothing unfinished right now. Only a SETTLED, COMPLETE generation earns
      # the re-read; an empty FIRST read is an unreadable or absent surface and
      # fails closed; and a PARTIAL generation (a leg not yet created) keeps
      # waiting below instead of settling on a subset — an absent leg is not a
      # foreign leg, so a subset-only predicate would merge inside the window the
      # pre-#1417 rail refused (review P1, PR #1640).
      if [ "$saw" -eq 1 ] && guard_generation_complete "$seen_keys"; then
        return 0
      fi
      if [ "$saw" -eq 0 ]; then
        return 1
      fi
    fi
    if [ "$waited" -ge "$SELF_EDIT_WAIT" ]; then
      if [ "$self_n" -gt 0 ]; then
        say_err "admin-merge: ✗ the rail's own body-edit run generation is STILL pending after ${SELF_EDIT_WAIT}s ($self_n run(s)) — §1b refuses exactly as before; raise ADMIN_MERGE_SELF_EDIT_WAIT or re-run the rail."
      else
        missing=""
        for k in $GUARD_WORKFLOW_KEYS; do
          case "$seen_keys" in *" $k "*) ;; *) missing="$missing ${k}" ;; esac
        done
        say_err "admin-merge: ✗ the rail's own body-edit run generation is STILL incomplete after ${SELF_EDIT_WAIT}s — not every guard workflow was ever observed at this head (never seen:${missing:- none}); §1b refuses exactly as before; raise ADMIN_MERGE_SELF_EDIT_WAIT or re-run the rail."
      fi
      return 1
    fi
    saw=1
    if [ "$self_n" -gt 0 ]; then
      info "admin-merge: … the rail's own body-edit run generation (#1417) is still pending ($self_n run(s)); waiting instead of discarding the round (${waited}s of ${SELF_EDIT_WAIT}s)"
    else
      info "admin-merge: … the rail's own body-edit run generation (#1417) settled for the leg(s) seen so far, but not every guard workflow has been observed yet; waiting for the remaining leg(s) instead of settling (${waited}s of ${SELF_EDIT_WAIT}s)"
    fi
    # CLAMP THE SLEEP TO THE REMAINING BUDGET (review P2, PR #1640). The bound is
    # documented in SECONDS; an unbounded `sleep $POLL_INTERVAL` lets a legal
    # ADMIN_MERGE_POLL_INTERVAL=3600 overshoot a 300s bound by an hour. Fail-closed
    # (it only waits longer), but it contradicts the knob's own documentation.
    step="$POLL_INTERVAL"
    [ "$step" -gt 0 ] 2>/dev/null || step=1
    [ "$step" -gt $((SELF_EDIT_WAIT - waited)) ] && step=$((SELF_EDIT_WAIT - waited))
    [ "$step" -gt 0 ] && sleep "$step"
    waited=$((waited + step))
  done
}

# run_exemption_decision <pr-rows> <main-rates> <main-sigs> <rotation> <prefix>
#   Runs the exemption decision and writes `<prefix>.{verdict,blocked,unattributable,exempt}`.
#   Returns 0 when a VERDICT was produced (BLOCK or CLEAN — both are decisions),
#   1 when the decision could NOT run (module absent, unreadable input, crash).
#   The distinction is load-bearing: the CLI exits 1 for a GATED verdict as well
#   as for a crash, so the VERDICT FILE is the only thing that tells "the gate
#   refused this PR" from "the gate is broken". Reading a crash as CLEAN is
#   fail-open; reading it as BLOCK is merely a false block, so every ambiguous
#   path returns 1 and the caller BLOCKS loudly.
run_exemption_decision() {
  local pr_rows="$1" main_rates="$2" main_sigs="$3" rotation="$4" prefix="$5"
  if [ ! -f "$EXEMPTION_PY" ]; then
    say_err "admin-merge: ✗ the exemption decision module is ABSENT at $EXEMPTION_PY."
    say_err "   The rail refuses to fall back to presence-based subtraction — that is the"
    say_err "   #3756 category-A defect (a PR that breaks a test main once flaked gets"
    say_err "   excused and the gate reports GREEN). Restore the agent-infra checkout."
    return 1
  fi
  rm -f "$prefix.verdict" "$prefix.blocked" "$prefix.unattributable" "$prefix.exempt"
  local rot_args=()
  [ -n "$rotation" ] && rot_args=(--rotation "$rotation")
  "$PYTHON_BIN" "$EXEMPTION_PY" decide \
    --pr-failures "$pr_rows" --main-rates "$main_rates" --main-signatures "$main_sigs" \
    ${rot_args[@]+"${rot_args[@]}"} \
    --blocked-out "$prefix.blocked" --unattributable-out "$prefix.unattributable" \
    --exempt-out "$prefix.exempt" --verdict-out "$prefix.verdict" \
    > "$prefix.lines" 2> "$prefix.err"
  if [ ! -s "$prefix.verdict" ] || ! grep -q '^VERDICT' "$prefix.verdict"; then
    say_err "admin-merge: ✗ BLOCK — the exemption decision produced NO verdict; refusing to"
    say_err "   read a broken gate as a green one. The module said:"
    sed 's/^/   /' "$prefix.err" >&2 2>/dev/null || true
    return 1
  fi
  return 0
}

# residual_of <prefix> <out-file> — the set the merge is refused over: the
# decision's BLOCKED ∪ UNATTRIBUTABLE ids. They are disjoint, and both refuse.
residual_of() {
  local prefix="$1" out="$2"
  : > "$out"
  [ -s "$prefix.blocked" ] && cat "$prefix.blocked" >> "$out"
  [ -s "$prefix.unattributable" ] && cat "$prefix.unattributable" >> "$out"
  sort -u -o "$out" "$out"
}

# ── THE CHECK SURFACE PROBE (#1261) ─────────────────────────────────────
# The lane-scoped comparison in steps 1-3 answers "did this PR introduce a
# failure in the one workflow I watch?". It cannot answer "is the tree this
# merge produces green?", and the difference is a false PASS: #4589 landed ruff
# violations, every open PR's merge ref went lint-red, and the rail merged two
# PRs onto it because `python-ci.yml` was green on both sides (both failing sets
# EMPTY, so nothing was compared). See the header for the source, the
# red/not-red/pending table, and the superseded-run rule.
#
# ONE PROBE, TWO SURFACES. This measures check runs and commit statuses attached
# to an arbitrary rev, and is called TWICE:
#   * the PR'S EVALUATED TREE (its head sha, which is where GitHub reports the
#     merge-ref evaluation) — this BLOCKS; and
#   * MAIN'S HEAD — this is REPORTED for context and NEVER blocks, because while
#     main is red the PR that repairs it is green on its own tree and must land.
# The caller snapshots the scratch set into BASE_* / TREE_* right after each
# call.
#
# Sets, NEVER exits — so no caller can forget which branch it took:
#   MAIN_HEALTH_STATUS   green | red | unmeasured | unreadable
#   MAIN_HEALTH_REF      the ref probed
#   MAIN_HEALTH_SHA      the probed commit sha (the ref name when unresolvable)
#   MAIN_HEALTH_SUMMARY  ONE legible line naming what was measured
#   MAIN_HEALTH_REDS     display lines, one per failing check (job, workflow, url)
#   MAIN_HEALTH_TOTAL / MAIN_HEALTH_RED / MAIN_HEALTH_PENDING   the counts
#
# WHY THE RUN LIST IS READ TOO — THE GATE IS UNUSABLE WITHOUT IT on MAIN. Main's
# check surface is dominated by lanes that measure NO revision: on tortoise's last
# eight main commits, SEVEN carried a failure-like check, and over the repo's
# last 100 main runs 6 of the 12 failure-like runs were `registry-backup-cron`
# (event `schedule`) and 1 was `finding-provenance` (event `issues`) — neither
# measures the tree a merge lands on. An unconditional "any red check on main
# refuses" gate would therefore refuse essentially EVERY merge in that repo,
# which is the blunt refusal this rail must not become. So each failing check is
# resolved — by the run id in its own URL — to the EVENT that produced it, and
# only an event that MEASURES CODE blocks — AND ONLY ON THE BASE SURFACE, which
# is the surface that filter was written for. The PR's own tree resolves the same
# event the same way but does NOT exempt the named non-code events: a
# default-branch run cannot attach to a PR head sha, so such a red there is an
# ANOMALY and BLOCKS (#1353). An unresolved red still fails closed on both.
#
#   REPORT-ONLY (no code measured): schedule, issues, issue_comment.
#   BLOCKING (code health):         push, pull_request, pull_request_target,
#                                   merge_group, workflow_dispatch, and every
#                                   event NOT in the list above.
# That is a DENY-list of the observed non-code events, deliberately: an
# UNRECOGNISED event BLOCKS (fail closed). The run map is a SNAPSHOT — one
# bounded, branch- or sha-scoped `gh run list` (and an EMPTY one when that
# listing fails) — so it can simply not carry a red's run. A red whose run the
# snapshot does not carry is resolved INDIVIDUALLY by its own run id (#1446)
# before the verdict is taken, because otherwise a non-code base red reads as
# unresolved and fail-closes into a code-measuring red that blocks every
# stale-surface PR (the observed `finding-provenance` / `issues` shape: that run
# WAS inside the window when re-checked, so the miss is a snapshot miss, not a
# cap). WHY a particular snapshot missed it is deliberately not assumed. A red
# check whose run id cannot be resolved AT ALL — a non-Actions app, or a run the
# individual resolve cannot read either — still BLOCKS: "I could not tell what
# this is" is not "this is noise", and the two cases must stay DISTINGUISHABLE
# (never default an unresolved run to exempt).
#
# ONE `gh run list` resolves them all (id -> event, workflow name), so no single
# red costs an extra call UNLESS the snapshot did not carry it — then exactly
# ONE per-run `gh api .../actions/runs/<id>` is spent on that red (the #1446
# resolve below).
# The listing is fetched ONLY when a red exists. BOUNDED at
# 200 runs; the probed commit is the newest one, so its runs sit at the top. The
# listing is selected by branch for a branch ref and by --commit for a sha.
MAIN_HEALTH_RUN_MAP_LIMIT=200

# ── #6807: THE WORKFLOW'S DECLARABILITY, ANSWERED FROM THE FILE ─────────────
# workflow_pr_evaluable <slug> <workflow-path> <ref> — answers "can this workflow
# attach a check to a pull-request head sha?" (does its `on:` block declare
# pull_request or pull_request_target?). The result lands in the global
# `WPE_VERDICT` (`yes`/`no`/`unknown`). The parse is delegated to
# scripts/ci-workflow-pr-evaluable.sh; the function does only the fetch and the
# per-invocation cache.
#
# ⛔ THE FILE IS READ AS OF <ref>. The contents API defaults `ref` to the
# repository's DEFAULT branch, but a PR can target a NON-default branch, and the
# workflow definition that governs that PR's evaluation is the one on the BASE
# branch. Fetching the default branch would read a different revision and could
# return `no` for a workflow that IS PR-evaluable on the base — a fail-open. The
# fetch is therefore pinned with `-f ref=<ref>` (gh URL-encodes the value, so a
# branch name containing `/`, `#`, `&`, … cannot break the request).
#
# WHY THE EVENT IS NOT THE QUESTION. The gate this feeds used to ask "did the red
# arrive on a schedule/issues event?" — an allow-list of unmeasurable EVENT NAMES.
# A push-only workflow reddens on `push`, which is not on that list, so its base
# red entered the §4.6 comparison and refused EVERY PR with a remedy no rebase can
# satisfy (no PR can make a push-only job run). Declarability is a property of the
# workflow FILE, so the set of unmeasurable workflows is DERIVED, not maintained.
#
# FAIL CLOSED. A missing path, a missing ref, a failed fetch, or an unparsable file
# is `unknown`, which the caller treats as PR-EVALUABLE (blocking). Only an
# affirmative `no` exempts. An EMPTY body is `unknown` too: it is never parsed, so
# a failed fetch cannot be read as "declares no PR trigger”.
# The cache is per-invocation: a base surface carries many reds, often on the same
# workflow, and both the ref and the answer are constant within one probe.
WF_PR_EVAL_CACHE=""
# The verdict lands HERE, never on stdout. WHY NOT a return value: the call site
# MUST NOT be a command substitution (`case "$(workflow_pr_evaluable …)"`), or the
# function would run in a SUBSHELL — an assignment to a global inside it would be
# discarded, WF_PR_EVAL_CACHE would stay empty in the parent, every call would make
# a FRESH empty cache (the cache would be dead) and leak that mktemp file. The
# function sets this global and the caller reads it, keeping the call a plain
# (non-subshell) call. §67(f) pins both the cache hit and the absence of a leak.
WPE_VERDICT="unknown"
# #1542: the PR's changed set, read ONCE per invocation (a base surface carries
# many reds). EMPTY on a failed read, which the predicate reads as UNDECIDABLE
# (`unknown`) — never as "no paths changed", which would exempt a red the PR
# could have measured.
WF_PR_CHANGED_PATHS=""
WF_PR_PATHS_READ=0
# read_pr_changed_paths — populate WF_PR_CHANGED_PATHS once per invocation. The
# diff input for BOTH the #1542 base-red filter comparison and the #1614
# lane-applicability check, so the two can never disagree about what changed.
#
# ⛔ `$slug` ALREADY CARRIES the `repos/` prefix — writing `repos/$slug/…` here
# composes `repos/repos/<owner>/<repo>/…`, which 404s, so WF_PR_CHANGED_PATHS came
# back EMPTY for every PR that needed it (#1569). Empty is not neutral:
# ci-workflow-pr-evaluable.sh then answers `unknown`, and the base-side red stays
# BLOCKING — a false block whose remedy no rebase satisfies — while the filter
# comparison this fetch feeds is silently disabled for the common case.
read_pr_changed_paths() {
  [ "${WF_PR_PATHS_READ:-0}" -eq 1 ] && return 0
  WF_PR_PATHS_READ=1
  local slug
  if [ -n "${REPO:-}" ]; then slug="repos/$REPO"; else slug="repos/{owner}/{repo}"; fi
  WF_PR_CHANGED_PATHS="$($GH api "$slug/pulls/$PR/files?per_page=100" --paginate \
                             --jq '.[].filename' 2>/dev/null || true)"
}
workflow_pr_evaluable() {
  local slug="$1" wf_path="$2" wf_ref="$3" cached body verdict
  WPE_VERDICT="unknown"
  [ -n "$wf_path" ] || return 0
  [ -n "$wf_ref" ] || return 0
  if [ -n "$WF_PR_EVAL_CACHE" ] && [ -f "$WF_PR_EVAL_CACHE" ]; then
    cached="$(awk -F'\t' -v p="$wf_path" '$1 == p { print $2; exit }' "$WF_PR_EVAL_CACHE")"
    [ -n "$cached" ] && { WPE_VERDICT="$cached"; return 0; }
  fi
  # The raw body (`Accept: ...vnd.github.raw`) is what the predicate parses. A
  # failed fetch leaves `body` empty, and an empty body is NEVER parsed — it is
  # `unknown` by construction, so a network failure cannot be read as `no`.
  body=""
  body="$($GH api "$slug/contents/$wf_path" -X GET -f "ref=$wf_ref" \
              -H 'Accept: application/vnd.github.raw' 2>/dev/null || true)"
  if [ -z "$body" ]; then
    verdict="unknown"
  else
    # #1542: a `paths:`-filtered `pull_request` workflow can only attach a check
    # to this PR's head if one of the PR's changed files matches its filter.
    # Without that filter the predicate could only answer `yes` for every
    # filtered workflow — comparing the PR against a base red it can never
    # produce (an over-block with a remedy no rebase satisfies).
    read_pr_changed_paths
    # ⛔ `env -u CI_WF_PR_EVALUABLE_QUESTION` (#1614 review): this call asks the
    # DEFAULT question — "can this FILE attach a check to a PR head?". The
    # question selector is a command-scoped variable at the ONE lane selector
    # below, but it is also an ordinary exported name, so an operator's (or an
    # agent's) shell that exports `lane-applicable` would silently re-ask a
    # different question here and flip a `workflow_call`-only lane from `unknown`
    # to `no`. `no` is consumed below as an affirmative exemption (`no)
    # pr_evaluable=0`), so that flip exempts a base red from the very surface
    # §4.6 gates the merge on — a fail-open reachable by ambient env.
    verdict="$(printf '%s' "$body" | env -u CI_WF_PR_EVALUABLE_QUESTION \
                 PR_CHANGED_PATHS="$WF_PR_CHANGED_PATHS" \
                 bash "$SELF_DIR/ci-workflow-pr-evaluable.sh" 2>/dev/null || true)"
  fi
  case "$verdict" in
    yes|no) ;;
    *) verdict="unknown" ;;
  esac
  if [ -z "$WF_PR_EVAL_CACHE" ]; then
    WF_PR_EVAL_CACHE="$(mktemp "${TMPDIR:-/tmp}/admin-merge-wfpr.XXXXXX")"
  fi
  printf '%s\t%s\n' "$wf_path" "$verdict" >> "$WF_PR_EVAL_CACHE"
  WPE_VERDICT="$verdict"
}

# ── #1614: IS THE WATCHED LANE APPLICABLE TO THIS DIFF? ─────────────────────
# The merge rail watches ONE lane (default `python-ci.yml`) and precondition 1
# requires a TESTED run of that lane on the PR head. A PR that touches nothing
# the lane can trigger on can NEVER satisfy it, so the sanctioned merge path is a
# DEAD END for the whole non-Python surface (`bin/`, `scripts/`, `extensions/`,
# `.github/workflows/`, `templates/`, `docs/`) — the run does not exist and
# waiting cannot create it.
#
# Two situations that look identical are NOT:
#   * the lane SHOULD have run and produced no run  -> a real gap -> REFUSE
#     (steps 1/1b, unchanged);
#   * the lane CANNOT run for this diff            -> INAPPLICABLE, not missing
#     -> fall back to the evaluated surface, LOUDLY (the caller's job).
#
# The rail holds both facts: the watched workflow's `on:` block (fetched at this
# head) and this PR's changed set. The parse is delegated to the SAME predicate
# the rest of the rail uses, asked the LANE-SELECTOR question — a second parser
# would be a second authority on what a trigger is (scripts/
# ci-workflow-pr-evaluable.sh, `CI_WF_PR_EVALUABLE_QUESTION=lane-applicable`).
#
# FAIL CLOSED. A missing path/ref, a failed fetch, an empty changed set, or an
# undecidable trigger block leaves LANE_APPLICABILITY=`unknown`, and the caller
# keeps the lane filter and refuses exactly as before. Only a MEASURED
# `inapplicable` falls back — an applicability that could not be read is never an
# exemption.
LANE_APPLICABILITY=""
LANE_APPLICABILITY_REASON=""
lane_applicable() {
  local wf_path="$1" wf_ref="$2" slug body verdict
  LANE_APPLICABILITY="unknown"
  LANE_APPLICABILITY_REASON=""
  [ -n "$wf_path" ] || { LANE_APPLICABILITY_REASON="no lane was named"; return 0; }
  [ -n "$wf_ref" ] || { LANE_APPLICABILITY_REASON="the head sha could not be resolved"; return 0; }
  if [ -n "${REPO:-}" ]; then slug="repos/$REPO"; else slug="repos/{owner}/{repo}"; fi
  # The raw body (`Accept: …vnd.github.raw`) is what the predicate parses, and the
  # fetch is pinned to THIS head (the revision whose run the precondition is
  # about) — a workflow can differ per branch, so reading the default branch would
  # measure a different revision. An empty body is never parsed: a failed fetch is
  # `unknown`, not "declares no trigger".
  body="$($GH api "$slug/contents/$wf_path" -X GET -f "ref=$wf_ref" \
            -H 'Accept: application/vnd.github.raw' 2>/dev/null || true)"
  if [ -z "$body" ]; then
    LANE_APPLICABILITY_REASON="the lane's workflow file ('$wf_path') could not be READ at head $wf_ref"
    return 0
  fi
  read_pr_changed_paths
  # `//[[:space:]]/` and not a bare `-z`: a WHITESPACE-ONLY value passes `-z` but
  # is not a changed set, and the predicate reads an empty list as "matches
  # nothing" — the two together would file an unmeasured lane as INAPPLICABLE.
  # The predicate collapses an all-blank list to undecidable too (#1614 review);
  # this leg keeps the rail's own reason line honest as well.
  #
  # ⛔ NOT a global `//[[:space:]]/` replace of $WF_PR_CHANGED_PATHS. That global
  # substitution is super-linear in bash 3.2 and NEVER completes on a large changed set: measured
  # on /bin/bash 3.2.57 — 50 paths 3.5 s, 100 paths 21.5 s, 200 paths > 25 s, and
  # PR #7653's 2,265 paths (173 KB) unbounded past 60 s. That hung the whole rail
  # SILENTLY (header printed, no verdict, no timeout) so a large PR could not be
  # landed at all and a watcher could not tell a hang from slow work (#7702).
  # A `case` glob match is ONE linear pass and tests exactly the same thing —
  # "does the value contain any non-whitespace character" — so it is not a weaker
  # guard, only a cheaper one. Do not reintroduce a //...// expansion here.
  # The `:-` is load-bearing for EXACT equivalence: the old form tolerated an UNSET
  # variable (`[ -z "${V//…}" ]` on unset V is a no-op under `set -u`), while a bare
  # `case "$V" in` aborts with "unbound variable". The variable is initialised at
  # 2375 and always assigned by read_pr_changed_paths() before this line, so the case
  # is unreachable today — but a future refactor must not turn a fail-closed
  # UNMEASURED into a hard abort.
  local _paths_has_nonspace=""
  case "${WF_PR_CHANGED_PATHS:-}" in
    *[![:space:]]*) _paths_has_nonspace=1 ;;
  esac
  if [ -z "$_paths_has_nonspace" ]; then
    LANE_APPLICABILITY_REASON="the PR's changed-file list could not be READ, so the lane's applicability is UNMEASURED"
    return 0
  fi
  printf '%s' "$body" | PR_CHANGED_PATHS="$WF_PR_CHANGED_PATHS" \
      CI_WF_PR_EVALUABLE_QUESTION=lane-applicable \
      bash "$SELF_DIR/ci-workflow-pr-evaluable.sh" \
      > "$TMP/lane-applicable.verdict" 2> "$TMP/lane-applicable.reason" || true
  verdict="$(cat "$TMP/lane-applicable.verdict" 2>/dev/null || true)"
  LANE_APPLICABILITY_REASON="$(cat "$TMP/lane-applicable.reason" 2>/dev/null || true)"
  case "$verdict" in
    yes) LANE_APPLICABILITY="applicable" ;;
    no)  LANE_APPLICABILITY="inapplicable" ;;
    *)   LANE_APPLICABILITY="unknown" ;;
  esac
  return 0
}

# lane_has_no_head_run <head> — TRUE (0) only when the watched lane PROVABLY has
# NO run for <head>. This is what keeps the #1614 fallback a DEAD-END repair
# rather than a trigger-shape repair: a lane that matched no trigger path but DID
# run for the head is not a dead end (precondition 1 is satisfiable), and widening
# there would be gratuitous. An UNREADABLE listing is NOT "no run" — fail closed,
# no widening.
lane_has_no_head_run() {
  local head="$1" args=() out rc=0
  [ -n "${REPO:-}" ] && args+=(--repo "$REPO")
  out="$($GH run list --commit "$head" --limit 1 --workflow "$WORKFLOW" \
           ${args[@]+"${args[@]}"} --json databaseId --jq '.[].databaseId' 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 1
  [ -z "$out" ] || return 1
  return 0
}

# check_surface_probe <ref> <label> [<exempt-noncode-events>] — measure EVERY
# workflow's check runs and commit statuses attached to <ref> (a branch name OR a
# sha), into the MAIN_HEALTH_* scratch set. The `label` names the surface in the
# summary lines, so a probe of the PR's evaluated tree never claims to be about
# main. <exempt-noncode-events> is 1 ONLY for the BASE surface (the
# `schedule`/`issues`/`issue_comment` exemption); the PR's evaluated tree passes 0
# and BLOCKS on them — the third argument is explicit so the exemption can never
# drift back onto the surface that gates the merge. Callers snapshot the scratch
# into their own prefix (BASE_* / TREE_*) immediately; see step 2c and step 4.5.
#
# A NON-CODE EVENT IS EXEMPT BY SURFACE, NOT BY EVENT (#1353). "Does this lane
# measure a revision?" is a property of the EVENT; "would refusing this red
# refuse every merge in a cron-noisy repo?" is a property of the SURFACE the red
# appears on — the BASE. On the TREE the exemption can only ever exempt an
# anomaly, because a default-branch run cannot attach to a PR head sha.
check_surface_probe() {
  local ref="$1" label="${2:-main}" allow_noncode="${3:-0}"
  local slug cr_json st_json map_file py_out sha rc=0 line tag job app concl url wf ev run_id ok_rest started_iso started_epoch red_note red_note_suffix noncode blocking_reason one wf_path pr_evaluable
  local map_sel=()
  local blocking=0 other=0 other_noneval=0
  local repo_args=()
  [ -n "${REPO:-}" ] && repo_args=(--repo "$REPO")
  MAIN_HEALTH_STATUS=""
  MAIN_HEALTH_REF="$ref"
  MAIN_HEALTH_SHA=""
  MAIN_HEALTH_SUMMARY=""
  MAIN_HEALTH_REDS=""
  MAIN_HEALTH_REDS_OTHER=""
  # The endpoint(s) that could NOT be read, named for the PARTIAL refusal. Empty
  # means the whole surface was read (both endpoints), or BOTH failed (which is
  # UNREADABLE).
  MAIN_HEALTH_UNREAD_EPS=""
  # Structured BLOCKING reds, for the staleness comparison (step 4.6):
  # `<name>\t<started_iso>\t<started_epoch>\t<url>`, one per code-measuring red.
  MAIN_HEALTH_RED_TS=""
  # EVERY red the surface carried, whatever the probe then did with it, as
  # `<name>\t<classification>` — one line per red (#2610). `MAIN_HEALTH_RED_TS` above is
  # the BLOCKING reds only (it feeds the staleness comparison), and a red that is
  # measured and then EXEMPTED (a non-code event, or a workflow that declares no PR
  # trigger) never enters it. A reader that asks "does the base carry a red check with
  # this NAME?" needs the wider set: on agent-infra main's only red is `script-validate`
  # on a `push` run from ci-main.yml, which the probe correctly calls not-PR-evaluable —
  # so a reader built on RED_TS alone would answer "no such red" about the one red that
  # exists. ONE probe, one extra accumulator: not a second reader.
  MAIN_HEALTH_ALL_REDS=""
  # The surface's own last-production time (max completed_at over its completed
  # checks) and that time as epoch seconds. Empty when the surface has no
  # completed check at all.
  MAIN_HEALTH_MAX_COMPLETED=""
  MAIN_HEALTH_MAX_COMPLETED_EPOCH=""
  MAIN_HEALTH_TOTAL=0
  MAIN_HEALTH_RED=0
  MAIN_HEALTH_RED_OTHER=0
  MAIN_HEALTH_PENDING=0
  # The NAMES behind the pending count. The count alone cannot tell the rail's own
  # [3/4] body-edit generation from real CI, and a refusal that says "N checks have
  # no conclusion" without saying WHICH asks the operator to guess. Filled from the
  # `PENDING` rows the classifier below already emits (#10399 review P1).
  MAIN_HEALTH_PENDINGS=""
  if [ -n "${REPO:-}" ]; then slug="repos/$REPO"; else slug="repos/{owner}/{repo}"; fi
  # The head SHA is for the RECORD: main moves, and the evidence must say which
  # commit was measured. Unresolvable is not fatal — a branch ref addresses
  # check-runs just as well — but it is then reported AS the ref, never as a sha.
  sha="$($GH api "$slug/commits/$ref" --jq .sha 2>/dev/null || true)"
  [ -n "$sha" ] && [ "$sha" != "null" ] || sha="$ref"
  MAIN_HEALTH_SHA="$sha"
  cr_json="$(mktemp "${TMPDIR:-/tmp}/admin-merge-checks.XXXXXX")"
  st_json="$(mktemp "${TMPDIR:-/tmp}/admin-merge-statuses.XXXXXX")"
  # READ EACH ENDPOINT INDEPENDENTLY — A PARTIAL READ IS CONSUMED, NEVER
  # DISCARDED (#1261 fix round). The old shape returned UNREADABLE the moment
  # EITHER call failed, which threw away the other endpoint's reds AND (on the
  # BASE) silently disarmed 4.6/4.7 — both are gated on the base being RED, so a
  # base that could not be read was treated as a base that is not red. A failed
  # call leaves an EMPTY file, so the parser sees no data for that half instead
  # of a half-written body (an unparseable body would also fail closed below).
  local cr_ok=1 st_ok=1 unread_eps=""
  if ! $GH api "$slug/commits/$sha/check-runs?per_page=100" --paginate > "$cr_json" 2>/dev/null; then
    cr_ok=0; : > "$cr_json"; unread_eps="check-runs"
  fi
  if ! $GH api "$slug/commits/$sha/status" > "$st_json" 2>/dev/null; then
    st_ok=0; : > "$st_json"
    unread_eps="${unread_eps:+$unread_eps and }status"
  fi
  # BOTH unreadable: the surface was never read AT ALL. That is the UNREADABLE
  # state proper, and the caller refuses loudly. (One unread endpoint is PARTIAL
  # — decided below, once what WAS read has been parsed.)
  if [ "$cr_ok" -eq 0 ] && [ "$st_ok" -eq 0 ]; then
    rm -f "$cr_json" "$st_json"
    MAIN_HEALTH_STATUS="unreadable"
    MAIN_HEALTH_SUMMARY="UNREADABLE — BOTH 'gh api .../check-runs' and '.../status' failed for '$ref' ($sha): the surface was never read"
    return 0
  fi
  py_out="$("$PYTHON_BIN" -c 'import datetime, json, sys
# ALLOW-LISTS, matching the header contract exactly. A conclusion/state is
# NON-RED only if it is NAMED here; "not in the red set" is not a synonym for
# non-red, because a token this list has never seen must fail closed. The old
# deny-list read `mystery_failure` (and `""`, and a status `state:"mystery"`) as
# silently non-red and merged on it (#1261 fix round).
NON_RED_CONC = {"success", "neutral", "skipped", "cancelled", "stale"}
NON_RED_STATE = {"success"}
# THE MEASUREMENT PREDICATE — ONE predicate, used at EVERY site that can set the
# surface anchor (#1353). `SURFACE` below is the surface LAST PRODUCTION TIME
# and step 4.6 compares a later base red against it: a red whose run STARTED after
# that moment cannot be part of what the surface measured. A COMPLETED check that
# measured NOTHING must not advance it — `skipped`/`cancelled`/`neutral`/`stale`
# exercised nothing, so stamping the anchor with such a run moved the
# last-production time FORWARD past the surface real evaluation and made an
# uncovered base red compare as already-measured (the stale green merged).
#   MEASURING_CONC — a completed CHECK RUN that actually RAN something. NAMED
#     explicitly and positive-direction: anything else (the non-measuring non-red
#     conclusions, and any token this rail has never seen) is NOT a measurement.
#   MEASURING_STATE — the legacy-status half (the GitHub status vocabulary is
#     `error|failure|pending|success`; `pending` is its own branch above and never
#     reaches the anchor).
# A surface with NO measuring completed check leaves the anchor EMPTY, which makes
# 4.6 refuse (fail closed) rather than compare against a non-measurement time.
MEASURING_CONC = {"success", "failure", "timed_out", "action_required"}
MEASURING_STATE = {"success", "failure", "error"}

def docs(path):
    try:
        raw = open(path, "r", encoding="utf-8", errors="replace").read()
    except OSError:
        raise SystemExit(2)
    dec = json.JSONDecoder()
    out = []
    i = 0
    while i < len(raw):
        while i < len(raw) and raw[i] in " \t\r\n":
            i += 1
        if i >= len(raw):
            break
        try:
            obj, i = dec.raw_decode(raw, i)
        except ValueError:
            raise SystemExit(2)
        out.append(obj)
    return out

# A CHECK RUN TIME, AS WHOLE EPOCH SECONDS, FOR THE STALENESS COMPARISON.
# GitHub returns ISO-8601 (`2026-09-22T15:52:53Z`); the rail compares these
# STRICTLY, so a value it cannot read must be distinguishable from epoch 0 (a
# real 1970 timestamp) - it is returned as the EMPTY STRING, and the caller
# fails closed rather than treating unparsable as "old".
def ts_epoch(raw):
    if not raw:
        return ""
    try:
        d = datetime.datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    except ValueError:
        return ""
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    try:
        return str(int(d.timestamp()))
    except (OverflowError, OSError, ValueError):
        return ""

cr_runs = []
for d in docs(sys.argv[1]):
    if isinstance(d, dict) and isinstance(d.get("check_runs"), list):
        cr_runs.extend(x for x in d["check_runs"] if isinstance(x, dict))

# THE LATEST CHECK RUN PER (app, name) DECIDES - a re-run leaves the OLD
# failing run in place beside the new one, so "any failure-like run" would
# report a RED that GitHub itself reports green (see the header).
# AN UNNAMED CHECK RUN IS CLASSIFIED, NOT DROPPED (#1353). `if not name: continue`
# let a RED vanish before classification: an unnamed run never entered `best`, so
# it appeared in NEITHER the red nor the pending list and the surface read
# `unmeasured — 0 failing of 0 measured` and MERGED. A check GitHub reports is a
# check the rail must CLASSIFY, so an unnamed one takes a PLACEHOLDER identity and
# is classified by its conclusion like any other — RED unless that conclusion is
# one this rail names as non-red.
UNNAMED_CHECK = "(unnamed check)"
best = {}
for cr_idx, r in enumerate(cr_runs):
    raw_name = str(r.get("name") or "")
    name = raw_name or UNNAMED_CHECK
    app = str((r.get("app") or {}).get("slug") or "unknown")
    try:
        rid = int(r.get("id") or 0)
    except (TypeError, ValueError):
        rid = 0
    entry = (rid, name, app, str(r.get("status") or ""), str(r.get("conclusion") or ""),
             str(r.get("html_url") or ""), str(r.get("started_at") or ""),
             str(r.get("completed_at") or ""))
    if raw_name and raw_name != UNNAMED_CHECK:
        # IDENTIFIED: the superseded-run rule (latest id per (app, name) wins).
        key = (app, name)
        if key not in best or rid > best[key][0]:
            best[key] = entry
    else:
        # UNNAMED or placeholder-named: key by the entry OWN identity as well, so
        # a newer unnamed non-red cannot SUPERSEDE an older unnamed red and
        # discard it before classification (#1353).
        best[(app, name, rid if rid else ("entry", cr_idx))] = entry

statuses = []
for d in docs(sys.argv[2]):
    if isinstance(d, dict) and isinstance(d.get("statuses"), list):
        statuses.extend(x for x in d["statuses"] if isinstance(x, dict))

# Legacy commit statuses: latest per context. NOTE the combined-status body
# reports aggregate state "pending" when it carries ZERO statuses, so the
# aggregate is NEVER read here - only the per-context entries. An UNNAMED context
# is NOT dropped either (#1353): it takes a placeholder and is classified by its
# state, so a red cannot vanish before classification.
UNNAMED_STATUS = "(unnamed status)"
sbest = {}
for st_idx, s in enumerate(statuses):
    raw_ctx = str(s.get("context") or "")
    ctx = raw_ctx or UNNAMED_STATUS
    stamp = str(s.get("updated_at") or s.get("created_at") or "")
    entry = (stamp, ctx, str(s.get("state") or ""), str(s.get("target_url") or ""))
    if raw_ctx and raw_ctx != UNNAMED_STATUS:
        # IDENTIFIED: latest per context wins (a re-announced status supersedes).
        if ctx not in sbest or stamp > sbest[ctx][0]:
            sbest[ctx] = entry
    else:
        # UNNAMED or placeholder-named: same per-entry identity rule as the check
        # half — two `context: ""` entries share one key otherwise, so a newer
        # unnamed non-red would supersede and DISCARD an older unnamed red.
        sbest[(ctx, st_idx)] = entry

# THE SURFACE OWN TIME - the last moment ANY MEASURING completed check on this
# surface was produced (see MEASURING_CONC / MEASURING_STATE: a completed check
# that ran nothing is not a measurement). The staleness rule compares a later
# base red against it: a red whose run STARTED after this time cannot be part of
# what the surface measured.
# Emitted for every probe; only the PR-tree call consumes it.
surface_epoch = 0
surface_iso = ""
reds = []   # (name, app, conclusion, url, started_iso)
pend = []
# A NON-COMPLETED CHECK RUN IS PENDING ONLY FOR A NAMED IN-FLIGHT SPELLING.
# `status != "completed"` used to be the whole test — a DENY-list — so a spelling
# this rail had never seen (`completely_finished`, `Completed`, the empty string)
# became PENDING, PENDING is never red, and the surface still read GREEN (#1353).
# The in-flight set is NAMED here; any OTHER non-completed status is classified by
# its CONCLUSION, RED unless that conclusion is one this rail names as non-red.
IN_FLIGHT_STATUS = {"queued", "in_progress", "waiting", "requested", "pending"}
for _, name, app, status, concl, url, started, completed in best.values():
    if status != "completed":
        if status in IN_FLIGHT_STATUS:
            pend.append((name, app))
        elif concl not in NON_RED_CONC:
            # The STATUS is the token that failed closed, so it is CARRIED on the
            # red line (its last field) and named in the refusal — an operator
            # must be able to see WHICH spelling was unrecognised.
            reds.append((name, app, concl, url, started,
                         "status %r is not a NAMED in-flight spelling (queued/in_progress/waiting/requested/pending)" % status))
        # NEITHER branch is a MEASUREMENT: a non-completed run has no
        # `completed_at`, so it can never set the surface time below.
        continue
    e = ts_epoch(completed)
    if concl in MEASURING_CONC and e != "" and (surface_iso == "" or int(e) > surface_epoch):
        surface_epoch, surface_iso = int(e), completed
    if concl not in NON_RED_CONC:
        reds.append((name, app, concl, url, started, ""))
for stamp, ctx, state, url in sbest.values():
    if state == "pending":
        # PENDING is checked FIRST and is its own state, never red: the GitHub
        # combined-status body reports aggregate `pending` for a body carrying
        # ZERO statuses, and that is not a failure.
        pend.append((ctx, "commit-status"))
        # AND IT IS NOT A MEASUREMENT (#1353). `updated_at` on a PENDING status is
        # the last time it was queued or re-announced — no revision was measured.
        # Letting it advance the surface time moved the staleness anchor FORWARD
        # past the PR real last production, so a base red that began in between
        # compared as already measured and the stale green merged. Only a status
        # that actually measured something may set the anchor.
        continue
    elif state not in NON_RED_STATE:
        reds.append((ctx, "commit-status", state, url, stamp, ""))
    e = ts_epoch(stamp)
    if state in MEASURING_STATE and e != "" and (surface_iso == "" or int(e) > surface_epoch):
        surface_epoch, surface_iso = int(e), stamp

total = len(best) + len(sbest)

def sane(v):
    # ⛔ THE ROW IS READ POSITIONALLY (`IFS=$'\t' read -r tag name app ...`), so a
    # TAB or NEWLINE inside ANY upstream free-text field IMPERSONATES the field
    # separator and SHIFTS every later field: a status `context` carrying three
    # tabs moves `app` off "commit-status" (defeating the legacy-status gate
    # that keys on it) and lands an attacker-chosen URL in the field the run-id
    # regex reads, so a `schedule` run is exempted for a code-measuring red. The
    # same shift forges `started_iso`/`epoch`, which the staleness anchor uses.
    # Every interpolated field is flattened to one line here — at the ONE
    # producer — so the whole shift class is closed at its source.
    return str(v).replace("\t", " ").replace("\r", " ").replace("\n", " ")

for name, app, concl, url, tiso, note in reds:
    sys.stdout.write("RED\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n"
                     % tuple(sane(x) for x in (name, app, concl, url, tiso, ts_epoch(tiso), note)))
for name, app in pend:
    sys.stdout.write("PENDING\t%s\t%s\n" % (sane(name), sane(app)))
sys.stdout.write("SURFACE\t%s\t%s\n" % (sane(surface_iso), ("" if surface_iso == "" else str(surface_epoch))))
sys.stdout.write("COUNTS\t%d\t%d\t%d\t%d\n" % (total, len(reds), len(pend), total - len(reds) - len(pend)))' \
    "$cr_json" "$st_json" 2>/dev/null)"
  rc=$?
  rm -f "$cr_json" "$st_json"
  if [ "$rc" -ne 0 ] || [ -z "$py_out" ]; then
    MAIN_HEALTH_STATUS="unreadable"
    MAIN_HEALTH_SUMMARY="UNREADABLE — the check surface for '$ref' ($sha) could not be parsed"
    return 0
  fi
  # Resolve every failing check's EVENT — from ONE bounded `gh run list`. Only
  # fetched when a red actually exists, so the green path costs no extra call. A
  # failure here leaves the map empty, and an unresolved red BLOCKS (below):
  # failing to classify a red is not a reason to ignore it. (A HERE-STRING, not a
  # pipe into `grep -q`: on a large enough payload the writer takes SIGPIPE under
  # `pipefail` and `grep -q` reports "not found" for a match that is present —
  # #841, and scripts/check-no-sigpipe-grep.sh enforces it.)
  map_file=""
  if grep -q '^RED' <<< "$py_out"; then
    map_file="$(mktemp "${TMPDIR:-/tmp}/admin-merge-runmap.XXXXXX")"
    # WHICH LISTING ANSWERS FOR THIS SURFACE? `--branch` names a branch; a SHA
    # is not a branch, so a sha-keyed surface (the PR's tree) must be listed by
    # `--commit`. Real gh has both flags; using the wrong one silently yields an
    # empty map here, which would report every red's workflow as unresolved.
    if [ "${#ref}" -eq 40 ] && [ -z "${ref//[0-9a-f]/}" ]; then
      map_sel=(--commit "$ref")
    else
      map_sel=(--branch "$ref")
    fi
    # shellcheck disable=SC2086
    $GH run list "${map_sel[@]}" --limit "$MAIN_HEALTH_RUN_MAP_LIMIT" \
      ${repo_args[@]+"${repo_args[@]}"} \
      --json databaseId,event,workflowName \
      --jq '.[] | "\(.databaseId)\t\(.event)\t\(.workflowName)"' \
      > "$map_file" 2>/dev/null || true
  fi
  while IFS= read -r line; do
    case "$line" in
      COUNTS$'\t'*)
        IFS=$'\t' read -r tag MAIN_HEALTH_TOTAL _ MAIN_HEALTH_PENDING ok_rest <<< "$line"
        ;;
      PENDING$'\t'*)
        # ⛔ THE ROW WAS ALREADY BEING EMITTED AND WAS BEING DROPPED. Without this
        # branch only the COUNT survived, so the #10399 refusal could name no
        # offender while every other refusal in this file insists on naming one.
        IFS=$'\t' read -r tag pend_name pend_app <<< "$line"
        MAIN_HEALTH_PENDINGS="${MAIN_HEALTH_PENDINGS}${MAIN_HEALTH_PENDINGS:+$'\n'}  ${pend_name} (${pend_app:-unknown app}) — no conclusion"
        ;;
      SURFACE$'\t'*)
        # The surface's own production time; consumed by the PR-tree probe in
        # step 4.6. A missing second field (the epoch) means "no completed
        # check", which the comparison treats as "no measurement time".
        IFS=$'\t' read -r tag MAIN_HEALTH_MAX_COMPLETED MAIN_HEALTH_MAX_COMPLETED_EPOCH <<< "$line"
        ;;
      RED$'\t'*)
        IFS=$'\t' read -r tag job app concl url started_iso started_epoch red_note <<< "$line"
        # A NOTE carried by the row — the token that FAILED CLOSED (an
        # unrecognised non-completed status, #1353). Appended to the display line
        # wherever the red lands, so the operator sees WHICH spelling was not
        # NAMED rather than only the conclusion it was classified by.
        red_note_suffix=""
        [ -n "$red_note" ] && red_note_suffix=" — ${red_note}"
        # WHICH EVENT PRODUCED THIS CHECK? A red on a `schedule`/`issues` lane
        # measures no revision, and blocking on it would refuse every merge (see
        # MAIN_HEALTH_RUN_MAP_LIMIT). The run id is in the check run's own URL.
        run_id="$(printf '%s' "$url" | sed -n 's#.*/runs/\([0-9][0-9]*\).*#\1#p' | head -1)"
        wf=""; ev=""; wf_path=""
        # ⛔ A LEGACY COMMIT STATUS IS NEVER RUN-RESOLVED. The `url` on a status
        # row is the status's OWN, app-supplied `target_url` — an arbitrary link
        # — so a `/runs/<N>` inside it names SOME run, not the run that produced
        # this row; a commit status has NO triggering Actions event at all. Left
        # ungated, a status red could inherit a `schedule`/`issues` event from
        # such a URL and be EXEMPTED on the base, though an app's verdict on the
        # commit measures code. Clearing the id closes BOTH the map path and the
        # per-run resolve (#1446 review): the row stays code-measuring and BLOCKS.
        [ "$app" = "commit-status" ] && run_id=""
        if [ -n "$run_id" ] && [ -s "$map_file" ]; then
          ev="$(awk -F'\t' -v id="$run_id" '$1 == id { print $2; exit }' "$map_file")"
          wf="$(awk -F'\t' -v id="$run_id" '$1 == id { print $3; exit }' "$map_file")"
        fi
        # ── #1446: RESOLVE A RUN THE SNAPSHOT DID NOT CARRY ─────────────────
        # The map above is a SNAPSHOT — one bounded, branch- or sha-scoped
        # `gh run list` (empty when that listing fails) — so it can simply not
        # carry a red's run. Left unresolved, a `schedule`/`issues` base red
        # would classify as code-measuring and step 4.6 would refuse every
        # stale-surface PR (the observed `finding-provenance` refusal — a run
        # that WAS inside the window when re-checked). Resolve THIS run by its
        # own id instead.
        # THE TWO CASES STAY DISTINGUISHABLE and only one of them is exempt:
        #   * the resolve SUCCEEDS and names a non-code event -> `ev` is set and
        #     the existing base-side exemption below applies;
        #   * the resolve SUCCEEDS and names a code event -> `ev` is set and the
        #     red BLOCKS exactly as before (the workflow is named now, not
        #     `(workflow unresolved)`);
        #   * the resolve ANSWERS NOTHING -> `ev` stays empty, `wf` stays
        #     `(workflow unresolved)`, and the red BLOCKS on BOTH surfaces — the
        #     fail-closed arm is unchanged. Never default an unresolved run to
        #     exempt; that would convert this guard into a fail-open.
        if [ -z "$ev" ] && [ -n "$run_id" ]; then
          one="$($GH api "$slug/actions/runs/$run_id" \
                   --jq '[(.event // ""), (.name // "")] | @tsv' 2>/dev/null || true)"
          # Accept ONLY the projected shape (an event AND the tab separator). A
          # tab-less answer is not a resolution, so `ev` stays empty and the red
          # stays fail-closed — the same arm as a resolve that answered nothing.
          if [ -n "$one" ] && [ "${one#*$'\t'}" != "$one" ]; then
            ev="${one%%$'\t'*}"
            wf="${one#*$'\t'}"
          fi
        fi
        [ -n "$wf" ] || wf="(workflow unresolved)"
        # WHICH NON-CODE EVENTS ARE EXEMPT, AND ON WHICH SURFACE (#1353).
        # `schedule`/`issues`/`issue_comment` measure no revision, so on the BASE
        # such a red is REPORTED and does not block — otherwise a repo whose cron
        # lanes are red most days refuses every merge. The exemption is scoped to
        # the base because on the PR's EVALUATED TREE it is VACUOUS BY
        # CONSTRUCTION: a run on the DEFAULT BRANCH cannot attach to a PR head
        # sha, so a non-code red there is not noise but an ANOMALY — a red this
        # merge would land. Treating it as noise (the old unconditional branch)
        # routed it to the non-blocking list and merged. The surface decides; the
        # event merely names itself. An UNRESOLVED event blocks on both.
        case "$ev" in
          schedule|issues|issue_comment) noncode=1 ;;
          *) noncode=0 ;;
        esac
        # ── #6807: IS THE WORKFLOW MEASURABLE FROM A PR AT ALL? ─────────────
        # The base-side exemption above keys on the EVENT, so `push` falls through
        # to code-measuring even when the WORKFLOW cannot possibly run on a PR
        # (`deploy-hosted.yml`: `on: push` + `workflow_dispatch`, no
        # pull_request). Such a red then enters MAIN_HEALTH_RED_TS and §4.6 refuses
        # every PR with an unsatisfiable remedy. Ask the WORKFLOW FILE instead.
        # SCOPED TO THE BASE: on the PR's evaluated tree a red whose workflow
        # cannot attach to a head sha is an ANOMALY, not noise (the same reasoning
        # as the non-code exemption), so the tree never consults this. The path is
        # resolved from the RUN itself — the one unambiguous source (`gh run list`
        # cannot project a path, and a name-keyed index could let a PR-evaluable
        # red borrow a push-only workflow's path: a fail-open) — and only when the
        # event has not already decided the red's fate. An affirmative `no`
        # exempts; `yes`/`unknown` block.
        pr_evaluable=1
        if [ "$allow_noncode" -eq 1 ] && [ "$noncode" -eq 0 ]; then
          if [ -z "$wf_path" ] && [ -n "$run_id" ]; then
            wf_path="$($GH api "$slug/actions/runs/$run_id" --jq '.path // ""' 2>/dev/null || true)"
          fi
          workflow_pr_evaluable "$slug" "$wf_path" "$ref"
          case "$WPE_VERDICT" in
            no) pr_evaluable=0 ;;
            *) pr_evaluable=1 ;;
          esac
        fi
        # The reason a NON-CODE red blocks. Only reachable when allow_noncode is
        # 0 (the base exempts and returns above), so the reason is stated in the
        # display line rather than left to be inferred.
        blocking_reason=""
        if [ "$noncode" -eq 1 ]; then
          blocking_reason=" — NOT EXEMPT ON THIS SURFACE: a non-code event on the PR's evaluated tree is an ANOMALY, so BLOCKING"
        fi
        if [ "$allow_noncode" -eq 1 ] && [ "$pr_evaluable" -eq 0 ]; then
            [ -n "$MAIN_HEALTH_REDS_OTHER" ] && MAIN_HEALTH_REDS_OTHER="${MAIN_HEALTH_REDS_OTHER}"$'\n'
            MAIN_HEALTH_REDS_OTHER="${MAIN_HEALTH_REDS_OTHER}   • ${job} — workflow '${wf}' — event '${ev:-(unresolved)}' — ${concl}${red_note_suffix} — NOT pull-request-evaluable (this workflow declares no pull_request/pull_request_target trigger, so no PR can attach its checks to a head sha), so NOT blocking — ${url}"
            [ -n "$MAIN_HEALTH_ALL_REDS" ] && MAIN_HEALTH_ALL_REDS="${MAIN_HEALTH_ALL_REDS}"$'\n'
            MAIN_HEALTH_ALL_REDS="${MAIN_HEALTH_ALL_REDS}${job}"$'\t'"exempt: this workflow declares no PR trigger, so a PR can never run it"
            other_noneval=$((other_noneval + 1))
        elif [ "$noncode" -eq 1 ] && [ "$allow_noncode" -eq 1 ]; then
            [ -n "$MAIN_HEALTH_REDS_OTHER" ] && MAIN_HEALTH_REDS_OTHER="${MAIN_HEALTH_REDS_OTHER}"$'\n'
            MAIN_HEALTH_REDS_OTHER="${MAIN_HEALTH_REDS_OTHER}   • ${job} — workflow '${wf}' — event '${ev}' — ${concl}${red_note_suffix} — NOT a code measurement, so NOT blocking — ${url}"
            [ -n "$MAIN_HEALTH_ALL_REDS" ] && MAIN_HEALTH_ALL_REDS="${MAIN_HEALTH_ALL_REDS}"$'\n'
            MAIN_HEALTH_ALL_REDS="${MAIN_HEALTH_ALL_REDS}${job}"$'\t'"exempt: a non-code event (${ev:-(unresolved)}) measures no revision"
            other=$((other + 1))
        else
            [ -n "$MAIN_HEALTH_REDS" ] && MAIN_HEALTH_REDS="${MAIN_HEALTH_REDS}"$'\n'
            if [ -n "$ev" ]; then
              MAIN_HEALTH_REDS="${MAIN_HEALTH_REDS}   • ${job} — workflow '${wf}' — event '${ev}' — ${concl}${red_note_suffix}${blocking_reason} — ${url}"
            else
              MAIN_HEALTH_REDS="${MAIN_HEALTH_REDS}   • ${job} — workflow '${wf}' — ${concl}${red_note_suffix} — ${url}"
            fi
            # Keep the red's own START time for the staleness comparison: a red
            # whose run began after the PR's surface was produced cannot have
            # been measured by it (step 4.6).
            [ -n "$MAIN_HEALTH_ALL_REDS" ] && MAIN_HEALTH_ALL_REDS="${MAIN_HEALTH_ALL_REDS}"$'\n'
            MAIN_HEALTH_ALL_REDS="${MAIN_HEALTH_ALL_REDS}${job}"$'\t'"blocking: ${concl}"
            [ -n "$MAIN_HEALTH_RED_TS" ] && MAIN_HEALTH_RED_TS="${MAIN_HEALTH_RED_TS}"$'\n'
            MAIN_HEALTH_RED_TS="${MAIN_HEALTH_RED_TS}${job}"$'\t'"${started_iso}"$'\t'"${started_epoch}"$'\t'"${url}"
            blocking=$((blocking + 1))
        fi
        ;;
    esac
  done <<< "$py_out"
  [ -n "$map_file" ] && rm -f "$map_file"
  # #6807: the per-invocation workflow-declarability cache, if the base surface
  # built one.
  if [ -n "$WF_PR_EVAL_CACHE" ]; then
    rm -f "$WF_PR_EVAL_CACHE"
    WF_PR_EVAL_CACHE=""
  fi
  if ! counter_is_number "$MAIN_HEALTH_TOTAL"; then
    MAIN_HEALTH_STATUS="unreadable"
    MAIN_HEALTH_SUMMARY="UNREADABLE — the check surface for '$ref' ($sha) produced unreadable counters"
    return 0
  fi
  # MAIN_HEALTH_RED is the BLOCKING count (code-measuring events), not the raw
  # red count: the raw count would refuse on a failing cron lane.
  MAIN_HEALTH_RED="$blocking"
  MAIN_HEALTH_RED_OTHER="$other"
  # A PARTIAL SURFACE IS NOT A CERTIFICATE (#1261 fix round). One endpoint was
  # never read, so the rail cannot show that half carries no red — and on the
  # BASE, a red hidden there is exactly what disarmed 4.6/4.7 and merged the
  # stale green this rail exists to stop. Whatever WAS read is kept and reported
  # (the RED lines below), so a red visible on the readable endpoint is named in
  # the refusal rather than discarded. Refusing is the counterfactual-correct
  # answer: with a COMPLETE read, a red there would have refused, so a partial
  # read must never convert a refusal into a merge.
  if [ -n "$unread_eps" ]; then
    MAIN_HEALTH_UNREAD_EPS="$unread_eps"
    MAIN_HEALTH_STATUS="partial"
    MAIN_HEALTH_SUMMARY="PARTIAL — 'gh api .../$unread_eps' failed for '$ref' ($sha): only the OTHER endpoint was read, so this surface is only HALF measured"
    if [ "$MAIN_HEALTH_RED" -gt 0 ]; then
      MAIN_HEALTH_SUMMARY="$MAIN_HEALTH_SUMMARY; the half that WAS read already carries $MAIN_HEALTH_RED code-measuring red(s)"
    fi
    return 0
  fi
  if [ "$MAIN_HEALTH_TOTAL" -eq 0 ]; then
    MAIN_HEALTH_STATUS="unmeasured"
    MAIN_HEALTH_SUMMARY="UNMEASURED — 0 check runs and 0 commit statuses are attached to '$ref' ($sha): $label has no checks yet, so this certifies NOTHING about the tree"
    return 0
  fi
  if [ "$MAIN_HEALTH_RED" -gt 0 ]; then
    MAIN_HEALTH_STATUS="red"
    MAIN_HEALTH_SUMMARY="RED — $MAIN_HEALTH_RED code-measuring check(s) FAIL on '$ref' ($sha) (of $MAIN_HEALTH_TOTAL measured, pending $MAIN_HEALTH_PENDING)"
  else
    MAIN_HEALTH_STATUS="green"
    MAIN_HEALTH_SUMMARY="GREEN — no code-measuring check fails among $MAIN_HEALTH_TOTAL check(s) on '$ref' ($sha) (pending $MAIN_HEALTH_PENDING)"
  fi
  if [ "$other" -gt 0 ]; then
    MAIN_HEALTH_SUMMARY="$MAIN_HEALTH_SUMMARY; $other further red check(s) on NON-code events (schedule/issues) — reported, not blocking"
  fi
  if [ "$other_noneval" -gt 0 ]; then
    MAIN_HEALTH_SUMMARY="$MAIN_HEALTH_SUMMARY; $other_noneval further red check(s) on workflows that declare NO pull_request/pull_request_target trigger — NOT pull-request-evaluable, so reported, not blocking (no PR can attach their checks to a head sha, so no PR could ever measure them; #6807)"
  fi
  return 0
}

# wait_for_run <run-id> [<attempt-before>] — the RE-RUN wait: poll until the
# run is `completed` AND, when an attempt baseline is supplied, its run attempt
# has ADVANCED (the re-run was actually OBSERVED, not assumed).
#   return 0  completed (and the re-run observed, when a baseline was supplied).
#   return 1  STALLED — still non-completed at the DERIVED per-shard bound. THIS is
#             the failure signal. A REMOTE run exposes no within-job activity
#             signal (`updatedAt` advances on job/step transitions, so a single
#             long step freezes it for the whole job), so a separate no-progress
#             window cannot distinguish a healthy long run from a wedged one — it
#             can only fire EARLY. The run's own green-derived bound is therefore
#             the ONLY honest discriminator; the message names the shard, its
#             green n and its green max.
#   return 2  CEILING — still RUNNING at an EXPLICIT `--rerun-timeout`. An
#             operator's cap is not a claim about the run, so this stays distinct
#             from STALLED; it is still NOT a failure of the run.
#   return 3  UNOBSERVABLE — gh could not be read for the whole bound, so the
#             run's state was NEVER OBSERVED. Deliberately distinct from STALLED
#             (1): "exceeded its bound" is a claim about a run we watched; an
#             outage is the absence of that observation. Opposite remedies.
#   return 4  RE-RUN NOT OBSERVED — `gh run rerun` was accepted, but the run kept
#             reporting its PRE-rerun attempt (still `completed`) for the whole
#             window. The old result is not a re-run result, so it can neither
#             certify nor clear the PR. A `gh run rerun` is ASYNCHRONOUS: without
#             this state the first poll returns the OLD `completed` and the wait
#             "succeeds" without ever tracking the re-run.
# A still-RUNNING run prints progress (status, attempt, elapsed, bound, and the
# derivation) instead of a verdict — the old flat message read as a failure
# when it was only impatience (B5).
RERUN_WAIT_WAITED=0
RERUN_WAIT_LAST=""
RERUN_WAIT_STATE=""
wait_for_run() {
  local run_id="$1" attempt_before="${2:-}" waited=0 unobs=0 observed=0 step adv status attempt line
  RERUN_WAIT_WAITED=0; RERUN_WAIT_LAST=""; RERUN_WAIT_STATE=""
  # Wall-clock accounting must advance even when the test seam sets the interval
  # to 0 — a 0-step loop can never reach its own bound and spins forever.
  step="$POLL_INTERVAL"; [ "$step" -gt 0 ] 2>/dev/null || step=1
  while [ "$waited" -lt "$RERUN_TIMEOUT" ]; do
    # ONE gh call: the run's completion state and its run attempt. `updatedAt` is
    # deliberately NOT read — it advances on JOB/STEP TRANSITIONS, so it is frozen
    # for the entire duration of a single long step, and treating its freeze as
    # "no progress" is the false STALL this wait no longer reports. `attempt` is
    # different in kind: GitHub increments it for each re-run, so it is the
    # OBSERVABLE identity of the re-run we requested.
    # shellcheck disable=SC2086
    line="$($GH run view "$run_id" ${repo_args[@]+"${repo_args[@]}"} \
      --json status,attempt --jq '"\(.status)\t\(.attempt // "")' 2>/dev/null || true)"
    IFS=$'\t' read -r status attempt <<< "$line"
    RERUN_WAIT_LAST="status=${status:-<unreadable>} attempt=${attempt:-<unreadable>}"
    # "Could not read the run" is NOT "the run exceeded its bound". A gh failure
    # yields an empty status; counting that as progress-less made a transient
    # gh/auth/network outage report STALLED — a claim the code cannot support,
    # because it never read the run. The two faults have OPPOSITE remedies —
    # repair gh, vs escalate a wedged run — so they must not share a diagnosis.
    # Fail-closed either way: an unreadable run still blocks.
    if [ -z "$status" ] || [ "$status" = "unknown" ]; then
      adv=$((10#$step))
      [ "$adv" -gt $((RERUN_TIMEOUT - waited)) ] && adv=$((RERUN_TIMEOUT - waited))
      [ "$adv" -gt 0 ] && sleep "$adv"
      unobs=$((unobs + adv)); waited=$((waited + adv)); continue
    fi
    observed=1; unobs=0
    if [ "$status" = "completed" ]; then
      # THE RE-RUN MUST BE OBSERVED, NOT ASSUMED. Until GitHub registers the new
      # attempt, `gh run view` still reports the OLD attempt as completed; taking
      # that as success would be the "request a re-run and then do not track it"
      # defect. No baseline (or no attempt field) keeps the status-only contract.
      if [ -z "$attempt_before" ] || [ -z "$attempt" ] \
         || { [ "$attempt" -gt "$attempt_before" ] 2>/dev/null; }; then
        RERUN_WAIT_WAITED=$waited
        RERUN_WAIT_STATE="completed"
        return 0
      fi
      RERUN_WAIT_STATE="rerun-not-observed"
      info "admin-merge: … RE-RUN wait: run $run_id still reports attempt $attempt (re-run requested at attempt $attempt_before) — GitHub has not started the re-run yet (${waited}s of the ${RERUN_TIMEOUT}s bound — ${RERUN_TIMEOUT_SOURCE})."
    else
      RERUN_WAIT_STATE="still-running"
      info "admin-merge: … RE-RUN wait: run $run_id STILL RUNNING (status=${status}, attempt=${attempt:-?}, ${waited}s of the ${RERUN_TIMEOUT}s bound — ${RERUN_TIMEOUT_SOURCE}). A running job is not a failure — waiting."
    fi
    adv=$((10#$step))
    [ "$adv" -gt $((RERUN_TIMEOUT - waited)) ] && adv=$((RERUN_TIMEOUT - waited))
    [ "$adv" -gt 0 ] && sleep "$adv"
    waited=$((waited + adv))
  done
  RERUN_WAIT_WAITED=$waited
  [ "$RERUN_WAIT_STATE" = "rerun-not-observed" ] && return 4
  # The bound elapsed. If the run was NEVER observed — unreadable for the whole
  # bound — this is not a stall claim: a stall is a claim about a run we watched.
  if [ "$observed" -eq 0 ] || [ "$unobs" -ge "$RERUN_TIMEOUT" ]; then
    RERUN_WAIT_STATE="unobservable"
    return 3
  fi
  # PROVENANCE, not timing, decides the verdict: an explicit cap is a CEILING;
  # the derived per-shard bound is a STALL.
  if [ "${RERUN_TIMEOUT_EXPLICIT:-0}" -eq 1 ]; then RERUN_WAIT_STATE="ceiling"; return 2; fi
  RERUN_WAIT_STATE="stalled"
  return 1
}

# describe_run_observation <run-id> — print what the RE-RUN wait last observed:
# each job's status/conclusion and its age. Called ONLY on an expiry path, so it
# costs one Jobs API read there and nothing on the happy path. It reads ages from
# `completed_at`/`started_at` and NEVER from `updatedAt` (see wait_for_run).
describe_run_observation() {
  local run_id="$1" json_file
  json_file="$(mktemp "${TMPDIR:-/tmp}/admin-merge-rerun-jobs.XXXXXX")"
  if ! fetch_run_jobs "$run_id" > "$json_file" 2>/dev/null || [ ! -s "$json_file" ]; then
    rm -f "$json_file"
    say_err "   last observed: the run's job list could NOT be read (gh/api error) — its per-check state was never observable"
    return 0
  fi
  # `fetch_run_jobs` uses `gh api --paginate`, which emits ONE JSON OBJECT PER
  # PAGE — a plain `json.load` raises `Extra data` on any large job list, i.e.
  # exactly the failing run this diagnostic exists for. Decode the document
  # stream (the same shape `derive_rerun_timeout` already parses).
  "$PYTHON_BIN" - "$json_file" <<'PY' 1>&2 || true
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc)
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
dec = json.JSONDecoder(); i = 0; jobs = []; saw = False
while i < len(raw):
    while i < len(raw) and raw[i] in " \t\r\n":
        i += 1
    if i >= len(raw):
        break
    try:
        obj, i = dec.raw_decode(raw, i)
    except ValueError:
        print("   last observed: the run's job list is unparsable (not a JSON document stream)")
        raise SystemExit
    if isinstance(obj, dict) and isinstance(obj.get("jobs"), list):
        saw = True
        jobs.extend(j for j in obj["jobs"] if isinstance(j, dict))
if not saw:
    print("   last observed: the response carried no job list")
    raise SystemExit
if not jobs:
    print("   last observed: the run lists NO jobs (a zero-job run measures nothing)")
    raise SystemExit
for j in jobs:
    raw_ts = j.get("completed_at") or j.get("started_at") or j.get("created_at")
    age = "age unknown"
    if raw_ts:
        try:
            age = "age %ds" % int((now - datetime.datetime.fromisoformat(str(raw_ts).replace("Z", "+00:00"))).total_seconds())
        except Exception:
            pass
    print("   last observed: job %r status=%s conclusion=%s %s" % (
        j.get("name"), j.get("status") or "unknown", j.get("conclusion") or "-", age))
PY
  rm -f "$json_file"
}

# print_bounds [<run-id>] — the re-run bound, its per-shard table (each figure
# carrying its n), and the source. `rerun-timeout=` stays the FIRST line:
# existing greps depend on the key, and it is also the STALLED threshold — there
# is ONE bound for a remote run (see wait_for_run). With NO run id there is
# nothing to derive from, so this is the one path that prints the fail-safe and
# makes no call.
print_bounds() {
  print_bounds_rerun "${1:-}"
  # THE FIRST-CHECKS WAIT'S OWN BOUNDS (#2481), printed with the same discipline
  # as the re-run bound: a `key=value` line first (greppable, stable), then the
  # DERIVATION as the source. They are printed here because an operator reading
  # `--print-bounds` must be able to see what the OTHER wait will do — the whole
  # B7 lesson is that an ambiguous bound sends the operator to the wrong knob.
  #
  # ⛔ `first-checks-stall` is NOT the flat "stall window" the re-run wait gave
  # up: there is no failing shard yet to sample a green population from (the run
  # has not finished), so this period derives from the lane's MEASURED step
  # distribution and is PROMOTED at runtime by the steps actually observed on the
  # runs being waited on. It is a floor on patience, never a claim that a shorter
  # silence means a wedged run.
  printf 'first-checks-stall=%s\n' "$FIRST_CHECKS_STALL"
  printf 'first-checks-ceiling=%s\n' "$FIRST_CHECKS_CEILING"
  printf 'first-checks-window=%s\n' "$FIRST_CHECKS_WAIT"
  printf 'first-checks-poll=%s\n' "$FIRST_CHECKS_POLL"
  printf 'first-checks-source=STALL = 2 × the longest MEASURED single step (4380s, "Bash shards"); CEILING = 2 × the slowest MEASURED green run (9032s); STALL is promoted at runtime to 2 × the longest COMPLETED step on the runs being waited on; WINDOW bounds only the states with no progress to observe (no run yet, or an unreadable surface).\n'
}

# print_bounds_rerun [<run-id>] — the RE-RUN bound's own half (see above).
print_bounds_rerun() {
  local run_id="$1"
  if [ "$RERUN_TIMEOUT_EXPLICIT" -eq 1 ]; then
    printf 'rerun-timeout=%s\n' "$RERUN_TIMEOUT"
    printf 'source=explicit --rerun-timeout (a CEILING, not a derived stall bound)\n'
    return 0
  fi
  if [ -z "$run_id" ]; then
    printf 'rerun-timeout=%s\n' "$FAILSAFE_RERUN_TIMEOUT"
    printf 'source=fail-safe %ss — no run id supplied; the derivation needs a run (pass one: --print-bounds <run-id>)\n' "$FAILSAFE_RERUN_TIMEOUT"
    return 0
  fi
  derive_rerun_timeout "$run_id"
  printf 'rerun-timeout=%s\n' "$DERIVED_RERUN_TIMEOUT"
  [ -n "$DERIVED_TABLE" ] && printf '%s\n' "$DERIVED_TABLE"
  printf 'source=%s\n' "$DERIVED_RERUN_SOURCE"
}

# build_evidence — the machine-readable comment. The marker binds the evidence
# to ONE head SHA: every push invalidates it, and the merge gate matches on it.
# ── EVIDENCE TAIL: one bound, one note, no fences ───────────────────────────
# The shape here is deliberately minimal, and the reasons are load-bearing:
#
#  * A LIST, not a fenced code block. A fence is a parser with state: a node id
#    containing a backtick run closes it early and swallows the rest of the
#    comment. A list has no such surface — so the fence-length computation, the
#    clip disclosure and the fence-balance test all cease to exist rather than
#    needing to be right.
#  * ONE limit for every embedded list, sized from the OBSERVED distribution:
#    main's union baseline runs ~18-19 entries of ~60 chars, and the default
#    window is 10 runs. So in practice the limit never fires — it is a safety
#    branch, not machinery that engages on every merge. 25 x 300 = 7,500 chars
#    per list; four lists is 30,000, comfortably under GitHub's 65,536-char body
#    cap, with no per-case arithmetic to re-derive.
#  * ONE note, on every list that was trimmed. A capped list that LOOKS complete
#    is worse than no list, so trimming is always stated.
#  * The display policy is stated ONCE in the body, not recomputed per list —
#    which is why there is no second note vocabulary.
#
# Bounds here are sized to what has actually been observed, not to a hypothetical
# worst case. Over-sizing them was how this section accumulated four interacting
# rules and a fence algorithm in the first place.
EVIDENCE_ENTRIES=25
EVIDENCE_WIDTH=300

# evidence_token_escape — neutralise the markdown/HTML metacharacters a hostile
# `FAILED` token could carry, before it is written into the POSTED EVIDENCE. This
# is the RECONCILIATION of two properties that pull in opposite directions:
#   * #1353 requires a DROPPED token to be NAMED in the posted evidence, and
#   * #3756 requires the evidence to stay INERT to a hostile token — a ` ``` `
#     payload must not open a code fence and swallow the comment, a `~~~` fence
#     must not do the same, and a `</details>` must not close a block early.
# The evidence is the ONE rendered surface; the escape is DISCLOSED in the list
# heading, so a reader knows the text is the token with metacharacters escaped
# rather than the raw bytes. The rail's STDERR keeps the token VERBATIM — a
# terminal is not a markdown surface, and the byte-exact text is what an operator
# greps for.
evidence_token_escape() {
  sed -e 's/\\/\\\\/g' -e 's/`/\\`/g' -e 's/</\\</g' -e 's/>/\\>/g' -e 's/~/\\~/g'
}

# One <details> block: a list, capped, with a single stated remainder.
#   $1 summary   $2 newline-separated content   $3 what to say when empty
evidence_list() {
  local summary="$1" content="$2" empty="$3"
  local shown total more=0
  # `|| true` guards the pipeline against SIGPIPE from `head` on large input.
  shown="$(printf '%s\n' "$content" | head -n "$EVIDENCE_ENTRIES" | cut -c1-"$EVIDENCE_WIDTH" || true)"
  total="$(printf '%s\n' "$content" | grep -c . 2>/dev/null || true)"
  total="${total:-0}"
  if [ "$total" -gt "$EVIDENCE_ENTRIES" ]; then more=$((total - EVIDENCE_ENTRIES)); fi
  printf '<details><summary>%s</summary>\n\n' "$summary"
  if [ -z "$(printf '%s' "$shown" | tr -d '[:space:]')" ]; then
    printf '%s\n' "$empty"
  else
    printf '%s\n' "$shown" | grep . | sed 's/^/- /'
    if [ "$more" -gt 0 ]; then
      printf -- '- ...and %s more (list capped; the full set is reproducible from the run ids above)\n' "$more"
    fi
  fi
  printf '\n</details>\n'
  return 0
}

# The run ids for the provenance line, comma-separated — same single limit, so
# there is one number to reason about rather than one per field.
provenance_ids() {
  local raw n
  raw="$(tr '\n' ',' < "$1" | sed 's/,,*/,/g; s/,$//')"
  n="$(printf '%s' "$raw" | awk -F, '{print NF+0}')"
  if [ "${n:-0}" -gt "$EVIDENCE_ENTRIES" ]; then
    printf '%s' "$(printf '%s' "$raw" | cut -d, -f1-"$EVIDENCE_ENTRIES"),+$((n - EVIDENCE_ENTRIES)) more"
  else
    printf '%s' "$raw"
  fi
}

build_evidence() {
  local head="$1" main_prov="$2" pr_count="$3" main_count="$4"
  local unique_raw="$5" flake_line="$6" analyzed="$7" lane="$8"
  local pr_fails="$9" main_fails="${10}" final_unique_raw="${11:-}" exempt_raw="${12:-}"
  local unattr_tokens="${13:-}" unattr_count="${14:-0}" repro_raw="${15:-}" repro_count="${16:-0}"

  printf '<!-- admin-merge-safety: %s -->\n' "$head"
  printf 'PR head: %s\n' "$head"
  printf 'test lane: %s\n' "$lane"
  # The count is the runs that ACTUALLY CONTRIBUTED to the union, not the
  # REQUESTED window ($MAIN_RUNS). A run that contributed nothing — it was green —
  # adds nothing to the union and is not counted, so N always equals the number of
  # ids printed here, and the total window is still stated on the `Lane completion:`
  # line. Printing the requested window instead asserted a comparison that did not
  # happen, in the one line the review-enforcer trusts enough to certify a bypass
  # (#1003).
  local main_union_n=0
  if [ -f "$main_prov" ]; then main_union_n="$(count_lines "$main_prov")"; fi
  local run_word="runs"
  if [ "$main_union_n" = "1" ]; then run_word="run"; fi
  printf 'main compared (union of %s %s of %s): %s\n' "$main_union_n" "$run_word" "$lane" "$(provenance_ids "$main_prov")"
  printf 'PR failing: %s | main failing: %s | blocked by the decision: 0\n' "$pr_count" "$main_count"
  printf '%s\n' "$analyzed"
  # THE AUDITABLE SET, not just its verdict (#3467 item 2): the decision only
  # reaches this point with a zero residual, so every failure the PR carries IS
  # exempt-with-evidence, and recording the set is what lets a reviewer reach
  # `blocked: 0` from the comment instead of taking it on faith.
  # THE HEADING MUST NOT OVERCLAIM (#3715 review). When the base reproduction
  # cleared an id, that id was neither EXEMPTed by the decision nor measured on
  # main — it was cleared by a local re-run on the base, and the summary must say
  # so rather than folding it into "all EXEMPT" (the evidence comment is the
  # audit artifact, so a claim that contradicts its own `Reproduction on base:`
  # line is a defect in the record).
  local exempt_heading="the $pr_count failure(s) this PR carries — all EXEMPT (id measured on main with a matching signature; rate compared where the PR sample was measurable)"
  if counter_is_positive "$repro_count"; then
    exempt_heading="the $pr_count failure(s) this PR carries — EXEMPT by the decision, or CLEARED as reproduced on the base (the $repro_count cleared id(s) had no main-side measurement of their own); rate compared where the PR sample was measurable"
  fi
  evidence_list "$exempt_heading" \
    "$(cat "$pr_fails")" "(none — this PR carries no failure of its own)"
  evidence_list "main baseline: $main_count pre-existing failure(s), for comparison" \
    "$(cat "$main_fails")" "(none)"
  # THE VISIBLE EXEMPTIONS (#3756). An exemption that exists only as an absence
  # IS the fail-open defect, so every exempt id is printed with the decision's
  # own reason — which carries both rates only where a rate was measurable, and
  # says "NOT measurable" when it was not (#5250).
  evidence_list 'EXEMPT by the decision (visible — the reason and the measurements it rested on)' \
    "$exempt_raw" "(none — no failure was exempted)"
  # The PRE-rerun residual, when the flake path ran. Labelled for what it IS: it
  # is NOT the diff of the two sets above (those are POST-rerun), so it must not
  # be presented under a "must be empty" heading.
  if [ -n "$unique_raw" ]; then
    evidence_list 'residual BEFORE the flake re-run — reclassified as flaky, NOT new failures' \
      "$unique_raw" "(none)"
  fi
  # ⛔ THE PLACEHOLDER MUST NOT CONTRADICT THE BLOCK ABOVE IT (#3715 review). The
  # EXEMPT heading was already made conditional on `repro_count`; this body was
  # not, so a run whose residual was cleared by the base reproduction printed
  # "empty — the decision exempts every failure this PR carries" directly under
  # "(none — no failure was exempted)" and directly under its own `Reproduction
  # on base:` line. A cleared id was NOT exempted; the body is chosen from the
  # same count as the heading, so the two claims cannot disagree.
  local final_empty="(empty — the decision exempts every failure this PR carries)"
  if counter_is_positive "$repro_count"; then
    final_empty="(empty — the decision exempted nothing here; the $repro_count cleared id(s) were reproduced on the base, and every other failure is exempt by the decision)"
  fi
  evidence_list 'final residual (the exemption decision: BLOCKED ∪ UNATTRIBUTABLE) — must be empty' \
    "$final_unique_raw" "$final_empty"
  # THE BASE REPRODUCTION (#3715) — stated ALWAYS, so a reader can tell "no failure
  # was refused" from "failures were refused and reproduced on the base". A
  # reproduction that cleared a failure is the one thing that lets a merge proceed
  # over a non-empty decision residual, so it is never silent.
  printf '%s\n' "$repro_raw"
  # THE ATTRIBUTION HALF (#1353) — one line per merge, ALWAYS, so a CLIPPED set is
  # never mistaken for a measured zero and a COMPLETE set is stated rather than
  # assumed. The count itself is in the analysed block above; this is the tokens.
  # The token text is ESCAPED for this markdown surface only (see
  # evidence_token_escape): the token is NAMED and the evidence stays inert, so
  # #1353's disclosure and #3756's injection pin hold at the same time.
  #
  # AND THE EMPTY-TEXT BODY IS CHOSEN FROM THE COUNT, NOT FROM THE RENDERED LINES
  # (#1353). An empty TOKEN on a DROPPED line (a bare `FAILED`) is a counted drop
  # that renders nothing: deciding "empty" from the rendered text alone printed
  # COMPLETE directly under a stated positive drop count, so the COMPLETE claim
  # contradicted the count the same block had just reported. A positive count with
  # no non-blank token text renders the CLIPPED body and NAMES the missing text.
  local unattr_rendered unattr_empty
  unattr_rendered="$(printf '%s\n' "$unattr_tokens" | evidence_token_escape)"
  if counter_is_positive "$unattr_count" \
     && [ -z "$(printf '%s' "$unattr_rendered" | tr -d '[:space:]')" ]; then
    unattr_empty="⛔ CLIPPED — ${unattr_count} drop(s) were reported with NO token text to render, so the failing sets above are NOT COMPARABLE to a measured zero. The parser COUNTED the drops but named no token for them (#1353)."
  else
    unattr_empty="(none — every FAILED token was a test id, so the failing sets above are COMPLETE)"
  fi
  evidence_list 'FAILED token(s) the parser DROPPED — not test ids, so NOT in any failing set (a CLIPPED set is NOT COMPARABLE to a measured zero, #1319). Rendering: the token text with markdown metacharacters escaped, so the evidence block structure cannot be broken.' \
    "$unattr_rendered" \
    "$unattr_empty"
  printf '\nLists show at most %s entries of %s chars; the full sets are reproducible from the run ids above.\n' \
    "$EVIDENCE_ENTRIES" "$EVIDENCE_WIDTH"
  printf '%s\n' "$flake_line"
}

# ⛔ ONE PATTERN FOR "an id NO LOCAL REPRODUCTION can execute" (#3715, #1185).
# These families name no pytest nodeid, so handed to the runner as ARGV ONE of
# them makes pytest EXIT 4 having run NOTHING (`ERROR: file or directory not
# found`) and the whole base run clears nothing. TWO readers ask this question —
# `reproduce_residual_on_base`, which must not hand them to the runner, and the
# #3715 block, which reports that the surviving candidate set names nothing a
# local run could execute. A second copy of the REGEX is exactly the drift the
# rail's one-derivation rule forbids, so the regex lives here and nowhere else.
# (This is ONE pattern with TWO readers, not one enumeration of the families:
# `repro_scope`'s `case` arms answer a DIFFERENT question — admission into the
# candidate set, which is #1185's narrowing — so a family added here must be
# considered there too, and vice versa.)
NON_LOCAL_REPRO_ID_RE='^guard-step::|^collect-error::|^watchdog-kill::|^job-unreadable::|^bash-shard::|^runner::|^pipeline-compliance::'

# ══ reproduce_residual_on_base — THE MISSING MEASUREMENT (#3715) ═══════════
#
# THE DEFECT. `main-rates.txt` is a FAILURE-ONLY projection over the last N runs
# of the lane on main. A failure that is genuinely pre-existing on main can be
# absent from it for three different reasons, and the decision cannot tell them
# apart:
#
#   (a) main ran the test in the EVALUATED SHAPE and it PASSED   -> an absent row
#       is real evidence of novelty (the PR broke it);
#   (b) main ran the test in a DIFFERENT shape and it passed/failed (this repo's
#       tier-2 PR legs run `TORTOISE_TEST_CARVE_OUT=1` embedded, while main's
#       push legs run the same files against docker — a same-nodeid row from the
#       other shape must never decide this one);
#   (c) main NEVER RAN the test (the selector is diff-gated, the leg ran nowhere,
#       the file was not in the shard) -> absence is NOT evidence of anything.
#
# (b) is the fail-open direction: a docker failure of X on main would EXEMPT an
# embedded failure of X in the PR, because the union is keyed on the bare
# nodeid. (c) is the false-BLOCK direction the issue is filed about: the rail
# attributes to the PR a failure it could not have caused, because the baseline
# never measured it. Both are the SAME defect — the comparison's key carries no
# shape — and no amount of set arithmetic can separate them, because the missing
# information is a MEASUREMENT, not a membership.
#
# THE REPAIR, and why it is the baseline's construction rather than a waiver:
# when the decision would BLOCK, the rail CONSTRUCTS the missing measurement by
# running the refused nodeids on a pristine worktree of the BASE (origin/main).
# A failure the base reproduces is one the base's code ALREADY fails in THIS
# lane's AMBIENT shape — a MEASUREMENT the failure-only baseline did not carry.
# It is NOT proof the PR is innocent (see the declared residue below); it is the
# missing observation, and it is strictly stronger than a set-membership test.
# THE QUESTION IT ANSWERS is a direction ("reproduce the residual set on
# origin/main"). What it establishes
# is REPRODUCED-ON-THE-BASE versus NOT — a MEASUREMENT, strictly stronger than
# any set-membership test. It does NOT establish case (a) versus case (c) (see
# the declared residue below): a base run cannot tell "main ran this shape and it
# passed" from "main never ran it".
#
# THE MEASUREMENT SHAPE (a DECLARED RESIDUE, and it is NOT one-directional).
# The reproduction runs in the AMBIENT test environment the rail inherits — it
# does not re-create CI's per-leg shape (e.g. this repo's tier-2 PR legs run the
# fast halves embedded while main's push legs run them against docker). The
# residue therefore has TWO directions, and only the first is fail-closed:
#   * a failure SHAPE-SPECIFIC to the evaluated lane may not reproduce here, so
#     the rail blocks exactly as before (fail closed, harmless); but
#   * an ambient failure main's own leg does NOT see (a missing service, an env
#     var, an order dependence) CAN reproduce on the base and clear an id whose
#     main-side leg is in fact GREEN — the fail-OPEN direction. Case (a) above
#     ("main ran it in this shape and it passed") and case (c) ("main never ran
#     it") are indistinguishable from a failure-only baseline, so this repair
#     cannot separate them and does not pretend to: closing (a)-versus-(c) needs
#     CI's own per-leg shape, not a local run.
# Two things bound the blast radius, and BOTH are load-bearing:
#   * an id is clearable only if the decision could not MEASURE it — no row for
#     the ID, and no row for its FILE (see `repro_candidates`); a MEASURED value
#     is never overridable by a local run; and
#   * only ids the base ITSELF reports FAILED *and that were actually candidates*
#     are cleared — the clearable set is `candidates ∩ reproduced`, never the
#     base's whole failing set, so a runner/parser that volunteers an id outside
#     its argv clears nothing.
# It is stated here rather than smoothed over because a residue that is only
# fail-closed in one direction must not read as "cannot fail open".
#
# IT IS NOT A WAIVER AND NOT AN EXCEPTION:
#   * it runs only on a residual the decision ALREADY REFUSED — it can never
#     widen an exemption the decision granted;
#   * CANDIDATES ARE THE MEASUREMENT GAP ONLY, AT BOTH LEVELS. An id whose row IS
#     in main's rate table was MEASURED by the decision — a rate regression
#     (#3756: main 1/8 vs PR 8/8), a signature mismatch, or a sample below
#     min_runs — and is NOT a candidate. Neither is an id whose FILE main's
#     baseline measured (a sibling failure in the same file): the rail's own
#     `attribute_residual` calls that MEASURED-ABSENT, "not present on main",
#     which is evidence of novelty. Only the absence of ANY measurement of the
#     file is the missing measurement this constructs. AND A NON-NODEID CLASS
#     IS NEVER CLEARABLE, because a base run cannot speak to what it asserts: an
#     UNATTRIBUTABLE id (a class red across runs under a MOVING id — "cannot be
#     attributed to this PR", and therefore never a merge), a guard-step
#     identity (no local runner), and the other non-nodeid families a local
#     pytest cannot execute (`collect-error::<file>` #6798,
#     `watchdog-kill::<reason>`, `job-unreadable::<slug>` #7131,
#     `bash-shard::<path>` #2643, `runner::<job>` — passed as argv they make
#     pytest exit 4 having run NOTHING). CANDIDACY AND CLEARANCE ARE NOT THE SAME
#     SET (#1185): `repro_scope` admits ONE guard-step identity into the
#     candidate set when the base's baseline was read and holds no row for its
#     step, so the rail can REPORT that the base cannot speak to it — while the
#     two filters in `reproduce_residual_on_base` keep it out of the runner's
#     argv AND out of the base's own capture before `intersect_sets`, so a
#     candidate of that class is still never cleared.
#     `repro_scope` then
#     `repro_candidates` are the one place that decision is made, and the cleared
#     set is its intersection with the base's own failures (`intersect_sets`,
#     below);
#   * it runs the exact NODEIDS as argv, never their whole files — that bounds
#     WHICH TESTS RUN on the base (an unrelated failure in the same file is never
#     executed), while `intersect_sets` separately bounds WHAT MAY BE CLEARED, so
#     a capture that NAMES an id outside its argv still clears nothing;
#   * only nodeids the BASE ITSELF reports FAILED are cleared, and a nodeid whose
#     reproduction cannot be parsed stays in the residual (fail-closed);
#   * a base that cannot be materialised / a lane with no runnable runner / an
#     invalid bound clears NOTHING and the rail blocks exactly as before — an
#     unrun reproduction is never read as "pre-existing";
#   * guard-step identities are NOT reproduced (they have no local runner) and
#     always remain in the residual — `repro_scope` admits one into the
#     CANDIDATE set only when the base holds no record of its step (#1185), and
#     even then nothing local can execute it: `reproduce_residual_on_base`
#     filters it from its argv AND from the base's own capture before the
#     intersection, so it can never be cleared.
#
# The worktree is a throwaway under $TMP and is always removed.
#
# Env seams (tests / operator):
#   ADMIN_MERGE_REPRO_CMD   the reproduction command, run with the residual
#                           nodeids on stdin and its pytest-shaped output on
#                           stdout. When set, no worktree is created and the
#                           command runs in $PWD — this is the harness seam, in
#                           the same spirit as ADMIN_MERGE_GH / CI_FAILURE_SET_GH.
#   ADMIN_MERGE_REPRO_TIMEOUT  seconds (default 900). The bound is MANDATORY
#                           and VALIDATED (positive integer): a value perl's
#                           `alarm` cannot numify cancels the timer, and a
#                           hanging suite must become "not reproduced" (a
#                           block), never an unbounded merge-time stall.
#
# RETURN: 0 = ran (the capture was read; `$out` may be empty) · 1 = could not
# run, so the caller clears NOTHING. "Found nothing" is NEVER reported as
# "could not run".
reproduce_residual_on_base() {
  local residual="$1" out="$2" base="${3:-}"
  : > "$out"
  # RETURN CONTRACT — the caller reports on it, so conflating the two outcomes is
  # itself a defect (#3715 review): 0 = the reproduction RAN (its capture was
  # read; `$out` may legitimately be empty) · 1 = it COULD NOT RUN (no base OID,
  # no worktree, no runner, no usable bound) — clear NOTHING. "ran and found
  # nothing" must never be reported as "could not run".
  [ -s "$residual" ] || return 1
  # ⛔ EVERY NON-NODEID FAMILY IS EXCLUDED, not just the guard step (#3715 review,
  # P2). The parser's other non-nodeid identities — `collect-error::<file>`
  # (#6798), `watchdog-kill::<reason>`, `job-unreadable::<slug>` (#7131),
  # `bash-shard::<path>` (#2643), `runner::<job>` and
  # `pipeline-compliance::<letter>::<subject>` (#1185) — are
  # real residual rows but they name no pytest nodeid. Handed to the runner as
  # ARGV, ONE of them makes pytest EXIT 4 having run NOTHING (`ERROR: file or
  # directory not found`), so a residual that mixes a collection error with real
  # nodeids aborted the whole base run and cleared nothing — the false block this
  # repair exists to remove, with no diagnostic naming the cause. (`repro_scope`
  # filters them from the candidate set — EXCEPT the guard-step ids #1185 admits,
  # the ones the base holds no record of, admitted so the rail can REPORT that
  # fact; this is the function's own guard, so the contract holds for every
  # caller, and it is also what keeps a base CAPTURE from volunteering one.)
  local nodeids
  nodeids="$(grep -Ev "$NON_LOCAL_REPRO_ID_RE" "$residual" 2>/dev/null || true)"
  [ -n "$nodeids" ] || return 1

  # THE BOUND IS MANDATORY, and it is VALIDATED THROUGH THE RAIL'S OWN
  # PREDICATES. `perl alarm` numifies its argument, so `alarm "abc"` is
  # `alarm 0` (the timer is CANCELED) and the runner becomes unbounded; and the
  # same is true of a LEADING-ZERO spelling (`alarm 00` == `alarm 0`) or a value
  # past the integer range (`alarm` errors, and the bound is never armed).
  # Reusing `counter_is_positive` / `counter_has_leading_zero` /
  # `counter_exceeds_max` is deliberate: every other timing knob in this rail is
  # validated by exactly these three, and a hand-rolled `case` here is how the
  # leading-zero and out-of-range holes reappear.
  local timeout_s="${ADMIN_MERGE_REPRO_TIMEOUT:-900}"
  if counter_has_leading_zero "$timeout_s" \
     || ! counter_is_positive "$timeout_s" \
     || counter_exceeds_max "$timeout_s" "$TIMING_KNOB_MAX"; then
    say_err "admin-merge: (reproduction) refusing ADMIN_MERGE_REPRO_TIMEOUT='$timeout_s' — a POSITIVE"
    say_err "   integer (no leading zero, within the usable range) is required: perl's alarm numifies"
    say_err "   its argument, so a non-integer, a leading-zero spelling, or an out-of-range value"
    say_err "   CANCELS or never arms the bound and the base run would be UNBOUNDED. Nothing"
    say_err "   reproduced; the refusal stands (fail closed)."
    return 1
  fi
  # The bound is enforced by `perl alarm` (macOS ships no `timeout`). Without perl
  # there is NO bound, and starting an unbounded merge-time suite is exactly what
  # this function must never do.
  if ! command -v perl >/dev/null 2>&1; then
    say_err "admin-merge: (reproduction) no 'perl' for the mandatory alarm bound — nothing"
    say_err "   reproduced; the refusal stands (fail closed)."
    return 1
  fi

  # THE REQUESTED SET IS THE NODEIDS, passed to the runner as ARGV (the seam also
  # gets them on stdin). Running the exact nodeids — never their whole files —
  # bounds the base's OWN output to the ids under test, so an unrelated failure
  # in the same file can never be read as a reproduced one. Built BEFORE the
  # worktree exists so an empty request can never leave one behind (#3715 review).
  local -a nodeid_arr=() n
  while IFS= read -r n; do [ -n "$n" ] && nodeid_arr+=("$n"); done <<< "$nodeids"
  [ "${#nodeid_arr[@]}" -gt 0 ] || return 1

  local work="$TMP/repro-base"
  rm -rf "$work"; mkdir -p "$work" || return 1

  local cmd_dir="$PWD" used_worktree=0
  if [ -z "${ADMIN_MERGE_REPRO_CMD:-}" ]; then
    # PRODUCTION PATH: a pristine base worktree. No base ref, not a git repo, or a
    # worktree that cannot be created -> clear NOTHING (fail closed).
    [ -n "$base" ] || return 1
    git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    if ! git -C "$PWD" worktree add --detach --force "$work/tree" "$base" >/dev/null 2>&1; then
      say_err "admin-merge: (reproduction) could not materialise the base '$base' as a worktree — the"
      say_err "   residual is NOT reproduced and the rail blocks as before (fail closed)."
      return 1
    fi
    cmd_dir="$work/tree"; used_worktree=1
  fi

  local -a runner
  if [ -n "${ADMIN_MERGE_REPRO_CMD:-}" ]; then
    runner=(bash -c "$ADMIN_MERGE_REPRO_CMD")
  elif command -v uv >/dev/null 2>&1 && [ -f "$cmd_dir/uv.lock" ]; then
    runner=(uv run --frozen pytest "${nodeid_arr[@]}" -q -p no:cacheprovider)
  else
    say_err "admin-merge: (reproduction) no runnable lane runner (no ADMIN_MERGE_REPRO_CMD and no uv.lock)"
    say_err "   — the residual is NOT reproduced and the rail blocks as before (fail closed)."
    [ "$used_worktree" -eq 1 ] && git -C "$PWD" worktree remove --force "$work/tree" >/dev/null 2>&1
    return 1
  fi
  local raw="$work/repro.raw" run_rc=0
  (
    cd "$cmd_dir" || exit 1
    printf '%s\n' "$nodeids" > "$work/nodeids.txt"
    perl -e 'alarm shift; exec @ARGV' "$timeout_s" "${runner[@]}" < "$work/nodeids.txt"
  ) > "$raw" 2> "$work/repro.err" || run_rc=$?
  [ "$used_worktree" -eq 1 ] && git -C "$PWD" worktree remove --force "$work/tree" >/dev/null 2>&1

  # The reproduced set, through the CANONICAL parser so the shapes cannot drift.
  # `ids` exits non-zero ONLY when the capture could not be READ (an empty id set
  # is a legitimate 0), so a non-zero here is "could not run", not "found none".
  local reproduced
  reproduced="$("$PYTHON_BIN" "$EXEMPTION_PY" ids --log "$raw" 2>/dev/null)" || return 1
  # ⛔ A RUNNER THAT DID NOT RUN IS NOT A RAN-AND-FOUND-NOTHING MEASUREMENT
  # (#3715 review, P2). The subshell's status was DISCARDED, so a crash, a
  # missing dependency, an argv the runner refused, or a suite KILLED at the
  # mandatory `perl alarm` bound all left an empty capture; `ids` reads that as a
  # legitimate empty set (exit 0), and the rail reported "NO refused failure
  # reproduced there" — a POSITIVE measurement that the base passed tests it
  # never executed, contradicted by the runner's own unread `$work/repro.err`.
  # The STATUS ALONE is not the test: pytest exits 1 when tests FAIL, which is a
  # successful measurement. The evidence is the CAPTURE — a runner that ran and
  # found failures names them, one that could not run names none — so BOTH
  # together are the predicate: non-zero status AND no recovered id is "could not
  # run" (fail closed), while a non-zero status WITH recovered ids is a
  # measurement. 142 is SIGALRM (128+14): the bound killed it.
  if [ "$run_rc" -ne 0 ] && [ -z "$reproduced" ]; then
    if [ "$run_rc" -eq 142 ]; then
      say_err "admin-merge: (reproduction) the base runner was KILLED by the ${timeout_s}s bound"
      say_err "   (SIGALRM) before it reported anything — that is a run that could NOT run, never a"
      say_err "   measurement that the base does not fail these tests."
    else
      say_err "admin-merge: (reproduction) the base runner exited $run_rc with NO recovered failure id"
      say_err "   — a crash, a missing dependency, or an argv the runner refused, NOT a run that found"
      say_err "   nothing. 'ran and found nothing' must never be reported as 'could not run', and this"
      say_err "   inverse is the same defect."
    fi
    local diag=""
    if [ -s "$work/repro.err" ]; then
      diag="$(tail -n 3 "$work/repro.err" 2>/dev/null)"
      say_err "   runner stderr (last 3 lines):"
      printf '%s\n' "$diag" | sed 's/^/      /' >&2
    fi
    say_err "   Nothing reproduced; the refusal stands (fail closed)."
    return 1
  fi
  # THE CAPTURE IS INTERSECTED WITH WHAT WAS ACTUALLY ASKED FOR (#3715 review,
  # P0). `ids --log` recovers nodeid-shaped tokens from ANYWHERE in the capture
  # and the test seam can echo whatever it likes, so the base's raw output may
  # name an id outside its argv — including a MEASURED one. Subtracting that from
  # the residual would override a measured verdict, which is the #3756 fail-open
  # the candidate set exists to stop. `$residual` IS the candidate set, so the
  # intersection belongs here, and it goes through the ONE comparison
  # implementation (never a second subtraction, never `comm -12`).
  if [ -n "$reproduced" ]; then
    printf '%s\n' "$reproduced" | sort -u > "$work/reproduced.all"
    # ⛔ THE ARGV FILTER ABOVE DOES NOT BOUND WHAT MAY BE CLEARED (#1185 review,
    # cycle 2). ⚠️ THIS FILTER IS UNFIXTURED: the cycle-2 author wrote a
    # rail-level fixture for it and MEASURED that it did not discriminate (the
    # same scenario cleared nothing with the filter removed), so the case was
    # deleted rather than shipped as a vacuous green — the effect below is
    # established by direct measurement of the parser instead
    # (`python3 scripts/ci_exemption.py ids --log` on a capture carrying the
    # `##[error]FAILED …` annotation prints the `guard-step::` id). `grep -Ev`
    # bounds what the runner was ASKED to run; a CAPTURE can
    # still volunteer an identity its argv never named — `ids --log` recovers
    # them from anywhere in the log, and a capture carrying a `##[error]FAILED …`
    # annotation emits a `guard-step::` identity. Since #1185 a guard-step id CAN
    # be in `$residual` (the candidate set), so before this filter it could be
    # subtracted from the rail's residual by the base's own output: a failure no
    # local run can execute, CLEARED. One more filter on the BASE'S side, through
    # the same one pattern, keeps "an id no local reproduction can execute can
    # never be cleared" true whichever side reports it.
    grep -Ev "$NON_LOCAL_REPRO_ID_RE" "$work/reproduced.all" > "$work/reproduced.exec" 2>/dev/null || : > "$work/reproduced.exec"
    intersect_sets "$work/reproduced.exec" "$residual" "$out" "$work/rep-outside.txt" || {
      : > "$out"; return 1
    }
  fi
  return 0
}

# attribute_residual <residual-file> <main-fails-file> — name WHY each residual
# failure is not in main's baseline. This IMPROVES the diagnosis of a refusal;
# it must never NARROW the refusal. Every caller blocks on a non-empty residual
# regardless of the label here, and there is deliberately NO waiver label
# (B1 asked for lane-matched attribution sufficient to CERTIFY; the answer is
# no — a gate cannot adjudicate causation, and accepting it once lets the next
# genuinely-new failure in that file ride the same argument).
#
# #3715 — A LABEL IS NOT A MEASUREMENT, AND THIS RULE IS ABOUT LABELS. The
# paragraph above refuses to CERTIFY from an ATTRIBUTION LABEL, i.e. an
# inference drawn from file proximity. The base reproduction is a different
# thing in kind, not a softer label: it RUNS the refused nodeids on the base and
# clears only an id the base itself reports FAILED — and only when main's rate
# table carries NO row for it, so a MEASURED verdict (including #3756's rate
# regression) is never overridden. "Both labels block" still holds: nothing
# here clears, and no label may be read as a waiver.
#
# The UNIT is the failure's own grouping: a pytest nodeid groups by FILE (before
# the first `::`), a guard-step identity (#4469, `guard-step::<step>::<shape>`)
# groups by STEP — it has no `.py` path, and reporting the bare `guard-step`
# prefix would name the whole mechanism instead of the failing check.
#
# The two NON-NODEID families (#6798) each bring their own unit, and both must
# be handled EXPLICITLY: the generic `s/::.*//` would collapse
# `collect-error::tests/a.py` and `collect-error::tests/other.py` onto the
# literal `collect-error`, so a main baseline for a DIFFERENT file would be
# reported as "measured on this lane" — the exact wrong remedy. An identity
# keyed on the file therefore groups by FILE (like a nodeid); an environmental
# kill has no file, so it groups by its own constant (like a guard step).
#
#   measured on this lane, not present on main
#       main's baseline carries a failure in the SAME unit, so the lane is
#       demonstrably measuring it and does not show this one red.
#   absent from main's failure set
#       main's baseline carries NO failure in that unit. A FAILURE-ONLY baseline
#       cannot tell "green on main" from "never run on main", so absence is NOT
#       evidence of novelty — the rail must not call it "unique to this PR".
#       (#7734) What it must ALSO not say is "no main-side measurement": main's
#       shards upload the nodeids they RAN (`expected-nodeids.txt`), and on the
#       four PRs #7734 names main's manifests carry 98/41/23/12 of the blocked
#       nodeids, so main demonstrably runs those files. The label is ABSENCE FROM
#       THE FAILURE SET; the block is right, the old wording was not.
#       (B1: CI's docker lane reproduces ZERO occurrences of the embedded lane's
#       redislite/GRAPH.COPY race while the embedded lane reproduces it — the old
#       wording asserted uniqueness with nothing to compare against.)
# main_measured_files <mainfails> — the FILES main's failure-only baseline
# actually MEASURED, i.e. a real test failure in the file (or a guard-step
# identity for it). A sibling failure in the file is proof main's lane RAN it and
# did not show THIS id red — MEASURED-ABSENT — which the rail must keep distinct
# from NOT-MEASURABLE.
#
# A `collect-error::<file>` is deliberately NOT in this set, and that is the whole
# reason this function is not `main_baseline_units`: pytest could not COLLECT the
# file, so NO test in it ran and main's baseline says NOTHING about the file's
# tests. It is a unit the rail can NAME, not a measurement it can rely on.
# Conflating the two makes the base reproduction refuse an id the base itself
# reproduces as FAILED — the false block #3715 exists to remove (a real
# regression when this set was widened; caught in review).
#
# `bash-shard::<path>` IS here, and is the one aggregate that belongs: the shard IS
# a file, so main having failed it is a measurement OF that file — the opposite of
# the `collect-error::` case, where nothing in it ran. `runner::<job>` and
# `job-unreadable::<slug>` are NOT: an aggregate failure names no file inside the
# job, so claiming one would be inventing a measurement. Their rows therefore fall
# through to the generic `s/::.*//` and stay a non-file unit, which can never equal
# a nodeid's file — fail-closed for clearance, which is why nothing else is needed.
main_measured_files() {
  local mainfails="$1"
  [ -s "$mainfails" ] || return 0
  {
    sed '/^guard-step::/d; /^pipeline-compliance::/d; s/::.*//' "$mainfails"
    sed -n 's/^guard-step::\([^:]*\)::.*/\1/p' "$mainfails"
    # #2643: the shard path IS the measured file (see the note above).
    sed -n 's/^bash-shard::\(.*\)$/\1/p' "$mainfails"
    # #1185: a gate identity is keyed by its CHECK, not by a file — the same
    # per-entry identity `job-unreadable::` uses, and for the same reason: a main
    # baseline red on a DIFFERENT check must not read as a pre-existing failure in
    # this one. The generic `s/::.*//` above is suppressed for the family so it
    # cannot also claim a "file" called `pipeline-compliance`.
    sed -n 's/^\(pipeline-compliance::[^:]*\)::.*/\1/p' "$mainfails"
  } | sort -u
}

# main_baseline_units <mainfails> — the UNIT each of main's baseline rows is
# keyed by, for MATCHING a residual and for PRINTING it. Wider than
# `main_measured_files` by exactly the rows that name no test: `collect-error::`
# groups by FILE (#6798 — a different file on main must not read as a
# pre-existing failure in the same unit) and an environmental kill groups by the
# MECHANISM. Read by `attribute_residual` (the rail's WORDS); deliberately NOT
# read by `repro_candidates` (its CLEARANCE), because a unit is not a
# measurement. The two coincide for every id that names a test, which is why one
# function looked sufficient.
main_baseline_units() {
  local mainfails="$1"
  [ -s "$mainfails" ] || return 0
  {
    sed '/^guard-step::/d; /^collect-error::/d; /^watchdog-kill::/d; /^job-unreadable::/d; /^bash-shard::/d; /^runner::/d; /^pipeline-compliance::/d; s/::.*//' "$mainfails"
    sed -n 's/^guard-step::\([^:]*\)::.*/\1/p' "$mainfails"
    sed -n 's/^collect-error::\(.*\)$/\1/p' "$mainfails"
    sed -n 's/^watchdog-kill::.*/watchdog-kill/p' "$mainfails"
    # #7131: the unit is the JOB SLUG. Without this arm the generic `s/::.*//`
    # above is suppressed for the family and a main baseline red on a DIFFERENT
    # job would read as pre-existing in this one.
    sed -n 's/^job-unreadable::\(.*\)$/\1/p' "$mainfails"
    # #2643/#6798: the file-coarse aggregates — the unit is the SHARD PATH / the
    # JOB SLUG, exactly as `failure_file_key` derives it. Without these arms the
    # generic `s/::.*//` above is suppressed for the family, every shard collapses
    # onto the literal `bash-shard`, and a main baseline red in ONE shard reads as
    # pre-existing in a DIFFERENT one.
    sed -n 's/^bash-shard::\(.*\)$/\1/p' "$mainfails"
    sed -n 's/^runner::\(.*\)$/\1/p' "$mainfails"
    # #1185: the unit is the CHECK (`pipeline-compliance::<letter>`), for exactly
    # the #7131 reason — main red on check (a) must not read as a pre-existing
    # failure in this PR's check (c). The letter stays ON the unit, so it can
    # never collide with a test file of the same name.
    sed -n 's/^\(pipeline-compliance::[^:]*\)::.*/\1/p' "$mainfails"
  } | sort -u
}

# failure_file_key <id> — the FILE (or, for an environmental kill, the
# MECHANISM) an id is grouped by. ONE derivation, because BOTH readers of
# `main_measured_files` must group an id identically or the rail's words and its
# clearance drift apart (the helper's own contract): `repro_candidates` decides
# what a base reproduction may clear, `attribute_residual` decides what the rail
# PRINTS. #6798: a `collect-error::` id is keyed by its FILE — a different file
# on main must not read as a pre-existing failure in the same unit — and an
# environmental kill carries no file, so it is keyed by the mechanism.
failure_file_key() {
  case "$1" in
    guard-step::*::*) local f="${1#guard-step::}"; printf '%s\n' "${f%%::*}" ;;
    collect-error::*) printf '%s\n' "${1#collect-error::}" ;;
    watchdog-kill::*) printf '%s\n' "watchdog-kill" ;;
    # #7131: an unreadable job's unit is the JOB SLUG — the key asserts only "a
    # job with this slug failed", so a different job on main must not read as a
    # pre-existing failure in this one. Without this arm the generic default
    # would collapse every job onto the literal `job-unreadable`.
    job-unreadable::*) printf '%s\n' "${1#job-unreadable::}" ;;
    # #2643/#6798: the file-coarse aggregates group by the PATH / JOB SLUG they
    # name — the same unit `main_baseline_units` derives. The generic default
    # would collapse every shard onto the literal `bash-shard` (and every JS
    # aggregate onto `runner`), so a main baseline red in one shard would be
    # reported as "measured on this lane" for a DIFFERENT shard's failure.
    bash-shard::*) printf '%s\n' "${1#bash-shard::}" ;;
    runner::*) printf '%s\n' "${1#runner::}" ;;
    # #1185: the unit is the CHECK, `pipeline-compliance::<letter>` — main red on
    # check (a) must not read as a pre-existing failure in this PR's check (c),
    # and the generic default would collapse the whole family onto the literal
    # `pipeline-compliance`.
    pipeline-compliance::*) local p="${1#pipeline-compliance::}"; printf '%s\n' "pipeline-compliance::${p%%::*}" ;;
    *) printf '%s\n' "${1%%::*}" ;;
  esac
}

# intersect_sets <a> <b> <out> <scratch> — a ∩ b, as `a − (a − b)`, through the
# ONE shared comparison. `comm -12` is forbidden in this file for the same reason
# `comm -23` is (the parity invariant): a second set implementation is drift.
# Returns 1 if either subtraction could not run — the caller clears NOTHING.
intersect_sets() {
  local a="$1" b="$2" out="$3" scratch="$4"
  run_failure_set --diff "$a" "$b" > "$scratch" 2>/dev/null || return 1
  run_failure_set --diff "$a" "$scratch" > "$out" 2>/dev/null || return 1
  return 0
}

# repro_scope <residual> <unattributable> <out> <scratch> [<mainfails>] — the ids
# a base run could even SPEAK TO, PLUS (since #1185) the guard-step ids the base
# holds NO record of: those are admitted so the rail can REPORT that fact, never
# because a run could speak to them (nothing local can execute one — see the
# caller's own branch). The set is the residual minus UNATTRIBUTABLE identities,
# minus guard-step identities THE BASE HAS A RECORD OF, and minus the other
# NON-NODEID families. Every arm is excluded on DOCTRINE — and the guard-step arm
# alone is additionally decided on EVIDENCE from the base's OWN baseline
# (`main_measured_files`), which is #1185's narrowing:
#   * UNATTRIBUTABLE is "a class red across runs under a MOVING id — the identity
#     provably will not be the same next run, so it cannot be attributed to this
#     PR". Reproducing ONE of the moving ids on the base says nothing about the
#     class, and the class is never a merge (`detect_rotating_identity`, E5).
#   * a guard-step identity has no local pytest runner, so a local run cannot
#     reproduce it — but that is a statement about the RUNNER, and it is only
#     half of the question. The other half is whether the BASE holds any record
#     of the id's UNIT at all (#1185): main's baseline is a union over main's own
#     runs, and a `pull_request`-only workflow NEVER RUNS ON MAIN, so its
#     `guard-step::<step>::<shape>` ids can never appear there however red main
#     is. Excluding that id as "a reproduction can never clear it" conflated two
#     different facts and named neither: the failure is real and on this head,
#     but the base has NO RECORD of the step, so `main-fails.txt`'s silence is a
#     structural absence, not evidence of novelty (#7734's own distinction). So
#     a guard-step id is admitted into the candidate set ONLY when
#     `main_measured_files` holds no row for its UNIT — the SAME derivation
#     `repro_candidates` applies at its FILE level, so the scope and the
#     clearance cannot disagree.
#     ⛔ WHAT THE CONDITION FORBIDS: it never admits a guard-step id whose step
#     main's baseline DID measure. There main HAS evaluated the unit, its
#     absence from the failure set is a measurement (MEASURED-ABSENT), and
#     reading it as "the base holds no record" would let a REAL failure be filed
#     as unmeasurable — the widening direction that turns a block into a
#     misdiagnosis. An EMPTY or unreadable baseline admits nothing either, and
#     that is a deliberate refusal, not an oversight: a failure-only baseline
#     that is empty cannot tell "main is GREEN" from "main has no run at all"
#     (#7734), so this function cannot assert the base holds no record on it.
#     The id then keeps the pre-change exclusion — fail closed.
#   * the other non-nodeid identities (`collect-error::<file>` #6798,
#     `watchdog-kill::<reason>`, `job-unreadable::<slug>` #7131,
#     `bash-shard::<path>` #2643, `runner::<job>`,
#     `pipeline-compliance::<letter>::<subject>` #1185) also name no
#     pytest nodeid. Handed to the runner as argv they make it EXIT 4 having run
#     NOTHING, so they are not candidates either — they are units the rail can
#     NAME, never measurements a local run can clear (#3715 review, P2).
# Return contract: 0 = computed (out may be empty) · 1 = could not compute.
repro_scope() {
  local residual="$1" unattrib="$2" out="$3" scratch="$4" mainfails="${5:-}" nid ukey main_units=""
  if [ -s "$unattrib" ]; then
    run_failure_set --diff "$residual" "$unattrib" > "$scratch" 2>/dev/null || return 1
  else
    cp "$residual" "$scratch" || return 1
  fi
  # THE BASE-SIDE RECORD, through the ONE derivation `repro_candidates` uses. An
  # absent or EMPTY baseline leaves this empty, which ADMITS NOTHING below: a
  # failure-only baseline that is empty cannot tell "main is green" from "main
  # has no run", so "the base holds no record of this unit" is not a claim this
  # function can make from it (fail closed — the pre-change exclusion stands).
  if [ -n "$mainfails" ] && [ -s "$mainfails" ]; then
    main_units="$(main_measured_files "$mainfails")"
  fi
  : > "$out"
  while IFS= read -r nid; do
    [ -n "$nid" ] || continue
    case "$nid" in
      guard-step::*)
        # #1185: admissible ONLY when the base's record is POSITIVELY readable and
        # holds no row for the id's UNIT. An empty record admits nothing.
        ukey="$(failure_file_key "$nid")"
        if [ -z "$main_units" ]; then
          continue
        fi
        if grep -qxF -- "$ukey" <<<"$main_units" 2>/dev/null; then
          continue
        fi
        ;;
      collect-error::*|watchdog-kill::*|job-unreadable::*) continue ;;
      bash-shard::*|runner::*|pipeline-compliance::*) continue ;;
    esac
    printf '%s\n' "$nid" >> "$out"
  done < "$scratch"
  return 0
}

# repro_candidates <scoped> <mainfails> <out> <idlevel> <mainfiles> — the ids the
# base reproduction may legitimately clear: the ones the decision could not
# MEASURE. TWO levels, and both are the rail's own doctrine:
#   * ID level — no row in main's rate table (the decision's `mr is None`).
#   * FILE level — main's baseline carries no measurement of the id's FILE, so
#     absence is not evidence of novelty. An id whose file main DID measure (a
#     sibling failure in main-fails) is MEASURED-ABSENT: `attribute_residual`
#     names that "measured on this lane, not present on main" — evidence of
#     novelty — and a local base run must never clear it (#3715 review, P0).
# `scoped` is `repro_scope`'s output. Return contract: 0 = computed (out may be
# empty) · 1 = could not compute.
repro_candidates() {
  local scoped="$1" mainfails="$2" out="$3" idlevel="$4" mainfiles="$5" nid file
  run_failure_set --diff "$scoped" "$mainfails" > "$idlevel" 2>/dev/null || return 1
  : > "$out"
  [ -s "$idlevel" ] || return 0
  main_measured_files "$mainfails" > "$mainfiles"
  while IFS= read -r nid; do
    [ -n "$nid" ] || continue
    file="$(failure_file_key "$nid")"
    if [ -s "$mainfiles" ] && grep -qxF -- "$file" "$mainfiles" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$nid" >> "$out"
  done < "$idlevel"
  return 0
}

attribute_residual() {
  local residual="$1" mainfails="$2" nodeid file main_files=""
  # main's side is kept: the file set is the WIDE one (main's #6798 families),
  # because this function MATCHES a residual id to the unit main's baseline
  # names. Its own inline block is now `main_baseline_units`, so the two readers
  # of a shared key derivation cannot drift — see `failure_file_key`.
  main_files="$(main_baseline_units "$mainfails")"
  while IFS= read -r nodeid; do
    [ -n "$nodeid" ] || continue
    file="$(failure_file_key "$nodeid")"
    if [ -n "$main_files" ] && grep -qxF -- "$file" <<<"$main_files"; then
      printf '   %s\n      -> measured on this lane, not present on main\n' "$nodeid"
    else
      printf '   %s\n      -> absent from main'\''s failure set: main carries no failure in %s. The baseline is FAILURE-ONLY, so this cannot tell '\''green on main'\'' from '\''never run on main'\'': absence is NOT evidence of novelty, and it is also NOT evidence main never ran the file (#7734)\n' "$nodeid" "$file"
    fi
  done < "$residual"
}

# ══ THE REPO THIS RAIL ACTS ON IS RESOLVED BY EVIDENCE (#2235) ══════════════
#
# ⛔ THE TARGET IS NEVER AN INHERITED `GH_REPO`. gh's own resolution is
# flag > `GH_REPO` > the local checkout, and the manual says of `GH_REPO`: "specify the
# GitHub repository in the `[HOST/]OWNER/REPO` format for commands that otherwise
# operate on a local repository" (`gh help environment`, gh 2.102.0). **That phrase is
# the whole defect**: it does not ADD a default, it REPLACES the checkout's answer for
# every invocation that does not pass `--repo`. This rail passed `--repo` only when its
# own `--repo` was given, so a cell exporting `GH_REPO=daniel-ospina/tortoise` (a
# `keys.env` line does exactly that) made every gh call here answer for tortoise:
#
#   $ bash scripts/admin-merge.sh 2232          # agent-infra PR, ambient GH_REPO=tortoise
#   admin-merge: ✅ PR #2232 is ALREADY MERGED (state=MERGED, mergedAt=2026-09-04T09:11:01Z)
#                — duplicate execution is a NO-OP: no CI work, no evidence comment, no merge attempt
#
# That was a SEPTEMBER tortoise PR. The real target was open. Exit 0, zero work, and a ✅
# printed over nothing — the fail-open direction, on the rail that exists to be the last
# gate (#2235). Nothing had to be stale for it to happen, and nothing reddens.
#
# ⛔ SO THE PRECEDENCE IS AN ALLOW-LIST OF EVIDENCE, in this order:
#   1. an explicit `--repo` — a caller's deliberate choice, and the documented selector;
#   2. the INVOCATION CHECKOUT's `origin` remote — what this rail is standing in, and the
#      only thing a bare PR number can plausibly mean;
#   3. the checkout as `gh` itself resolves it, WITH `GH_REPO` STRIPPED, so the answer
#      cannot be the ambient value this whole block exists to distrust;
#   4. otherwise REFUSE. A rail that cannot name its target must not guess one.
#
# ⛔ AND AN INHERITED `GH_REPO` THAT DISAGREES IS A STOP-WORK CONDITION, NOT A WARNING.
# It is refused BEFORE ANY gh CALL, naming both values and the one-line fix. The
# ordering is the testable property, not a detail: a warning followed by an API call is
# the same fail-open one line later, because the CALL is what decides the verdict.
# `tests/admin-merge/run.sh` §70 proves it with a fake `gh` that records whether it ran
# at all (it must not have).
#
# ⛔ THIS ENFORCES A DECISION THE FILE ALREADY RECORDED, it does not reverse one. The
# usage text above says `--repo` "is the ONLY way to select a repo"; before this block
# the ambient env was silently a second way. Explicit `--repo` still WORKS as documented
# (including cross-repo) — it just stops being the only thing that decides.
RAIL_REPO=""
RAIL_CHECKOUT_REPO=""
RAIL_CHECKOUT_HOST=""
RAIL_CHECKOUT_ROOT=""
RAIL_REPO_SOURCE=""

# rail_lc <value> — case-folded for comparison. GitHub owner/repo names are
# case-INSENSITIVE (`gh` accepts any case and echoes back the spelling it was handed), so
# a verbatim comparison refuses a pair that names ONE repo — the shape #1856's review
# found when `check` passed a pair that `start` then refused.
rail_lc() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

# rail_slug_of_remote <url> -> `owner/name`, or nothing (rc 1) when it names no repo.
#
# ⛔ WHY A LOCAL PARSER AND NOT `repo_of_checkout` (corrected: the first draft of this
# comment claimed the rail is farmed to cells, which is FALSE — `pi-bootstrap/setup.sh`'s
# `merge_gate_srcs` is `(record-review.sh)` and `admin-merge.sh` appears in NO farm array.
# It is executed from a checkout: `merge-one.sh:515` runs `$REPO/scripts/admin-merge.sh`,
# `atomic-land.sh` runs `$SELF_DIR/admin-merge.sh`. So `scripts/lib/orchestrator-registry.sh`
# IS beside it wherever it runs, and a `source` would work.) The reason it is still local is
# the DEPENDENCY, not availability: this is the last merge gate, and sourcing pulls in
# `pid-identity.sh` at that library's top level, so a missing or unreadable lib would become a
# new way for the RAIL ITSELF not to start. A 30-line parse that refuses is a smaller failure
# surface than a startup dependency on the gate that must always run.
#
# ⛔ THE COST IS A FOURTH COPY OF THIS PARSE, AND IT IS A DECLARED RESIDUAL rather than a
# claim the others are wrong: `lib/orchestrator-registry.sh:repo_of_checkout`,
# `cloud-cell-supervisor.sh:queue_repo_from_url` and `orchestrator-harness/repo-slug.sh`
# derive the same value, and `orchestrator-harness/test-gates.sh` holds them in lockstep over a
# shape table. This copy is NOT in that table — so the shapes below are deliberately chosen to
# be the STRICT subset: every shape this parser accepts, the others accept too, and everything
# else is UNREADABLE here (rc 1) and the caller refuses. Divergence in that direction cannot
# certify a wrong repo; the fail-open direction is what the table exists to catch.
#
# Shapes: scheme URLs must carry a HOST (http/https/ssh); scp-like `[user@]host:owner/name`;
# an EMPTY PATH SEGMENT is refused (`https://host//o/r` and `git@host:/o/r` are not slugs here,
# matching the supervisor). `.git` and ONE trailing slash are stripped. A PORT is accepted and
# stripped (the supervisor accepts it too).
#
# ⛔ AND ITS SUBJECT IS THE LOCAL TREE, never a third party's claim: it parses the remote
# of the checkout the rail is running in. It cannot certify anything else, which is why
# the mismatch arms below can be trusted.
rail_slug_of_remote() {
  local url="${1:-}" slug="" host=""
  case "$url" in
    https://*|http://*|ssh://*)
      # A scheme URL must NAME A HOST: `https:///o/r` has no authority, so there is no git
      # host to read and any slug built from it is an invention.
      host="${url#*://}"; host="${host%%/*}"
      host="${host#*@}"; host="${host%%:*}"
      [ -n "$host" ] || return 1
      slug="${url#*://*/}"
      [ "$slug" != "$url" ] || return 1 ;;
    *@*:*)
      # scp-like. ⛔ The part before the colon must be a HOST: `/home/u@srv:o/r.git`
      # carries both `@` and `:` and git treats it as a LOCAL PATH, so reading `o/r` out
      # of it names a repo on a git host that this checkout does not have.
      case "${url%%:*}" in */*) return 1 ;; esac
      slug="${url#*:}" ;;
    *) return 1 ;;
  esac
  # Strip `.git` and ONE trailing slash. ⛔ `/*` IS REFUSED FIRST: an empty path segment is
  # repaired by a bare `${slug#/}`, and repairing it made this parser derive `acme/widget`
  # from `git@host:/acme/widget.git` and `https://host//acme/widget.git` — shapes the
  # supervisor's own parser REFUSES (review round 2, P2), so the rail would have accepted an
  # origin its queue gate calls "not a slug". Refusing is the direction that cannot be wrong.
  case "$slug" in /*) return 1 ;; esac
  slug="${slug%/}"; slug="${slug%.git}"
  case "$slug" in
    ''|*/*/*|/*|*:*) return 1 ;;   # not exactly owner/name
    */*) : ;;
    *) return 1 ;;
  esac
  case "${slug%%/*}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "${slug#*/}"  in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s\n' "$slug"
}

# rail_checkout_repo — resolve THIS invocation's checkout. Sets RAIL_CHECKOUT_ROOT and
# RAIL_CHECKOUT_REPO; rc 1 when the tree (or its `origin`) cannot be read.
#
# ⛔ BOTH ARE SET EVEN ON FAILURE, and the caller distinguishes them: a ROOT with no slug
# is "this is a checkout, but its origin names no GitHub repo" — a DIFFERENT refusal from
# "this is not a checkout at all", and the operator's fix differs.
# `git rev-parse --show-toplevel` (not `$PWD`) is what makes a lane invoked from a
# SUBDIRECTORY resolve the same identity, while `git -C <root> remote get-url origin`
# pins the remote the operator actually fetches — `gh repo view` prefers a remote named
# `upstream`, which is a different subject in a fork layout (`atomic-land.sh`'s
# #7727 note).
# ⛔ `GH_REPO` IS DOCUMENTED AS `[HOST/]OWNER/REPO` (`gh help environment`, quoted above), and
# `--repo` takes the same form — so `github.com/o/r` and `o/r` name the SAME repository and must
# compare equal. Case-folding alone graded the host form as a DIFFERENT repo: it refused a rail
# invocation that was correct, and (worse) it made `cloud-cell-supervisor.sh check` FATAL on a
# cell whose keys.env used the documented spelling (§2235 review P2). The leading segment is
# dropped only when it IS a host — dotted, or the checkout's own remote host — so a 3-segment
# value that is not host-shaped stays unrecognised and is still refused.
rail_normalize_slug() {
  local v="${1:-}" host="" first=""
  case "$v" in */*/*) : ;; *) printf '%s\n' "$v"; return 0 ;; esac
  first="${v%%/*}"
  case "$first" in
    *.*|*:*) host="$(rail_lc "$first")" ;;
    *) printf '%s\n' "$v"; return 0 ;;
  esac
  # `host/owner/name` — accept only a host we can attest: github.com, or the checkout's own.
  if [ "$host" = "github.com" ] || { [ -n "${RAIL_CHECKOUT_HOST:-}" ] && [ "$host" = "$RAIL_CHECKOUT_HOST" ]; }; then
    v="${v#*/}"
  fi
  printf '%s\n' "$v"
}

rail_checkout_repo() {
  local root="" url="" host=""
  RAIL_CHECKOUT_REPO=""; RAIL_CHECKOUT_ROOT=""; RAIL_CHECKOUT_HOST=""
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=""
  [ -n "$root" ] || return 1
  RAIL_CHECKOUT_ROOT="$root"
  url="$(git -C "$root" remote get-url origin 2>/dev/null)" || url=""
  RAIL_CHECKOUT_REPO="$(rail_slug_of_remote "${url:-}")" || RAIL_CHECKOUT_REPO=""
  # The HOST the slug came from, kept separately for `rail_pr_url_names` (#2235 review P2):
  # the url proof compares owner/name/number, so without this a same-slug PR on ANOTHER host
  # (a GHE/GitLab mirror, or `GH_HOST` pointing elsewhere) would certify the no-op. A
  # scheme-less remote has no host to read here; the url proof then says so rather than passing
  # silently.
  case "$url" in
    *://*) host="${url#*://}"; host="${host%%/*}"; host="${host#*@}"; host="${host%%:*}" ;;
    *@*:*) host="${url%%:*}"; host="${host#*@}" ;;
    *) host="" ;;
  esac
  RAIL_CHECKOUT_HOST="$(rail_lc "$host")"
  [ -n "$RAIL_CHECKOUT_REPO" ]
}

# refuse_gh_repo_disagreement <ambient> <target> <target-label>
# The stop-work condition. Prints BOTH values, which one is authoritative, and the exact
# fix — never a bare "refusing".
refuse_gh_repo_disagreement() {
  local ambient="$1" target="$2" label="$3"
  say_err "admin-merge: ✗ REFUSING — the inherited GH_REPO names a DIFFERENT repository than $label."
  say_err "   GH_REPO (inherited from the environment) = $ambient"
  say_err "   $label = $target"
  say_err "   gh gives GH_REPO precedence over the checkout for EVERY call that does not pass"
  say_err "   --repo, so this rail would grade and report $ambient's PR #<n> while believing it"
  say_err "   was grading $target's — the #2235 fail-open ('✅ ALREADY MERGED' over a stranger's"
  say_err "   PR, exit 0). That is decided HERE, before any API call."
  say_err "   FIX (per-invocation state, never a cell-wide export):"
  say_err "     • drop the GH_REPO line from the cell's keys.env (it must not be exported at all),"
  say_err "       or unset it for one command:  env -u GH_REPO bash scripts/admin-merge.sh <PR>"
  say_err "     • if a DIFFERENT repo really is the target, say so explicitly:"
  say_err "         bash scripts/admin-merge.sh <PR> --repo $target"
  return 2
}

# resolve_rail_repo <explicit-repo> — the ONLY place the target is decided.
# Sets RAIL_REPO / RAIL_REPO_SOURCE, exports GH_REPO for the whole run (so no helper
# script and no gh call without `--repo` can drift to a third repo), and returns 2 when
# the target cannot be established or an ambient selector disagrees.
resolve_rail_repo() {
  local explicit="${1:-}" ambient="${RAIL_AMBIENT_GH_REPO:-}" target="" source="" gh_answer=""
  rail_checkout_repo || true

  if [ -n "$explicit" ]; then
    # (1) THE CALLER'S CHOICE. Shape-checked first: a `--repo` that is not <owner>/<repo>
    # builds an argument gh cannot resolve, and the resulting failure reads as an
    # auth/credential problem rather than a typo.
    # `[HOST/]OWNER/REPO` is accepted by dropping a host we can attest (see
    # rail_normalize_slug); the value used below is the owner/name form gh's REST paths need.
    explicit="$(rail_normalize_slug "$explicit")"
    case "$explicit" in
      */*/*|/*|*:*) say_err "admin-merge: ✗ refusing --repo '${1:-}' — it is not an <owner>/<repo> (want e.g. daniel-ospina/tortoise)"; return 2 ;;
    esac
    case "$explicit" in
      */*) : ;;
      *) say_err "admin-merge: ✗ refusing --repo '$explicit' — it is not an <owner>/<repo> (want e.g. daniel-ospina/tortoise)"; return 2 ;;
    esac
    case "${explicit%%/*}" in ''|*[!A-Za-z0-9._-]*) say_err "admin-merge: ✗ refusing --repo '$explicit' — the owner segment is not a valid GitHub owner"; return 2 ;; esac
    case "${explicit#*/}"  in ''|*[!A-Za-z0-9._-]*) say_err "admin-merge: ✗ refusing --repo '$explicit' — the repo segment is not a valid GitHub repo name"; return 2 ;; esac
    target="$explicit"; source="--repo"
  elif [ -n "$RAIL_CHECKOUT_REPO" ]; then
    # (2) THE CHECKOUT THIS RAIL IS RUNNING IN.
    target="$RAIL_CHECKOUT_REPO"; source="checkout origin ($RAIL_CHECKOUT_ROOT)"
  else
    # (3) ONLY NOW may gh answer — and only with the ambient selector STRIPPED. Without
    # `env -u GH_REPO` this call answers WITH GH_REPO, so the comparison below would
    # certify the very value it exists to test: a circular read, i.e. a gate that always
    # passes. An ambient selector whose agreement cannot be PROVEN is refused, so this arm
    # is reachable only when GH_REPO is empty.
    if [ -n "$ambient" ]; then
      say_err "admin-merge: ✗ REFUSING — GH_REPO is set ($ambient), but this invocation's checkout could not be read:"
      say_err "   ${RAIL_CHECKOUT_ROOT:+no usable origin remote at $RAIL_CHECKOUT_ROOT}${RAIL_CHECKOUT_ROOT:-this is not a git checkout}"
      say_err "   Nothing here can prove GH_REPO agrees with the tree it is grading, and gh would use it"
      say_err "   for every call without --repo (#2235). Name the target explicitly, or run from its checkout:"
      say_err "       bash scripts/admin-merge.sh <PR> --repo $ambient     # or env -u GH_REPO …"
      return 2
    fi
    # shellcheck disable=SC2086
    gh_answer="$(env -u GH_REPO $GH repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || gh_answer=""
    gh_answer="$(printf '%s' "$gh_answer" | tr -d '[:space:]')"
    case "$gh_answer" in
      */*/*|*:*) gh_answer="" ;;
      */*) : ;;
      *) gh_answer="" ;;
    esac
    if [ -z "$gh_answer" ]; then
      # (4) NO EVIDENCE, NO TARGET. This is the refuse arm of the precedence — a rail that
      # cannot say WHICH repo it is grading must not pick one, because every later verdict
      # (including a clean ✅) would be a claim about a repo it never identified.
      say_err "admin-merge: ✗ refusing — the repo could not be resolved from this checkout."
      say_err "   Tried, in order: an explicit --repo; 'git rev-parse --show-toplevel' + 'git remote get-url origin'"
      say_err "   here (${RAIL_CHECKOUT_ROOT:-not a git checkout}); then 'gh repo view' with GH_REPO stripped."
      say_err "   Select it explicitly:  bash scripts/admin-merge.sh <PR> --repo owner/repo"
      return 2
    fi
    target="$gh_answer"; source="gh repo view (GH_REPO stripped)"
  fi

  # ⛔ THE DISAGREEMENT CHECK RUNS BEFORE ANY gh CALL IN EVERY ARM THAT CAN REACH IT,
  # and it is against the value the ENVIRONMENT claimed — not against the resolved answer
  # (which by now IS the answer, so comparing them would be vacuous).
  # ⛔ `[HOST/]OWNER/REPO` NORMALIZATION BEFORE THE COMPARISON (see rail_normalize_slug): the
  # documented host form names the same repo, so comparing it verbatim was a false block.
  if [ -n "$ambient" ] \
     && [ "$(rail_lc "$(rail_normalize_slug "$ambient")")" != "$(rail_lc "$target")" ]; then
    refuse_gh_repo_disagreement "$ambient" "$target" "the checkout/--repo target"
    return 2
  fi

  RAIL_REPO="$target"; RAIL_REPO_SOURCE="$source"
  # ⛔ PIN IT FOR THE WHOLE RUN. From here every gh call passes `--repo` explicitly (REPO
  # is never empty now, so `repo_args` is always populated) AND every helper that resolves
  # the repo from `GH_REPO` — `record-review.sh`'s documented fallback — receives the same
  # answer. One repo per rail, by construction rather than by convention.
  export GH_REPO="$RAIL_REPO"
  # THE EVIDENCE LINE (#2235's "with that value printed on the evidence line"): an operator
  # reading a merge log must be able to see WHICH repo was graded without inferring it from
  # the PR number, which is exactly the inference that failed.
  info "admin-merge: repo $RAIL_REPO (resolved from $RAIL_REPO_SOURCE)${RAIL_CHECKOUT_REPO:+ — checkout ${RAIL_CHECKOUT_REPO}}"
  return 0
}

main() {
  local PR="" MAIN_RUNS="${MAIN_RUNS:-10}" REPO="" DRY_RUN=0 NO_RERUN=0
  local WORKFLOW="${CI_FAILURE_SET_WORKFLOW:-python-ci.yml}" ANY_WORKFLOW=0
  local PRINT_BOUNDS=0 PRINT_BOUNDS_RUN=""
  # Numeric operator knobs are validated BEFORE anything reads them: a value that
  # is not a positive integer makes the `-ge`/`-lt` guards return 2 and silently
  # skip, which disables the gate rather than failing it.
  validate_timing_knobs || exit 2
  # NO GLOBAL CEILING. An explicit --rerun-timeout (or $RERUN_TIMEOUT) is a
  # verbatim override; otherwise the bound is DERIVED from a GREEN population's
  # observed shard durations at the re-run site, and the fail-safe applies only
  # when the derivation is unavailable — never as a small default.
  RERUN_TIMEOUT="${RERUN_TIMEOUT:-}"
  RERUN_TIMEOUT_EXPLICIT=0
  [ -n "$RERUN_TIMEOUT" ] && RERUN_TIMEOUT_EXPLICIT=1
  RERUN_TIMEOUT_SOURCE=""
  [ "$RERUN_TIMEOUT_EXPLICIT" -eq 1 ] && RERUN_TIMEOUT_SOURCE="explicit --rerun-timeout"
  local MERGE_ARGS=() MERGE_METHOD_SET=0
  # ── THE `--` BOUNDARY IS THE PARSER/gh BOUNDARY (#4078) ──────────────────
  # Everything after `--` goes to `gh pr merge`. The lane-selector pair is the
  # DOCUMENTED remedy for a trigger-split repo (#1003: no single --workflow spans
  # a PR-only and a main-only lane), and the usage line prints it BEFORE `--`. An
  # operator who writes the natural order
  #     admin-merge.sh 42 -- --squash --any-workflow
  # has the flag swallowed into gh's argv: ANY_WORKFLOW stays 0, the lane stays
  # the default, and the rail blocks with a remedy its own invocation could not
  # have applied. Nothing said the flag was ignored — a silent, documented
  # no-op. So the boundary is now enforced in BOTH directions:
  #   * the two LANE-SELECTOR flags are RECOVERED from after `--` and applied as
  #     parser flags (LOUDLY, so the caller learns the boundary) — the documented
  #     order is no longer a trap; and
  #   * every OTHER post-`--` token must be one of `gh pr merge`'s own flags. An
  #     unrecognised token, a bare positional, or one of THIS parser's flags is
  #     REFUSED BY NAME, never handed to gh, because a token the parser silently
  #     drops or forwards is exactly this defect. The only parser flags that are
  #     ALSO gh's own (`--admin`, `--help`) are forwarded, since refusing them
  #     would be a false block on a real gh invocation.
  # A flag that TAKES A VALUE consumes the next token verbatim, so a merge body
  # that happens to be spelled `--any-workflow` stays data, not a flag. A value may
  # also be carried INLINE (`--body=text`); both spellings are gh's.
  local RECOVERED=() PS_TAKES_VALUE=0
  # `gh pr merge`'s own flag set, by NAME (an inline `=value` is split off first).
  # NO REPO SELECTOR IS FORWARDED. `--repo` and its short `-R` are THIS PARSER's
  # (they belong BEFORE `--`, where they route to the analysis AND the merge via
  # ${repo_args[@]}). Forwarded, either spelling points the MERGE at a different
  # repo than the analysis, and the analysis and the head-bound evidence stay on
  # the original one — so both are refused by name below. The allow-list is the
  # gh 2.97.0 `gh pr merge` set exactly; a genuinely new gh flag needs adding here,
  # and a COMBINED shorthand (`-sd`) is refused (names are matched, not spellings).
  local GH_MERGE_BOOL_FLAGS=' --admin --auto --disable-auto --delete-branch -d --merge -m --rebase -r --squash -s --help -h '
  local GH_MERGE_VALUE_FLAGS=' --author-email -A --body -b --body-file -F --subject -t --match-head-commit '

  while [ $# -gt 0 ]; do
    case "$1" in
      --main-runs) MAIN_RUNS="${2:-}"; shift 2 ;;
      --repo) REPO="${2:-}"; shift 2 ;;
      --workflow) WORKFLOW="${2:-}"; shift 2 ;;
      --any-workflow) ANY_WORKFLOW=1; shift ;;
      --rerun-timeout) RERUN_TIMEOUT="${2:-}"; RERUN_TIMEOUT_EXPLICIT=1; RERUN_TIMEOUT_SOURCE="explicit --rerun-timeout"; shift 2 ;;
      --no-rerun) NO_RERUN=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      # Make the DERIVATION visible on demand: the re-run bound is not a round
      # number, and an operator must be able to see where it came from without
      # reading the source. Handled AFTER the loop so `--repo` may appear on
      # either side of it; the run id is OPTIONAL and must not swallow a flag.
      --print-bounds)
        PRINT_BOUNDS=1
        if [ $# -ge 2 ] && is_run_id "${2:-}"; then PRINT_BOUNDS_RUN="${2:-}"; shift; fi
        shift ;;
      --help|-h) usage; exit 0 ;;
      --) shift; while [ $# -gt 0 ]; do
            # The value of a value-taking gh flag is DATA, whatever it is spelled.
            if [ "$PS_TAKES_VALUE" -eq 1 ]; then
              PS_TAKES_VALUE=0
              MERGE_ARGS+=("$1"); shift; continue
            fi
            # gh carries a value INLINE too (`--body=text`). Classify on the NAME
            # and keep the token whole, so the `=value` half is neither dropped
            # nor mistaken for a separate token.
            local ps_name="$1" ps_inline=0
            case "$ps_name" in
              -*=*) ps_name="${ps_name%%=*}"; ps_inline=1 ;;
            esac
            case "$ps_name" in
              # The documented remedy, in either order: RECOVER it for the parser.
              --any-workflow)
                if [ "$ps_inline" -eq 1 ]; then
                  say_err "admin-merge: ✗ refusing '$1' — '--any-workflow' takes no value. Put it BEFORE the"
                  say_err "   separator: admin-merge.sh <PR> --any-workflow -- <gh flags>"
                  exit 2
                fi
                RECOVERED+=(--any-workflow); shift; continue ;;
              --workflow)
                if [ "$ps_inline" -eq 1 ]; then
                  say_err "admin-merge: ✗ refusing '$1' — the parser's --workflow takes its value as the NEXT"
                  say_err "   argument and must precede the separator: admin-merge.sh <PR> --workflow <f> -- …"
                  exit 2
                fi
                # A MISSING VALUE IS REFUSED, not defaulted. Recovering an
                # empty --workflow would leave WORKFLOW empty, and an empty lane
                # reads as the --any-workflow opt-out — a SILENT widening to the
                # weaker certificate, i.e. this defect's own class. A value that
                # is ITSELF a flag is refused for the same reason. Both refusals
                # are pre-gh, like the inline spelling above.
                if [ $# -lt 2 ] || [ -z "${2:-}" ] || [ "${2#-}" != "$2" ]; then
                  say_err "admin-merge: ✗ refusing '--workflow' after the '--' separator — it needs its"
                  say_err "   value as the NEXT argument, and a flag cannot be that value. Put it BEFORE the"
                  say_err "   separator: admin-merge.sh <PR> --workflow <file> -- <gh flags>"
                  exit 2
                fi
                RECOVERED+=(--workflow "$2"); shift 2
                continue ;;
              # THIS PARSER's flags after `--` are refused BY NAME. `--repo` and
              # its short `-R` are the repo selectors: forwarded, either would
              # point the MERGE at another repo while the analysis and the
              # head-bound evidence stayed on this one.
              --main-runs|--repo|-R|--rerun-timeout|--no-rerun|--dry-run|--print-bounds)
                local ps_hint="$ps_name"
                [ "$ps_name" = "-R" ] && ps_hint="--repo owner/repo"
                say_err "admin-merge: ✗ refusing '$ps_name' after the '--' separator — that is a PARSER flag,"
                say_err "   and only 'gh pr merge' flags may follow '--'. Repo selection belongs to this"
                say_err "   parser, where it routes to the analysis AND the merge:"
                say_err "   admin-merge.sh <PR> $ps_hint … -- --squash"
                exit 2 ;;
            esac
            case " $GH_MERGE_BOOL_FLAGS " in *" $ps_name "*)
              case "$ps_name" in --merge|--rebase|--squash) MERGE_METHOD_SET=1 ;; esac
              MERGE_ARGS+=("$1"); shift; continue ;;
            esac
            case " $GH_MERGE_VALUE_FLAGS " in *" $ps_name "*)
              MERGE_ARGS+=("$1")
              [ "$ps_inline" -eq 1 ] || PS_TAKES_VALUE=1
              shift; continue ;;
            esac
            case "$1" in
              -*)
                say_err "admin-merge: ✗ refusing '$1' after the '--' separator — it is not one of the 'gh pr"
                say_err "   merge' flags this rail forwards, so passing it through would either fail at gh or"
                say_err "   be dropped IN SILENCE. If it is a parser flag, put it BEFORE the separator:"
                say_err "   admin-merge.sh <PR> $1 -- --squash"
                say_err "   (A COMBINED shorthand such as '-sd' is valid at gh but is not matched here —"
                say_err "    write it as '-s -d'.)"
                exit 2 ;;
              *)
                say_err "admin-merge: ✗ refusing the bare argument '$1' after the '--' separator — the PR is"
                say_err "   already supplied, so gh would reject a second positional. Only 'gh pr merge' flags"
                say_err "   may follow '--'."
                exit 2 ;;
            esac
          done ;;
      --admin|--admin=true) shift ;;  # always added by this script
      -*) case "$1" in --merge|--rebase|--squash) MERGE_METHOD_SET=1 ;; esac
          MERGE_ARGS+=("$1"); shift ;;
      *)
        if [ -z "$PR" ]; then PR="$1"; else say_err "admin-merge: unexpected argument '$1'"; exit 2; fi
        shift ;;
    esac
  done

  # Apply the lane-selector flags RECOVERED from after `--`. LOUD, because the
  # invocation that needs recovery is one whose author should learn the boundary;
  # and applied AFTER the loop so a recovered flag wins, exactly as if it had been
  # written before `--` (the parser's last-occurrence rule — where a `--workflow`
  # with no value, or with a flag as its value, is refused in the loop above, so
  # nothing applied here can be empty).
  if [ "${#RECOVERED[@]}" -gt 0 ]; then
    say_err "admin-merge: ⚠ parser flag(s) found AFTER the '--' separator — recovering them for the parser"
    say_err "   (only 'gh pr merge' flags belong after '--'; a lane selector is recovered instead of being"
    say_err "    handed to gh, which would reject it)."
    say_err "   Prefer: admin-merge.sh <PR> [--workflow <f>|--any-workflow] -- <gh flags>"
    local ri=0 rn="${#RECOVERED[@]}"
    while [ "$ri" -lt "$rn" ]; do
      case "${RECOVERED[$ri]}" in
        --any-workflow) ANY_WORKFLOW=1; ri=$((ri + 1)) ;;
        --workflow) WORKFLOW="${RECOVERED[$((ri + 1))]:-}"; ri=$((ri + 2)) ;;
        *) ri=$((ri + 1)) ;;
      esac
    done
  fi

  # The baseline WINDOW is an operator knob like the timing ones, and it is
  # validated for the same two reasons: `--main-runs abc` makes `gh run list
  # --limit abc` fail (which the lane gate now reads as a LISTING failure — a
  # named BLOCK, but one the operator could have been told about before any CI
  # work), and an unbounded window turns this correctness knob into a COST one —
  # the lane gate fetches one Jobs API listing per run on each side, and one
  # confirmation of the stage-1 baseline is not worth 10,000 calls.
  if ! counter_is_positive "$MAIN_RUNS"; then
    say_err "admin-merge: ✗ refusing --main-runs '${MAIN_RUNS}' — the baseline window must be a"
    say_err "   POSITIVE integer number of main runs (the #3469 union needs several; one run is not"
    say_err "   a baseline)."
    exit 2
  fi
  if counter_exceeds_max "$MAIN_RUNS" "$MAIN_RUNS_MAX"; then
    say_err "admin-merge: ✗ refusing --main-runs '${MAIN_RUNS}' — beyond the usable window (max"
    say_err "   ${MAIN_RUNS_MAX} runs). The lane-coverage gate fetches one Jobs API listing per run on"
    say_err "   each side, so an unbounded window is a cost, not a better baseline."
    exit 2
  fi
  # An explicit --rerun-timeout is an operator-supplied CEILING, checked here (not
  # in validate_timing_knobs, which runs before the flags are parsed) for two
  # faults:
  #   * a LEADING ZERO (`0100`) — bash ARITHMETIC reads it as OCTAL while the
  #     `[ "$waited" -lt "$RERUN_TIMEOUT" ]` loop condition reads it as DECIMAL,
  #     so the same spelling would mean two different bounds;
  #   * not a POSITIVE INTEGER — `[ "$waited" -lt "$RERUN_TIMEOUT" ]` returns 2, the
  #     loop body NEVER RUNS and the function falls through to the bound with ZERO
  #     polls, printing a verdict about a run it never looked at.
  # There is no ordering to enforce against a stall window: they are the same
  # derived bound, so an explicit cap is always coherent (see wait_for_run).
  if [ "$RERUN_TIMEOUT_EXPLICIT" -eq 1 ]; then
    if counter_has_leading_zero "$RERUN_TIMEOUT"; then
      say_err "admin-merge: ✗ refusing --rerun-timeout '${RERUN_TIMEOUT}' — a LEADING ZERO is ambiguous: bash"
      say_err "   ARITHMETIC reads it as OCTAL while the 'test' comparisons that bound the wait read it as"
      say_err "   DECIMAL, so the same spelling would mean two different bounds."
      say_err "   Write it without the leading zero (e.g. '100', not '0100')."
      exit 2
    fi
    if ! counter_is_positive "$RERUN_TIMEOUT"; then
      say_err "admin-merge: ✗ refusing --rerun-timeout '${RERUN_TIMEOUT}' — it must be a POSITIVE integer number of seconds."
      say_err "   A non-numeric or zero bound makes the re-run wait's comparison error out, so the"
      say_err "   loop runs ZERO polls and the rail reports a verdict about a run it never looked at."
      say_err "   Omit the flag to derive the bound per shard."
      exit 2
    fi
    if counter_exceeds_max "$RERUN_TIMEOUT" "$TIMING_KNOB_MAX"; then
      say_err "admin-merge: ✗ refusing --rerun-timeout '${RERUN_TIMEOUT}' — beyond the usable range"
      say_err "   (max ${TIMING_KNOB_MAX}s). An all-digit value past the shell's integer range makes the"
      say_err "   wait's comparison error out, which SKIPS the loop instead of bounding it."
      exit 2
    fi
  fi

  # ── 0. THE REPO IS DECIDED BY EVIDENCE, BEFORE ANY API CALL (#2235) ──────
  # ⛔ THIS MUST STAY ABOVE THE FIRST gh CALL AND ABOVE `repo_args`. Above the first call
  # because the refusal has to happen before anything can answer for the wrong repo (and
  # because the test that pins it asserts ZERO gh invocations); above `repo_args` because
  # every downstream call is pinned by `REPO` being non-empty, which is what turns this
  # one resolution into a property of the whole run rather than of one call site.
  # ⛔ AND ABOVE `--print-bounds`, which is not an exception: `print_bounds` →
  # `derive_rerun_timeout` → `fetch_run_jobs`/`green_run_ids` reads the RUN's shard durations
  # and the GREEN population with NO `--repo`, so on that path the ambient `GH_REPO` decided
  # which repo's timings were measured and reported — the same leak, one symptom over (§2235
  # review P1: the arm exits ~20 lines before the resolver, and no test covers it because
  # every `--print-bounds <run-id>` arm in the suite passes `--repo`).
  resolve_rail_repo "$REPO" || exit 2
  REPO="$RAIL_REPO"

  # The derivation report is an inspection: print and exit BEFORE any PR is
  # required, so `--print-bounds <run-id>` works on a bare invocation.
  if [ "$PRINT_BOUNDS" -eq 1 ]; then print_bounds "$PRINT_BOUNDS_RUN"; exit 0; fi

  # gh REQUIRES a merge method when it is not interactive. Default it so an
  # omission cannot leave the evidence marker standing over an unmerged PR. An
  # explicit --merge/--rebase/--squash wins and is not doubled (the caller's
  # flags keep their exact order/position).
  if [ "$MERGE_METHOD_SET" -eq 0 ]; then
    MERGE_ARGS=(--squash ${MERGE_ARGS[@]+"${MERGE_ARGS[@]}"})
  fi

  [ -n "$PR" ] || { say_err "admin-merge: a PR number is required"; usage >&2; exit 2; }
  case "$PR" in *[!0-9]*) say_err "admin-merge: PR must be numeric (got '$PR')"; exit 2 ;; esac
  [ -x "$CFS" ] || [ -f "$CFS" ] || { say_err "admin-merge: parser not found at $CFS"; exit 1; }
  BASH="${BASH:-bash}"

  # ── 0. THE REPO IS DECIDED BY EVIDENCE, BEFORE ANY API CALL (#2235) ──────
  # (The resolution itself runs ABOVE `--print-bounds` — see the note there; this is the
  # point where its answer starts pinning every downstream call.)
  local repo_args=()
  [ -n "$REPO" ] && repo_args=(--repo "$REPO")

  # The lane both sides are read from. An unfiltered main window is how the
  # baseline reads EMPTY while main is red (the bogus zero) — so the filter is
  # the default and the opt-out is explicit.
  local wf_args=() lane="$WORKFLOW"
  if [ "$ANY_WORKFLOW" -eq 1 ] || [ -z "$WORKFLOW" ]; then
    wf_args=(--any-workflow); lane="any workflow"
  else
    wf_args=(--workflow "$WORKFLOW")
  fi

  # P1-2 (fresh review): `local TMP` + a trap that READS it is broken — bash runs
  # the EXIT trap after `main` returns, when the local is already out of scope, so
  # under `set -u` the trap aborted with "TMP: unbound variable" and cleanup never
  # ran (729 stale `admin-merge.*` directories, 21 MB, on the reviewing machine).
  # Assign the FILE-SCOPE `TMP` declared below and expand it at trap-set time.
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/admin-merge.XXXXXX")"
  # ⛔ THE READ PROBES' STDERR FILE IS CREATED HERE, IN THE PARENT (#1750 review). The reads
  # run inside command substitutions, so a `mktemp` performed THERE would put the path in a
  # subshell that this trap cannot see — and the trap is the only thing that removes the file
  # after a process-group signal. `mktemp` (O_EXCL) is still what makes the name
  # unpredictable, so the truncation primitive the predictable name allowed is gone; this line
  # is what keeps the trap able to clean up after it.
  READ_ERRTMP="$(mktemp "${TMPDIR:-/tmp}/admin-merge-read.XXXXXX" 2>/dev/null)"
  # ⛔ THE READ'S OWN TEMP FILE IS IN THE EXIT TRAP (#1690 review). `resolve_head` removes it on
  # both normal exits, but a process-group signal (what a terminal Ctrl-C actually delivers)
  # kills the subshell before its `rm` runs, and the file leaks. SIGKILL can still leak it —
  # nothing can trap that — so this narrows the window rather than closing it to zero. The path
  # is `mktemp`-generated and read from the file-scope `READ_ERRTMP` at TRAP TIME, so it follows
  # the file the reads actually created instead of naming a predictable path (#1750 review).
  trap 'rm -rf "${TMP:-}"; rm -f "${READ_ERRTMP:-}"' EXIT

  # ── 0a. ALREADY MERGED ⇒ BENIGN NO-OP (#1709 rec 7) ──────────────────────
  # The rail runs at-least-once: a crash, a pause that resumes, or a second box
  # sweeping the same PR can execute this SAME merge twice. A duplicate that lands
  # on a PR another execution already merged must be a no-op, not a second write
  # and not a confusing failure. Before this guard it was neither benign nor clear:
  # the rail ran its WHOLE CI parity analysis, posted a SECOND head-bound evidence
  # comment, then `gh pr merge` exited non-zero (the PR is already merged) and the
  # lost-response arm rendered that as "the response was lost" — a network-incident
  # narrative for an entirely ordinary duplicate.
  #
  # ⛔ ONE SHOT, THROUGH THE ONE DOOR. The state read goes through
  # `poll_merge_artifact` (the same projection, the same MERGED/OPEN/CLOSED
  # allow-list, the same unreadable-vs-value discipline the post-merge arms use)
  # with an attempts override of 1 — this is a SNAPSHOT question ("is it already
  # merged?"), not the bounded WAIT the other two callers ask. A second reader here
  # would be a second definition of "merged", which is exactly the drift #1298
  # closed.
  #
  # ⛔ UNREADABLE IS NOT A REFUSAL, and the direction is deliberate. This guard
  # removes WASTE; it is not a safety gate, and nothing is skipped by proceeding:
  # if the state cannot be read we fall through to the rail exactly as it behaved
  # before this block, and the post-merge artifact read still governs the outcome.
  # Refusing here would block every legitimate merge on a transient GitHub blip —
  # a false block, the other failure direction — for no safety gain. The residual is
  # declared rather than implied: a duplicate whose PRE-check read fails can still
  # post its second evidence comment. It cannot corrupt state.
  # ⛔ A REFUSED OVERRIDE IS A CALLER ERROR, NOT A READ FAILURE, so it is not folded into
  # the unreadable arm below: that arm prints "could not READ the state of PR #…", which for
  # a refusal would name the wrong cause (a GitHub blip) for a caller's bad bound, and would
  # attribute a claim about reality to a read that never ran. `poll_merge_artifact` returns
  # NON-ZERO exactly on a refusal, so the status separates the two cases here. Both of the
  # door's refusals are excluded TODAY — the knob by `validate_timing_knobs` at startup, the
  # override by this call's literal `1` — so the arm below is DEFENSIVE rather than live: it
  # exists so that a future caller passing a COMPUTED override cannot have a bad bound
  # re-narrated as a GitHub read failure.
  # shellcheck disable=SC2086
  if ! poll_merge_artifact "$PR" 1; then
    say_err "admin-merge: ✗ the already-merged pre-check could not run — its attempts override was REFUSED (above)."
    say_err "   This is a CALLER error, not a read failure: refusing rather than reading the artifact with an unvalidated bound."
    exit 2
  fi
  if [ "$MERGE_ART_VERDICT" = "merged" ]; then
    # ⛔ "ALREADY MERGED" IS A CLAIM ABOUT ONE SPECIFIC PR, AND IT IS PROVED BEFORE IT IS
    # MADE (#2235). This line is the one that lied: it printed a ✅ and exit 0 for a
    # SEPTEMBER tortoise PR while grading an open agent-infra one, because the number alone
    # was assumed to identify a PR. Two independent proofs are required now, and either
    # refusal names the two repos in play:
    #
    #   (i) THE TARGET MUST BE THE CHECKOUT'S REPO. The no-op is a SUCCESS REPORT, and a
    #   success report about a repo this rail is not standing in is precisely the shape
    #   that hid the defect — an inherited selector adopting a stranger's PR as "already
    #   done". An explicit `--repo` naming another repo is still honoured for a real
    #   merge (that is the documented selector), but it cannot certify a no-op: the
    #   answer here is "go and look from that repo's checkout", not ✅.
    #   (ii) THE PR'S URL MUST NAME THAT REPO AND THIS NUMBER — the url is the only field
    #   that carries the (repo, number) pair as data, so it is the only field that can
    #   distinguish the two #2234s.
    if [ -n "${RAIL_CHECKOUT_REPO:-}" ] \
       && [ "$(rail_lc "$RAIL_CHECKOUT_REPO")" != "$(rail_lc "$REPO")" ]; then
      say_err "admin-merge: ✗ REFUSING to report PR #$PR as ALREADY MERGED — the resolved target is not this checkout's repo:"
      say_err "   resolved target (${RAIL_REPO_SOURCE:-unstated}) = $REPO"
      say_err "   this checkout ($RAIL_CHECKOUT_ROOT)          = $RAIL_CHECKOUT_REPO"
      say_err "   A merged PR in ANOTHER repo is NOT evidence about this one: a bare number exists in"
      say_err "   both, and that ambiguity is exactly how #2235 printed a ✅ over an unmerged PR (#2235)."
      say_err "   FIX: re-run from the checkout of $REPO, or drop the cross-repo --repo if $RAIL_CHECKOUT_REPO was meant."
      exit 2
    fi
    rail_pr_url_names "$PR" "$REPO"; local id_rc=$?
    case "$id_rc" in
      0) : ;;
      1)  say_err "admin-merge: ✗ REFUSING to report PR #$PR as ALREADY MERGED — its url names a DIFFERENT repository:"
          say_err "   resolved target = $REPO"
          say_err "   the PR's own url answers for another repo, so the number and the repo do not agree."
          say_err "   Nothing here is evidence that $REPO#$PR is merged. Check the selector: --repo, or an"
          # ⛔ THE INHERITED VALUE, NOT `$GH_REPO` (#2235). By this point the rail has EXPORTED its own
          # resolved slug into `GH_REPO`, so printing that variable here would report the resolved
          # answer as if it were the ambient claim — attributing the failure to a value that is not
          # the one in play. `RAIL_AMBIENT_GH_REPO` is the spelling the environment actually carried.
          say_err "   inherited GH_REPO in the environment ($( [ -n "${RAIL_AMBIENT_GH_REPO:-}" ] && printf '%s' "$RAIL_AMBIENT_GH_REPO" || printf 'unset' ))."
          exit 2 ;;
      *)  say_err "admin-merge: ✗ REFUSING to report PR #$PR as ALREADY MERGED — the PR's identity could not be read."
          say_err "   The state read said MERGED, but a no-op SUCCESS LINE is a claim about a specific PR, and"
          say_err "   this run cannot name it. Re-run; if this persists, check gh auth/network and --repo $REPO."
          exit 2 ;;
    esac
    info "admin-merge: ✅ PR #$PR is ALREADY MERGED (state=MERGED, mergedAt=$MERGE_ART_MERGED_AT) — duplicate execution is a NO-OP: no CI work, no evidence comment, no merge attempt"
    exit 0
  fi
  if [ "$MERGE_ART_VERDICT" = "unreadable" ]; then
    # ⛔ CLASSIFIED, NOT JUST ANNOUNCED (#1910). The measured incident's SECOND surface:
    # `merged_precheck_unreadable` was a rate-limit refusal, and this line said nothing about
    # that, so the next step was to keep going rather than to wait. The tag makes the cause
    # machine-readable; §13i pins it.
    local pre_tag=""
    diag_is_rate_limit "${MERGE_ART_DIAG:-}" && pre_tag=" [rate_limited]"
    say_err "admin-merge: ⚠️  [merged_precheck_unreadable]${pre_tag} — could not READ the state of PR #$PR, so this run does NOT know whether it is already merged."
    say_err "   This is NOT a claim about the PR. Proceeding with the rail (the pre-#1709 behaviour): if the PR turns out to be"
    say_err "   already merged, a duplicate evidence comment may be posted — the post-merge state read still governs the outcome."
    if [ -n "${MERGE_ART_DIAG:-}" ]; then
      say_err "   the state read reported: ${MERGE_ART_DIAG}"
      [ -n "$pre_tag" ] && say_rate_limit_note
    else
      say_err "   the state read wrote no non-blank message."
    fi
  fi

  local head
  # shellcheck disable=SC2086
  head="$(require_head "$PR" ${repo_args[@]+"${repo_args[@]}"})" || exit 1
  # ⛔ NO DEFENCE-IN-DEPTH EMPTINESS CHECK HERE (#1690 review). `require_head` can only
  # return 0 with a 40-hex value, so an emptiness guard at this site is DEAD CODE — and
  # keeping this site defended while the two §4 COMPARISON sites (the ones that actually
  # printed "head moved") ran bare INVERTED the invariant: the least-exposed site was the
  # guarded one. The guarantee lives in `require_head`, once, and covers every caller.
  info "admin-merge: PR #$PR head $head"

  # ── 0. A DRAFT CANNOT BE MERGED — refuse EARLY, by name ──────────────────
  # gh refuses a draft with "Pull Request is still a draft", and commit-workflow
  # opens drafts deliberately, so this is a systematic collision, not an edge
  # case. Refuse BEFORE any CI work and with the SPECIFIC reason, rather than
  # letting it surface as a generic merge failure after the evidence marker was
  # posted. The rail does NOT silently ready the PR: a draft is a deliberate
  # review checkpoint, and clearing it is the author's act, not the rail's.
  local is_draft
  # ⛔ READ THROUGH THE DOOR, AND PROPAGATE ITS FAILURE (#1750). The bare read here was
  # the defect: a failed read yielded "", and the comparison below read that as "not a
  # draft" and let the rail proceed. `require_draft` prints the value ONLY when it is
  # exactly `true`/`false`, so `|| exit 1` is what makes an unreadable probe refuse
  # instead of becoming a permission. It is deliberately NOT defended by a second
  # emptiness check here: the guarantee lives in the door, once, and a defence at the
  # one site that already refuses is how the @1690 fix inverted its own invariant.
  # shellcheck disable=SC2086
  is_draft="$(require_draft "$PR" ${repo_args[@]+"${repo_args[@]}"})" || exit 1
  if [ "$is_draft" = "true" ]; then
    say_err "admin-merge: ✗ BLOCK — PR #$PR is a DRAFT, and gh refuses to merge a draft"
    say_err "   (\"Pull Request is still a draft\"). This is NOT a CI-failure verdict and NOT"
    say_err "   a merge failure: no comparison was run and no evidence was posted. A draft is a"
    say_err "   deliberate review checkpoint, so clearing it is the author's act, not the rail's."
    say_err "   Mark the PR ready and re-run:  gh pr ready $PR"
    exit 1
  fi

  # ── 0b. IS THE WATCHED LANE APPLICABLE TO THIS DIFF? (#1614) ──────────────
  # Measured BEFORE the lane is read: if the watched workflow's own `on:` block
  # cannot fire for this PR's changed set, then no run OF that lane can ever
  # attach to this head, and the lane filter is not "unavailable" but
  # INAPPLICABLE. #1439 refused rather than SILENTLY widening the lane; this is
  # not that. The widening is (a) MEASURED from the workflow file and the diff,
  # (b) SCOPED to the measured-inapplicable case, and (c) PRINTED. The #1261
  # protection is untouched: the fallback is a STRICTER surface (every lane that
  # ran) AND the PR's evaluated-tree gate (§4.5, every workflow and app) still
  # runs. An UNDECIDABLE applicability does NOT fall back — the rail refuses
  # exactly as before, and a lane that SHOULD have run still refuses at §1b.
  local LANE_FALLBACK_FROM=""
  local lane_reason=""
  if [ "$ANY_WORKFLOW" -ne 1 ] && [ -n "$WORKFLOW" ]; then
    lane_applicable ".github/workflows/$WORKFLOW" "$head"
    case "$LANE_APPLICABILITY" in
      inapplicable)
        # ⛔ THE FALLBACK IS FOR THE DEAD END, NOT FOR THE TRIGGER SHAPE. An
        # inapplicable lane only DEAD-ENDS the rail when it has NO run for this
        # head (that is what makes precondition 1 unsatisfiable). A lane that
        # matched no trigger path but DID run for the head is not a dead end, and
        # widening there would be gratuitous — so the probe decides, and an
        # UNREADABLE probe fails closed (no widening).
        if lane_has_no_head_run "$head"; then
          LANE_FALLBACK_FROM="$WORKFLOW"
          # ⛔ NEVER embed the fallback text in a `${VAR:-word}` default here. An
          # apostrophe inside the `word` of a parameter expansion opens a QUOTE that
          # bash does not close on this line — it swallows the rest of the branch as
          # one command, `bash -n` still passes, and the whole fallback silently
          # becomes a no-op. Caught by the suite (the message printed, the lane did
          # not change). Assign first, then expand.
          lane_reason="$LANE_APPLICABILITY_REASON"
          [ -n "$lane_reason" ] || lane_reason="the lane workflow declares no PR trigger that can fire for this changed set"
          say_err "admin-merge: ⚠️  LANE INAPPLICABLE — falling back to the evaluated surface (this is NOT a silent widening)."
          say_err "   watched lane: '$WORKFLOW'  (workflow file: .github/workflows/$WORKFLOW at head $head)"
          say_err "   $lane_reason"
          say_err "   Why: the lane's own 'on:' block cannot fire for THIS PR's changed set, and the"
          say_err "   lane has NO run for head $head — waiting for CI cannot clear it. The lane is"
          say_err "   INAPPLICABLE here, not missing."
          if [ -n "$WF_PR_CHANGED_PATHS" ]; then
            say_err "   changed file(s) consulted ($(printf '%s' "$WF_PR_CHANGED_PATHS" | grep -c '[^[:space:]]') total):"
            printf '%s\n' "$WF_PR_CHANGED_PATHS" | sed -n '1,10p' | sed 's/^/      /' >&2
          fi
          say_err "   FALLING BACK to the evaluated surface: the lane filter is DROPPED for this run, so"
          say_err "   the PR's failures are compared against EVERY workflow on main that ran, and the"
          say_err "   PR's own evaluated tree (all workflows, all apps) still gates the merge at §4.5."
          say_err "   The #1261 guard is NOT weakened: a lane that SHOULD have run and produced no run"
          say_err "   still REFUSES at §1b — only a lane that CANNOT run is skipped."
          # Set the SAME state the parser flag sets, so every downstream consumer
          # (wf_args, lane_run_ids, lane coverage, the certificate) sees ONE path.
          ANY_WORKFLOW=1
          wf_args=(--any-workflow)
          lane="any workflow"
        fi
        ;;
      unknown)
        # Fail closed: an applicability that could not be MEASURED is not an
        # exemption. Keep the lane filter; §1b refuses exactly as before. Quiet by
        # design: the refusal below is the loud part, and this fires on every
        # unreadable map (including the common case where the lane simply has no
        # PR-relevant trigger and the file could not be fetched).
        :
        ;;
    esac
  fi

  # ── 1. the PR's failing set, with provenance for the flake re-run ────────
  # Selected by COMMIT, not by PR: the analyzed set must be provably the SHA the
  # evidence marker names. `--pr` would re-resolve the head internally, so a push
  # between the two resolutions could analyze one SHA and certify another (#P1).
  #
  # #1417 — THE ANALYSIS IS RE-RUN, ONCE, WHEN THE ONLY THING UNFINISHED IS THE
  # RAIL'S OWN BODY-EDIT GENERATION. `[3/4] record` PATCHes the review marker
  # into the PR body (an `edited` activity), which re-triggers exactly the two
  # NON-code-measuring guard workflows (`pipeline-compliance` — #513's verdict
  # binding — and `workflow-lock`), creating two fresh runs 11-87s AFTER `[2/4]
  # verify` certified the head. MEASURED on #1495 and #1633: `[4/4]` refused with
  # `run still in_progress` against its own work, costing a whole extra rail
  # round. The generation is WAITED FOR and the surface RE-READ, so a guard run
  # that FAILS enters the failing set and blocks exactly as before — this
  # defers a refusal on an unfinished run set, never a failure.
  local pr_status=0 pr_completed pr_tested pr_pending pr_self_edit_retry=0 pr_first_checks_waited=0 pr_first_checks_cleared=0
  # The last diagnostics block emitted, so the #1417 re-read pass does not
  # DOUBLE-EMIT byte-identical parser diagnostics (review P2, PR #1640). The
  # `pr-drops.err` FILE is left intact — the attribution half reads it later.
  local pr_drops_emitted=""
  while :; do
    pr_status=0
    # THE PARSER'S DIAGNOSTICS ARE CAPTURED, NOT INHERITED (#1353): the dropped
    # FAILED tokens it names are the ONLY source of the attribution half, and they
    # must reach the posted evidence. They are re-emitted verbatim below, so nothing
    # that used to be visible on stderr is silenced.
    run_failure_set --commit-rows "$head" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
      --provenance "$TMP/pr-runs.txt" --runs-report "$TMP/pr-report.txt" --per-run "$TMP/pr-per-run.txt" \
      --unattributed "$TMP/pr-unattributed.txt" \
      > "$TMP/pr-rows.txt" 2> "$TMP/pr-drops.err" || pr_status=$?
    if [ -s "$TMP/pr-drops.err" ]; then
      local pr_drops_cur
      pr_drops_cur="$(cat "$TMP/pr-drops.err")"
      if [ "$pr_drops_cur" != "$pr_drops_emitted" ]; then
        printf '%s\n' "$pr_drops_cur" >&2
        pr_drops_emitted="$pr_drops_cur"
      fi
    fi
    if [ "$pr_status" -ne 0 ]; then
      say_err "admin-merge: ✗ BLOCK — could not extract the PR's failing set (parser exit $pr_status)."
      say_err "   Refusing to certify a comparison computed over an unreadable set."
      exit 1
    fi
    # The id set the evidence and the re-run loop use, derived from the ROWS the
    # decision consumes, so the two can never disagree about which ids exist.
    cut -f1 "$TMP/pr-rows.txt" 2>/dev/null | sort -u > "$TMP/pr-fails.txt"

    # ── 1b. THE HEAD MUST HAVE BEEN TESTED (review P0 #3) ────────────────
    # `examined=0` is NOT the signal — a green lane legitimately has no failing
    # runs. The signal is `tested=0` (no run actually exercised this revision) or
    # `pending>0` (something has not finished). Either way an empty failing set
    # proves nothing, so the rail must not read it as "no unique failures".
    pr_completed="$(report_value "$TMP/pr-report.txt" completed)"
    pr_tested="$(report_value "$TMP/pr-report.txt" tested)"
    pr_pending="$(report_value "$TMP/pr-report.txt" pending)"

    # #1417: defer ONLY the rail's own body-edit generation, and re-verify the
    # surface ONCE. A NEGATIVE test is deliberate: `pending` that is 0 (nothing
    # unfinished) and `pending` that is UNREADABLE ('n/a') both leave the loop
    # immediately, and the unreadable one is refused by §1b below — the loop
    # never waits on a counter it could not read.
    # ── 1b-i. THE FIRST-CHECKS WAIT — the fresh-PR race and the #2090 shape ──
    # Nothing to compare is not the same as nothing failing. If no run has
    # APPEARED at this head, or a run is still queued/in_progress, hold this
    # wait's OWN window and report ITS state on expiry — never the RE-RUN
    # wait's bound or message. The #1417 body-edit generation keeps its own
    # smaller wait first; only a run that is NOT that generation falls through.
    if [ "$pr_first_checks_waited" -eq 0 ] \
       && { counter_is_positive "$pr_pending" \
            || { counter_is_zero "$pr_completed" && counter_is_zero "$pr_pending"; }; }; then
      if counter_is_positive "$pr_pending" && [ "$pr_self_edit_retry" -eq 0 ] \
         && settle_self_edit_generation "$head"; then
        pr_self_edit_retry=1
        continue
      fi
      if wait_for_first_checks "$head"; then
        pr_first_checks_waited=1
        pr_first_checks_cleared=1
        # Let the #1417 settle probe run again on the re-read: a NEW run may be
        # the rail's own body-edit generation, and suppressing it here would
        # reproduce the #2090 refusal one generation later.
        pr_self_edit_retry=0
        continue
      fi
      # Report the FIRST-CHECKS wait's OWN expiry...
      block_on_first_checks "$head"
      # ...then let the ORIGINAL §1b refusal decide (pending → not-finished;
      # no run at all → the lane-applicability analysis). The wait holds the
      # rail until there is something to measure; it never replaces the gate's
      # diagnosis, and it never merges.
      break
    fi
    if ! counter_is_positive "$pr_pending"; then break; fi
    if [ "$pr_self_edit_retry" -eq 1 ]; then break; fi
    settle_self_edit_generation "$head" || break
    pr_self_edit_retry=1
  done

  # "Not proven finished" is not "finished": `! counter_is_zero` blocks on an
  # UNREADABLE `pending` too, not only on a positive one. A bare `-gt 0` skipped
  # the body on a non-numeric value (`[ n/a: integer expression expected`, exit
  # 2) and the rail merged while the lane might still be running — the #3420
  # ratchet that precondition 1 exists to stop (VGATE cycle 2, #1003).
  if ! counter_is_zero "$pr_pending"; then
    say_err "admin-merge: ✗ BLOCK — precondition unmet: run still in_progress — no classification attempted."
    say_err "   The test lane has NOT finished for head $head:"
    if counter_is_positive "$pr_pending"; then
      say_err "   $pr_pending run(s) still queued/in progress (lane: $lane)."
      if [ "$pr_first_checks_cleared" -eq 1 ]; then
        say_err "   The FIRST-CHECKS wait CLEARED (the lane was terminal), but a NEW run"
        say_err "   appeared on the re-read — the #2090 shape one generation later. The rail"
        say_err "   refuses rather than compare an unfinished set."
        say_err "   Next: re-run the rail once that new run completes."
      else
        say_err "   This is the FIRST-CHECKS precondition, which gates BEFORE any comparison;"
        say_err "   the FIRST-CHECKS wait is closed (see above) and it says WHICH way it closed:"
        say_err "   a STALL (nothing moved), a CEILING (still moving, out of room), or the legacy"
        say_err "   window (no run appeared, or the surface could not be read)."
        say_err "   Next: re-run the rail once those runs complete, or raise"
        say_err "   ADMIN_MERGE_FIRST_CHECKS_CEILING (currently ${FIRST_CHECKS_CEILING}s) for a run that"
        say_err "   is still progressing, or ADMIN_MERGE_FIRST_CHECKS_STALL (currently ${FIRST_CHECKS_STALL}s)"
        say_err "   for one that is not. ADMIN_MERGE_FIRST_CHECKS_WAIT (currently ${FIRST_CHECKS_WAIT}s) bounds"
        say_err "   only the states with no progress to observe: no run yet, or an unreadable surface."
      fi
      say_err "   Nothing was compared, no evidence was posted and nothing was merged."
    else
      say_err "   the run report's 'pending' counter is unreadable ('${pr_pending:-}'), so the rail"
      say_err "   cannot show the lane finished (lane: $lane)."
      say_err "   This is NOT a CI verdict and NOT a wait: repair the read (gh auth/--repo), then"
      say_err "   re-run the rail. Nothing was compared, no evidence was posted and nothing merged."
    fi
    exit 1
  fi
  # NOT `completed`: a `cancelled`/`skipped` run is terminal but exercised
  # nothing, so it cannot certify the revision (review P1, cycle 2). A parser too
  # old to emit `tested` therefore BLOCKS — fail closed, never vacuous. The
  # counter is VALIDATED, not trusted: a non-numeric `tested` made `[ -eq ]`
  # error and skip this body, which is a fail-open (VGATE, #1003).
  if ! counter_is_positive "$pr_tested"; then
    say_err "admin-merge: ✗ BLOCK — no run of the lane actually TESTED head $head (lane: $lane)."
    say_err "   completed=${pr_completed:-0} run(s), of which tested=${pr_tested:-0}."
    say_err "   A cancelled or skipped run is finished but exercised nothing, so an"
    say_err "   empty failing set proves nothing about this revision."
    # "The lane ran but exercised nothing" and "this lane does not run on pull
    # requests at all" are different faults with different fixes. On a repo that
    # splits its lanes by trigger the second is the common one, and waiting for
    # CI cannot help — the lane must be changed (#1003).
    # "No runs at all" is completed AND pending BOTH zero — NOT `examined=0`,
    # which is equally true of a run that finished `cancelled`/`skipped`. Those
    # are the "ran but proved nothing" case the lines above already describe.
    #
    # #1413 — ASK THE WORKFLOW, DO NOT GUESS ITS SHAPE. This block used to assert
    # "which is what a MAIN-ONLY lane looks like", and that guess is FALSE for the
    # case that actually bit: agent-infra's default lane `python-ci.yml` is
    # `workflow_call`-ONLY (a REUSABLE workflow — measured 2026-10-04: 0 standalone
    # triggers, most recent run 2026-08-24), so its jobs execute inside its
    # CALLER's run and no run OF IT can ever attach to a PR head. Its remedy,
    # "pick a lane that runs on pull requests", is also a dead end in a
    # trigger-split repo, where NO single lane spans both sides. So the condition
    # is MEASURED with `ci-workflow-pr-evaluable.sh` — the one predicate for "can
    # this workflow attach a check to a PR head sha" — instead of inferred from
    # the absence of runs. An empty body (no such workflow, a display-name
    # selector, or an API failure) stays `unknown` and takes the generic branch,
    # which names the remaining possibilities WITHOUT claiming a cause.
    if counter_is_zero "$pr_completed" && counter_is_zero "$pr_pending"; then
      local lane_slug lane_body lane_verdict
      if [ -n "$REPO" ]; then lane_slug="repos/$REPO"; else lane_slug="repos/{owner}/{repo}"; fi
      # THE REF MATTERS. The contents API defaults to the repository's DEFAULT
      # branch, and a workflow can DIFFER per branch — so reading the default would
      # attribute one revision's `on:` block to another. The question here is about
      # the revision whose checks would attach, so pin `$head`.
      # ⛔ AND `-X GET` IS NOT OPTIONAL: `gh api` switches to POST as soon as ANY
      # `-f`/`-F` parameter is added, and this endpoint is GET/PUT only, so
      # `-f "ref=..."` without it answers `404 Not Found` — which would empty
      # `lane_body` on EVERY call and make the branches below unreachable. All three
      # sibling fetches in this file (1622/1629/2236) pair the two; the suite's fake
      # `gh` enforces the same contract, because a fake that models the ref but not
      # the transport cannot see this class of defect at all.
      lane_body="$($GH api "$lane_slug/contents/.github/workflows/$lane" \
                    -X GET -f "ref=$head" -H 'Accept: application/vnd.github.raw' 2>/dev/null || true)"
      lane_verdict="unknown"
      if [ -n "$lane_body" ]; then
        # ⛔ THE PR-CONTEXT ENV IS SCRUBBED, AND THAT IS LOAD-BEARING. The predicate
        # reads PR_CHANGED_PATHS (and PR_HEAD_BRANCH): with changed paths present it
        # answers `no` for a `pull_request` trigger whose `paths:` filter the changed
        # set does not match — measured, a file declaring `pull_request` + `paths:
        # src/**` returns `no` under PR_CHANGED_PATHS=docs/x.md and `unknown` without
        # it. The rail is asking a question about the FILE, not about one PR, and
        # PR_CHANGED_PATHS is an ambient export here, so an operator's shell could
        # otherwise turn the `no` branch's "declares NO pull_request trigger" into a
        # FALSE claim. Scrubbing it makes `no` mean what the message says: no declared
        # trigger can attach to a PR head, whatever any single PR changed.
        lane_verdict="$(printf '%s' "$lane_body" \
          | env -u PR_CHANGED_PATHS -u PR_HEAD_BRANCH -u CI_WF_PR_EVALUABLE_QUESTION \
              bash "$SELF_DIR/ci-workflow-pr-evaluable.sh" 2>/dev/null || true)"
      fi
      # ⛔ THE DIAGNOSIS IS KEYED ON THE PREDICATE'S VERDICT — NOT ON A GREP OF THE
      # FILE. Three review rounds in a row found that reading the reusable shape out
      # of the body with a bash grep emits a claim that is FALSE for some legal input,
      # and every instance is a real workflow shape:
      #   • `workflow_call:` inside a `run: |` block, an `env:` key or a job id is a
      #     line match but declares no trigger;
      #   • a PR trigger spelled `"pull_request":`, `'pull_request':`,
      #     `!!str pull_request:`, `pull_request :` or `? pull_request` is a real
      #     trigger a line-anchored regex misses.
      # A grep can decide neither, and a wrong diagnosis on a refusing path is the very
      # defect #1413 exists to remove — so the greps are gone. The predicate IS sound
      # here: it parses, and it REFUSES (`unknown`) whenever it cannot attribute every
      # declared trigger, so — with the PR-context env scrubbed at this call site —
      # `no` is a MEASUREMENT ("every declared trigger was read, and none of them can
      # attach to a PR head") rather than a guess. The verdict is therefore the
      # primitive the rail uses, and the reusable guidance is delivered as a
      # CONDITIONAL hint under the two branches that establish no PR trigger, instead
      # of as a separate diagnosis the rail cannot soundly support.
      # Measured with this predicate: `workflow_call` + `inputs` → `unknown`; a bare
      # `workflow_call` → `no`; `workflow_call` + a `paths:`-filtered `pull_request`
      # → `unknown` (the PR-side call site never exports PR_CHANGED_PATHS, so a
      # filtered PR trigger is undecidable there by construction).
      if [ -z "$lane_body" ]; then
        # UNMEASURED, and it says so. Either the fetch returned nothing — a 404 (the
        # selector may be a display NAME, which `--workflow` allows) or an API
        # failure — or the body was only whitespace, which `$( … )` strips to empty.
        # Naming a cause here would assert something unread.
        say_err "   The lane '$lane' has NO run for this head at all, and its workflow"
        say_err "   file came back EMPTY from .github/workflows/$lane (not found, not"
        say_err "   readable, or a blank file) — so whether a run of it can even attach to a"
        say_err "   PR head is UNMEASURED here, not a coverage gap in this PR."
        say_err "   Confirm the lane (--workflow takes a file OR a display name); if this"
        say_err "   repo splits its lanes by trigger, add --any-workflow."
      elif [ "$lane_verdict" = "yes" ]; then
        say_err "   The lane '$lane' has NO run for this head at all, but its workflow DOES"
        say_err "   declare a PR trigger — so either no run of it landed on THIS head (a"
        say_err "   'paths:' filter, or not yet started), or the selector names a different"
        say_err "   lane. Confirm the lane and that CI ran for this head; if this repo splits"
        say_err "   its lanes by trigger, add --any-workflow."
      elif [ "$lane_verdict" = "no" ]; then
        say_err "   The lane '$lane' has NO run for this head at all, and its workflow"
        say_err "   declares NO pull_request / pull_request_target trigger — so no run of it"
        say_err "   can EVER attach to a PR head. A lane whose triggers are all non-PR —"
        say_err "   push-only, schedule-only, workflow_dispatch-only or reusable-only — looks"
        say_err "   like this."
        say_err "   IF this lane is a reusable workflow (its file declares workflow_call), its"
        say_err "   jobs run inside its CALLER's run under the CALLER's name — compare against"
        say_err "   the CALLER's lane."
        say_err "   In a trigger-split repo no single lane spans both sides, so picking"
        say_err "   another lane cannot help: use --any-workflow, which compares against"
        say_err "   every lane that actually ran."
      else
        say_err "   The lane '$lane' has NO run for this head at all. Its workflow file was"
        say_err "   READ, but the PR-evaluability predicate cannot DECIDE whether a run of it"
        say_err "   could ever attach to a PR head — so that question is UNMEASURED here (this"
        say_err "   is NOT a coverage gap in this PR, and no cause is asserted)."
        say_err "   IF this lane is a reusable workflow (its file declares workflow_call), its"
        say_err "   jobs run inside its CALLER's run under the CALLER's name — compare against"
        say_err "   the CALLER's lane."
        say_err "   Confirm the lane (--workflow); if this repo splits its lanes by trigger,"
        say_err "   add --any-workflow."
      fi
    fi
    say_err "   Confirm the lane is the right one (--workflow) and that CI ran for this head."
    say_err "   If this repo splits its lanes by trigger, add --any-workflow BEFORE the -- separator"
    say_err "   and re-run (after '--' only 'gh pr merge' flags belong; a lane selector written there is"
    say_err "    recovered with a warning, and any other parser flag is refused)."
    exit 1
  fi
  # ── 1c. EVERY FAILING RUN MUST BE ATTRIBUTED (cycle-3 review) ────────────
  # `examined` counts the lane's failing runs; `extracted` counts those whose log
  # yielded at least one failure IDENTITY — a `FAILED <nodeid>` line, or (since
  # #4469) an attributable guard-step error annotation FROM THE RUN'S ROOT
  # FAILING STEP. A failing run
  # that contributes NOTHING leaves the residual UNKNOWN while the certificate
  # would print `PR failing: 0` for a lane that is RED — a FALSE certificate, the
  # one severity this rail exists to prevent (the cycle-3 repro: a head run
  # failing with `ImportError: no module named y` certified as zero-residual, and
  # the rail merged). A gate whose output authorises a bypass fails CLOSED here.
  #
  # #4469 WIDENED WHAT IS PARSEABLE, IT DID NOT WEAKEN THE REFUSAL: a guard-step
  # failure becomes an id so it is COMPARED like a test nodeid, while a run
  # carrying neither a nodeid nor a substantive annotation (the runner's generic
  # `Process completed with exit code <N>.` is not one) still trips this block.
  # Three conditions carry that, all in `guard_step_failures`: the annotation must
  # come from a step the RUNNER marked failed; the run's ROOT failing step (keyed
  # by job+step, because matrix legs use the same step NAMES) must itself yield an
  # identity; and a step showing pytest's own `E   <exception>` output must yield a
  # NODEID. So neither a sibling — nor a same-step — annotation can stand in for an
  # unparseable pytest failure (the cycle-3 false certificate, pinned by
  # tests/admin-merge/run.sh section 50(d)). What remains is an unparseable failure
  # that leaves no pytest-shaped line and is not the root: the declared residual,
  # agent-infra #1366.
  #
  # ORDER MATTERS: this sits AFTER the not-finished / not-tested diagnostics. Run
  # first, an absent or unreadable report made THIS the reported reason, masking the
  # real one — and the suite pins those messages (cycle-3, caught by CI).
  #
  # Deliberately NOT applied to the MAIN side: an unattributed run there
  # under-reports the BASELINE, which can only make the residual look larger — a
  # false block, whose designed remedy is the retry path. The false-certificate
  # direction is the PR side.
  local pr_examined pr_extracted
  pr_examined="$(report_value "$TMP/pr-report.txt" examined)"
  pr_extracted="$(report_value "$TMP/pr-report.txt" extracted)"
  if ! counter_is_number "$pr_examined" || ! counter_is_number "$pr_extracted"; then
    say_err "⛔ admin-merge: BLOCKED — the lane run report carries unreadable"
    say_err "   examined/extracted counters (examined='${pr_examined:-}', extracted='${pr_extracted:-}'),"
    say_err "   so the failing set cannot be shown to be complete."
    exit 1
  fi
  if [ "$pr_extracted" -lt "$pr_examined" ]; then
    say_err "⛔ admin-merge: BLOCKED — $((pr_examined - pr_extracted)) of $pr_examined failing PR run(s)"
    say_err "   yielded NO parseable failure identity (none of: a 'FAILED <nodeid>' line, an"
    say_err "   attributable guard-step '::error::' annotation, or the other families the parser"
    say_err "   knows: collect-error::, watchdog-kill::, job-unreadable::, bash-shard::, runner::,"
    say_err "   pipeline-compliance:: ('check-pipeline-compliance.sh' prints '❌ [<letter>] …' — #1185)),"
    say_err "   so their failures are NOT in the set and 'blocked by the decision: 0' would be a false"
    say_err "   certificate (lane: $lane)."
    say_err "   Either the run failed outside the test step (fix it), or the log format moved"
    say_err "   and the parser needs updating. This is a refusal, not a comparison."
    # NAME the dropped tokens here too: when a run's failures were ENTIRELY
    # unattributable this refusal is the one the operator sees, and the reason is
    # exactly the drop (#1353).
    if ! counter_is_zero "$(unattributable_count "$TMP/pr-drops.err")"; then
      say_err "   The parser DROPPED $(unattributable_count "$TMP/pr-drops.err") FAILED token(s) in these runs — not test ids, so NOT in the set:"
      unattributable_tokens "$TMP/pr-drops.err" | sed 's/^/      DROPPED: /' >&2
    fi
    # ── THE REFUSAL MUST NAME ITS SUBJECT (#2610) ─────────────────────────────────
    # A count is not a subject. The base ref is resolved HERE rather than reusing the
    # §2C one, because §2C is downstream of this exit: passing a name-bound reader the
    # base it must ask about is cheaper than moving the §2C probe (which §4.6's
    # staleness anchor is timed against). One `pr view` + one base probe, on a path
    # that ends the run — no cost on any path that proceeds.
    local named_base_ref
    named_base_ref="$(resolve_base_ref "$PR" ${repo_args[@]+"${repo_args[@]}"})"
    # NOT defaulted to `main`: a failed read is not a base, and asserting a red is "on main"
    # about a ref the rail never resolved is a claim about reality it did not measure
    # (#2610 review, P3-4). Empty reaches the reader's UNANSWERED arm.
    named_unattributable_runs "$TMP/pr-unattributed.txt" "$named_base_ref" \
      "$((pr_examined - pr_extracted))" || true
    exit 1
  fi

  # NAME the drops on the ordinary path too: a partial drop does not block (the
  # run DID yield ids), but the set it produced is CLIPPED and must not be read as
  # a complete measurement (#1353).
  report_unattributable "$TMP/pr-drops.err" "the PR's failing set" || true

  info "admin-merge: lane finished for $head (${pr_tested} tested of ${pr_completed} completed run(s))"

  # ── 2. main's baseline: the RATE table and the SIGNATURE table ───────────
  # Both halves of ONE measurement. The rate table alone is not enough: an empty
  # `main_signatures` makes the decision's subset rule fail CLOSED and no failure
  # is ever exempt. Neither side is drawn from the repo being merged.
  local main_status=0
  run_failure_set --main-union-rates "$MAIN_RUNS" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
    --exclude "$head" --provenance "$TMP/main-runs.txt" --runs-report "$TMP/main-report.txt" \
    > "$TMP/main-rates.txt" 2> "$TMP/main-drops.err" || main_status=$?
  [ -s "$TMP/main-drops.err" ] && cat "$TMP/main-drops.err" >&2
  if [ "$main_status" -ne 0 ]; then
    # ── #2569: TWO OPPOSITE STATES, ONE MESSAGE ────────────────────────────────
    # "main is GREEN, so the table is empty" and "main could not be READ" both used
    # to reach an operator as this one line plus `parser exit 1`. They are opposite
    # claims — the first is a real measurement, the second is no measurement at all —
    # and the difference is in data the capture already holds (#2569, measured on
    # the fleet's own refusals 2026-10-23). The REFUSAL is unchanged; what changes is
    # that it now SAYS which case it is in and names the window it measured.
    #
    # `unreadable=` names WHICH read died, so the remedy named is one that can work.
    # On THIS mode the label is `parse:<id>` (see the arm below); an ABSENT report
    # means no read window reached the collector at all — the LISTING failed, or the
    # capture was killed/refused before publishing, or the report could not be
    # written (which `write_runs_report` now says out loud).
    local main_unreadable main_tested_bad main_completed_bad
    main_unreadable="$(report_value "$TMP/main-report.txt" unreadable)"
    main_tested_bad="$(report_value "$TMP/main-report.txt" tested)"
    main_completed_bad="$(report_value "$TMP/main-report.txt" completed)"
    say_err "admin-merge: ✗ BLOCK — could not extract main's rate table (parser exit $main_status)."
    # ⛔ `log:` IS NOT A RATE-PATH LABEL (review, cycle 3). This capture extracts
    # through the COMPOSITE `extract_failed_tests` (fetch → ids → job-level fallback
    # for a pruned log), so its reason is `parse:<id>`: naming a FETCH here would
    # claim a precision the collector does not have — and a dead `log:` arm in a
    # gate is worse than no arm, because a test that drives it proves nothing. The
    # signature block below DOES establish the fetch (it calls `fetch_failed_log`
    # directly), so `log:` lives there and only there.
    case "$main_unreadable" in
      parse:*)
        say_err "   This is a FAILED READ, not an empty baseline: the window WAS listed and"
        say_err "   partially measured — main: completed=${main_completed_bad:-0} run(s), of which"
        say_err "   tested=${main_tested_bad:-0} — and run ${main_unreadable#parse:} was read but"
        say_err "   yielded NO failure identity (its log could not be fetched, or the id parser"
        say_err "   could not read it — a missing/updated parser, or a moved log format)."
        say_err "   Re-running fixes the first; the second needs the parser updated." ;;
      truncated:*)
        # ── #3174: A THIRD STATE, AND ITS OWN REMEDY ───────────────────────────────
        # The window WAS listed and read; its failing runs were KILLED MID-LIST, so the shard
        # runner's recap is INCOMPLETE and the failure set it names is a SAMPLE. This is
        # neither "main is green" nor "the listing could not be read", which is why it has
        # its own arm: the remedy is a WIDER/OLDER window (or waiting for a completed run),
        # NOT a re-run of the parser — the parser read the capture fine and refused it on
        # purpose (scripts/ci-failure-set.sh `collect_union_truncated`).
        say_err "   This is an UNPROVEN baseline, not an empty one and not a failed read: the window"
        say_err "   WAS listed (main: completed=${main_completed_bad:-0} run(s), of which"
        say_err "   tested=${main_tested_bad:-0}) but run ${main_unreadable#truncated:} was killed before"
        say_err "   its shard list finished, so the failures it names are a TRUNCATED SAMPLE."
        say_err "   Folding a partial set into the reference would report a real main failure as new."
        say_err "   Remedy: re-read a window that contains a run whose shard step FINISHED (raise"
        say_err "   --main-runs) — do NOT re-run the parser, which produced this verdict deliberately." ;;
      *)
        say_err "   This is an UNREADABLE window, not an empty baseline: main's run LISTING"
        say_err "   could not be read (or the capture refused before publishing any counters),"
        say_err "   so nothing was measured that could be read. An empty table is authoritative"
        say_err "   only when the read SUCCEEDED — a green main that was read names its measured"
        say_err "   run count instead." ;;
    esac
    say_err "   Refusing to certify a comparison computed over an unreadable baseline."
    exit 1
  fi
  local main_sig_status=0
  # A SEPARATE capture for the signature pass. It re-parses the SAME main runs, so
  # its drops are the same tokens the rate pass already counted — capturing them
  # into the rate file would DOUBLE the count in the evidence. They are re-emitted
  # for visibility and deliberately NOT counted.
  run_failure_set --main-union-signatures "$MAIN_RUNS" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
    --exclude "$head" --runs-report "$TMP/main-sig-report.txt" \
    > "$TMP/main-signatures.txt" 2> "$TMP/main-sig-drops.err" || main_sig_status=$?
  [ -s "$TMP/main-sig-drops.err" ] && cat "$TMP/main-sig-drops.err" >&2
  if [ "$main_sig_status" -ne 0 ]; then
    # #2569: same two-state disclosure as the rate table above, read from this
    # pass's OWN report (the signature capture used to write none at all, so its
    # counters and its reason were discarded on every run).
    local main_sig_unreadable
    main_sig_unreadable="$(report_value "$TMP/main-sig-report.txt" unreadable)"
    say_err "admin-merge: ✗ BLOCK — could not extract main's signature table (parser exit $main_sig_status)."
    case "$main_sig_unreadable" in
      log:*)
        say_err "   A FAILED READ over a window that WAS listed: main's rate table measured"
        say_err "   $(report_value "$TMP/main-report.txt" tested) tested run(s), and the failed-step"
        say_err "   log of run ${main_sig_unreadable#log:} could not be fetched for the signature pass." ;;
      parse:*)
        say_err "   A FAILED READ over a window that WAS listed: main's rate table measured"
        say_err "   $(report_value "$TMP/main-report.txt" tested) tested run(s), and run ${main_sig_unreadable#parse:}"
        say_err "   yielded no failure identity for the signature pass (fetch or parser)." ;;
      truncated:*)
        # #3174: same third state as the rate pass above — the signature table cannot be built
        # from a run whose recap is truncated (scripts/ci_exemption.py refuses both doors).
        say_err "   UNPROVEN, not unreadable: the window WAS listed and its failing run"
        say_err "   ${main_sig_unreadable#truncated:} was KILLED before its shard list finished, so its"
        say_err "   shard recap is incomplete and no signature table can be signed from it (#3174)."
        say_err "   Remedy: re-read a window containing a run whose shard step FINISHED (raise --main-runs)." ;;
      *)
        say_err "   No signature pass ran over a read window: main's run LISTING could not be"
        say_err "   read (or the capture refused before it), so nothing was measured here." ;;
    esac
    say_err "   Without it every signature check fails closed; that is a refusal, not a green."
    exit 1
  fi
  # NAME main's drops: a dropped token under-reports the BASELINE, which can only
  # make a residual look larger (a false block, the re-run path's business) — but
  # it is still a CLIPPED measurement and is named as one (#1353).
  report_unattributable "$TMP/main-drops.err" "main's baseline failing set" || true
  # main's failing UNION — the baseline list the evidence shows — IS the rate
  # table's id column. One measurement, one source, no second pass to disagree.
  cut -f1 "$TMP/main-rates.txt" 2>/dev/null | sort -u > "$TMP/main-fails.txt"

  # ── 2b. is the selected lane a BASELINE at all? ───────────────────────────
  # A rail certificate claims "this PR carries no failure that is not already red
  # on main". That claim IS a comparison, so it needs a baseline. A lane that
  # never ran on main gives an empty baseline, and an empty baseline absorbs
  # nothing: every failure the PR carries reads as new, PRE-EXISTING ones
  # included, and a safe merge is refused for the wrong reason. An over-blocking
  # gate is a broken gate too — but the remedy is a REAL baseline, not a
  # certificate backed by nothing, so this BLOCKS and names the way to one.
  #
  # The signal is `tested`, NOT `examined`, and deliberately the SAME one the
  # head-side check uses: `examined` counts only FAILING runs (a green lane
  # legitimately has examined=0), so it cannot tell a green baseline from a
  # missing one. `tested` counts every run that actually exercised the revision,
  # passing or failing — exactly the question here.
  #
  # This does not ride on the vacuous case below: "green on both sides" is an
  # OUTCOME of a comparison that happened, "never tested main" is a
  # MISCONFIGURATION in which none did, and a reader must tell them apart. Repos
  # that split their lanes by trigger (a pull_request-only lane and a push-only
  # lane — this one does) have no single --workflow spanning both sides, which is
  # what --any-workflow is for (#1003).
  local main_tested main_completed
  # The EMPTY-baseline reason, computed ONCE at step 2b-bis and reused verbatim in the
  # posted evidence's `main side:` line, so stdout and the durable artifact cannot
  # disagree about whether the zero means "green" or "clipped" (#2569 review).
  local main_side_reason=""
  main_tested="$(report_value "$TMP/main-report.txt" tested)"
  main_completed="$(report_value "$TMP/main-report.txt" completed)"
  if ! counter_is_positive "$main_tested"; then
    say_err "admin-merge: ✗ BLOCK — the lane '$lane' never TESTED main, so there is no baseline."
    say_err "   main: completed=${main_completed:-0} run(s), of which tested=${main_tested:-0}."
    say_err "   A rail certificate claims \"this PR carries no failure that is not already red"
    say_err "   on main\". That claim IS a comparison. With nothing on main to compare against,"
    say_err "   every failure this PR carries reads as new — PRE-EXISTING ones included — and a"
    say_err "   safe merge is refused for the wrong reason."
    say_err "   A repo can split its lanes by TRIGGER (a PR-only lane and a main-only lane), and"
    say_err "   then no single --workflow spans both sides. Compare against every lane on main"
    say_err "   instead: add --any-workflow BEFORE the -- separator."
    exit 1
  fi

  # ── 2b-bis. NAME THE MEASUREMENT BEHIND AN EMPTY TABLE (#2569) ─────────────
  # An empty rate table over a POSITIVE `tested` count means the read SUCCEEDED and
  # produced no failing id. That is the OPPOSITE claim from the refusal above, which
  # fires when nothing could be read — and a bare "empty" cannot tell them apart.
  # The capture that produced this table exits 0 (a failed read exits 1), so the
  # states are already separated in CODE; this block separates them in the EVIDENCE,
  # at the point of the read rather than only in the closing summary.
  #
  # ⛔ IT DOES NOT CLAIM GREEN UNCONDITIONALLY (#2569 review). An empty table is also
  # what a CLIPPED baseline looks like: a failing main run that yielded no failure
  # identity (a collection error, a job that died before pytest) is invisible to a
  # FAILURE-ONLY projection, so `examined > extracted` with zero rows is main RED and
  # UNMEASURED — not main green. The main side deliberately does not BLOCK on that
  # (an under-reported baseline can only cause a false block, whose remedy is the
  # re-run), but it must not be reported as a certificate either.
  if [ ! -s "$TMP/main-rates.txt" ]; then
    local main_examined main_extracted
    main_examined="$(report_value "$TMP/main-report.txt" examined)"
    main_extracted="$(report_value "$TMP/main-report.txt" extracted)"
    info "admin-merge: main's baseline is EMPTY BY MEASUREMENT — 0 failing id(s) over ${main_tested} tested run(s) of ${main_completed} completed (lane: $lane)."
    # ONE predicate, and the reason it produces is used BOTH here and in the POSTED
    # EVIDENCE below (`main side:`), because the evidence body is the durable artifact
    # a human and the verifier read: `verify-admin-merge-evidence.sh` names that very
    # line as reading the zero as "EMPTY because the lane is GREEN", and a CLIPPED
    # baseline producing that zero would make the certificate contradict the run
    # (#2569 review, cycle 3). `main_side_reason` is that shared sentence.
    if counter_is_zero "$main_examined"; then
      main_side_reason="EMPTY because the lane is GREEN over that window — NOT because main has no run (a lane that never tested main BLOCKS at step 2b)."
      info "admin-merge:    examined=0, so no run in that window failed: this is a READ that measured no failure, i.e. main is GREEN here — not a failed read."
    elif counter_is_number "$main_examined" && counter_is_number "$main_extracted"; then
      main_side_reason="EMPTY of ATTRIBUTABLE ids, but CLIPPED, not green: ${main_examined} failing run(s) yielded only ${main_extracted} identity(ies), so a main-side failure with NO failure identity is invisible to this comparison."
      info "admin-merge:    BUT examined=${main_examined} with only ${main_extracted} yielding an identity: the baseline is CLIPPED, not green —"
      info "admin-merge:    a main-side failure with NO failure identity is invisible to this comparison (it can only make a residual look larger)."
    else
      main_side_reason="EMPTY, but the window published no examined/extracted counters, so its completeness is UNKNOWN."
      info "admin-merge:    The window's examined/extracted counters were not published, so this table's completeness is UNKNOWN."
    fi
  fi

  # ── 2c. THE PR'S EVALUATED TREE — RESOLVED HERE; THE BASE IS CONTEXT (#1261) ───────────────────
  # Steps 1-2b are LANE-SCOPED: they answer "did this PR introduce a failure in
  # the one workflow I watch?". A red on any OTHER workflow is invisible to that
  # question — and the vacuous branch below then merges, because both failing
  # sets are empty. That is not a wording problem; it is a false PASS at the
  # merge level (#4589's ruff violations, then #4600 on top of them).
  #
  # THREE THINGS HAPPEN HERE, AND NONE OF THEM IS THE GATE:
  #   (1) the base ref is resolved;
  #   (2) the PR's MERGE REF is resolved and its state CHECKED — a CONFLICTED or
  #       ABSENT merge ref is refused HERE, loudly, before the exemption decision
  #       and before any CI mutation: such a PR has no trustworthy evaluated tree
  #       (and GitHub cannot merge it anyway);
  #   (3) MAIN'S HEAD SURFACE is measured and REPORTED — NEVER blocking. While
  #       main is red, the PR that REPAIRS it is green on its own tree, and the
  #       old main-head refusal made the rail unable to land its own recovery.
  #
  # THE GATE IS STEP 4.5, not here. It reads the PR's OWN evaluated-tree surface
  # (the head sha, where GitHub reports the merge-ref evaluation — see the
  # header). It deliberately runs AFTER the lane adjudication and the flake
  # re-run: a red the PR itself introduced is the rail's own business and the
  # re-run may clear it, so the tree must be judged on the REFRESHED surface.
  # Judging it here would make the flake path unreachable for any PR whose lane
  # run is red — i.e. exactly when the rail's comparison matters.
  local base_ref
  base_ref="$(resolve_base_ref "$PR" ${repo_args[@]+"${repo_args[@]}"})"
  [ -n "$base_ref" ] || base_ref="main"

  resolve_merge_ref "$PR"
  case "$MERGE_REF_STATUS" in
    ok)
      info "admin-merge: evaluated tree: ${MERGE_REF_SUMMARY}" ;;
    conflicted)
      say_err "admin-merge: ✗ BLOCK — ${MERGE_REF_SUMMARY}"
      say_err "   A CONFLICTED PR has no simulated merge — GitHub cannot compute one — so there"
      say_err "   is no tree to evaluate and no merge to make. Resolve the conflict and re-run."
      say_err "   This is NOT a CI verdict: nothing about the PR was compared and no evidence"
      say_err "   was posted. GitHub keeps the OLD merge ref around after a PR becomes"
      say_err "   conflicted, which is why its sha is never measured as if it were current."
      exit 1 ;;
    absent)
      say_err "admin-merge: ✗ BLOCK — ${MERGE_REF_SUMMARY}"
      say_err "   This is the MERGE-REF wait (ADMIN_MERGE_MERGE_REF_WAIT), not a CI verdict: no CI"
      say_err "   run has evaluated the merge of this PR into its base, so measuring anything"
      say_err "   else would certify a tree that is not this merge."
      say_err "   Next: re-run the rail once the merge ref exists (usually within seconds); if"
      say_err "   it never appears, the PR may be conflicted or GitHub's mergeability job is"
      say_err "   stuck. No evidence was posted and nothing was merged."
      exit 1 ;;
    unreadable)
      say_err "admin-merge: ✗ BLOCK — ${MERGE_REF_SUMMARY}"
      say_err "   The rail could not tell whether this PR's evaluated tree can be read at all,"
      say_err "   and an unread probe is never a certificate. Check gh auth/network (and"
      say_err "   --repo), then re-run. No evidence was posted."
      exit 1 ;;
    *)
      say_err "admin-merge: ✗ BLOCK — the merge-ref probe returned an unrecognised state"
      say_err "   ('${MERGE_REF_STATUS:-<empty>}'). No evidence was posted."
      exit 1 ;;
  esac

  # MAIN'S HEAD SURFACE — CONTEXT ONLY (#1261). It is measured so the evidence can
  # say whether the base is itself red — which is what makes a repair PR a repair —
  # but it NEVER blocks. It was the BLOCKING source in the previous revision, and
  # that is precisely what refused the PR that repairs a red main.
  local BASE_STATUS BASE_SUMMARY BASE_REDS BASE_REDS_OTHER BASE_TOTAL BASE_RED BASE_RED_OTHER BASE_PENDING BASE_REF BASE_SHA BASE_RED_TS BASE_MAX_COMPLETED BASE_MAX_COMPLETED_EPOCH
  check_surface_probe "$base_ref" "the base branch '$base_ref'" 1
  BASE_STATUS="$MAIN_HEALTH_STATUS"; BASE_SUMMARY="$MAIN_HEALTH_SUMMARY"
  BASE_REDS="$MAIN_HEALTH_REDS"; BASE_REDS_OTHER="$MAIN_HEALTH_REDS_OTHER"
  BASE_TOTAL="$MAIN_HEALTH_TOTAL"; BASE_RED="$MAIN_HEALTH_RED"; BASE_RED_OTHER="$MAIN_HEALTH_RED_OTHER"
  BASE_PENDING="$MAIN_HEALTH_PENDING"; BASE_REF="$MAIN_HEALTH_REF"; BASE_SHA="$MAIN_HEALTH_SHA"
  # The base's BLOCKING reds with their start times, and the base surface's own
  # production time — snapshotted for step 4.6's staleness comparison (#1261).
  BASE_RED_TS="$MAIN_HEALTH_RED_TS"
  BASE_MAX_COMPLETED="$MAIN_HEALTH_MAX_COMPLETED"
  BASE_MAX_COMPLETED_EPOCH="$MAIN_HEALTH_MAX_COMPLETED_EPOCH"
  case "$BASE_STATUS" in
    green)
      info "admin-merge: base tree ('$base_ref') ${BASE_SUMMARY}"
      if [ -n "$BASE_REDS_OTHER" ]; then
        # The base's NON-blocking reds carry the identifying detail (job,
        # workflow, run URL): the summary names only a count, and an exemption
        # that cannot be audited is indistinguishable from a silent drop.
        say_err "admin-merge:    Base red(s) reported but NOT blocking:"
        printf '%s\n' "$BASE_REDS_OTHER" | sed 's/^/      /' >&2
      fi ;;
    unmeasured)
      info "admin-merge: ⚠️  base tree ('$base_ref') ${BASE_SUMMARY}" ;;
    red)
      info "admin-merge: ⚠️  base tree ('$base_ref') ${BASE_SUMMARY}"
      info "admin-merge:    NOT blocking — the base is context. The gate is the PR's OWN tree"
      info "admin-merge:    (step 4.5): a PR that repairs this red must still be able to land."
      printf '%s\n' "$BASE_REDS" | sed 's/^/      /' >&2
      if [ -n "$BASE_REDS_OTHER" ]; then
        say_err "admin-merge:    Base red(s) reported but NOT blocking:"
        printf '%s\n' "$BASE_REDS_OTHER" | sed 's/^/      /' >&2
      fi ;;
    unreadable)
      say_err "admin-merge: ✗ BLOCK — THE BASE BRANCH'S CHECK SURFACE COULD NOT BE READ."
      say_err "   ${BASE_SUMMARY}"
      say_err "   The base is context, not the gate — but 4.6 and 4.7 are BOTH gated on the"
      say_err "   base being RED, so a base the rail could not read is a base whose red would"
      say_err "   silently disarm them, and the stale green this rail exists to stop would merge"
      say_err "   (#1261). A surface that was never read is never a certificate: this rail merges"
      say_err "   with --admin. Check gh auth/network (and --repo), then re-run. No evidence was"
      say_err "   posted."
      exit 1 ;;
    partial)
      say_err "admin-merge: ✗ BLOCK — THE BASE BRANCH'S CHECK SURFACE WAS ONLY HALF READ."
      say_err "   ${BASE_SUMMARY}"
      if [ -n "$BASE_REDS" ]; then
        say_err "   The half that WAS read already carries this code-measuring red:"
        printf '%s\n' "$BASE_REDS" | sed 's/^/      /' >&2
      fi
      if [ -n "$BASE_REDS_OTHER" ]; then
        say_err "   Reported but NOT blocking (not counted against the PR):"
        printf '%s\n' "$BASE_REDS_OTHER" | sed 's/^/      /' >&2
      fi
      say_err "   Consuming the readable endpoint is not enough on its own: the endpoint that"
      say_err "   failed could carry a red this PR has not measured, and 4.6/4.7 are BOTH gated"
      say_err "   on the base being RED — so a half-read base is exactly the disarm this refusal"
      say_err "   closes (#1261). No evidence was posted and no merge attempted."
      say_err "   Check gh auth/network (and --repo), then re-run."
      exit 1 ;;
    *)
      say_err "admin-merge: ✗ BLOCK — the base-surface probe returned an unrecognised state"
      say_err "   ('${BASE_STATUS:-<empty>}'). No evidence was posted."
      exit 1 ;;
  esac

  # ── 3. THE EXEMPTION DECISION (one implementation, two consumers) ────────
  # No `comm -23`: membership in main's sample is not evidence that a failure
  # pre-exists, and the more main flakes the less the subtraction checks. The
  # decision's own exit cannot distinguish a GATED verdict from a crash, so
  # `run_exemption_decision` returns 0 for a VERDICT and 1 for a broken gate —
  # and a broken gate BLOCKS.
  local dec_rc=0
  run_exemption_decision "$TMP/pr-rows.txt" "$TMP/main-rates.txt" "$TMP/main-signatures.txt" \
    "$TMP/pr-per-run.txt" "$TMP/unique" || dec_rc=$?
  if [ "$dec_rc" -ne 0 ]; then
    say_err "admin-merge: ✗ BLOCK — the exemption decision could not run. No merge."
    exit 1
  fi
  residual_of "$TMP/unique" "$TMP/unique.txt"
  local unique_before
  unique_before="$(count_lines "$TMP/unique.txt")"

  # ── 3b. THE MISSING MEASUREMENT (#3715) ──────────────────────────────────
  # The decision has refused this residual because main's lane carries no
  # measurement of it (or too thin a one). Absence is NOT evidence of novelty:
  # main may never have run the test in the evaluated shape at all. Before the
  # rail attributes them to this PR, it CONSTRUCTS the missing measurement by
  # running the residual nodeids on a pristine worktree of the BASE. A failure
  # the base itself reproduces is pre-existing by construction and is cleared
  # from the residual; anything the base does NOT reproduce stays refused. See
  # `reproduce_residual_on_base` for why this is the baseline's construction and
  # not a waiver. A reproduction that cannot run clears NOTHING (fail closed).
  #
  # `--dry-run` MUTATES NOTHING, so it must not run the base suite either: the
  # reproduction materialises a worktree and executes tests, and a documented
  # no-op that runs a suite is the same defect the CI-re-run guard below closes.
  local repro_line="Reproduction on base: not attempted (the decision blocked nothing)"
  local repro_base="${BASE_SHA:-$base_ref}"
  local repro_n=0
  if [ "$unique_before" -gt 0 ] && [ "${DRY_RUN:-0}" -eq 0 ]; then
    # THE CANDIDATES ARE ONLY THE MEASUREMENT GAP (#3715 review, P1). The
    # residual is BLOCKED ∪ UNATTRIBUTABLE, and BLOCKED is not one class: the
    # decision also blocks a MEASURED verdict — a rate regression (#3756:
    # main 1/8 vs PR 8/8), a signature mismatch, or a sample below min_runs. A
    # single ambient run on the base must never override a MEASURED verdict; the
    # missing measurement this constructs is exactly the case where main's rate
    # table carries NO row for the id. `main-fails.txt` IS that table's id column
    # (step 2). An id WITH a row stays refused no matter what the base does.
    local cand="$TMP/repro-candidates.txt"
    if ! repro_scope "$TMP/unique.txt" "$TMP/unique.unattributable" \
         "$TMP/repro-scope.txt" "$TMP/repro-nonattr.txt" "$TMP/main-fails.txt" \
       || ! repro_candidates "$TMP/repro-scope.txt" "$TMP/main-fails.txt" "$cand" \
         "$TMP/repro-idlevel.txt" "$TMP/main-files.txt"; then
      repro_line="Reproduction on base: attempted on base $repro_base; the candidate set could not be computed through the shared parser — the refusal stands (fail closed)"
    elif [ ! -s "$cand" ]; then
      # THREE ways the candidate set is empty, and they are DIFFERENT claims:
      # nothing is left after the UNATTRIBUTABLE/guard-step exclusion, or every id
      # carries a main-side measurement, or every id's FILE is measured on main
      # (MEASURED-ABSENT). Naming the wrong one would be a false report.
      if [ ! -s "$TMP/repro-scope.txt" ]; then
        repro_line="Reproduction on base: attempted on base $repro_base; every refused failure is UNATTRIBUTABLE (a moving identity) or a guard-step — a reproduction can never clear these — or names no test a local run could execute (a collection error, a watchdog kill, an unreadable job). A guard-step is NOT in this class only when it is not UNATTRIBUTABLE (that arm wins first) AND main's baseline was READ, is non-empty, and holds no row for its step (#1185) — then it reaches the candidate set and is reported there; an EMPTY or unreadable baseline keeps it in THIS class, because a failure-only baseline cannot tell 'main is green' from 'main has no run' (#7734). The refusal stands"
      elif [ ! -s "$TMP/repro-idlevel.txt" ]; then
        repro_line="Reproduction on base: attempted on base $repro_base; every failure a reproduction could speak to carries a main-side measurement, so there is no missing measurement to construct — the refusal stands"
      else
        repro_line="Reproduction on base: attempted on base $repro_base; every failure a reproduction could speak to sits in a FILE main's baseline measured (MEASURED-ABSENT), which is evidence of novelty — the refusal stands"
      fi
    elif ! grep -Eqv "$NON_LOCAL_REPRO_ID_RE" "$cand" 2>/dev/null; then
      # #1185: THE CANDIDATE SET NAMES NO ID A LOCAL RUN COULD EXECUTE. The scope
      # admitted such an id because `main_measured_files` carries no row for its
      # unit, and no local runner can execute it — so NOTHING WAS ATTEMPTED, and
      # the honest report is the fact that made it unmeasurable rather than "the
      # reproduction could not RUN" (it never ran because it was never runnable).
      # The message names NO family on purpose: the admission is `repro_scope`'s
      # case arms, the report's classifier is `NON_LOCAL_REPRO_ID_RE`, and a
      # family added to one and not the other must not produce a message that
      # asserts WHICH family the operator is looking at.
      # NOTHING IS CLEARED: the failure is on this head, and the refusal stands
      # exactly as before.
      repro_line="Reproduction on base: NOT attempted on base $repro_base — no candidate names an id a LOCAL run could execute, and the base's failure baseline holds no row for their units, so neither a local reproduction nor main's rate table can speak to them. The refusal stands"
    elif ! is_full_sha "$repro_base"; then
      # A REF NAME is not a pinned base. `check_surface_probe` falls back to the
      # REF when the commits API cannot resolve a SHA, and `git worktree add main`
      # would then resolve the LOCAL ref — a stale, redder main would clear
      # failures that are not pre-existing on the real base.
      repro_line="Reproduction on base: attempted on base '$repro_base'; the base is not a pinned commit OID, so nothing was reproduced — the refusal stands (fail closed)"
    elif reproduce_residual_on_base "$cand" "$TMP/reproduced.txt" "$repro_base"; then
      # The subtractions are the SHARED comparison (`ci-failure-set.sh --diff`,
      # the one `comm -23` in the rail) — a second implementation here is exactly
      # the drift the parity invariant exists to stop. A `--diff` that cannot run
      # clears NOTHING and the refusal stands (fail closed).
      cp "$TMP/unique.txt" "$TMP/unique.before"
      if run_failure_set --diff "$TMP/unique.txt" "$TMP/reproduced.txt" > "$TMP/unique.filtered" 2>/dev/null; then
        # THE CLEARED SET IS THE ACTUAL DIFFERENCE — the ids that left the
        # residual — never the base's whole failing set (which may include ids
        # that were never refused). Printed and counted from this one source.
        run_failure_set --diff "$TMP/unique.before" "$TMP/unique.filtered" > "$TMP/repro-cleared.txt" 2>/dev/null \
          || : > "$TMP/repro-cleared.txt"
        repro_n="$(count_lines "$TMP/repro-cleared.txt")"
        if [ "$repro_n" -gt 0 ]; then
          mv "$TMP/unique.filtered" "$TMP/unique.txt"
          unique_before="$(count_lines "$TMP/unique.txt")"
          repro_line="Reproduction on base: $repro_n of the refused failure(s) REPRODUCE on base $repro_base in this AMBIENT lane shape — cleared as pre-existing there. NOTE: a failure-only baseline cannot separate 'main ran this shape and passed' from 'main never ran it', so this is a measurement of the base in THIS shape, not proof that the PR is innocent"
          info "admin-merge: ↩︎ $repro_n refused failure(s) reproduce on the BASE $repro_base in this AMBIENT shape — cleared (a measurement of the base here, not proof the PR is innocent)"
          sed 's/^/   pre-existing: /' "$TMP/repro-cleared.txt" >&2
        else
          repro_line="Reproduction on base: attempted on base $repro_base; NO refused failure reproduced there — the refusal stands"
        fi
      else
        repro_line="Reproduction on base: attempted on base $repro_base; the reproduction could not be compared through the shared parser — the refusal stands (fail closed)"
      fi
    else
      repro_line="Reproduction on base: attempted on base $repro_base; the reproduction could not RUN — the refusal stands (fail closed)"
    fi
  fi

  local flake_line="Flake classification: none needed (nothing blocked before the re-run)"
  local rerun_residual=0

  # THE RE-RUN IS FORCED WHENEVER THE BASE CLEARED ANYTHING (#3715 review, P1).
  # The re-run is the ONLY mechanism that collects the SECOND sample the E5
  # rotation rule needs (`detect_rotating_identity` needs >= 2 samples), and a
  # reproduction that clears the WHOLE residual would otherwise skip it — letting
  # a single-sample MOVING identity be cleared by the base, which is the
  # exempt-and-silent direction on the one class that may never merge. The second
  # sample is taken BEFORE the merge decision, so a rotation that appears on retry
  # still blocks.
  if [ "$unique_before" -gt 0 ] || [ "${repro_n:-0}" -gt 0 ]; then
    if [ "$unique_before" -gt 0 ]; then
      info "admin-merge: $unique_before failure(s) are blocked by the decision — re-run classification:"
      sed 's/^/   /' "$TMP/unique.txt"
    else
      info "admin-merge: the base reproduction cleared $repro_n failure(s); re-running to collect a SECOND"
      info "admin-merge:   sample (the E5 rotation rule needs two) before deciding to merge:"
    fi
    if [ "$NO_RERUN" -eq 1 ]; then
      if [ "$unique_before" -gt 0 ]; then
        say_err "admin-merge: ✗ BLOCK — failures are blocked by the decision and --no-rerun given. No merge."
      else
        say_err "admin-merge: ✗ BLOCK — the base reproduction cleared the residual, but --no-rerun denies"
        say_err "   the E5 second sample the re-run would take. No merge."
      fi
      say_err "   $repro_line"
      # §33 (#1147): the REASON, not just the node id — the SAME lines the
      # post-rerun refusal prints below. This path used to drop them, so an
      # operator who blocked with `--no-rerun` got only the FILE-level diagnosis
      # below and never the decision's own per-id reason. That gap is what made a
      # `pipeline-compliance` check (#1185) read as "main carries no failure in
      # pipeline-compliance::c" instead of "blocked by check (c): <subject>" — and
      # for a GATE failure this is the path a lane should take, because a re-run
      # cannot mint the artifact the check is asking for.
      grep -v '^EXEMPT' "$TMP/unique.lines" 2>/dev/null | sed 's/^/   /' >&2 || true
      # §37 (main): WHY each residual could not be attributed to this PR — the
      # FILE-level diagnosis. Complementary to the decision's id-level reason
      # lines below, not a replacement: the decision says WHAT it decided and on
      # what evidence; this says why the residual's file was not attributable.
      # BOTH block; no label here clears a failure.
      attribute_residual "$TMP/unique.txt" "$TMP/main-fails.txt" >&2
      exit 1
    fi
    # `--dry-run` MUTATES NOTHING — including CI. Re-running failed jobs before
    # the DRY_RUN branch would make a documented no-op re-run a caller's CI
    # (review P2, cycle 2). Report the decision instead of performing it.
    if [ "$DRY_RUN" -eq 1 ]; then
      info "admin-merge: (dry-run) a real run would CONSTRUCT the missing main-side measurement (run"
      info "admin-merge: (dry-run)   the residual on a pristine base worktree, #3715) before this point."
      info "admin-merge: (dry-run) a real run would re-run the failing job(s) of this head once and re-classify them."
      info "admin-merge: (dry-run) --dry-run performs no base run, no CI re-run, posts no comment and merges nothing."
      info "admin-merge: (dry-run) decision: BLOCK unless the residual clears on the base or on retry. No merge."
      exit 0
    fi
    # Re-run every failing run of the PR head ONCE. A test that passes on retry
    # is order/timing flaky, not new — the #3469 shape (a sibling pair that
    # trips alternately on main) must not hard-block a safe merge.
    local run_line run_id wait_rc attempt_before
    while IFS= read -r run_line; do
      [ -n "$run_line" ] || continue
      run_id="${run_line##*:}"
      # DERIVE BEFORE THE RE-RUN. At this point the run is terminal (`pr-runs.txt`
      # carries failing runs), so EVERY shard has a completed sample and the run
      # bound is the slow shard's own 2 x max. Deriving AFTER the re-run would
      # see the just-re-started shard as unfinished with no sample of its own —
      # exactly the shard whose bound matters — and substitute a floor/fail-safe
      # for the one measurement that was available a moment earlier.
      if [ "$RERUN_TIMEOUT_EXPLICIT" -eq 0 ]; then
        derive_rerun_timeout "$run_id"
        RERUN_TIMEOUT="$DERIVED_RERUN_TIMEOUT"
        RERUN_TIMEOUT_SOURCE="$DERIVED_RERUN_SOURCE"
      fi
      # THE RE-RUN'S OBSERVABLE IDENTITY. GitHub increments `attempt` on every
      # re-run, so the pre-request value is what lets the wait prove the re-run
      # STARTED instead of accepting the old `completed` on its first poll. An
      # unreadable attempt degrades to the status-only contract (fail-closed:
      # the run still has to finish).
      attempt_before=""
      # shellcheck disable=SC2086
      attempt_before="$($GH run view "$run_id" ${repo_args[@]+"${repo_args[@]}"} \
        --json attempt --jq '.attempt // ""' 2>/dev/null || true)"
      info "admin-merge: ↻ RE-RUN wait: re-running failed jobs of run $run_id (attempt before: ${attempt_before:-unreadable})"
      # shellcheck disable=SC2086
      if ! $GH run rerun "$run_id" --failed ${repo_args[@]+"${repo_args[@]}"} >/dev/null 2>&1; then
        say_err "admin-merge: ✗ BLOCK — could not re-run $run_id (gh error). No merge."
        exit 1
      fi
      wait_for_run "$run_id" "$attempt_before"; wait_rc=$?
      if [ "$wait_rc" -ne 0 ]; then
        # What it last observed — each job's status/conclusion and its age.
        describe_run_observation "$run_id"
      fi
      if [ "$wait_rc" -eq 4 ]; then
        say_err "admin-merge: ✗ BLOCK — RE-RUN wait could not OBSERVE the re-run of run $run_id: after ${RERUN_WAIT_WAITED}s (bound ${RERUN_TIMEOUT}s — ${RERUN_TIMEOUT_SOURCE}) the run still reported ${RERUN_WAIT_LAST}. gh accepted the re-run request but the run attempt never advanced, so the OLD result is NOT a re-run result and can neither certify nor clear this PR. Next: re-run the rail (or trigger the workflow) and watch the attempt advance. No merge."
        exit 1
      fi
      if [ "$wait_rc" -eq 1 ]; then
        say_err "admin-merge: ✗ BLOCK — RE-RUN wait: run $run_id STALLED: still non-completed at its DERIVED per-shard bound — ${RERUN_TIMEOUT_SOURCE}; waited ${RERUN_WAIT_WAITED}s, last observed ${RERUN_WAIT_LAST}. A REMOTE run exposes no within-job activity signal (updatedAt advances only on job/step transitions, so one long step freezes it for the whole job), so exceeding the run's own green-derived bound is the only honest wedge signal: this run is either wedged or pathologically slower than its entire green population. No merge."
        exit 1
      fi
      if [ "$wait_rc" -eq 3 ]; then
        say_err "admin-merge: ✗ BLOCK — RE-RUN wait: run $run_id UNOBSERVABLE: gh could not be read for the whole bound (${RERUN_TIMEOUT}s); waited ${RERUN_WAIT_WAITED}s. This is NOT a stall — a stall is a claim about a run we watched, and this rail never saw the field. Remedy differs: check gh auth/network, then re-run. No merge."
        exit 1
      fi
      if [ "$wait_rc" -ne 0 ]; then
        say_err "admin-merge: ✗ BLOCK — RE-RUN wait: run $run_id still RUNNING at the ${RERUN_TIMEOUT}s ceiling — ${RERUN_TIMEOUT_SOURCE}; waited ${RERUN_WAIT_WAITED}s, last observed ${RERUN_WAIT_LAST}. Not a stall — this is an operator cap that was reached, not a claim that the run is wedged. No merge."
        exit 1
      fi
    done < "$TMP/pr-runs.txt"

    # The branch must not have moved during the re-run — evidence is bound to a
    # SHA, and a push invalidates it.
    local head_after
    # shellcheck disable=SC2086
    head_after="$(require_head "$PR" ${repo_args[@]+"${repo_args[@]}"})" || exit 1
    if [ "$head_after" != "$head" ]; then
      say_err "admin-merge: ✗ BLOCK — head moved during re-run ($head → $head_after). Re-run the rail."
      exit 1
    fi

    local pr_status2=0
    run_failure_set --commit-rows "$head" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
      --runs-report "$TMP/pr-report2.txt" --per-run "$TMP/pr-per-run2.txt" \
      > "$TMP/pr-rows2.txt" 2> "$TMP/pr-drops2.err" || pr_status2=$?
    [ -s "$TMP/pr-drops2.err" ] && cat "$TMP/pr-drops2.err" >&2
    report_unattributable "$TMP/pr-drops2.err" "the PR's failing set (post-rerun collection)" || true
    [ "$pr_status2" -eq 0 ] || { say_err "admin-merge: ✗ BLOCK — PR failing set unreadable after re-run"; exit 1; }
    cut -f1 "$TMP/pr-rows2.txt" 2>/dev/null | sort -u > "$TMP/pr-fails2.txt"
    # THE SECOND DOOR (#3756): the post-rerun verdict is the DECISION again, not a
    # second subtraction. A swap touching only the first would leave this verdict
    # presence-based, so a failure excused on the first pass would be excused
    # identically here.
    #
    # E5, DOOR 3 — the identity that MOVED. B7 measured it on #3749: the SAME
    # head's SAME run id (35221282837) yielded DIFFERENT failure ids when sampled
    # before and after the re-run. A single per-collection sample cannot see that,
    # so the rotation observation is the UNION of every sample of THIS head — the
    # head is provably unmoved (`head_after == head` above), so the samples are
    # two observations of one revision, not a baseline drawn from a second tree.
    # Without this the moved id is read as "unique to this PR" (a wrong reason,
    # and a permanent one), or — when main also measures the new id — as EXEMPT
    # AND SILENT, which is the fail-open direction B7's two cycles produced.
    # With it the class is red across runs with a MOVING id, which
    # `detect_rotating_identity` classifies UNATTRIBUTABLE: never PR-unique,
    # never exempt, and therefore never a merge.
    cat "$TMP/pr-per-run.txt" "$TMP/pr-per-run2.txt" > "$TMP/pr-rotation.txt"
    local dec2_rc=0
    run_exemption_decision "$TMP/pr-rows2.txt" "$TMP/main-rates.txt" "$TMP/main-signatures.txt" \
      "$TMP/pr-rotation.txt" "$TMP/unique2" || dec2_rc=$?
    if [ "$dec2_rc" -ne 0 ]; then
      say_err "admin-merge: ✗ BLOCK — the exemption decision could not run after the re-run. No merge."
      exit 1
    fi
    residual_of "$TMP/unique2" "$TMP/unique2.txt"
    # The base reproduction applies to the POST-rerun residual too (and only
    # ever REMOVES ids the base itself reported FAILED): a failure cleared
    # before the re-run must not reappear as "survived the re-run". SAME shared
    # comparison as 3b — a failing `--diff` clears NOTHING (fail closed).
    if [ -s "$TMP/reproduced.txt" ] \
       && run_failure_set --diff "$TMP/unique2.txt" "$TMP/reproduced.txt" > "$TMP/unique2.filtered" 2>/dev/null; then
      mv "$TMP/unique2.filtered" "$TMP/unique2.txt"
      # PRESENTATION ONLY: the decision's reason lines for the ids that remain.
      # A cleared id's reason line must not be printed under a refusal it is no
      # longer part of. `reproduced.txt` is sorted-unique; a cleared BLOCK line
      # is `<prefix><nodeid>  <reason>` (ci_exemption.py's render), so the nodeid
      # is field 1 after the `BLOCK : ` prefix and the two-space reason gap.
      awk 'NR==FNR { rep[$0]=1; next }
           { key=$0; sub(/^BLOCK[[:space:]]*:[[:space:]]*/, "", key); sub(/  .*/, "", key);
             if (!(key in rep)) print }' \
        "$TMP/reproduced.txt" "$TMP/unique2.lines" > "$TMP/unique2.lines.filtered" 2>/dev/null \
        && mv "$TMP/unique2.lines.filtered" "$TMP/unique2.lines"
    fi
    rerun_residual="$(count_lines "$TMP/unique2.txt")"

    if [ "$rerun_residual" -gt 0 ]; then
      say_err "admin-merge: ✗ BLOCK — $rerun_residual failure(s) SURVIVED the re-run:"
      # THE REPRODUCTION'S OUTCOME IS REPORTED ON EVERY REFUSAL (#3715 review):
      # an operator must be able to tell "the base did not reproduce it" from
      # "the reproduction could not run" / "could not be compared" — the
      # refusal is the same either way, but the reason is not.
      say_err "   $repro_line"
      # §33 (#1147): the REASON, not just the node id. An UNATTRIBUTABLE id (a rotating identity,
      # or one ABSENT from main's failure set) is created with `blocked=True`, so its
      # verdict line is a `BLOCK` line whose reason names the class — and a refusal
      # that printed ONLY the node id would read as an ordinary "unique to this PR",
      # leaving the E5 class unreported. Never exempt-and-SILENT applies to the
      # refusal too.
      grep -v '^EXEMPT' "$TMP/unique2.lines" 2>/dev/null | sed 's/^/   /' >&2 \
        || sed 's/^/   /' "$TMP/unique2.txt" >&2
      # §37 (main): the FILE-level attribution. Complementary to the id-level
      # reason lines above — BOTH are printed, BOTH block. Printing only one of
      # them leaves either the E5 class or the file-level refusal unexplained.
      attribute_residual "$TMP/unique2.txt" "$TMP/main-fails.txt" >&2
      say_err "   The attribution above separates MEASURED-ABSENT (main's lane demonstrably"
      say_err "   measures this file and does not show this test red) from ABSENT FROM MAIN'S"
      say_err "   FAILURE SET (main carries no failure in it). The baseline is FAILURE-ONLY,"
      say_err "   so absence is NOT evidence of novelty — and NOT evidence main never ran"
      say_err "   the file, either (#7734). BOTH block; no label here clears a failure."
      say_err "   The exemption decision still refuses them — merge refused."
      exit 1
    fi
    cp "$TMP/pr-fails2.txt" "$TMP/pr-fails.txt"
    if [ "$unique_before" -gt 0 ]; then
      flake_line="Flake classification: $unique_before residual re-ran → all passed on retry (flaky, not new)"
      info "admin-merge: ✅ all $unique_before residual failure(s) passed on retry — flaky, not new"
    else
      # The residual was cleared by the BASE, not by a flake: the retry was taken
      # only for the E5 second sample, and nothing survived it.
      flake_line="Flake classification: the base reproduction cleared $repro_n failure(s); the re-run's second sample survived none (no E5 rotation observed)"
      info "admin-merge: ✅ the re-run's second sample survived nothing — merging on the reproduced-on-base clearance"
    fi
  fi

  # ── 4. THE HEAD IS RE-RESOLVED IMMEDIATELY BEFORE THE EVIDENCE (review P1) ─
  # This check used to live only inside the flake branch, so the common clean
  # path resolved the head once, posted evidence for that SHA, and then merged
  # whatever the head was by then. A rebase/update-branch in that window merged
  # an unanalyzed head behind SHA-bound evidence. Now it runs unconditionally —
  # and GitHub is asked to enforce it too, via --match-head-commit below.
  local head_final
  # shellcheck disable=SC2086
  head_final="$(require_head "$PR" ${repo_args[@]+"${repo_args[@]}"})" || exit 1
  if [ "$head_final" != "$head" ]; then
    say_err "admin-merge: ✗ BLOCK — head moved before the evidence was posted ($head → $head_final)."
    say_err "   The evidence would be bound to $head; re-run the rail for the new head."
    exit 1
  fi

  # ── 4.5. THE GATE: IS THE PR'S OWN EVALUATED TREE GREEN? (#1261) ─────────
  # THE ONLY TREE-SCOPED REFUSAL IN THE RAIL, and the fix for #1261. Steps 1-3
  # compare ONE lane; the base surface at step 2c is context. This asks the
  # question the merge actually needs answered: CI evaluated the MERGE of this
  # head into its base (the `pull_request` merge ref — see the header), and
  # GitHub reports the resulting checks against the HEAD commit, so the
  # head-keyed surface IS the evaluated tree's surface. A code-measuring red
  # there means the tree this merge lands is red.
  #
  # THE DISCRIMINATION THAT MATTERS. A PR that REPAIRS a red base has the red
  # GONE from its own tree -> this passes and the merge lands. A PR opened onto
  # an already-red base that does NOT fix it keeps the red on its own tree ->
  # this refuses, naming the job, its workflow and its run URL. That is exactly
  # #4600-on-#4589, and it no longer depends on the base still being red at read
  # time — it depends on what CI measured for THIS tree.
  #
  # WHY HERE, AND NOT IN STEP 2C. A red the PR itself introduced is what the
  # lane comparison and the flake re-run above exist to adjudicate; a flaky red
  # clears when its run is re-run (the LATEST check run per (app,name) wins —
  # the superseded-run rule). Judging the tree before that would refuse every PR
  # whose watched lane is red — i.e. make the flake path dead code — and
  # over-block on exactly the red the rail is built to re-test. The head is
  # re-resolved immediately above, so this measures the SAME sha the evidence
  # will be bound to.
  #
  # PROCEEDS on UNMEASURED (a surface with no checks certifies nothing, but is
  # not a refusal — same rule as before) and REFUSES on UNREADABLE (failing to
  # look is never a green).
  local TREE_STATUS TREE_SUMMARY TREE_REDS TREE_REDS_OTHER TREE_TOTAL TREE_RED TREE_RED_OTHER TREE_PENDING TREE_PENDINGS TREE_REF TREE_SHA TREE_MAX_COMPLETED TREE_MAX_COMPLETED_EPOCH
  check_surface_probe "$head" "the PR's evaluated tree (head $head)" 0
  TREE_STATUS="$MAIN_HEALTH_STATUS"; TREE_SUMMARY="$MAIN_HEALTH_SUMMARY"
  TREE_REDS="$MAIN_HEALTH_REDS"; TREE_REDS_OTHER="$MAIN_HEALTH_REDS_OTHER"
  TREE_PENDING="$MAIN_HEALTH_PENDING"; TREE_PENDINGS="$MAIN_HEALTH_PENDINGS"
  TREE_TOTAL="$MAIN_HEALTH_TOTAL"; TREE_RED="$MAIN_HEALTH_RED"; TREE_RED_OTHER="$MAIN_HEALTH_RED_OTHER"
  TREE_REF="$MAIN_HEALTH_REF"; TREE_SHA="$MAIN_HEALTH_SHA"
  # The PR surface's own production time — the anchor step 4.6 compares a base
  # red against. Empty means the surface has produced no completed check at all.
  TREE_MAX_COMPLETED="$MAIN_HEALTH_MAX_COMPLETED"
  TREE_MAX_COMPLETED_EPOCH="$MAIN_HEALTH_MAX_COMPLETED_EPOCH"
  case "$TREE_STATUS" in
    green)
      # ⛔ AN IN-FLIGHT CHECK ON THE PR'S TREE IS **NOT** A RED, AND THIS ARM DOES
      # NOT REDDEN ONE — RESTORED DELIBERATELY (PR #3205 review, blocking).
      #
      # A first cut of #10399 also refused here whenever `TREE_PENDING > 0`, on the
      # argument that an unresolved check certifies nothing. That argument is sound
      # IN THE ABSTRACT and it REVERSES A RECORDED DECISION: this repo already
      # settled the question, and the settlement is TESTED in four arms of
      # tests/admin-merge/run.sh — "A CHECK STILL RUNNING IS NOT A RED — on the PR's
      # tree either. Main always has something in flight; a busy PR tree does too."
      # Measured: that cut reddened `bash-suites (1)` with 14 of 1841 assertions
      # failing, four of them the arms that pin exactly this behaviour.
      #
      # The reversal also had a practical cost the abstract argument missed: on a
      # saturated runner pool, "some check on head just started" is the NORMAL case,
      # so a head-wide pending refusal makes the rail unlandable until every advisory
      # workflow on the head concludes — a false block on a healthy tree.
      #
      # ⛔ SO WHERE IS THE #10399 DEFECT ACTUALLY CLOSED? In the FIRST-CHECKS wait,
      # which is where the hang was measured (900s and 330s, no decision): there the
      # rail is waiting ON those unresolved checks, `check-unresolved` bounds that
      # wait at CHECK_UNRESOLVED_BOUND and REFUSES BY NAME. A surface nobody is
      # waiting on is not waiting to be certified either — the merge gate is the
      # lane/§1b pending precondition, which has no green path.
      # The pending NAMES are still accumulated and still reported in the summary, so
      # "which check has no conclusion" is legible without reddening a busy tree.
      info "admin-merge: ✅ evaluated tree ${TREE_SUMMARY}"
      if [ -n "${TREE_PENDINGS:-}" ]; then
        info "admin-merge:    in flight on this tree (reported, NOT blocking — a check still running is not a red):"
        printf '%s\n' "$TREE_PENDINGS"
      fi ;;
    unmeasured)
      info "admin-merge: ⚠️  evaluated tree ${TREE_SUMMARY}" ;;
    red)
      say_err "admin-merge: ✗ BLOCK — THE TREE THIS PR PRODUCES IS RED."
      say_err "   $TREE_SUMMARY"
      say_err "   CI evaluates a PR as the MERGE of its head into its base — the tree the base"
      say_err "   becomes if this PR lands — and GitHub reports those checks against the PR's"
      say_err "   head commit. A CODE-MEASURING check failing there fails the tree this merge"
      say_err "   lands, whatever the watched lane '$lane' says."
      say_err "   Failing checks (every workflow and app, not only the watched lane):"
      printf '%s\n' "$TREE_REDS" >&2
      if [ -n "$TREE_REDS_OTHER" ]; then
        say_err "   (Also red on NON-code events — reported, not blocking here; a PR surface"
        say_err "    is not expected to carry one, so this is an anomaly:)"
        printf '%s\n' "$TREE_REDS_OTHER" >&2
      fi
      say_err "   BASE CONTEXT: $BASE_SUMMARY"
      say_err "   If the base is red and THIS PR is the repair, the red should already be GONE"
      say_err "   from this tree — a red still here means the repair is incomplete. If this PR is"
      say_err "   NOT the repair, fix the failing check (here or on the base) and re-run. Landing"
      say_err "   a red tree on purpose is the audited enforcer override:"
      say_err "   AGENT_ADMIN_MERGE_OVERRIDE=1. No evidence was posted and no merge attempted."
      exit 1 ;;
    partial)
      say_err "admin-merge: ✗ BLOCK — the PR's evaluated-tree surface was only HALF read, so the"
      say_err "   rail cannot show the tree this merge produces is green."
      say_err "   $TREE_SUMMARY"
      if [ -n "$TREE_REDS" ]; then
        say_err "   The half that WAS read already carries this red:"
        printf '%s\n' "$TREE_REDS" >&2
      fi
      say_err "   One probe FAILED and the other is no certificate for it: the endpoint that"
      say_err "   could not be read may carry a red this merge would land. This rail merges with"
      say_err "   --admin, so an incomplete read is not a green. Check gh auth/network (and"
      say_err "   --repo), then re-run. No evidence was posted."
      exit 1 ;;
    unreadable)
      say_err "admin-merge: ✗ BLOCK — the PR's evaluated-tree surface could NOT be read, so the"
      say_err "   rail cannot show that the tree this merge produces is green."
      say_err "   $TREE_SUMMARY"
      say_err "   A probe that FAILED is not a green tree: this rail merges with --admin, and"
      say_err "   certifying a merge it never measured is the #1261 false PASS. Check gh"
      say_err "   auth/network (and --repo), then re-run. No evidence was posted."
      exit 1 ;;
    *)
      say_err "admin-merge: ✗ BLOCK — the evaluated-tree probe returned an unrecognised state"
      say_err "   ('${TREE_STATUS:-<empty>}'), so the rail cannot report on the tree this merge"
      say_err "   produces. No evidence was posted."
      exit 1 ;;
  esac

  # ── 4.6. STALENESS: A RED BASE THIS PR HAS NOT MEASURED (#1261) ──────────
  # THE HOLE IN STEP 4.5. The PR's evaluated-tree surface reflects the base AS OF
  # THE LAST RUN, and GitHub does NOT reliably re-run PR workflows when the base
  # moves. So a base red that appeared AFTER this PR's checks were produced is
  # invisible to the tree gate: the surface is a STALE GREEN, and the merge lands
  # a tree the PR never measured. That is the incident's shape (#4600 opened
  # before #4589 made main red, merged after).
  #
  # WHY THIS IS RED-RELATIVE, NOT MOVEMENT-RELATIVE. A busy base moves
  # constantly, and almost all of that movement is irrelevant. Refusing whenever
  # the base moved would refuse essentially every open PR — an over-block, which
  # is a failure, not safety. The ONLY thing a stale surface can fail to cover is
  # a red: if the base moved and is green, there is nothing this PR has not
  # measured, so it merges. So the comparison runs ONLY when the base head
  # carries a code-measuring red, and refuses only when such a red's run STARTED
  # after the PR surface was last produced.
  #
  # WHY `started_at > TREE_MAX_COMPLETED`. `TREE_MAX_COMPLETED` is the latest
  # `completed_at` among the PR surface's completed checks — the last moment the
  # evaluated surface was produced. A base red whose run STARTED after that
  # moment cannot be part of what the surface measured: the run did not exist
  # yet. The repair direction falls out for free — a base red that predates the
  # PR's evaluation WAS measured by it, the PR's own tree carries the fix, and
  # this passes — so the PR that repairs a red base still merges. (MEASURED, not
  # assumed: on tortoise, main head 1f5d6efc49 carried `welcome-e2e` failure
  # started 2026-09-22T16:13:22Z while open PR 4591's surface was last produced
  # 2026-09-22T06:23:46Z — a stale green of ~10h; the merge ref's base parent
  # also lagged main by hours, which is why a merge-ref comparison alone would
  # MISS the recomputed-but-unre-run case, while this timestamp comparison
  # catches both.)
  #
  # WHAT THIS DOES NOT FIX. A base red whose run started BEFORE the surface was
  # produced but on a base the surface never used (the merge ref can lag the
  # base) is not caught HERE — the ordering rule cannot see it. That case is step
  # 4.7, which compares the merge ref's base parent against the current base head
  # and refuses when they differ while the base is red.
  if [ "$BASE_STATUS" = "red" ]; then
    local stale_any=0 stale_reds="" stale_name stale_iso stale_epoch stale_url
    if counter_is_number "$TREE_MAX_COMPLETED_EPOCH"; then
      while IFS=$'\t' read -r stale_name stale_iso stale_epoch stale_url; do
        [ -n "$stale_name" ] || continue
        if ! counter_is_number "$stale_epoch"; then
          stale_any=1
          stale_reds="${stale_reds}   • ${stale_name} — ${stale_url} — began at an UNREADABLE time, so the rail cannot show this PR measured it"$'\n'
        elif counter_exceeds_max "$stale_epoch" "$TREE_MAX_COMPLETED_EPOCH"; then
          stale_any=1
          stale_reds="${stale_reds}   • ${stale_name} — ${stale_url} — began ${stale_iso}, AFTER this PR's surface was last produced (${TREE_MAX_COMPLETED})"$'\n'
        fi
      done <<< "$BASE_RED_TS"
    else
      # No MEASURING completed check on the PR surface — none at all, or only
      # checks that completed without exercising anything (#1353): there is no
      # measurement time to compare against, so the rail cannot show this PR
      # measured the base's red.
      stale_any=1
      stale_reds="   • the PR's evaluated surface has produced NO MEASURING completed check run (none at all, or only \`skipped\`/\`cancelled\`/\`neutral\`/\`stale\` checks, which measured nothing), so it has no time to compare against the base's red(s)"$'\n'
    fi
    if [ "$stale_any" -eq 1 ]; then
      say_err "admin-merge: ✗ BLOCK — THE BASE IS RED AND THIS PR HAS NOT MEASURED IT (a STALE surface)."
      say_err "   $BASE_SUMMARY"
      say_err "   Base red(s) this PR's evaluated surface does not cover:"
      printf '%s' "$stale_reds" >&2
      say_err "   CI evaluates a PR as the MERGE of its head into its base, and GitHub does not"
      say_err "   re-run PR checks when the base moves. This base red began after this PR's checks"
      say_err "   were produced, so the PR's green surface is STALE for it — it certifies a tree"
      say_err "   that no longer includes this red. This is the #1261 incident (a PR opened before"
      say_err "   the base went red and merged after)."
      # #4764: PERFORM the remedy this refusal names — and then say which of the two
      # outcomes actually happened. The helper returns 1 on --dry-run AND on a refused
      # API call, so an unconditional "the update above …" would tell the lane a
      # re-measurement is under way on a path where no new head was created and no
      # check will ever run. THIS invocation still refuses either way (the refreshed
      # head has no completed check yet), so the refusal above is unchanged.
      if refresh_pr_branch "$PR" "$head"; then
        say_err "   RE-MEASURE against the current base, then re-run the rail: the update above"
        say_err "   recomputes the merge-ref evaluation and its checks re-run against the base's"
        say_err "   current head. No review record was left stale by this update — checked BEFORE"
        say_err "   updating, since an update cannot be undone."
      else
        say_err "   RE-MEASURE against the current base, then re-run the rail: the helper above"
        say_err "   states why the rail did not do it for you: a record it refused to strand, a"
        say_err "   dry run, an unresolved repo identity, or a failed update call. Note that"
        say_err "   pushing an empty commit moves the head and strands any record bound to it."
        say_err "   If this PR is the REPAIR, its own checks pass on the re-measured tree."
      fi
      say_err "   No evidence was posted and no merge attempted."
      exit 1
    fi
  fi

  # ── 4.7. THE MERGE REF'S BASE PARENT — A LAGGING EVALUATION (#1261) ─────
  # THE LAST HOLE IN 4.6. Step 4.6 compares TIMES: it refuses a base red that
  # STARTED after the PR's surface was produced. That misses the merge-ref-lag
  # case — `refs/pull/<N>/merge` is recomputed when the base moves but the PR's
  # checks are NOT re-run, so a surface produced AFTER a base red began can still
  # have been evaluated against an OLDER base that does not contain that red. The
  # ordering rule then says "not stale" while the tree the merge will actually
  # produce (head merged into the CURRENT base) was never measured. MEASURED live
  # 2026-09-22: tortoise #4659's merge ref 6f0b119a has base parent 283e919dd1
  # while main's head was 1f5d6efc49, which carried 8 code-measuring reds
  # including `welcome-e2e` started 16:13:22Z — and #4659's own surface was last
  # produced at 18:41:31Z, so the STARTED-AFTER rule did NOT fire, while its
  # merge ref demonstrably did not contain the red head.
  #
  # THE DISCRIMINATOR IS THE BASE PARENT. The merge ref's first parent is the
  # base commit it was computed against. If it differs from the CURRENT base
  # head, then the PR's checks — keyed to a merge ref whose base is not the
  # current one — cannot have measured a merge into the current base (the base
  # only moves forward and a recompute always takes the tip, so a lagging parent
  # is strictly older). AND ONLY A RED BASE MATTERS: if the base is green there
  # is nothing the PR failed to measure, so a lagging ref onto a green base
  # MERGES — refusing on movement alone would refuse essentially every open PR,
  # because GitHub recomputes the merge ref continuously and a lag of a commit or
  # two is the normal state (measured on 12 of 12 open tortoise PRs while main
  # was green).
  #
  # WHY IT DOES NOT OVER-BLOCK THE REPAIR. A PR that repairs a red base must be
  # evaluated against a base that CONTAINS the red; if its merge ref lags, the
  # remedy is a RE-MEASUREMENT against the current base — the refusals below say
  # "RE-MEASURE … then re-run the rail", and a re-triggering event that does not move
  # the head is named where the guard declines to move one. Re-measuring recomputes
  # the merge ref against the current
  # base. A `gh run rerun` does NOT: it re-executes the SAME merge commit, so it
  # re-measures the ref that was already lagging. Once the checks have re-measured
  # the current base, a genuine repair is green on its own tree (step 4.5) and 4.6
  # sees a surface that postdates the red, so it lands. The refusal is a
  # re-measurement request, never a verdict on the PR.
  #
  # FAIL CLOSED ON AN UNREADABLE PARENT. The probe runs ONLY when the base is red
  # (so a green base costs no extra call), and if it cannot read the parent there
  # is no way to show the PR measured the current base — "I did not look" is
  # never a green (the same rule as 4.5's unreadable surface).
  if [ "$BASE_STATUS" = "red" ]; then
    local merge_base_parent=""
    merge_base_parent="$(resolve_merge_base_parent "$MERGE_REF_SHA")"
    if [ -z "$merge_base_parent" ] || [ "$merge_base_parent" = "null" ]; then
      say_err "admin-merge: ✗ BLOCK — THE BASE IS RED AND THE MERGE REF'S BASE PARENT COULD NOT BE READ."
      say_err "   $BASE_SUMMARY"
      say_err "   The merge ref ${MERGE_REF_SHA:-<none>} could not be resolved to its first parent"
      say_err "   (the base commit it was computed against), so the rail cannot show this PR's"
      say_err "   checks were evaluated against the base that is now red. An unread probe is"
      say_err "   never a certificate: this rail merges with --admin."
      say_err "   Check gh auth/network (and --repo), then re-run. No evidence was posted."
      exit 1
    fi
    if [ "$merge_base_parent" != "$BASE_SHA" ]; then
      say_err "admin-merge: ✗ BLOCK — THE BASE IS RED AND THIS PR WAS EVALUATED AGAINST AN OLDER BASE (a LAGGING MERGE REF)."
      say_err "   $BASE_SUMMARY"
      say_err "   The PR's merge ref (refs/pull/$PR/merge = $MERGE_REF_SHA) was computed against"
      say_err "   base commit $merge_base_parent, but the base branch '$base_ref' is now at $BASE_SHA."
      say_err "   The PR's checks are keyed to a tree that does not contain the current base, so"
      say_err "   its green does not cover this base red — GitHub recomputes the merge ref when the"
      say_err "   base moves but does NOT re-run the PR's checks. This is the #1261 merge-ref-lag case."
      say_err "   Base red(s) this PR has not measured:"
      printf '%s\n' "$BASE_REDS" >&2
      # #4764: the same performed remedy as step 4.6, with the same branch on its
      # return — the lag this refusal names is exactly what update-branch clears, and
      # the refusal still stands for THIS run.
      if refresh_pr_branch "$PR" "$head"; then
        say_err "   RE-MEASURE against the current base, then re-run the rail: the update above"
        say_err "   recomputes the merge ref against $BASE_SHA and its checks re-run against it."
        say_err "   No review record was left stale by this update — checked BEFORE updating,"
        say_err "   since an update cannot be undone."
      else
        say_err "   RE-MEASURE against the current base, then re-run the rail: the helper above"
        say_err "   states why the rail did not do it for you: a record it refused to strand, a"
        say_err "   dry run, an unresolved repo identity, or a failed update call. Note that"
        say_err "   pushing an empty commit moves the head and strands any record bound to it."
        say_err "   If this PR is the REPAIR, its own checks then pass on the re-measured tree."
      fi
      say_err "   No evidence was posted and no merge attempted."
      exit 1
    fi
  fi

  local pr_count main_count
  pr_count="$(count_lines "$TMP/pr-fails.txt")"
  main_count="$(count_lines "$TMP/main-fails.txt")"
  local analyzed
  analyzed="$(printf 'Failing runs examined: PR=%s main=%s (with parseable FAILED lines: PR=%s main=%s)' \
    "$(report_value "$TMP/pr-report.txt" examined)" "$(report_value "$TMP/main-report.txt" examined)" \
    "$(report_value "$TMP/pr-report.txt" extracted)" "$(report_value "$TMP/main-report.txt" extracted)")"
  [ -s "$TMP/pr-report2.txt" ] && analyzed="$(printf 'Failing runs examined: PR=%s main=%s (with parseable FAILED lines: PR=%s main=%s)' \
    "$(report_value "$TMP/pr-report2.txt" examined)" "$(report_value "$TMP/main-report.txt" examined)" \
    "$(report_value "$TMP/pr-report2.txt" extracted)" "$(report_value "$TMP/main-report.txt" extracted)")"
  # The lane's COMPLETION state is part of the evidence: it is the fact that
  # makes an empty failing set mean "tested and green" rather than "never ran".
  analyzed="$analyzed
Lane completion: PR completed=$(report_value "$TMP/pr-report.txt" completed) tested=$(report_value "$TMP/pr-report.txt" tested) pending=$(report_value "$TMP/pr-report.txt" pending) | main completed=$(report_value "$TMP/main-report.txt" completed) tested=$(report_value "$TMP/main-report.txt" tested) pending=$(report_value "$TMP/main-report.txt" pending)"
  # THE TWO SURFACES, in the auditable record (#1261): the tree that GATES the
  # merge (the PR's own evaluated tree — the head-keyed surface the merge-ref
  # evaluation is reported on) and the base's head surface, which is CONTEXT
  # ONLY. A reviewer must be able to tell "the lane is green" from "the tree is
  # green" from "the base is red but this PR is not responsible for it".
  local health_line
  health_line="PR evaluated-tree surface (every workflow and app on head $head): ${TREE_STATUS} — ${TREE_RED} failing of ${TREE_TOTAL} measured, ${TREE_PENDING} pending
Base check surface (every workflow and app on head of '$base_ref'): ${BASE_STATUS} — ${BASE_RED} failing of ${BASE_TOTAL} measured, ${BASE_PENDING} pending (reported for CONTEXT, never blocking)"
  # #6807: an exemption that lives only on ephemeral stderr is indistinguishable,
  # in the DURABLE posted record, from a silent drop. The base reds this rail did
  # NOT count against the PR belong in the evidence the reviewer reads later.
  if [ -n "$BASE_REDS_OTHER" ]; then
    health_line="$health_line
Base red(s) reported but NOT blocking:
$BASE_REDS_OTHER"
  fi
  analyzed="$analyzed
$health_line"

  # ── THE ATTRIBUTION HALF, IN THE POSTED EVIDENCE (#1353) ────────────────
  # `PR failing: 0` can mean "no failures", "not comparable" (the parity gate)
  # OR "the failures were DROPPED". The parser puts every dropped token on
  # stderr; this states the COUNT for each side in the evidence, and the token
  # list follows as its own list block, so a COMPLETE set is distinguishable from
  # a CLIPPED one. Named as its own step so the number is not inferable only from
  # a token list that may be empty for a reason other than "none".
  local pr_drops main_drops unattr_total attribution_line unattr_tokens
  pr_drops="$(unattributable_count_of "$TMP/pr-drops.err" "$TMP/pr-drops2.err")"
  main_drops="$(unattributable_count_of "$TMP/main-drops.err")"
  unattr_tokens="$(unattributable_tokens_of "$TMP/pr-drops.err" "$TMP/pr-drops2.err" "$TMP/main-drops.err")"
  # The TOTAL the empty-text decision reads: every collected drop, so a positive
  # count with blank token text renders CLIPPED rather than COMPLETE (#1353).
  unattr_total="$(unattributable_count_of "$TMP/pr-drops.err" "$TMP/pr-drops2.err" "$TMP/main-drops.err")"
  # NOTE: a REAL newline, not `\n` — bash does not expand escapes inside double
  # quotes, and a literal `\n` would ship into the posted evidence.
  attribution_line="Attribution — FAILED tokens DROPPED by the parser (not test ids, so NEVER in a failing set): PR=${pr_drops} | main=${main_drops}.
   A set carrying a dropped token is CLIPPED, and a CLIPPED set is NOT COMPARABLE to a measured zero (the lane-parity gate's vocabulary, #1319). COMPLETE is the drop count 0 with no token listed below."
  analyzed="$analyzed
$attribution_line"

  # ── 4c. A VACUOUS PASS IS AN ABSENCE, NOT A MEASUREMENT (#1319) ──────────
  # `PR failing: 0 | main failing: 0` certifies nothing on its own: the two
  # zeros mean "the lanes were green" ONLY if both sides ran the SAME lane. On
  # 2026-09-21 the rail printed exactly this line and merged tortoise #4263,
  # whose tier-2 PR lane had SKIPPED shards main's push lane runs — the failure
  # then lived in a shard the PR never executed, so it could appear in NEITHER
  # collected set, and the merge reddened main's required check for the whole
  # fleet (tortoise #4457). The vacuous pass is therefore REFUSED unless the PR
  # side demonstrably EXECUTED every test shard main's lane EXECUTED, and it
  # fails CLOSED: a side whose shard list cannot be read is never read as "the
  # same". See the LANE COVERAGE block for the declared parity key and its bound.
  #
  # A vacuous comparison is STATED, never implied. Both sides empty is usually a
  # correct outcome (the lane is green on both sides) — but it is also exactly
  # what a WRONG lane selector looks like, so the two must be distinguishable by
  # a reader of the evidence. See the bogus-zero trap in ci-failure-set.sh.
  #
  # #1261 — AND THE MESSAGE MUST SAY WHICH SET WAS MEASURED AND WHY IT IS EMPTY.
  # "no failing runs" and "I did not look" are different facts, and the old line
  # ("nothing was compared") left both behind one glyph. A failing run whose log
  # yielded no parseable failure identity already BLOCKS on the PR side
  # (step 1c), and a lane that never TESTED main already BLOCKS (step 2b) — so an
  # empty set HERE is one of exactly two things, and each is named per side.
  # #1319 adds the third: the two sides must also have run the SAME LANE, which
  # is what the parity line reports.
  if [ "$pr_count" -eq 0 ] && [ "$main_count" -eq 0 ]; then
    local parity_rc=0 parity_evidence parity_window_note="" parity_forgiven_note=""
    lane_parity_check "$head" "$MAIN_RUNS" || parity_rc=$?
    if [ "$parity_rc" -eq 0 ]; then
      # #6928 P3b: NO separate `parity_note` variable. The old one was set on this
      # branch with the sentence below, but its only reader was the non-zero branch
      # — which now REFUSES outright (#1439) — so it is deleted rather than parked.
      # The truth lives in `$parity_evidence` (and, when shards were forgiven, in
      # the override immediately below).
      parity_evidence="PR ⊇ main — the PR executed every test shard main's lane executed (parity family: ${LANE_JOB_PREFIX}*; $(lane_count "$TMP/lane-pr.txt") shard(s) on the PR side, $(lane_count "$TMP/lane-main.txt") on main)"
      # #6928 P3a: ON THE FORGIVING PATH THAT LINE IS FALSE AS WRITTEN — the PR did
      # NOT execute every shard main ran; it executed every shard main ran that its
      # diff selector did NOT decline. The machine-checked `lane parity:` line
      # therefore STATES THE TRUTH ITSELF instead of leaving the correction to
      # unchecked prose on the next line. It stays ONE line, still starts with
      # `lane parity:`, and still carries at most one `parity family:` — the three
      # properties the evidence gate (`verify-admin-merge-evidence.sh`) anchors on.
      # The per-shard detail and the selector verdict remain on the disclosure line
      # appended below.
      if [ -n "$LANE_PARITY_FORGIVEN" ]; then
        parity_evidence="PR ⊇ main — the PR executed every test shard main's lane executed EXCEPT the $(lane_count "$TMP/lane-forgiven.txt") shard(s) its diff selector DECLINED for this head, which are forgiven (parity family: ${LANE_JOB_PREFIX}*; $(lane_count "$TMP/lane-pr.txt") shard(s) on the PR side, $(lane_count "$TMP/lane-main.txt") on main)"
      fi
      # DISCLOSE a widened reference (#4844). A reference drawn from further back
      # than the operator asked for is a different window, and the evidence must
      # say so rather than let `--main-runs` describe a window it did not read.
      # ⛔ Its OWN line, appended AFTER the literal block below — never on the
      # `lane parity:` line. The evidence gate (`verify-admin-merge-evidence.sh`)
      # matches that line to its END, so a suffix makes the whole certificate
      # unmatchable and the rail then has its own merge refused and retracts its
      # own evidence. Two assertions pin that apart: the contract suite checks the
      # producer's `lane parity: $parity_evidence` SOURCE line is unadorned
      # (tests/admin-merge-evidence-contract), and (r1) runs the REAL verifier over
      # a WIDENED body (tests/admin-merge) — the source-line check alone cannot
      # catch a suffix added to the line's VALUE.
      if [ "${LANE_PARITY_MAIN_WINDOW:-0}" -gt "$MAIN_RUNS" ]; then
        parity_window_note="   reference window: main's lane reference was widened to a ${LANE_PARITY_MAIN_WINDOW}-run window (from the requested ${MAIN_RUNS}) because the requested ${MAIN_RUNS}-run window carried no shard in the parity family '${LANE_JOB_PREFIX}*'"
      fi
    fi
    # ── THE #6928 FORGIVENESS LINE, ON THE CERTIFICATE ──────────────────────
    # `lane_parity_check` already warns on stderr with the forgiven shard list and
    # the selector verdict, on whatever path follows; this is the same fact for the
    # EVIDENCE, which a PR reader sees and the stderr warning never reaches. It must
    # be its OWN line, appended after the literal block below, and never carry
    # `lane parity:` — that line is matched to its END by the evidence gate, and
    # carries at most one `parity family:`.
    if [ -n "$LANE_PARITY_FORGIVEN" ]; then
      parity_forgiven_note="   lane-coverage forgiveness (#6928): these shard(s) main's lane executed were DECLINED by this head's diff selector and are therefore NOT required of it: $(printf '%s' "$LANE_PARITY_FORGIVEN" | tr '\n' ' ') Selector verdict: ${LANE_PARITY_SELECTOR_VERDICT}. This is the SELECTOR's own decision — the same rule the CI aggregate applies to a selector-declined leg — not a blanket exemption: every shard the selector did not decline still had to be executed, and was."
    fi
    if [ "$parity_rc" -ne 0 ]; then
      # ── ONE REFUSAL FOR BOTH FAILURE MODES (#1439) ──────────────────────────
      # `ADMIN_MERGE_LANE_PARITY=declared-off` USED TO certify here and then call
      # the merge. It cannot: the evidence gate refuses a vacuous certificate that
      # does not carry the positive `lane parity: PR ⊇ main` line
      # (verify-admin-merge-evidence.sh clause 5 — #1319's own rule, and the case
      # #1388's decision scoped clause 5 to). So the escape advertised a
      # certificate its consumer rejects: the producer posted evidence, announced
      # a merge, and the shim then refused it and retracted the evidence (#3549).
      # A rail that cannot tell "certified" from "refused one layer down" is a
      # FALSE PASS, so the producer now fails CLOSED where it used to certify —
      # and names the route that does work, instead of one that cannot.
      if [ "$parity_rc" -eq 2 ]; then
        say_err "⛔ admin-merge: BLOCK — NOT COMPARABLE: both failing sets are EMPTY and the"
        # #2842: STATE THE CONDITION THAT ACTUALLY HELD. Every empty reference used
        # to be described as an UNREADABLE list. That is accurate when the listing or
        # a job list could not be read — and FALSE, in the direction of "your repo's
        # coverage cannot be measured", when the lists were read perfectly and simply
        # carried no job in the family. The operator then chases a comparability
        # defect that does not exist while the one-line naming fix sits unread in WHY.
        case "${LANE_PARITY_EMPTY_KIND:-}" in
          family)
            say_err "   lane coverage could not be established: the shard FAMILY '${LANE_JOB_PREFIX}*'"
            say_err "   selected NOTHING from job lists that WERE READABLE. That is a NAMING"
            say_err "   mismatch — NOT an unreadable list and NOT a red check: no failing check"
            say_err "   was measured on either side, so nothing here says this PR is broken."
            say_err "   The job name(s) it executed are listed in WHY below." ;;
          lifecycle)
            say_err "   lane coverage could not be established: the shard FAMILY '${LANE_JOB_PREFIX}*'"
            say_err "   matched only workflow LIFECYCLE (bookkeeping) jobs, which measure no test."
            say_err "   That is a MISNAMED family — NOT an unreadable list and NOT a red check." ;;
          *)
            say_err "   lane coverage could not be established (lane: $lane). 'Nothing was compared'"
            say_err "   cannot be told from 'both sides were clean' when the shard lists are not"
            say_err "   readable — and an unreadable shard list is NOT an empty one." ;;
        esac
        say_err "   WHY: ${LANE_PARITY_REASON}."
        # #2842: THE REMEDY MUST CARRY A VALUE THAT WORKS. Naming the knob and the
        # names it saw still leaves the operator to guess the value, and the guess the
        # rail's own example teaches ('unit') is refuted by a case-SENSITIVE prefix
        # match against 'Unit tests'. So the retry command is DERIVED from the names
        # this window actually executed.
        if [ "${LANE_PARITY_EMPTY_KIND:-}" = "family" ] || [ "${LANE_PARITY_EMPTY_KIND:-}" = "lifecycle" ]; then
          lane_prefix_candidates "$TMP/lane-main-alljobs.txt" "$TMP/lane-candidates.txt"
          if [ -s "$TMP/lane-candidates.txt" ]; then
            say_err "   THE RETRY VALUE, derived from the job name(s) main's lane EXECUTED — the"
            say_err "   family is a PREFIX match and CASE-SENSITIVE ('unit' does NOT select"
            say_err "   'Unit tests'), so pick the line whose name is the TEST shard:"
            sed 's/^/      /' "$TMP/lane-candidates.txt" >&2
            say_err "   Re-run the rail unchanged with it exported. This repairs a NAME — it is"
            say_err "   not a bypass, and it is not what AGENT_ADMIN_MERGE_OVERRIDE=1 is for."
          fi
        fi
      else
        say_err "⛔ admin-merge: BLOCK — NOT COMPARABLE: both failing sets are EMPTY, and the"
        say_err "   PR's lane did NOT EXECUTE $(lane_count "$TMP/lane-missing.txt") test shard(s) that main's lane executes."
        say_err "   'PR failing: 0 | main failing: 0' therefore compares TWO DIFFERENT LANES: a"
        say_err "   failure in a shard this head never ran can appear in NEITHER set, so the"
        say_err "   zeros certify nothing (tortoise #4263 → #4457)."
        say_err "   parity family: ${LANE_JOB_PREFIX}* (a job OUTSIDE this family leaves the comparison)"
        say_err "   shard(s) main EXECUTED and this head did not:"
        sed 's/^/      /' "$TMP/lane-missing.txt" >&2
        say_err "   PR lane — executed $(lane_count "$TMP/lane-pr.txt") test shard(s):"
        sed 's/^/      /' "$TMP/lane-pr.txt" >&2
        say_err "   main lane — executed $(lane_count "$TMP/lane-main.txt") test shard(s):"
        sed 's/^/      /' "$TMP/lane-main.txt" >&2
      fi
      # WHY A SHARD WAS NOT REQUIRED is disclosed on stderr by `lane_parity_check`
      # ITSELF (#6928 P3-1): whenever forgiveness is applied it warns with the
      # forgiven shard list and the selector verdict, on the path that certifies AND
      # on the path that refuses. So this refusal does not restate it in a second
      # spelling — the count above is ALREADY net of the forgiven shards, and that
      # warning is what says so.
      if [ "$LANE_PARITY_MODE" = "declared-off" ]; then
        say_err "   ⛔ ADMIN_MERGE_LANE_PARITY=declared-off is set, and it does NOT rescue this:"
        say_err "      the evidence gate refuses a vacuous certificate that does not state"
        say_err "      'lane parity: PR ⊇ main' (verify-admin-merge-evidence.sh clause 5), so"
        say_err "      certifying here would post evidence the merge shim then refuses. The escape"
        say_err "      was removed as a certifier because it could never survive that gate."
        say_err "      Run the FULL lane for this head, or — if this repo's PR lane cannot run"
        say_err "      these shards by design (a trigger-split repo, see #1349) — the audited"
        say_err "      route is AGENT_ADMIN_MERGE_OVERRIDE=1, which is logged as"
        say_err "      admin_merge_override and bypasses the certificate rather than faking one."
      else
        say_err "   Remedy: run the FULL lane for this head (the shards above are what main"
        say_err "   measures), then re-run the rail. If this lane's test shards are not named"
        say_err "   '${LANE_JOB_PREFIX}*', set ADMIN_MERGE_LANE_JOB_PREFIX to the prefix they use."
        # #2842: the OTHER shape of the same defect — main's family matched, this
        # head's did not. Then the useful names are the PR's, and naming only the knob
        # leaves the operator to guess the value against a CASE-SENSITIVE match.
        if [ "$(lane_count "$TMP/lane-pr.txt")" -eq 0 ]; then
          lane_prefix_candidates "$TMP/lane-pr-alljobs.txt" "$TMP/lane-candidates.txt"
          if [ -s "$TMP/lane-candidates.txt" ]; then
            say_err "   This head's lane EXECUTED job name(s) the family '${LANE_JOB_PREFIX}*' does not"
            say_err "   match (a PREFIX match, and CASE-SENSITIVE: 'unit' does NOT select"
            say_err "   'Unit tests'). The retry value(s), for the name that is the TEST shard:"
            sed 's/^/      /' "$TMP/lane-candidates.txt" >&2
          fi
        fi
        say_err "   If this repo's PR lane CANNOT run them by design (a trigger-split repo,"
        say_err "   see #1349), the audited route is AGENT_ADMIN_MERGE_OVERRIDE=1, which is"
        say_err "   logged as admin_merge_override."
      fi
      say_err "   This is a refusal, not a comparison. No evidence was posted and no merge attempted."
      exit 1
    fi
    # The vacuous outcome is STATED, never implied — and it states WHAT it rests
    # on: the comparison, its coverage, and per side WHY each set is empty. The
    # two are different facts and a reader must not have to guess.
    analyzed="$analyzed
⚠️ vacuous comparison — no failure was compared, because NEITHER measured set carried one.
   measured sets: PR failing runs=0 | main failing runs=0 (lane: $lane)
   lane parity: $parity_evidence
   PR side: ${pr_examined:-0} failing run(s) of ${pr_completed:-0} completed / ${pr_tested:-0} tested for head $head (${pr_pending:-0} pending). EMPTY because nothing FAILED — a failing run whose log yielded no parseable failure identity would have BLOCKED at step 1c, not read as zero.
   main side: $(report_value "$TMP/main-report.txt" examined) failing run(s) of ${main_completed:-0} completed / ${main_tested:-0} tested over the window ($MAIN_RUNS run(s) requested). ${main_side_reason:-EMPTY, but the window published no examined/extracted counters, so its completeness is UNKNOWN.}
   main check surface: $BASE_STATUS — $BASE_RED failing of $BASE_TOTAL measured, $BASE_PENDING pending; read across EVERY workflow, not just this lane. CONTEXT ONLY: it never blocks (a PR that repairs a red base must still land).
   PR evaluated tree: $TREE_STATUS — $TREE_RED failing of $TREE_TOTAL measured, $TREE_PENDING pending; read from the HEAD commit, where GitHub reports the merge-ref evaluation, across EVERY workflow. THIS is the surface that gates the merge.
   Correct when the lane is green on both sides — but ONLY when both sides ran the SAME lane. The per-side counters tell 'green' from 'never run'; the parity line tells 'the same lane' from 'two different lanes'. A wrong lane selector certifies neither."
    # The widening disclosure is appended HERE, after the literal: the `lane
    # parity:` line above must stay byte-identical to what the gate and the
    # contract suite pin (#4844, #1388).
    if [ -n "$parity_window_note" ]; then
      analyzed="${analyzed}
${parity_window_note}"
    fi
    if [ -n "$parity_forgiven_note" ]; then
      analyzed="${analyzed}
${parity_forgiven_note}"
    fi
    info "admin-merge: ⚠️  vacuous comparison — measured sets: PR failing=0 | main failing=0 (lane: $lane); lane parity: $parity_evidence; PR tree: $TREE_STATUS ($TREE_RED failing of $TREE_TOTAL measured); main check surface: $BASE_STATUS ($BASE_RED failing of $BASE_TOTAL measured, context only)"
  fi

  info "admin-merge: PR failing: $pr_count | main failing: $main_count | blocked by the decision: 0"

  # The set the "must be empty" claim is actually ABOUT: after a flake re-run,
  # unique2.txt is the post-rerun residual (pr-fails2 vs main-fails), while
  # unique.txt is the PRE-rerun one. Showing the pre-rerun set under a "must be
  # empty" heading contradicts the displayed (post-rerun) sets. (VGATE round 2.)
  local final_unique="$TMP/unique.txt"
  if [ -f "$TMP/unique2.txt" ]; then final_unique="$TMP/unique2.txt"; fi
  # Post-rerun state wins when it exists: the evidence must describe the decision
  # that actually authorised the merge, not the pre-rerun one.
  local final_exempt="$TMP/unique.exempt"
  if [ -f "$TMP/unique2.verdict" ]; then final_exempt="$TMP/unique2.exempt"; fi
  # ── #1614: THE LANE-APPLICABILITY FALLBACK, ON THE CERTIFICATE ────
  # The stderr block above says WHY the fallback fired; a reader of the posted
  # evidence never sees stderr, so the same fact is stated here. APPENDED, after
  # the literal parity lines — never spliced into them.
  if [ -n "$LANE_FALLBACK_FROM" ]; then
    analyzed="${analyzed}
   lane applicability fallback (#1614): the watched lane '${LANE_FALLBACK_FROM}' is INAPPLICABLE to this diff — its workflow's 'on:' block declares no pull_request / pull_request_target trigger that can fire for this PR's changed set, so no run OF that lane can attach to head $head. The lane filter was DROPPED for this run (the full evaluated surface was compared) — a MEASURED fallback, never a silent widening. A lane that SHOULD have run and produced no run still refuses at step 1b; only a lane that CANNOT run is skipped."
  fi

  build_evidence "$head" "$TMP/main-runs.txt" "$pr_count" "$main_count" \
    "$(cat "$TMP/unique.txt")" "$flake_line" "$analyzed" "$lane" \
    "$TMP/pr-fails.txt" "$TMP/main-fails.txt" "$(cat "$final_unique")" \
    "$(cat "$final_exempt" 2>/dev/null || true)" "$unattr_tokens" "$unattr_total" "$repro_line" "$repro_n" > "$TMP/evidence.md"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "admin-merge: --dry-run — evidence that WOULD be posted:"
    cat "$TMP/evidence.md"
    info "admin-merge: (dry-run) no comment posted, no merge"
    exit 0
  fi

  # ── THE HOLD-PROOF AT THE ACTION SITE (agent-infra#2867) ──
  # The claim registry fences DISPATCH, not ACTION. This merge is the action whose wrongness
  # costs most (an `--admin` merge lands a head into main irreversibly, with the evidence bound
  # to a head the actor may not have reviewed), so it is the ONE action fenced here — and the
  # gate runs BEFORE the evidence comment is posted, so a dead lane neither merges nor mints an
  # attestation. When the harness invoked this rail it passes CLAIM_ACTION_CLAIMS_SH +
  # CLAIM_ACTION_HEAD_TOKEN (the claim commit merge-one.sh pushed); the rail then REFUSES unless
  # `claim_action_proof` holds — a claim exists, its tip is this actor's own commit (the fencing
  # token), it names this box, and its holder is not dead. A manual invocation (no
  # CLAIM_ACTION_CLAIMS_SH) is outside the harness's ownership model and stays covered by the
  # review-enforcer's head-bound evidence gate and the post-merge detector (the "caller
  # deliberately removes the guard" class).
  # ⛔ NEVER FALLS OPEN: an unset/empty token under a harness invocation, a missing claims.sh,
  # or ANY non-zero proof result all refuse the merge — an unknown verdict is a refusal.
  if [ -n "${CLAIM_ACTION_CLAIMS_SH:-}" ]; then
    local proof_rc=0 proof_out=""
    if [ -z "${CLAIM_ACTION_HEAD_TOKEN:-}" ]; then
      say_err "⛔ admin-merge: REFUSED [hold-proof] — the harness invoked the rail with no claim token for PR #$PR at head ${head:0:12} (claim-action-proof: REFUSED pr=$PR head=${head:0:12} holder=<none> reason=no-token). An action without a claim proof is refused; never falls open."
      exit 1
    fi
    if [ ! -f "$CLAIM_ACTION_CLAIMS_SH" ]; then
      say_err "⛔ admin-merge: REFUSED [hold-proof] — the claim registry ($CLAIM_ACTION_CLAIMS_SH) is missing/unreadable, so the hold-proof cannot run for PR #$PR at head ${head:0:12}. Refusing; never falls open."
      exit 1
    fi
    proof_out="$( CLAIM_REPO="${CLAIM_ACTION_REPO:-$REPO}" bash -c '
      . "$1" || exit 2
      claim_action_proof "$2" "$3" "$4"
    ' _ "$CLAIM_ACTION_CLAIMS_SH" "$PR" "$head" "$CLAIM_ACTION_HEAD_TOKEN" 2>&1 )" || proof_rc=$?
    if [ "$proof_rc" -ne 0 ]; then
      say_err "⛔ admin-merge: REFUSED [hold-proof] — $proof_out"
      exit 1
    fi
    info "admin-merge: hold-proof held: $proof_out"
  fi

  # shellcheck disable=SC2086
  if ! $GH pr comment "$PR" ${repo_args[@]+"${repo_args[@]}"} --body-file "$TMP/evidence.md" >/dev/null; then
    say_err "admin-merge: ✗ could not post the evidence comment — refusing to merge without it"
    exit 1
  fi
  info "admin-merge: ✅ head-bound evidence posted (marker: admin-merge-safety: $head)"

  # shellcheck disable=SC2086
  # ORDER MATTERS. `--match-head-commit "$head"` is deliberately passed AFTER the caller's
  # passthrough args (MERGE_ARGS): gh takes the LAST occurrence of a scalar flag, so with
  # the old order a `-- --match-head-commit <other>` passthrough silently REBOUND the merge
  # to a head other than the one just certified, defeating the binding this comment claims
  # (cycle-3 review). Ours goes last so ours wins.
  #
  # THE EXIT STATUS IS CHECKED. `gh pr merge` requires a merge method when it is
  # not interactive; with none it printed that error and NO-OPed while this
  # function returned success — leaving "✅ head-bound evidence posted" standing
  # over an UNMERGED PR (B1 lost #3754/#3755 to exactly that). A merge that fails
  # must fail LOUD.
  local merge_status=0
  # shellcheck disable=SC2086
  $GH pr merge "$PR" --admin ${MERGE_ARGS[@]+"${MERGE_ARGS[@]}"} --match-head-commit "$head" ${repo_args[@]+"${repo_args[@]}"} \
    >"$TMP/merge.out" 2>"$TMP/merge.err" || merge_status=$?

  # ── THE ARTIFACT, NOT THE SEND (#1359) ─────────────────────────────────────
  #
  # `gh pr merge` exiting 0 is a SEND. It is not the artifact. `--auto` enqueues a
  # merge and exits 0 while the PR is still OPEN (and MERGE_ARGS is CALLER-
  # supplied, so `-- --auto` reaches this line); an enqueued or asynchronously-
  # completed merge can also lag the command's return. Either way the next line
  # asserts a fact about the REPOSITORY, so the repository is what gets read.
  #
  # BOUNDED POLL: a genuine merge can take a moment to be reflected, so we ask a
  # few times before concluding it did not happen — and we ask the API, never a
  # local inference, because a wrong "merged" is the one error that cannot be
  # walked back (the evidence comment is already standing).
  local merge_state="" merge_merged_at=""
  # ⛔ `gh pr merge` EXITING NON-ZERO IS NOT EVIDENCE THAT IT DID NOT MERGE (#1298).
  # A mutation whose RESPONSE READ failed is ambiguous by definition about whether the
  # mutation ran, and the exit status cannot resolve it. Both arms below therefore ask
  # the REPOSITORY through `poll_merge_artifact`, which answers with THREE outcomes —
  # merged / not_merged / unreadable — and NEITHER arm infers the artifact from the send.
  local merge_response_lost=0
  if [ "$merge_status" -eq 0 ]; then
    # ── THE ARTIFACT, NOT THE SEND (#1359) ───────────────────────────────────
    # `gh pr merge` exiting 0 is a SEND. It is not the artifact. `--auto` enqueues a
    # merge and exits 0 while the PR is still OPEN (and MERGE_ARGS is CALLER-supplied,
    # so `-- --auto` reaches this line); an enqueued or asynchronously-completed merge
    # can also lag the command's return. Either way the next line asserts a fact about
    # the REPOSITORY, so the repository is what gets read — through the ONE read door,
    # bounded, because a genuine merge can take a moment to be reflected and a wrong
    # "merged" is the one error that cannot be walked back (the evidence comment is
    # already standing).
    poll_merge_artifact "$PR"
    merge_state="$MERGE_ART_STATE"
    merge_merged_at="$MERGE_ART_MERGED_AT"
    if [ "$MERGE_ART_VERDICT" = "not_merged" ]; then
      say_err "⛔ admin-merge: FAILED — gh pr merge reported SUCCESS (exit 0), but PR #$PR is NOT merged."
      say_err "   The API reports state=$merge_state mergedAt=$merge_merged_at after ${MERGE_ART_ATTEMPTS} attempt(s)."
      say_err "   THE SUCCESS MARKER IS STANDING OVER AN UNMERGED PR. Read"
      say_err "     ✅ head-bound evidence posted (marker: admin-merge-safety: $head)"
      say_err "   as 'the EVIDENCE COMMENT was posted' — NOT as 'the PR merged'. A QUEUED merge is"
      say_err "   not a merge: the rail certifies the ARTIFACT, not the command's exit code. If you"
      say_err "   passed '--auto' through MERGE_ARGS, that is the cause."
      write_merge_retraction "$PR" "$head" \
        "gh pr merge exited 0, but the API reports this PR as state=$merge_state (mergedAt=$merge_merged_at) after ${MERGE_ART_ATTEMPTS} attempt(s). A merge that is still QUEUED (for example one requested with '--auto') is not a merge that happened." \
        "$TMP/merge.err" "gh pr merge said:"
      exit 1
    fi
    # ⛔ THE RETRACTION GATE IS AN ALLOW-LIST, MATCHING ITS SIBLING ARM (#1298 review).
    # This arm used to retract on `verdict != merged` — a DENY-LIST, so ANY verdict that
    # was neither `merged` nor the explicitly-caught `unreadable` would fall through to a
    # DURABLE retraction asserting "the merge did NOT happen" on a state nobody read as
    # refused. `not_merged` is now the only licensed retraction, and everything else —
    # today only `unreadable`, tomorrow any verdict this read grows — lands here and
    # claims NEITHER outcome. The polarity is the rule `poll_merge_artifact` states: an
    # unnamed value must never fall through a gap into a claim about the repository.
    if [ "$MERGE_ART_VERDICT" != "merged" ]; then
      local mu_tag=""
      observed_rate_limit "$TMP/merge.err" "${MERGE_ART_DIAG:-}" && mu_tag=" [rate_limited]"
      say_err "⛔ admin-merge: BLOCK [merge_unreadable]${mu_tag} — gh pr merge reported SUCCESS (exit 0), but the"
      say_err "   state of PR #$PR could NOT be READ (${MERGE_ART_ATTEMPTS} attempt(s)), so the rail does"
      say_err "   NOT know whether it merged."
      say_err "   This is NOT a claim that the merge did not happen, and NOT a claim that it did."
      say_err "   Nothing is retracted and no claim about the PR is made — a retraction posted over"
      say_err "   an UNKNOWN state is the worst of the three outcomes (#1298)."
      say_err "   THE SUCCESS MARKER MAY BE STANDING OVER AN UNKNOWN STATE. Read"
      say_err "     ✅ head-bound evidence posted (marker: admin-merge-safety: $head)"
      say_err "   as 'the EVIDENCE COMMENT was posted' — NOT as 'the PR merged'."
      if [ -n "${MERGE_ART_DIAG:-}" ]; then
        say_err "   the state read reported: ${MERGE_ART_DIAG}"
      else
        say_err "   the state read wrote no non-blank message — the read either answered with"
        say_err "   something other than the projection, or failed without saying why."
      fi
      # ⛔ A RATE LIMIT IS NOT AN UNREADABLE STATE, AND THE REMEDY IS NOT THE SAME ONE
      # (#1910). Left unclassified, the line below sends the operator to re-read a PR
      # whose read was REFUSED, and the measured consequence was a raw REST merge that
      # bypassed this rail. The classification is stated BEFORE the re-read advice.
      [ -n "$mu_tag" ] && say_rate_limit_note
      say_err "   Determine the state and re-run: gh pr view $PR ${REPO:+--repo $REPO} --json state,mergedAt"
      exit 1
    fi
  fi

  if [ "$merge_status" -ne 0 ]; then
    # ── A READ THAT FAILED IS NOT A VALUE (#1298, the #1690 rule, one arm over) ──
    # `gh pr merge` exited non-zero. That may be a REFUSAL (a draft, a moved head, a
    # permissions error) — or it may be a merge GitHub PERFORMED whose RESPONSE the
    # client never read (a timeout; tortoise #4413 is the measured case). Both produce
    # the SAME non-zero status, so the status decides NOTHING about the repository, and
    # the rail asks the repository before it says anything about reality.
    poll_merge_artifact "$PR"
    merge_state="$MERGE_ART_STATE"
    merge_merged_at="$MERGE_ART_MERGED_AT"
    if [ "$MERGE_ART_VERDICT" = "merged" ]; then
      # ⛔ THE MERGE HAPPENED. `gh pr merge` exited non-zero and the PR is MERGED — the
      # two facts are INDEPENDENT, and the artifact decides. Reporting this as "did NOT
      # happen" is #1298: the rail's loudest statement would be false, and a DURABLE
      # retraction would annotate a MERGED PR forever. NO RETRACTION IS POSTED — there
      # is nothing to correct: the marker's own claim ("the evidence comment was
      # posted") is true and stays true.
      #
      # ⛔ THE MARKER ASSERTS ONLY WHAT WAS OBSERVED (#1298 review, io-contract).
      # `[merge_response_lost]` names the CLASS this fix exists for, but a non-zero exit
      # plus MERGED is also consistent with a refusal that coincided with a merged PR
      # (gh answering "already merged", or another actor landing it). So the emitted
      # lines state the OBSERVATIONS and point at the only evidence of the CAUSE — the
      # command's own output — rather than asserting a networking incident.
      merge_response_lost="$merge_status"
      merge_status=0    # fall through to the landed-commit read and the success line
    elif [ "$MERGE_ART_VERDICT" = "not_merged" ]; then
      say_err "⛔ admin-merge: FAILED — the merge of PR #$PR did NOT happen (gh pr merge exit $merge_status)."
      say_err "   This is the ARTIFACT, not the exit status: the API reports state=$merge_state after"
      say_err "   ${MERGE_ART_ATTEMPTS} attempt(s), so the PR really is unmerged."
      say_err "   THE SUCCESS MARKER IS STANDING OVER AN UNMERGED PR. Read"
      say_err "     ✅ head-bound evidence posted (marker: admin-merge-safety: $head)"
      say_err "   as 'the EVIDENCE COMMENT was posted' — NOT as 'the PR merged'. The merge it was"
      say_err "   posted to authorize FAILED, so PR #$PR is NOT merged."
      if [ -s "$TMP/merge.err" ]; then
        say_err "   gh pr merge said:"
        sed 's/^/      /' "$TMP/merge.err" >&2
      fi
      if [ -s "$TMP/merge.out" ]; then
        say_err "   gh pr merge stdout:"
        sed 's/^/      /' "$TMP/merge.out" >&2
      fi
      write_merge_retraction "$PR" "$head" \
        "\`gh pr merge\` exited $merge_status after that marker was posted, and the API reports state=$merge_state — so this retraction rests on the ARTIFACT read after the failure, not on the exit status alone." \
        "$TMP/merge.err" "gh pr merge said:"
      exit 1
    else
      local mu2_tag=""
      observed_rate_limit "$TMP/merge.err" "${MERGE_ART_DIAG:-}" && mu2_tag=" [rate_limited]"
      say_err "⛔ admin-merge: BLOCK [merge_unreadable]${mu2_tag} — gh pr merge exited $merge_status and the state of"
      say_err "   PR #$PR could NOT be READ (${MERGE_ART_ATTEMPTS} attempt(s)), so the rail does NOT know"
      say_err "   whether the merge happened."
      say_err "   This is NOT a claim that the merge did not happen, and NOT a claim that it did. A"
      say_err "   non-zero exit means the RESPONSE could not be read, and a lost answer to a mutation"
      say_err "   is ambiguous BY DEFINITION about whether the mutation ran — so NOTHING is retracted"
      say_err "   and no claim about the PR is made (#1298; a retraction posted over an UNKNOWN state"
      say_err "   is the worst of the three outcomes)."
      say_err "   THE SUCCESS MARKER MAY BE STANDING OVER AN UNKNOWN STATE. Read"
      say_err "     ✅ head-bound evidence posted (marker: admin-merge-safety: $head)"
      say_err "   as 'the EVIDENCE COMMENT was posted' — NOT as 'the PR merged'."
      if [ -s "$TMP/merge.err" ]; then
        say_err "   gh pr merge said:"
        sed 's/^/      /' "$TMP/merge.err" >&2
      fi
      if [ -n "${MERGE_ART_DIAG:-}" ]; then
        say_err "   the state read reported: ${MERGE_ART_DIAG}"
      else
        say_err "   the state read wrote no non-blank message — the read either answered with"
        say_err "   something other than the projection, or failed without saying why."
      fi
      # ⛔ SAME CLASSIFICATION AS ITS SIBLING ARM (#1910): this is the arm the measured
      # incident landed in — the merge mutation was refused on the rate limit, and the
      # state read was refused for the same reason, so BOTH channels are checked.
      [ -n "$mu2_tag" ] && say_rate_limit_note
      say_err "   Determine the state and re-run: gh pr view $PR ${REPO:+--repo $REPO} --json state,mergedAt"
      exit 1
    fi
  fi
  # THE SHA THAT LANDED, NOT THE SHA WE SENT (#7504). `$head` is the BRANCH head, and
  # under the DEFAULT `--squash` (see the MERGE_ARGS note above) the commit that lands
  # on main is a NEW commit that shares no sha with it — so printing `$head` here
  # recorded a sha that is not on main at all. Measured on three landings, and the
  # printed value was `head.sha`: verified against the API on #7537 (printed
  # fbdcddb1… = head.sha, while its `merge_commit_sha` is daab0afe…) and on #7417
  # (printed 9df5bd21… = head.sha, `merge_commit_sha` 39f92e37…). So it failed
  # `git merge-base --is-ancestor <sha> origin/main` because a squash creates a NEW
  # commit, and it was "not a valid commit name" because the PR-HEAD object was never
  # fetched into the clone that was asked to resolve it — NOT because anything was
  # deleted on GitHub.
  #
  # CORRECTION (review round 2, and it is worth keeping visible): an earlier version
  # of this comment blamed the PREDICTED merge ref `refs/pull/N/merge`. That was
  # WRONG. The old line read `$head` — it never touched `merge_commit_sha` at all. The
  # general fact that a PRE-merge `merge_commit_sha` holds the predicted
  # `refs/pull/N/merge` ref is true (see the note above `resolve_merge_ref`), but it
  # explains nothing about this defect, and a reader who believed it would go and
  # look for a deleted ref instead of at the line that printed the head.
  #
  # Read the landed commit from the
  # REST PR object AFTER the merge: the same source `resolve_merge_ref` trusts, for
  # the same reason it states (REST `merge_commit_sha` is populated while the PR is
  # still OPEN, where GraphQL `mergeCommit` is NULL — see the note above
  # `resolve_merge_ref`; the same REST object is re-read here, AFTER the merge,
  # where the field holds the landed commit).
  local landed_sha="" slug
  if [ -n "${REPO:-}" ]; then slug="repos/$REPO"; else slug="repos/{owner}/{repo}"; fi
  landed_sha="$($GH api "$slug/pulls/$PR" --jq '.merge_commit_sha // ""' 2>/dev/null || true)"
  case "$landed_sha" in
    ""|null)
      # No sha is better than a WRONG sha: the whole defect was a figure that looked
      # like the artifact and was not. The head is printed SHORT (12 chars) because a
      # second full 40-hex token on this line is machine-reachable — anything reading
      # "the sha off the success line" would recover the head, which is the #7504
      # defect reintroduced (review round 1, P2-3).
      info "admin-merge: ✅ merged PR #$PR (state=$merge_state confirmed via the API) — the merge commit was NOT readable, so it is deliberately NOT printed; branch head was ${head:0:12}…, which under a squash is NOT on main. Read the artifact with: gh pr view $PR ${REPO:+--repo $REPO} --json mergeCommit"
      ;;
    *)
      info "admin-merge: ✅ merged PR #$PR at $landed_sha (state=$merge_state confirmed via the API; branch head was ${head:0:12}…)"
      ;;
  esac
  # ── THE LOST RESPONSE IS DISCLOSED, NOT ERASED (#1298) ────────────────────
  # When the merge happened DESPITE a non-zero exit, the success above is the truth
  # and this line is the rest of it: the exit status was unreadable, and the merge was
  # established by re-reading the ARTIFACT. It is machine-distinguishable from the
  # ordinary success (a consumer must not have to parse the prose), and it is stated on
  # the SAME run as the success line rather than in a comment somebody has to find.
  if [ "$merge_response_lost" -ne 0 ]; then
    info "admin-merge: ⚠️  [merge_response_lost] gh pr merge exited ${merge_response_lost} while the API reports"
    info "   state=$merge_state — the merge DID happen, decided by the ARTIFACT and not by the exit status."
    info "   The non-zero exit is NOT read as a refused merge: no retraction was posted, and the evidence"
    info "   marker still stands over a MERGED PR. This marker asserts only what was OBSERVED (a non-zero"
    info "   exit and a MERGED state); the command's own output below is the only evidence of WHY it was"
    info "   non-zero — a lost response is the case this fix exists for, not the only one it admits."
    # ⛔ THE READ'S OWN WORDS, ON THE DIAGNOSTIC CHANNEL (#1690 review, round 4: a refusal
    # that cannot say WHAT it measured can only prescribe "re-run it"). Discarding this is
    # how a transient timeout and a permanent cause became the same sentence — and it is the
    # one thing that tells an operator whether the lost response was a blip or a config error.
    if [ -s "$TMP/merge.err" ]; then
      say_err "   gh pr merge said:"
      sed 's/^/      /' "$TMP/merge.err" >&2
    fi
  fi
}

# ⛔ ENTRY-POINT GUARD (#1690): the read path must be REACHABLE FROM A TEST.
# Without this a test cannot call the read path directly at all — it can only run the
# WHOLE rail through the hermetic fake-gh harness — so the empty-read branch, the one
# that blocked a healthy PR, had no test that could reach it. The guard changes nothing
# about `bash scripts/admin-merge.sh`.
#
# ⛔ KEEP THIS ON ONE LINE (#1690 review). `tests/admin-merge/run.sh` loads the rail's
# function definitions with `sed '$d'` — "the `main "$@"` entrypoint stripped". A
# three-line guard leaves that strip deleting only `fi` and producing an UNTERMINATED
# `if`, so the suite sources a file that does not parse.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
