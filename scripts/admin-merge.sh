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
#                    enough runs WITH a matching signature and the PR's failure
#                    RATE is not materially higher. The residual is the
#                    decision's BLOCKED ∪ UNATTRIBUTABLE set.
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
# flaked, the less the gate checked. Presence is never sufficient; only a
# measured RATE on both trees is. The module that makes that decision ships WITH
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
# CLASSIFICATION. RED = a completed check run whose conclusion is `failure`,
# `timed_out`, `action_required` or `startup_failure`; or a commit status whose
# state is `failure`/`error`. NOT red, by name: `success`; `neutral`; `skipped`
# (a path-gated job legitimately skips — agent-infra's own `python-ci / lint`
# skips); `cancelled` (a superseded run — `cancel-in-progress: true` is normal);
# and `stale`. A check still `queued`/`in_progress` is PENDING, never red: main
# always has something running, and refusing on that would block the fleet every
# time a post-merge run starts. The pending COUNT is printed, so an unmeasured
# surface is legible rather than silent.
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
# ON THE PR'S OWN TREE THAT FILTER IS VACUOUS — AND THAT IS THE POINT. A
# `schedule`/`issues` run executes against the DEFAULT BRANCH head, so it can
# never attach to a PR head sha: every red on the PR's surface is a
# `pull_request`/`pull_request_target`/`push` run, i.e. a lane that measures a
# revision, and it BLOCKS. The classifier is kept (shared code, and an
# unresolved event still fails closed) but it is EXPECTED to exclude nothing
# here; a non-code event appearing on a PR surface would itself be an anomaly.
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
# AN EMPTY SURFACE IS UNMEASURED, NOT GREEN, AND NOT A REFUSAL. Right after a
# merge, main's head has no check runs YET. Refusing there would block the common
# case, and the rail ALREADY refuses when the watched lane never tested main
# (precondition 3) — the lane-scoped half of "I did not look". So a zero-check
# surface prints UNMEASURED and proceeds; what it must never do is pretend the
# surface was read. An UNREADABLE probe (gh error, unparseable body) is a third
# thing again: that is the rail FAILING to look, and it REFUSES, by name.
#
# Usage:
#   scripts/admin-merge.sh <PR> [--main-runs N] [--repo owner/repo]
#                              [--workflow <file|name>] [--any-workflow]
#                              [--no-rerun] [--rerun-timeout S] [--dry-run]
#                              [-- <extra gh pr merge flags>]
#
#   --main-runs N        union over main's last N runs (default 10 — see the
#                        #3469 trap in ci-failure-set.sh; a single run is not a
#                        baseline)
#   --workflow <f>       the TEST lane both sides are read from (default
#                        `python-ci.yml`). NOT cosmetic: an unfiltered main
#                        window is dominated by cron/watchdog lanes and can
#                        contain ZERO test runs, so the baseline extracts EMPTY
#                        and every PR failure reads as new — the bogus zero. See
#                        THE BOGUS ZERO in ci-failure-set.sh.
#   --any-workflow       drop the lane filter (opt-out; re-opens the bogus zero)
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
#                        unique set then blocks immediately)
#   --print-bounds [<run-id>]
#                        print the re-run bound + per-shard table + source. With NO
#                        run id there is nothing to derive from, so this prints the
#                        FAIL-SAFE (3900s) and makes no gh call at all.
#   --dry-run            compute + print the decision; mutates nothing at all —
#                        no CI re-run, no comment, no merge. On the flake path it
#                        reports and exits 0 (it is an inspection, not a verdict;
#                        a real run would re-run and re-classify). Add --no-rerun
#                        to get the no-reclassification verdict as the exit code.
#   --repo owner/repo    repo for the gh calls
#   Extra flags (`--squash`, `--merge`, `--rebase`, `--delete-branch`, `--auto`,
#   …) are passed through to `gh pr merge` rather than hardcoded. `--admin` is
#   always added by this script; a caller-supplied `--admin` is dropped.
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
#   THE TWO WAITS ARE DIFFERENT, AND THEY READ DIFFERENTLY. Two independent
#   bounds gate a merge and must never be mistaken for one another (B7: an
#   operator raised --rerun-timeout and the rail exited INSTANTLY, because the
#   precondition gated first — an ambiguous message made it read as a fresh
#   failure):
#     * the LANE-TERMINAL PRECONDITION — the lane must have finished for the
#       head BEFORE any comparison happens. It REFUSES, naming itself:
#       `precondition unmet: run still in_progress — no classification
#       attempted`. `--rerun-timeout` does NOT apply and never started.
#     * the RE-RUN WAIT (`--rerun-timeout`) — a real wait, after a re-run, on a
#       run that is still RUNNING. A still-RUNNING job is not a failure while it
#       is inside its bound; the wait prints STILL-RUNNING progress, and its
#       bound is DERIVED PER SHARD from the run's own observed green durations —
#       never a global constant — with the derivation named in the message. The
#       SAME bound is the STALLED threshold: a remote run exposes no finer
#       activity signal, so "exceeded its own derived bound" IS the wedge signal
#       (an explicit `--rerun-timeout` is a CEILING instead — an operator's cap,
#       with the OPPOSITE remedy ordering: investigate vs wait).
#
#   A DRAFT IS REFUSED EARLY. `commit-workflow` opens drafts deliberately and
#   `gh` refuses to merge one ("Pull Request is still a draft"), so this is a
#   systematic collision. The rail reads `isDraft` BEFORE any CI work and
#   refuses with that specific reason (tell the caller to `gh pr ready`) — never
#   a generic merge failure after the evidence marker.
#
# Env seams (tests only):
#   ADMIN_MERGE_GH                       the gh command (default: `gh`)
#   ADMIN_MERGE_FAILURE_SET_SH           the parser (default: ./ci-failure-set.sh)
#   ADMIN_MERGE_POLL_INTERVAL            seconds between re-run polls (default 10)
#   ADMIN_MERGE_GREEN_RUNS               recent SUCCESSFUL runs sampled per shard
#                                         for the healthy duration (default 5)
#   ADMIN_MERGE_RERUN_FLOOR              per-shard bound FLOOR (default 1200). A
#                                         floor only ever RAISES the bound, so it
#                                         cannot cause the false block the flat
#                                         no-progress window did; it guards a
#                                         shard whose green sample is a single
#                                         short run.
#   ADMIN_MERGE_RERUN_TIMEOUT_FALLBACK   derivation fail-safe (default 3900)

set -uo pipefail

# File-scope so the EXIT trap can read it after `main` returns (P1-2).
TMP=""

GH="${ADMIN_MERGE_GH:-gh}"
# The jobs-JSON parse and the ISO-8601 age both need a real JSON/timestamp
# reader. python3 is already a hard dependency of this rail — ci-failure-set.sh
# routes its FAILED-id parsing through ci_exemption.py — so this adds no new
# dependency, and it is the portable reader (`date -d` is GNU-only).
if command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3; else PYTHON_BIN=python; fi
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFS="${ADMIN_MERGE_FAILURE_SET_SH:-$SELF_DIR/ci-failure-set.sh}"
EXEMPTION_PY="$SELF_DIR/ci_exemption.py"
POLL_INTERVAL="${ADMIN_MERGE_POLL_INTERVAL:-10}"

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

# The lane-run projection, mirrored from ci-failure-set.sh's LANE_RUN_JQ. Used
# ONLY to locate a PENDING run id for the lane-terminal diagnostic: the parser's
# provenance file records the FAILING runs, and a pending run has no conclusion,
# so its id never reaches that file.
LANE_RUN_JQ='.[] | "\(.status)\t\(.conclusion)\t\(.headSha):\(.databaseId)"'

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }
say_err() { printf '%s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

count_lines() { wc -l < "$1" | tr -d ' '; }

# report_value <report-file> <key> → the numeric value, or empty.
report_value() {
  [ -n "$1" ] && [ -r "$1" ] || { printf ''; return 0; }
  awk -F= -v k="$2" '$1 == k { print $2 }' "$1"
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
  [ "$bad" -eq 0 ] || { say_err "   These are operator knobs; fix the value and re-run the rail."; return 1; }
  return 0
}

resolve_head() {
  local pr="$1"; shift
  # shellcheck disable=SC2086
  $GH pr view "$pr" "$@" --json headRefOid --jq .headRefOid 2>/dev/null
}

# resolve_draft <pr> → the PR's `isDraft` flag (`true`/`false`). `commit-workflow`
# opens drafts on purpose, and `gh pr merge` refuses a draft with "Pull Request is
# still a draft" — so the rail probes this BEFORE any CI work and refuses early
# with THAT reason, rather than surfacing it late as a generic merge failure once
# the head-bound evidence marker has already been posted.
resolve_draft() {
  local pr="$1"; shift
  # shellcheck disable=SC2086
  $GH pr view "$pr" "$@" --json isDraft --jq .isDraft 2>/dev/null
}

# resolve_base_ref <pr> → the PR's TARGET branch (`baseRefName`). The base branch's
# head surface is measured for CONTEXT ONLY (it says whether main is currently
# red); the tree that GATES the merge is the PR's own evaluated tree (#1261).
# An unreadable or empty answer is not fatal — the caller defaults to `main`,
# which every repo in this fleet uses — but the root cause is that a PR can
# target a non-default branch, so the answer is preferred when it exists.
resolve_base_ref() {
  local pr="$1"; shift
  # shellcheck disable=SC2086
  $GH pr view "$pr" "$@" --json baseRefName --jq .baseRefName 2>/dev/null
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
# completes), so it is RE-POLLED a bounded number of times before giving up —
# the documented remedy, not a workaround. `MERGE_POLL_ATTEMPTS` is the bound;
# POLL_INTERVAL paces it (0 in the harness).
MERGE_POLL_ATTEMPTS="${ADMIN_MERGE_MERGE_POLL_ATTEMPTS:-3}"
resolve_merge_ref() {
  local pr="$1"
  local slug line attempt=0 state
  MERGE_REF_STATUS=""; MERGE_REF_SHA=""; MERGE_REF_SUMMARY=""
  if [ -n "${REPO:-}" ]; then slug="repos/$REPO"; else slug="repos/{owner}/{repo}"; fi
  while :; do
    # ONE call: mergeability and the merge ref sha together. `--jq` is real gh's
    # projection; the harness stub answers with the already-projected line.
    line="$($GH api "$slug/pulls/$pr" --jq '"\(.mergeable)" + "\t" + (.merge_commit_sha // "")' 2>/dev/null || true)"
    attempt=$((attempt + 1))
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
      *)
        # `null` (still computing) or an unrecognised token: re-poll while we can,
        # then give up LOUDLY. Never guess a tree.
        if [ "$attempt" -ge "$MERGE_POLL_ATTEMPTS" ]; then break; fi
        sleep "$POLL_INTERVAL"
        ;;
    esac
  done
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
      MERGE_REF_SUMMARY="ABSENT — GitHub has not computed mergeability/merge ref for PR #$pr (mergeable=$state after $attempt attempt(s)): no merge ref exists yet, so no CI has evaluated a merge of this PR"
      return 0 ;;
  esac
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
# rail's network surface (pending_run_id uses it); the jobs fetch is the Jobs API
# fetch_run_jobs already uses.
GREEN_RUNS="${ADMIN_MERGE_GREEN_RUNS:-5}"

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
    name = norm(job.get("name"))
    if not name:
        continue
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
        name = norm(job.get("name"))
        if not name:
            continue
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

# pending_run_id <head> — the first NON-COMPLETED lane run id for this head, or
# empty. Only the lane-terminal diagnostic needs it: the parser's provenance file
# records the FAILING runs, and a pending run has no conclusion, so its id never
# reaches that file.
pending_run_id() {
  local head="$1" line args=()
  [ -n "${REPO:-}" ] && args+=(--repo "$REPO")
  # ONLY gh-native flags. `--any-workflow` is the PARSER's opt-out: real gh
  # rejects it (`unknown flag`), and `2>/dev/null || true` hid that, so the
  # WAIT-vs-STALLED diagnostic was silently dead for the very invocation
  # commit-workflow's own docs prescribe.
  if [ "${ANY_WORKFLOW:-0}" -ne 1 ] && [ -n "${WORKFLOW:-}" ]; then
    args+=(--workflow "$WORKFLOW")
  fi
  # shellcheck disable=SC2086
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in completed$'\t'*) continue ;; esac
    printf '%s' "${line##*:}"
    return 0
  done < <($GH run list --commit "$head" --limit 100 \
      ${args[@]+"${args[@]}"} \
      --json databaseId,status,conclusion,headSha --jq "$LANE_RUN_JQ" 2>/dev/null || true)
  return 0
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
# only an event that MEASURES CODE blocks. On the PR's own tree that filter is
# VACUOUS (a cron run cannot attach to a PR head sha) and kept only because it is
# shared code and an unresolved red must still fail closed.
#
#   REPORT-ONLY (no code measured): schedule, issues, issue_comment.
#   BLOCKING (code health):         push, pull_request, pull_request_target,
#                                   merge_group, workflow_dispatch, and every
#                                   event NOT in the list above.
# That is a DENY-list of the observed non-code events, deliberately: an
# UNRECOGNISED event BLOCKS (fail closed). A red check whose run id cannot be
# resolved at all (a non-Actions app, or a run outside the map window) also
# BLOCKS — "I could not tell what this is" is not "this is noise".
#
# ONE `gh run list` resolves them all (id -> event, workflow name), so no single
# red costs an extra call, and it is fetched ONLY when a red exists. BOUNDED at
# 200 runs; the probed commit is the newest one, so its runs sit at the top. The
# listing is selected by branch for a branch ref and by --commit for a sha.
MAIN_HEALTH_RUN_MAP_LIMIT=200

# check_surface_probe <ref> <label> — measure EVERY workflow's check runs and
# commit statuses attached to <ref> (a branch name OR a sha), into the
# MAIN_HEALTH_* scratch set. The `label` names the surface in the summary lines,
# so a probe of the PR's evaluated tree never claims to be about main. Callers
# snapshot the scratch into their own prefix (BASE_* / TREE_*) immediately; see
# step 2c and step 4.5.
check_surface_probe() {
  local ref="$1" label="${2:-main}"
  local slug cr_json st_json map_file py_out sha rc=0 line tag job app concl url wf ev run_id ok_rest started_iso started_epoch
  local map_sel=()
  local blocking=0 other=0
  local repo_args=()
  [ -n "${REPO:-}" ] && repo_args=(--repo "$REPO")
  MAIN_HEALTH_STATUS=""
  MAIN_HEALTH_REF="$ref"
  MAIN_HEALTH_SHA=""
  MAIN_HEALTH_SUMMARY=""
  MAIN_HEALTH_REDS=""
  MAIN_HEALTH_REDS_OTHER=""
  # Structured BLOCKING reds, for the staleness comparison (step 4.6):
  # `<name>\t<started_iso>\t<started_epoch>\t<url>`, one per code-measuring red.
  MAIN_HEALTH_RED_TS=""
  # The surface's own last-production time (max completed_at over its completed
  # checks) and that time as epoch seconds. Empty when the surface has no
  # completed check at all.
  MAIN_HEALTH_MAX_COMPLETED=""
  MAIN_HEALTH_MAX_COMPLETED_EPOCH=""
  MAIN_HEALTH_TOTAL=0
  MAIN_HEALTH_RED=0
  MAIN_HEALTH_RED_OTHER=0
  MAIN_HEALTH_PENDING=0
  if [ -n "${REPO:-}" ]; then slug="repos/$REPO"; else slug="repos/{owner}/{repo}"; fi
  # The head SHA is for the RECORD: main moves, and the evidence must say which
  # commit was measured. Unresolvable is not fatal — a branch ref addresses
  # check-runs just as well — but it is then reported AS the ref, never as a sha.
  sha="$($GH api "$slug/commits/$ref" --jq .sha 2>/dev/null || true)"
  [ -n "$sha" ] && [ "$sha" != "null" ] || sha="$ref"
  MAIN_HEALTH_SHA="$sha"
  cr_json="$(mktemp "${TMPDIR:-/tmp}/admin-merge-checks.XXXXXX")"
  st_json="$(mktemp "${TMPDIR:-/tmp}/admin-merge-statuses.XXXXXX")"
  # BOTH surfaces must be READABLE. A gh failure here is the rail failing to
  # look, and "I did not look" is never green — the caller REFUSES. (An EMPTY
  # surface is a THIRD state: main's checks have not started. Also not green,
  # but not a refusal — see the header.)
  if ! $GH api "$slug/commits/$sha/check-runs?per_page=100" --paginate > "$cr_json" 2>/dev/null; then
    rm -f "$cr_json" "$st_json"
    MAIN_HEALTH_STATUS="unreadable"
    MAIN_HEALTH_SUMMARY="UNREADABLE — 'gh api .../check-runs' failed for '$ref' ($sha): the surface was never read"
    return 0
  fi
  if ! $GH api "$slug/commits/$sha/status" > "$st_json" 2>/dev/null; then
    rm -f "$cr_json" "$st_json"
    MAIN_HEALTH_STATUS="unreadable"
    MAIN_HEALTH_SUMMARY="UNREADABLE — 'gh api .../status' failed for '$ref' ($sha): the surface was only half read"
    return 0
  fi
  py_out="$("$PYTHON_BIN" -c 'import datetime, json, sys
RED_CONC = {"failure", "timed_out", "action_required", "startup_failure"}
RED_STATE = {"failure", "error"}

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
best = {}
for r in cr_runs:
    name = str(r.get("name") or "")
    if not name:
        continue
    app = str((r.get("app") or {}).get("slug") or "unknown")
    try:
        rid = int(r.get("id") or 0)
    except (TypeError, ValueError):
        rid = 0
    key = (app, name)
    if key not in best or rid > best[key][0]:
        best[key] = (rid, name, app, str(r.get("status") or ""), str(r.get("conclusion") or ""),
                     str(r.get("html_url") or ""), str(r.get("started_at") or ""),
                     str(r.get("completed_at") or ""))

statuses = []
for d in docs(sys.argv[2]):
    if isinstance(d, dict) and isinstance(d.get("statuses"), list):
        statuses.extend(x for x in d["statuses"] if isinstance(x, dict))

# Legacy commit statuses: latest per context. NOTE the combined-status body
# reports aggregate state "pending" when it carries ZERO statuses, so the
# aggregate is NEVER read here - only the per-context entries.
sbest = {}
for s in statuses:
    ctx = str(s.get("context") or "")
    if not ctx:
        continue
    stamp = str(s.get("updated_at") or s.get("created_at") or "")
    if ctx not in sbest or stamp > sbest[ctx][0]:
        sbest[ctx] = (stamp, ctx, str(s.get("state") or ""), str(s.get("target_url") or ""))

# THE SURFACE OWN TIME - the last moment ANY completed check on this surface
# was produced. The staleness rule compares a later base red against it: a red
# whose run STARTED after this time cannot be part of what the surface measured.
# Emitted for every probe; only the PR-tree call consumes it.
surface_epoch = 0
surface_iso = ""
reds = []   # (name, app, conclusion, url, started_iso)
pend = []
for _, name, app, status, concl, url, started, completed in best.values():
    if status != "completed":
        pend.append((name, app))
        continue
    e = ts_epoch(completed)
    if e != "" and (surface_iso == "" or int(e) > surface_epoch):
        surface_epoch, surface_iso = int(e), completed
    if concl in RED_CONC:
        reds.append((name, app, concl, url, started))
for stamp, ctx, state, url in sbest.values():
    if state in RED_STATE:
        reds.append((ctx, "commit-status", state, url, stamp))
    elif state == "pending":
        pend.append((ctx, "commit-status"))
    e = ts_epoch(stamp)
    if e != "" and (surface_iso == "" or int(e) > surface_epoch):
        surface_epoch, surface_iso = int(e), stamp

total = len(best) + len(sbest)
for name, app, concl, url, tiso in reds:
    sys.stdout.write("RED\t%s\t%s\t%s\t%s\t%s\t%s\n" % (name, app, concl, url, tiso, ts_epoch(tiso)))
for name, app in pend:
    sys.stdout.write("PENDING\t%s\t%s\n" % (name, app))
sys.stdout.write("SURFACE\t%s\t%s\n" % (surface_iso, ("" if surface_iso == "" else str(surface_epoch))))
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
      SURFACE$'\t'*)
        # The surface's own production time; consumed by the PR-tree probe in
        # step 4.6. A missing second field (the epoch) means "no completed
        # check", which the comparison treats as "no measurement time".
        IFS=$'\t' read -r tag MAIN_HEALTH_MAX_COMPLETED MAIN_HEALTH_MAX_COMPLETED_EPOCH <<< "$line"
        ;;
      RED$'\t'*)
        IFS=$'\t' read -r tag job app concl url started_iso started_epoch <<< "$line"
        # WHICH EVENT PRODUCED THIS CHECK? A red on a `schedule`/`issues` lane
        # measures no revision, and blocking on it would refuse every merge (see
        # MAIN_HEALTH_RUN_MAP_LIMIT). The run id is in the check run's own URL.
        run_id="$(printf '%s' "$url" | sed -n 's#.*/runs/\([0-9][0-9]*\).*#\1#p' | head -1)"
        wf=""; ev=""
        if [ -n "$run_id" ] && [ -s "$map_file" ]; then
          ev="$(awk -F'\t' -v id="$run_id" '$1 == id { print $2; exit }' "$map_file")"
          wf="$(awk -F'\t' -v id="$run_id" '$1 == id { print $3; exit }' "$map_file")"
        fi
        [ -n "$wf" ] || wf="(workflow unresolved)"
        case "$ev" in
          schedule|issues|issue_comment)
            [ -n "$MAIN_HEALTH_REDS_OTHER" ] && MAIN_HEALTH_REDS_OTHER="${MAIN_HEALTH_REDS_OTHER}"$'\n'
            MAIN_HEALTH_REDS_OTHER="${MAIN_HEALTH_REDS_OTHER}   • ${job} — workflow '${wf}' — event '${ev}' — ${concl} — NOT a code measurement, so NOT blocking — ${url}"
            other=$((other + 1))
            ;;
          *)
            [ -n "$MAIN_HEALTH_REDS" ] && MAIN_HEALTH_REDS="${MAIN_HEALTH_REDS}"$'\n'
            if [ -n "$ev" ]; then
              MAIN_HEALTH_REDS="${MAIN_HEALTH_REDS}   • ${job} — workflow '${wf}' — event '${ev}' — ${concl} — ${url}"
            else
              MAIN_HEALTH_REDS="${MAIN_HEALTH_REDS}   • ${job} — workflow '${wf}' — ${concl} — ${url}"
            fi
            # Keep the red's own START time for the staleness comparison: a red
            # whose run began after the PR's surface was produced cannot have
            # been measured by it (step 4.6).
            [ -n "$MAIN_HEALTH_RED_TS" ] && MAIN_HEALTH_RED_TS="${MAIN_HEALTH_RED_TS}"$'\n'
            MAIN_HEALTH_RED_TS="${MAIN_HEALTH_RED_TS}${job}"$'\t'"${started_iso}"$'\t'"${started_epoch}"$'\t'"${url}"
            blocking=$((blocking + 1))
            ;;
        esac
        ;;
    esac
  done <<< "$py_out"
  [ -n "$map_file" ] && rm -f "$map_file"
  if ! counter_is_number "$MAIN_HEALTH_TOTAL"; then
    MAIN_HEALTH_STATUS="unreadable"
    MAIN_HEALTH_SUMMARY="UNREADABLE — the check surface for '$ref' ($sha) produced unreadable counters"
    return 0
  fi
  # MAIN_HEALTH_RED is the BLOCKING count (code-measuring events), not the raw
  # red count: the raw count would refuse on a failing cron lane.
  MAIN_HEALTH_RED="$blocking"
  MAIN_HEALTH_RED_OTHER="$other"
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
  return 0
}

# wait_for_run <run-id> — poll until the run is `completed`.
#   return 0  completed.
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
# A still-RUNNING run prints progress (status, elapsed, bound, and the
# derivation) instead of a verdict — the old flat message read as a failure
# when it was only impatience (B5).
wait_for_run() {
  local run_id="$1" waited=0 unobs=0 observed=0 step status line
  # Wall-clock accounting must advance even when the test seam sets the interval
  # to 0 — a 0-step loop can never reach its own bound and spins forever.
  step="$POLL_INTERVAL"; [ "$step" -gt 0 ] 2>/dev/null || step=1
  while [ "$waited" -lt "$RERUN_TIMEOUT" ]; do
    # ONE gh call: the run's completion state. `updatedAt` is deliberately NOT
    # read. It advances on JOB/STEP TRANSITIONS, so it is frozen for the entire
    # duration of a single long step — a progress clock that cannot tick during
    # the very job it is supposed to be watching. Treating its freeze as "no
    # progress" is the false STALL this wait no longer reports.
    # shellcheck disable=SC2086
    line="$($GH run view "$run_id" ${repo_args[@]+"${repo_args[@]}"} \
      --json status --jq '.status' 2>/dev/null || true)"
    status="$line"
    [ "$status" = "completed" ] && return 0
    # "Could not read the run" is NOT "the run exceeded its bound". A gh failure
    # yields an empty status; counting that as progress-less made a transient
    # gh/auth/network outage report STALLED — a claim the code cannot support,
    # because it never read the run. The two faults have OPPOSITE remedies —
    # repair gh, vs escalate a wedged run — so they must not share a diagnosis.
    # Fail-closed either way: an unreadable run still blocks.
    if [ -z "$status" ] || [ "$status" = "unknown" ]; then
      unobs=$((unobs + 10#$step))
      sleep "$POLL_INTERVAL"; waited=$((waited + 10#$step)); continue
    fi
    observed=1; unobs=0
    info "admin-merge: … run $run_id STILL RUNNING (status=${status}, ${waited}s of the ${RERUN_TIMEOUT}s bound — ${RERUN_TIMEOUT_SOURCE}). A running job is not a failure — waiting."
    sleep "$POLL_INTERVAL"
    waited=$((waited + 10#$step))
  done
  # The bound elapsed. If the run was NEVER observed — unreadable for the whole
  # bound — this is not a stall claim: a stall is a claim about a run we watched.
  if [ "$observed" -eq 0 ] || [ "$unobs" -ge "$RERUN_TIMEOUT" ]; then
    return 3
  fi
  # PROVENANCE, not timing, decides the verdict: an explicit cap is a CEILING;
  # the derived per-shard bound is a STALL.
  [ "${RERUN_TIMEOUT_EXPLICIT:-0}" -eq 1 ] && return 2
  return 1
}

# print_bounds [<run-id>] — the re-run bound, its per-shard table (each figure
# carrying its n), and the source. `rerun-timeout=` stays the FIRST line:
# existing greps depend on the key, and it is also the STALLED threshold — there
# is ONE bound for a remote run (see wait_for_run). With NO run id there is
# nothing to derive from, so this is the one path that prints the fail-safe and
# makes no call.
print_bounds() {
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
  evidence_list "the $pr_count failure(s) this PR carries — all EXEMPT (measured on main with a matching signature and no worse rate)" \
    "$(cat "$pr_fails")" "(none — this PR carries no failure of its own)"
  evidence_list "main baseline: $main_count pre-existing failure(s), for comparison" \
    "$(cat "$main_fails")" "(none)"
  # THE VISIBLE EXEMPTIONS (#3756). An exemption that exists only as an absence
  # IS the fail-open defect, so every exempt id is printed with BOTH rates and
  # the reason the decision permitted it.
  evidence_list 'EXEMPT by the decision (visible — both rates, matching signature)' \
    "$exempt_raw" "(none — no failure was exempted)"
  # The PRE-rerun residual, when the flake path ran. Labelled for what it IS: it
  # is NOT the diff of the two sets above (those are POST-rerun), so it must not
  # be presented under a "must be empty" heading.
  if [ -n "$unique_raw" ]; then
    evidence_list 'residual BEFORE the flake re-run — reclassified as flaky, NOT new failures' \
      "$unique_raw" "(none)"
  fi
  evidence_list 'final residual (the exemption decision: BLOCKED ∪ UNATTRIBUTABLE) — must be empty' \
    "$final_unique_raw" "(empty — the decision exempts every failure this PR carries)"
  printf '\nLists show at most %s entries of %s chars; the full sets are reproducible from the run ids above.\n' \
    "$EVIDENCE_ENTRIES" "$EVIDENCE_WIDTH"
  printf '%s\n' "$flake_line"
}

# attribute_residual <residual-file> <main-fails-file> — name WHY each residual
# failure is not in main's baseline. This IMPROVES the diagnosis of a refusal;
# it must never NARROW the refusal. Every caller blocks on a non-empty residual
# regardless of the label here, and there is deliberately NO waiver label
# (B1 asked for lane-matched attribution sufficient to CERTIFY; the answer is
# no — a gate cannot adjudicate causation, and accepting it once lets the next
# genuinely-new failure in that file ride the same argument).
#
#   measured on this lane, not present on main
#       main's baseline carries a failure in the SAME test file, so the lane is
#       demonstrably measuring that file and does not show this test red.
#   not measurable on this lane
#       main's baseline carries NO failure in that file. A FAILURE-ONLY baseline
#       cannot tell "green on main" from "never run on main", so absence is NOT
#       evidence of novelty — the rail must not call it "unique to this PR".
#       (B1: CI's docker lane reproduces ZERO occurrences of the embedded lane's
#       redislite/GRAPH.COPY race while the embedded lane reproduces it — the old
#       wording asserted uniqueness with nothing to compare against.)
attribute_residual() {
  local residual="$1" mainfails="$2" nodeid file main_files=""
  [ -s "$mainfails" ] && main_files="$(sed 's/::.*//' "$mainfails" | sort -u)"
  while IFS= read -r nodeid; do
    [ -n "$nodeid" ] || continue
    file="${nodeid%%::*}"
    if [ -n "$main_files" ] && grep -qxF -- "$file" <<<"$main_files"; then
      printf '   %s\n      -> measured on this lane, not present on main\n' "$nodeid"
    else
      printf '   %s\n      -> not measurable on this lane: main carries no failure in %s, so absence is NOT evidence of novelty\n' "$nodeid" "$file"
    fi
  done < "$residual"
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
            case "$1" in --merge|--rebase|--squash) MERGE_METHOD_SET=1 ;; esac
            MERGE_ARGS+=("$1"); shift
          done ;;
      --admin|--admin=true) shift ;;  # always added by this script
      -*) case "$1" in --merge|--rebase|--squash) MERGE_METHOD_SET=1 ;; esac
          MERGE_ARGS+=("$1"); shift ;;
      *)
        if [ -z "$PR" ]; then PR="$1"; else say_err "admin-merge: unexpected argument '$1'"; exit 2; fi
        shift ;;
    esac
  done

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
  trap 'rm -rf "${TMP:-}"' EXIT

  local head
  # shellcheck disable=SC2086
  head="$(resolve_head "$PR" ${repo_args[@]+"${repo_args[@]}"})"
  [ -n "$head" ] || { say_err "admin-merge: ✗ could not resolve the head of PR #$PR"; exit 1; }
  info "admin-merge: PR #$PR head $head"

  # ── 0. A DRAFT CANNOT BE MERGED — refuse EARLY, by name ──────────────────
  # gh refuses a draft with "Pull Request is still a draft", and commit-workflow
  # opens drafts deliberately, so this is a systematic collision, not an edge
  # case. Refuse BEFORE any CI work and with the SPECIFIC reason, rather than
  # letting it surface as a generic merge failure after the evidence marker was
  # posted. The rail does NOT silently ready the PR: a draft is a deliberate
  # review checkpoint, and clearing it is the author's act, not the rail's.
  local is_draft
  # shellcheck disable=SC2086
  is_draft="$(resolve_draft "$PR" ${repo_args[@]+"${repo_args[@]}"})"
  if [ "$is_draft" = "true" ]; then
    say_err "admin-merge: ✗ BLOCK — PR #$PR is a DRAFT, and gh refuses to merge a draft"
    say_err "   (\"Pull Request is still a draft\"). This is NOT a CI-failure verdict and NOT"
    say_err "   a merge failure: no comparison was run and no evidence was posted. A draft is a"
    say_err "   deliberate review checkpoint, so clearing it is the author's act, not the rail's."
    say_err "   Mark the PR ready and re-run:  gh pr ready $PR"
    exit 1
  fi

  # ── 1. the PR's failing set, with provenance for the flake re-run ────────
  # Selected by COMMIT, not by PR: the analyzed set must be provably the SHA the
  # evidence marker names. `--pr` would re-resolve the head internally, so a push
  # between the two resolutions could analyze one SHA and certify another (#P1).
  local pr_status=0
  run_failure_set --commit-rows "$head" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
    --provenance "$TMP/pr-runs.txt" --runs-report "$TMP/pr-report.txt" --per-run "$TMP/pr-per-run.txt" \
    > "$TMP/pr-rows.txt" || pr_status=$?
  if [ "$pr_status" -ne 0 ]; then
    say_err "admin-merge: ✗ BLOCK — could not extract the PR's failing set (parser exit $pr_status)."
    say_err "   Refusing to certify a comparison computed over an unreadable set."
    exit 1
  fi
  # The id set the evidence and the re-run loop use, derived from the ROWS the
  # decision consumes, so the two can never disagree about which ids exist.
  cut -f1 "$TMP/pr-rows.txt" 2>/dev/null | sort -u > "$TMP/pr-fails.txt"

  # ── 1b. THE HEAD MUST HAVE BEEN TESTED (review P0 #3) ────────────────────
  # `examined=0` is NOT the signal — a green lane legitimately has no failing
  # runs. The signal is `tested=0` (no run actually exercised this revision) or
  # `pending>0` (something has not finished). Either way an empty failing set
  # proves nothing, so the rail must not read it as "no unique failures".
  local pr_completed pr_tested pr_pending
  pr_completed="$(report_value "$TMP/pr-report.txt" completed)"
  pr_tested="$(report_value "$TMP/pr-report.txt" tested)"
  pr_pending="$(report_value "$TMP/pr-report.txt" pending)"

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
    else
      say_err "   the run report's 'pending' counter is unreadable ('${pr_pending:-}'), so the rail"
      say_err "   cannot show the lane finished (lane: $lane)."
    fi
    # ── WHICH WAIT IS THIS? BOTH waits must read differently (B7). One
    # `gh run view` call, ONLY here, on the pending run. This is the
    # LANE-TERMINAL PRECONDITION, not the re-run wait: the re-run wait has not
    # started, and its derived bound does not exist yet. So this claims NEITHER a
    # WAIT NOR a STALL — a stall is a claim that a run exceeded its own bound, and
    # no bound has been derived here. A remote run exposes no within-job activity
    # signal anyway (`updatedAt` is frozen for the whole of a single long step),
    # so the old "frozen clock ⇒ STALLED" reading here was the same false claim
    # this rail removed from wait_for_run. The parser COUNTS pending runs but does
    # not record their ids (a pending run has no conclusion), so the id is looked
    # up here; this is the failure path, so the extra list costs nothing.
    if counter_is_positive "$pr_pending"; then
      local pend_id="" vline="" vstatus=""
      pend_id="$(pending_run_id "$head")"
      if [ -n "$pend_id" ]; then
        # shellcheck disable=SC2086
        vline="$($GH run view "$pend_id" ${repo_args[@]+"${repo_args[@]}"} --json status --jq '.status' 2>/dev/null || true)"
        vstatus="$vline"
        if [ -n "$vstatus" ] && [ "$vstatus" != "completed" ]; then
          say_err "   the lane run $pend_id reports status=$vstatus — still running. A running job is not a failure, and this is NOT a stall claim: the re-run bound has not been DERIVED yet, so there is no bound for this run to have exceeded. This is the LANE-TERMINAL PRECONDITION, not the re-run wait."
        elif [ "$vstatus" = "completed" ]; then
          say_err "   the lane run $pend_id now reports status=completed — re-run the rail to re-list the lane."
        else
          say_err "   the lane run $pend_id could not be read (its status was not obtained) — check gh auth/network, then re-run. This is NOT a stall: a stall is a claim about a run we watched."
        fi
      fi
    fi
    say_err "   An unfinished lane yields an empty failing set, which proves nothing."
    say_err "   Wait for CI to complete, then re-run the rail."
    say_err "   This is the LANE-TERMINAL PRECONDITION, which gates BEFORE any comparison:"
    say_err "   --rerun-timeout never started and would not change this exit. The re-run"
    say_err "   wait is a DIFFERENT wait and names itself differently when it fires."
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
    # are the "ran but proved nothing" case the lines above already describe, and
    # calling them a main-only lane is simply false (VGATE, #1003).
    if counter_is_zero "$pr_completed" && counter_is_zero "$pr_pending"; then
      say_err "   The lane '$lane' has NO runs for this head at all — which is what a"
      say_err "   MAIN-ONLY lane looks like. If this repo splits its lanes by trigger,"
      say_err "   pick a lane that runs on pull requests."
    fi
    say_err "   Confirm the lane is the right one (--workflow) and that CI ran for this head."
    exit 1
  fi
  # ── 1c. EVERY FAILING RUN MUST BE ATTRIBUTED (cycle-3 review) ────────────
  # `examined` counts the lane's failing runs; `extracted` counts those whose log
  # yielded at least one `FAILED <nodeid>` line. A failing run that contributes
  # NOTHING leaves the residual UNKNOWN while the certificate would print
  # `PR failing: 0` for a lane that is RED — a FALSE certificate, the one severity
  # this rail exists to prevent (the cycle-3 repro: a head run failing with
  # `ImportError: no module named y` certified as zero-residual, and the rail
  # merged). A gate whose output authorises a bypass fails CLOSED here.
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
    say_err "   yielded NO parseable 'FAILED <nodeid>' line, so their failures are NOT in the"
    say_err "   set and 'blocked by the decision: 0' would be a false certificate (lane: $lane)."
    say_err "   Either the run failed outside the test step (fix it), or the log format moved"
    say_err "   and the parser needs updating. This is a refusal, not a comparison."
    exit 1
  fi

  info "admin-merge: lane finished for $head (${pr_tested} tested of ${pr_completed} completed run(s))"

  # ── 2. main's baseline: the RATE table and the SIGNATURE table ───────────
  # Both halves of ONE measurement. The rate table alone is not enough: an empty
  # `main_signatures` makes the decision's subset rule fail CLOSED and no failure
  # is ever exempt. Neither side is drawn from the repo being merged.
  local main_status=0
  run_failure_set --main-union-rates "$MAIN_RUNS" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
    --exclude "$head" --provenance "$TMP/main-runs.txt" --runs-report "$TMP/main-report.txt" \
    > "$TMP/main-rates.txt" || main_status=$?
  if [ "$main_status" -ne 0 ]; then
    say_err "admin-merge: ✗ BLOCK — could not extract main's rate table (parser exit $main_status)."
    say_err "   Refusing to certify a comparison computed over an unreadable baseline."
    exit 1
  fi
  local main_sig_status=0
  run_failure_set --main-union-signatures "$MAIN_RUNS" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
    --exclude "$head" \
    > "$TMP/main-signatures.txt" || main_sig_status=$?
  if [ "$main_sig_status" -ne 0 ]; then
    say_err "admin-merge: ✗ BLOCK — could not extract main's signature table (parser exit $main_sig_status)."
    say_err "   Without it every signature check fails closed; that is a refusal, not a green."
    exit 1
  fi
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
    say_err "   instead: add --any-workflow."
    exit 1
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
      say_err "   GitHub has not produced the merge ref yet, so no CI run has evaluated the"
      say_err "   merge of this PR into its base — measuring anything else would certify a tree"
      say_err "   that is not this merge. This is the fresh-PR race, not a failure: re-run the"
      say_err "   rail once the PR's checks have started. No evidence was posted."
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
  check_surface_probe "$base_ref" "the base branch '$base_ref'"
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
      info "admin-merge: base tree ('$base_ref') ${BASE_SUMMARY}" ;;
    unmeasured)
      info "admin-merge: ⚠️  base tree ('$base_ref') ${BASE_SUMMARY}" ;;
    red)
      info "admin-merge: ⚠️  base tree ('$base_ref') ${BASE_SUMMARY}"
      info "admin-merge:    NOT blocking — the base is context. The gate is the PR's OWN tree"
      info "admin-merge:    (step 4.5): a PR that repairs this red must still be able to land."
      printf '%s\n' "$BASE_REDS" | sed 's/^/      /' >&2 ;;
    unreadable)
      info "admin-merge: ⚠️  base tree ('$base_ref') ${BASE_SUMMARY}"
      info "admin-merge:    NOT blocking — this is context; the gate is the PR's own tree." ;;
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

  local flake_line="Flake classification: none needed (nothing blocked before the re-run)"
  local rerun_residual=0

  if [ "$unique_before" -gt 0 ]; then
    info "admin-merge: $unique_before failure(s) are blocked by the decision — re-run classification:"
    sed 's/^/   /' "$TMP/unique.txt"
    if [ "$NO_RERUN" -eq 1 ]; then
      say_err "admin-merge: ✗ BLOCK — failures are blocked by the decision and --no-rerun given. No merge."
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
      info "admin-merge: (dry-run) a real run would re-run the failing job(s) of this head once and re-classify them."
      info "admin-merge: (dry-run) --dry-run performs no CI re-run, posts no comment and merges nothing."
      info "admin-merge: (dry-run) decision: BLOCK unless the residual clears on retry. No merge."
      exit 0
    fi
    # Re-run every failing run of the PR head ONCE. A test that passes on retry
    # is order/timing flaky, not new — the #3469 shape (a sibling pair that
    # trips alternately on main) must not hard-block a safe merge.
    local run_line run_id wait_rc
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
      info "admin-merge: ↻ re-running failed jobs of run $run_id"
      # shellcheck disable=SC2086
      if ! $GH run rerun "$run_id" --failed ${repo_args[@]+"${repo_args[@]}"} >/dev/null 2>&1; then
        say_err "admin-merge: ✗ BLOCK — could not re-run $run_id (gh error). No merge."
        exit 1
      fi
      wait_for_run "$run_id"; wait_rc=$?
      if [ "$wait_rc" -eq 1 ]; then
        say_err "admin-merge: ✗ BLOCK — run $run_id STALLED: still non-completed at its DERIVED per-shard bound — ${RERUN_TIMEOUT_SOURCE}. A REMOTE run exposes no within-job activity signal (updatedAt advances only on job/step transitions, so one long step freezes it for the whole job), so exceeding the run's own green-derived bound is the only honest wedge signal: this run is either wedged or pathologically slower than its entire green population. No merge."
        exit 1
      fi
      if [ "$wait_rc" -eq 3 ]; then
        say_err "admin-merge: ✗ BLOCK — run $run_id UNOBSERVABLE: gh could not be read for the whole bound (${RERUN_TIMEOUT}s). This is NOT a stall — a stall is a claim about a run we watched, and this rail never saw the field. Remedy differs: check gh auth/network, then re-run. No merge."
        exit 1
      fi
      if [ "$wait_rc" -ne 0 ]; then
        say_err "admin-merge: ✗ BLOCK — run $run_id still RUNNING at the ${RERUN_TIMEOUT}s ceiling — ${RERUN_TIMEOUT_SOURCE}. Not a stall — this is an operator cap that was reached, not a claim that the run is wedged. No merge."
        exit 1
      fi
    done < "$TMP/pr-runs.txt"

    # The branch must not have moved during the re-run — evidence is bound to a
    # SHA, and a push invalidates it.
    local head_after
    # shellcheck disable=SC2086
    head_after="$(resolve_head "$PR" ${repo_args[@]+"${repo_args[@]}"})"
    if [ "$head_after" != "$head" ]; then
      say_err "admin-merge: ✗ BLOCK — head moved during re-run ($head → $head_after). Re-run the rail."
      exit 1
    fi

    local pr_status2=0
    run_failure_set --commit-rows "$head" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
      --runs-report "$TMP/pr-report2.txt" --per-run "$TMP/pr-per-run2.txt" \
      > "$TMP/pr-rows2.txt" || pr_status2=$?
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
    rerun_residual="$(count_lines "$TMP/unique2.txt")"

    if [ "$rerun_residual" -gt 0 ]; then
      say_err "admin-merge: ✗ BLOCK — $rerun_residual failure(s) SURVIVED the re-run:"
      # §33 (#1147): the REASON, not just the node id. An UNATTRIBUTABLE id (a rotating identity,
      # or one with no main-side measurement) is created with `blocked=True`, so its
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
      say_err "   measures this file and does not show this test red) from NOT-MEASURABLE"
      say_err "   (main's baseline carries no measurement of the file, so absence is NOT"
      say_err "   evidence of novelty). BOTH block; no label here clears a failure."
      say_err "   The exemption decision still refuses them — merge refused."
      exit 1
    fi
    cp "$TMP/pr-fails2.txt" "$TMP/pr-fails.txt"
    flake_line="Flake classification: $unique_before residual re-ran → all passed on retry (flaky, not new)"
    info "admin-merge: ✅ all $unique_before residual failure(s) passed on retry — flaky, not new"
  fi

  # ── 4. THE HEAD IS RE-RESOLVED IMMEDIATELY BEFORE THE EVIDENCE (review P1) ─
  # This check used to live only inside the flake branch, so the common clean
  # path resolved the head once, posted evidence for that SHA, and then merged
  # whatever the head was by then. A rebase/update-branch in that window merged
  # an unanalyzed head behind SHA-bound evidence. Now it runs unconditionally —
  # and GitHub is asked to enforce it too, via --match-head-commit below.
  local head_final
  # shellcheck disable=SC2086
  head_final="$(resolve_head "$PR" ${repo_args[@]+"${repo_args[@]}"})"
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
  local TREE_STATUS TREE_SUMMARY TREE_REDS TREE_REDS_OTHER TREE_TOTAL TREE_RED TREE_RED_OTHER TREE_PENDING TREE_REF TREE_SHA TREE_MAX_COMPLETED TREE_MAX_COMPLETED_EPOCH
  check_surface_probe "$head" "the PR's evaluated tree (head $head)"
  TREE_STATUS="$MAIN_HEALTH_STATUS"; TREE_SUMMARY="$MAIN_HEALTH_SUMMARY"
  TREE_REDS="$MAIN_HEALTH_REDS"; TREE_REDS_OTHER="$MAIN_HEALTH_REDS_OTHER"
  TREE_TOTAL="$MAIN_HEALTH_TOTAL"; TREE_RED="$MAIN_HEALTH_RED"; TREE_RED_OTHER="$MAIN_HEALTH_RED_OTHER"
  TREE_PENDING="$MAIN_HEALTH_PENDING"; TREE_REF="$MAIN_HEALTH_REF"; TREE_SHA="$MAIN_HEALTH_SHA"
  # The PR surface's own production time — the anchor step 4.6 compares a base
  # red against. Empty means the surface has produced no completed check at all.
  TREE_MAX_COMPLETED="$MAIN_HEALTH_MAX_COMPLETED"
  TREE_MAX_COMPLETED_EPOCH="$MAIN_HEALTH_MAX_COMPLETED_EPOCH"
  case "$TREE_STATUS" in
    green)
      info "admin-merge: ✅ evaluated tree ${TREE_SUMMARY}" ;;
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
  # WHAT IT DOES NOT FIX, STATED: a base red whose run started BEFORE the surface
  # was produced but on a base the surface did not actually use (the merge ref can
  # lag the base) is not caught here; the merge-ref base parent is the other
  # signal, tracked as a residual rather than pretended away.
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
      # No completed check on the PR surface: there is no measurement time to
      # compare against, so the rail cannot show this PR measured the base's red.
      stale_any=1
      stale_reds="   • the PR's evaluated surface has produced NO completed check run, so it has no time to compare against the base's red(s)"$'\n'
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
      say_err "   RE-MEASURE against the current base, then re-run the rail: re-run this PR's checks"
      say_err "   ('gh run rerun' the PR's runs, or push an empty commit) so the merge-ref"
      say_err "   evaluation covers the base's red. If this PR is the REPAIR, its own checks pass"
      say_err "   on the re-measured tree and the merge then proceeds."
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
  analyzed="$analyzed
$health_line"

  # A vacuous comparison is STATED, never implied. Both sides empty is usually a
  # correct outcome (the lane is green on both sides) — but it is also exactly
  # what a WRONG lane selector looks like, so the two must be distinguishable by
  # a reader of the evidence. See the bogus-zero trap in ci-failure-set.sh.
  #
  # #1261 — AND THE MESSAGE MUST SAY WHICH SET WAS MEASURED AND WHY IT IS EMPTY.
  # "no failing runs" and "I did not look" are different facts, and the old line
  # ("nothing was compared") left both behind one glyph. A failing run whose log
  # yielded no parseable 'FAILED <nodeid>' line already BLOCKS on the PR side
  # (step 1c), and a lane that never TESTED main already BLOCKS (step 2b) — so an
  # empty set HERE is one of exactly two things, and each is named per side.
  if [ "$pr_count" -eq 0 ] && [ "$main_count" -eq 0 ]; then
    analyzed="$analyzed
⚠️ vacuous comparison — no failure was compared, because NEITHER measured set carried one.
   measured sets: PR failing runs=0 | main failing runs=0 (lane: $lane)
   PR side: ${pr_examined:-0} failing run(s) of ${pr_completed:-0} completed / ${pr_tested:-0} tested for head $head (${pr_pending:-0} pending). EMPTY because nothing FAILED — a failing run whose log yielded no parseable 'FAILED <nodeid>' line would have BLOCKED at step 1c, not read as zero.
   main side: $(report_value "$TMP/main-report.txt" examined) failing run(s) of ${main_completed:-0} completed / ${main_tested:-0} tested over the window ($MAIN_RUNS run(s) requested). EMPTY because the lane is GREEN over that window — NOT because main has no run (a lane that never tested main BLOCKS at step 2b).
   main check surface: $BASE_STATUS — $BASE_RED failing of $BASE_TOTAL measured, $BASE_PENDING pending; read across EVERY workflow, not just this lane. CONTEXT ONLY: it never blocks (a PR that repairs a red base must still land).
   PR evaluated tree: $TREE_STATUS — $TREE_RED failing of $TREE_TOTAL measured, $TREE_PENDING pending; read from the HEAD commit, where GitHub reports the merge-ref evaluation, across EVERY workflow. THIS is the surface that gates the merge.
   Correct when the lane is green on both sides — but if the lane selector (--workflow '$lane') is wrong this certifies nothing. The per-side counters above are what tell 'green' from 'never run'."
    info "admin-merge: ⚠️  vacuous comparison — measured sets: PR failing=0 | main failing=0 (lane: $lane); PR tree: $TREE_STATUS ($TREE_RED failing of $TREE_TOTAL measured); main check surface: $BASE_STATUS ($BASE_RED failing of $BASE_TOTAL measured, context only)"
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
  build_evidence "$head" "$TMP/main-runs.txt" "$pr_count" "$main_count" \
    "$(cat "$TMP/unique.txt")" "$flake_line" "$analyzed" "$lane" \
    "$TMP/pr-fails.txt" "$TMP/main-fails.txt" "$(cat "$final_unique")" \
    "$(cat "$final_exempt" 2>/dev/null || true)" > "$TMP/evidence.md"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "admin-merge: --dry-run — evidence that WOULD be posted:"
    cat "$TMP/evidence.md"
    info "admin-merge: (dry-run) no comment posted, no merge"
    exit 0
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
  if [ "$merge_status" -ne 0 ]; then
    say_err "⛔ admin-merge: FAILED — the merge of PR #$PR did NOT happen (gh pr merge exit $merge_status)."
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
    # CORRECT THE MARKER. A posted marker must never be left standing over an
    # unmerged PR, so a head-bound RETRACTION is posted (best effort) stating that
    # the merge FAILED and the evidence above is not a successful merge. The
    # retraction is deliberately NOT a certificate — it carries no
    # `unique to this PR: 0` line — so the merge gate will not accept it in place
    # of the evidence.
    {
      printf '<!-- admin-merge-retraction: %s -->\n' "$head"
      printf '⚠️ RETRACTED — the admin merge of head `%s` FAILED and did NOT happen.\n\n' "$head"
      printf 'The evidence comment above (`admin-merge-safety: %s`) records that the safety\n' "$head"
      printf 'comparison passed and the evidence was posted. It does NOT mean this PR merged:\n'
      printf '`gh pr merge` exited %s after that marker was posted.\n\n' "$merge_status"
      if [ -s "$TMP/merge.err" ]; then
        printf 'gh pr merge said:\n\n'
        # Indented, never fenced: this body is machine-read too, and a fence is a
        # parser with state.
        sed 's/^/    /' "$TMP/merge.err"
        printf '\n'
      fi
      printf 'Re-run the rail once the cause is fixed; the evidence above is still head-bound to `%s`.\n' "$head"
    } > "$TMP/retraction.md"
    # shellcheck disable=SC2086
    if ! $GH pr comment "$PR" ${repo_args[@]+"${repo_args[@]}"} --body-file "$TMP/retraction.md" >/dev/null 2>&1; then
      say_err "   (could not post the retraction comment — the FAILED merge above still stands)"
    fi
    exit 1
  fi
  info "admin-merge: ✅ merged PR #$PR at $head"
}

main "$@"
