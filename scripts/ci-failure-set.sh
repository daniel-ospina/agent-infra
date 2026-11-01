#!/usr/bin/env bash
# ci-failure-set.sh — resolve a revision's failing test set (#930).
#
# ONE PARSER, TWO CONSUMERS. The pre-merge chokepoint (scripts/admin-merge.sh)
# and the post-merge detector (.github/workflows/admin-merge-detector.yml) must
# agree on what "a unique failure" means — if they are two implementations, they
# drift, and the pre-merge gate stops matching the post-merge alarm. Every
# consumer calls this script; nothing re-implements the parse.
#
# What it does:
#   1. lists the FAILING check runs for a selector (a PR head, a commit, or the
#      last N runs on main);
#   2. fetches each failing run's failed-step log (`gh run view --log-failed`);
#   3. extracts `FAILED <nodeid>` lines, attributable GUARD-STEP failures
#      (#4469 — a substantive GitHub Actions error annotation in a step the
#      RUNNER marked failed, when the run's ROOT failing step also yields an
#      identity and no step showed an UNCLASSIFIED pytest failure), the other
#      NON-NODEID families (#6798/#7131), JS/TS RUNNER aggregates, and
#      `check-pipeline-compliance.sh` gate failures (#1185 — `❌ [<letter>] …`,
#      keyed on the check letter plus the subject its first clause names), and
#      emits a sorted, unique, one-identity-per-line set.
#
# Guard-step and gate attribution exist so a non-pytest failure is COMPARED
# against main like a test nodeid instead of tripping the caller's fail-closed
# refusal. The refusal is
# NOT weakened: the runner's own `Process completed with exit code <N>.` is never
# an identity, an annotation from a step that did not fail the run is never one, a
# sibling annotation may not stand in for an unparseable ROOT failure, and a step
# showing pytest's `E   <exception>` output must yield a NODEID.
#
# Modes:
#   --pr <N>                  failing set of PR #N's head commit
#   --commit <sha>            failing set of a commit's runs
#   --main-union [N]          UNION of main's failing sets over the last N runs
#                             (default 10 — deliberately NOT a single run: a
#                             test that fails on main only in *some* runs, e.g.
#                             an order-dependent sibling pair, must still count
#                             as "already red on main". See the #3469 trap below.)
#   --diff <a> <b>            tests in file a not in file b (the `comm -23`
#                             comparison, shared by every consumer so the two
#                             sides cannot drift). RETAINED for the post-merge
#                             detector; the pre-merge rail's VERDICT is the
#                             exemption decision, not this subtraction (#3756).
#   --commit-rows <sha>       (#3756) the PR-side input for the exemption
#                             decision: `<nodeid>\t<failures>\t<runs>\t<signature>`
#                             over the commit's failing runs. `<failures>` is the
#                             number of the commit's runs in which the id failed,
#                             `<runs>` the number that actually exercised the suite.
#                             An id with no stable signature is still EMITTED (blank
#                             signature) so it cannot vanish from the decision —
#                             `decide()` fails it CLOSED. Emits NOTHING when no run
#                             exercised the suite (fail-closed).
#
# Options:
#   --exclude <sha>           (--main-union / --main-union-rates /
#                             --main-union-signatures) drop runs whose headSha is
#                             <sha> (full or short; matched against the run's headSha)
#
#   ⚠️ WHAT [N] MEANS IN THE TWO WIDENED MAIN MODES (#9689) — `--main-union-rates`
#   and `--main-union-signatures`, and NOT `--main-union` (see the next note). N is
#   a STARTING WIDTH, not the size of the window: the listing is widened (doubling,
#   bounded at 200 runs) until the window holds AT LEAST N runs that FINISHED A
#   MEASUREMENT — so the doubling can OVERSHOOT N — and it can also stop EARLY,
#   holding FEWER than N, when the listing is EMPTY, the history is exhausted
#   (`--limit 2 → 4 → 8` on a 3-run main where fewer than N runs measured: the
#   wider reads return no NEW run, so it stops at 8), or the 200-run bound is
#   reached. The window is therefore never pinned to N: ≥ N when the sufficiency
#   rule fires, < N on an early stop.
#   Without the widening, a `completed/cancelled` run that never expanded a job
#   spends one of the N, a push burst can spend all of them, and `tested=0` makes
#   admin-merge.sh report "the lane never TESTED main" about a main that simply had
#   not been READ deep enough. The widening says so on stderr.
#   `tested` in `--runs-report` is the COLLECTORS' count over that window, not the
#   criterion's: normally the two agree, but a `completed/failure|timed_out` whose
#   job list turns out EMPTY is counted by the criterion and DEBITED by `tested`
#   (#1482) — so `tested` can fall below N even when the window reached it, and a
#   window that measured nothing still blocks. That asymmetry is stated in full at
#   `list_main_baseline`.
#   --main-union-rates [N]    (#3756) per-id failure COUNTS over the main window
#                             widened TOWARD N MEASURED runs — it can OVERSHOOT N, and
#                             it can stop short of it; read "WHAT [N] MEANS" above:
#                             `<nodeid>\t<failures>\t<runs>`. The rate table the
#                             exemption decision consumes — a union cannot express
#                             `main 1/8` vs `PR 8/8`, which is why presence-based
#                             subtraction excused an eight-fold regression. Emits
#                             NOTHING when no run exercised the suite (fail-closed).
#   --main-union-signatures [N]
#                             (#3756) main's per-id stable SIGNATURE over the SAME
#                             widened window as --main-union-rates (identical early
#                             stops, so it can hold FEWER than N measured runs):
#                             `<nodeid>\t<signature>`. The rate table alone leaves
#                             `main_signatures` empty, so the decision's subset rule
#                             fails CLOSED and nothing is ever exempt; this is the
#                             other half of the same measurement.
#   ⚠️ `--main-union` is NOT widened, deliberately: it is the POST-merge detector's
#   window, which must read the width the merge was certified over rather than a
#   wider one. Its dilution residual is therefore unchanged, and it is stated (with
#   its direction) in the `list_main_baseline` block: over-alarm only, never a
#   false clean.
#   --per-run <file>          (--commit-rows) write one line per FAILING run with
#                             that run's failing ids, whitespace-separated — the
#                             per-run id sets `decide()` consumes for REQUIRED
#                             class E5 (a class red across runs with a MOVING id is
#                             UNATTRIBUTABLE, neither PR-unique nor exempt).
#   --repo <owner/repo>       repo for the gh calls (default: gh's own resolution)
#   --workflow <file|name>    restrict the run listing to ONE workflow (default
#                             `python-ci.yml`, or $CI_FAILURE_SET_WORKFLOW).
#                             See THE BOGUS ZERO below — this is not optional in
#                             a repo whose main also runs cron/watchdog lanes.
#   --any-workflow            drop the workflow filter (opt-out; re-opens the
#                             bogus zero — use only when the test lane is the
#                             repo's only failing surface)
#   --provenance <file>       write the examined failing runs as `<sha>:<run-id>`
#   --unattributed <file>     (#2610, --commit-rows) write ONLY the examined failing
#                             runs that yielded NO identity, in the same
#                             `<sha>:<run-id>` form. `--provenance` is every run the
#                             collector LOOKED AT; this is the subset it could not
#                             attribute — and it is written HERE because this is the
#                             function that decides `extracted`. A caller deriving that
#                             subset from `--provenance` would be re-running the parse,
#                             and would label every run that DID yield ids as
#                             unattributable.
#   --runs-report <file>      write `examined=` / `extracted=` / `completed=` /
#                             `tested=` / `pending=` counts for the lane runs.
#                             ⛔ WRITTEN ON BOTH EXITS (#2569): a capture that
#                             fails closed AFTER reading its window still writes
#                             these counters plus `unreadable=log:<run-id>`, so a
#                             refusal can name a MEASURED window instead of
#                             reading like an empty one. A capture whose LISTING
#                             failed writes NO report — a window that was never
#                             listed must not be readable as a baseline, and the
#                             report's ABSENCE is what tells the rail the window
#                             itself could not be read.
#
# --exclude MATCHES the run's headSha, whatever the projection looks like. It is
# compared against the PARSED sha field, never a blind awk `$1` — the listing's
# own column layout must not be able to silently disable it (review P0, cycle 2).
# The PARSING is still positional (`$3`, split on `:`), so a future projection
# change must update this too; that is why it is done in one place, next to the
# projection it reads.
#   --help
#
# Exit codes:
#   0  extracted (the set may legitimately be EMPTY — no failing runs, or
#      failing runs whose failures carry no parseable identity: none of a
#      `FAILED <nodeid>` line, an attributable guard-step annotation, or a
#      `❌ [<letter>]` gate line)
#   1  the extraction itself failed (gh error, unreadable log) — the caller MUST
#      treat this as "cannot certify", never as "no unique failures". A rail
#      that reads an extraction error as an empty set is vacuously green.
#   2  usage error
#
# WHY THIS IS NOT `comm` ON A SINGLE RUN (#3469):
#   tortoise #3469: raw `comm -23` reported 1 unique failure, true value 0.
#   `test_import_wrong_key_422` and `test_import_count_mismatch_422` share one
#   assertion; WHICH sibling trips depends on execution order, and main fails
#   each in different runs. A single-run main baseline sees only one of them, so
#   the other reads as "new" — and a literal "require `comm -23` empty" would
#   hard-block a safe merge. A gate that false-blocks once gets disabled, and
#   then we are back to a convention. Hence the union over the last N runs.
#
# THE BOGUS ZERO (the second trap this design exists to avoid):
#   `gh run list --branch main` returns whatever ran most, NOT the test lane.
#   tortoise main, measured 2026-09-13: of the last 30 runs on main, 11 were
#   `availability-watchdog`, 3 `Inbound relay`, 3 `redis-guard`, 3
#   `welcome-e2e-monitor`, 2 `registry-backup-cron` — and only 2 were `Python CI`.
#   So a window of the last 10 runs can contain ZERO test runs, the baseline
#   extracts EMPTY, and every failing test in the PR reads as NEW. That is a
#   vacuous baseline, and it false-blocks: the same failure mode as #3469, just
#   from the other side. Resolve the baseline from the TEST workflow.
#
#   The filter also applies to `--pr`/`--commit`: the PR side and the main side
#   must come from the SAME lane, or `comm -23` compares two different things.
#
# WHAT `--runs-report` MEANS (the completion doctrine):
#   examined   failing runs in the lane (the ones whose logs are parsed), AFTER
#              the supersede rule drops any failing run that a later successful
#              run of the same workflow replaced (#1358, see drop_superseded_runs
#              below — the SELECTION is corrected, so every counter reads it)
#   extracted  failing runs that yielded at least one failure identity — a
#              `FAILED <nodeid>` line OR (since #4469) an attributable guard-step
#              error annotation from the run's ROOT failing step, OR (since #1185)
#              a `check-pipeline-compliance.sh` `❌ [<letter>] …` gate line
#   completed  lane runs that FINISHED (any conclusion)
#   tested     of `completed`, the runs that actually EXERCISED the code:
#              `success`, `failure`, `timed_out`. NOT `cancelled`/`skipped`
#              (finished without running the suite) and NOT `startup_failure`
#              (the workflow never started — nothing ran at all).
#   pending    lane runs still queued/in-progress — MINUS a run GitHub never
#              EXPANDED into a job, i.e. one whose jobs API answers 0 (#1623; see
#              `run_is_unexpanded` and the discriminator in `collect_union`). Such
#              a run is un-startable AND un-cancellable and persists, so counting
#              it would block a reviewed head forever. An UNREADABLE job count is
#              NOT zero, so this exception fails CLOSED — and a run that has merely
#              not expanded YET cannot enter `tested` either, so a listing holding
#              ONLY such runs is refused by the `tested > 0` precondition regardless.
#   `examined=0` is NOT a failure — a green lane legitimately has none. The
#   vacuity signal is `tested=0`: it means nothing about this revision was ever
#   exercised, so an empty failing set proves nothing. A failures-only
#   projection cannot express that, which is how a pre-CI merge certified an
#   empty set (review P0 #3). Consumers gate on `tested`/`pending`; see
#   scripts/admin-merge.sh.
#
#   FINISHED IS NOT TESTED (review P1, cycle 2): gating on `completed` alone let
#   a `cancelled` run — a `cancel-in-progress` supersede, or a cancelled CI —
#   satisfy the "this revision was tested" requirement. Both are terminal; only
#   one is evidence. A superseded run belongs to the OLD commit, so it cannot
#   satisfy the NEW head's `tested` count either — the fix is safe.
#
# THE MODULE IS RESOLVED FROM THE RAIL'S OWN DIRECTORY (#3756 defect 1 + the
# decision).
#   `ci_exemption.py`, shipped next to this script, holds BOTH halves: the ONE
#   definition of a failure KEY — a pytest nodeid OR (since #4469) an
#   attributable guard-step identity — and the signature/rate exemption decision
#   built on top of it. The id extraction routes through it (`ci_exemption.py
#   ids`) instead of a second shell regex, so the rail and the decision can
#   never disagree about the id universe — and a candidate that is NEITHER a test
#   nodeid NOR an attributable guard-step annotation is DROPPED, COUNTED and
#   REPORTED as UNATTRIBUTABLE rather than carried as a failure id (the `may`
#   leak: a garbage id can never match main, so it reads as "unique to this PR"
#   on every run, forever).
#
#   Signature extraction and the exemption decision are the SAME single
#   implementation (`ci_exemption.py signatures`, `ci_exemption.py decide`). It is
#   deliberately NOT read from the repo being merged: a grader drawn from the
#   graded system is a bypass — a PR could ship a `tools/ci_exemption.py` that
#   always reports CLEAN. A missing module is a LOUD REFUSAL (exit 1): never a
#   fallback to the presence-based subtraction (the category-A defect this fixes),
#   and never a fallback to a shell regex (how an unparseable token became a
#   failure id).
#
#   The parser half is the extractor authored on the rail-extractor side (#3756 /
#   PR #1165); the decision half is #1147, and it is built ON TOP of that parser —
#   never beside it. The rail's own suite drives both halves end to end.
#
# Env seams (tests only):
#   CI_FAILURE_SET_GH         the gh command to run (default: `gh`)
#   CI_FAILURE_SET_WORKFLOW   the workflow filter (default: `python-ci.yml`)
#   CI_FAILURE_SET_LOG_ATTEMPTS   attempts at a TRANSPORT-failed --log-failed
#                             fetch, including the first (default: 3, #1574)
#   CI_FAILURE_SET_LOG_BACKOFF_S  seconds of backoff before attempt N is
#                             `N-1` times this (default: 2 → 2s then 4s)

set -uo pipefail

GH="${CI_FAILURE_SET_GH:-gh}"
DEFAULT_MAIN_RUNS=10

# #1574 — A TRANSPORT-FAILED LOG FETCH IS RETRIED, A PRUNED LOG IS NOT.
# Measured on this defect, so the numbers are not a guess: one `--log-failed`
# fetch of a 27-job run takes ~2.3 s and returns ~620 KB, and a widened baseline
# pass fetches EVERY failing run in the window — the tortoise main window that hit
# the defect held 15 failed runs, so a single pass makes 15 separate log fetches
# and ANY ONE of them returning a transient error used to abort the whole rail
# (`BLOCK … could not extract main's rate table`) and cost that PR an hour
# (MERGE_RETRY_S=3600) with no defect in it.
#
# The retry is bounded and offline-safe: three attempts over ~6 s of backoff, and
# only on the branch that is NOT proven-absent. `log not found` never retries —
# that is GitHub saying the log does not exist, which the existing #7131
# discrimination turns into a job-level attribution, not a refusal.
LOG_FETCH_ATTEMPTS="${CI_FAILURE_SET_LOG_ATTEMPTS:-3}"
LOG_FETCH_BACKOFF_S="${CI_FAILURE_SET_LOG_BACKOFF_S:-2}"
case "$LOG_FETCH_ATTEMPTS" in ''|*[!0-9]*) LOG_FETCH_ATTEMPTS=3 ;; esac
[ "$LOG_FETCH_ATTEMPTS" -ge 1 ] || LOG_FETCH_ATTEMPTS=1
case "$LOG_FETCH_BACKOFF_S" in ''|*[!0-9]*) LOG_FETCH_BACKOFF_S=2 ;; esac
#: The largest window the #9689 widening may read — the same 200-run ceiling
#: admin-merge.sh applies to `--main-runs`, because every run in the window may
#: cost one Jobs API read and, when it FAILED, one failed-log fetch.
MAIN_RUNS_MAX=200
DEFAULT_WORKFLOW="python-ci.yml"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXEMPTION_PY="$SELF_DIR/ci_exemption.py"
if command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3; else PYTHON_BIN=python; fi

# Populated by main() before any selector runs. Bash locals are dynamically
# scoped, but these are deliberately global: every helper below (and every
# helper they call) must route --repo and --workflow identically, or one call
# site silently drops a flag — which is how the bogus zero happened the first
# time (--repo was accepted and then never forwarded to `gh run list`).
REPO_ARGS=()
WORKFLOW_ARGS=()

# A lane run. The projection is TAGGED rather than pre-filtered to failures so
# ONE listing answers two different questions: which runs failed, AND whether the
# lane has FINISHED. A failures-only projection cannot see a queued run at all —
# which is how the chokepoint certified an empty set and merged before CI had
# completed (the #3420 ratchet it exists to stop).
#
# `cancelled` is deliberately not a FAILURE (ci.yml uses `cancel-in-progress`, so
# a superseded run is cancelled, not red) — and it is not EVIDENCE either: it
# counts toward `completed` (the run is over) but never toward `tested` (the run
# exercised nothing) nor toward `examined` (it has no failing set).
# Byte-identical to admin-merge.sh's LANE_RUN_JQ by design; see the note there.
# This file splits the line with `${line%%$'\t'*}` / `${rest%%$'\t'*}` (literal TAB,
# no IFS, so an empty field is harmless here). admin-merge.sh splits it with
# `IFS=$'\t' read`, where an empty field collapses the delimiter and shifts the
# payload — which is why every field must be non-empty (#1368).
#
# The sentinel must not be a conclusion token: the `case "$conclusion"` statements in
# collect_union below credit `success|failure|timed_out` to `tested` and
# `failure|timed_out|startup_failure` to `examined`.
LANE_RUN_JQ='.[] | "\(.status)\t\(if (.conclusion // "") == "" then "-" else .conclusion end)\t\(.headSha):\(.databaseId)"'

#
# THE RAW PROJECTION (#1358). The canonical three fields — which ARE the whole of
# admin-merge.sh's mirrored `LANE_RUN_JQ`, so its coverage gate and the pending-run
# probe keep reading exactly what they always read — PLUS the identity fields the
# supersede rule needs: which workflow, and which event. `drop_superseded_runs`
# re-emits exactly those three fields, so no consumer of this script can observe
# the wider listing.
#
# NO CLOCK IS ASKED FOR, deliberately. `updatedAt` is frozen for the whole of a
# single long step, so this repo's tests forbid it as a liveness signal (§39/§40 in
# tests/admin-merge/run.sh) — and ordering does not need it either: a run's
# `databaseId` IS its creation order (#1358's own residual, stated there).
#
# ⛔ THE THREE IDENTITY FIELDS ARE BASE64-ENCODED, and that is a FAIL-CLOSED
# REQUIREMENT, not tidiness (adversarial cycle 1, 2026-09-23). A workflow's `name:`
# is AUTHOR-CONTROLLED free text, and YAML carries a literal NEWLINE happily in a
# double-quoted scalar. `gh --jq` interpolates that name RAW, so a run whose
# workflow name contains "…\npython-ci\t…\t<sha>:<huge id>\t…" SPLITS this
# projection into TWO records — and the tail is a syntactically perfect six-field
# line whose group key the AUTHOR chose. It then superseded the run's own red and
# the lane read `examined=0`: a fail-OPEN, the one direction this rule must never
# take. The `NF != 6` guard in drop_superseded_runs defends a TAB (one record with
# a bogus boundary); it CANNOT defend a NEWLINE, because awk's record separator has
# already split the input before the guard runs. A record separator that cannot be
# told from a field boundary is unreadable identity, exactly as a TAB inside a
# field is — so the fields that form the GROUP KEY are encoded into an alphabet
# that can contain neither. They are compared, never printed, so the encoding
# costs nothing and cannot drift from a human-readable form.
#
# The canonical three fields stay RAW, and deliberately: they are GitHub enums and
# a hex sha, with no free text among them — and they are what every consumer reads.
LANE_RUN_RAW_JQ='.[] | "\(.status)\t\(.conclusion)\t\(.headSha // ""):\(.databaseId // "")\t\((.workflowDatabaseId // "") | tostring | @base64)\t\((.workflowName // "") | @base64)\t\((.event // "") | @base64)"'

# ── drop_superseded_runs — THE SUPERSEDE RULE (#1358) ────
#
# A failing run that a LATER run of the SAME workflow, at the SAME commit, under
# the SAME event, replaced is NOT a failing run. Without this, a run re-run green
# on the same head left the old red in the failing set — and for a GATE failure,
# one whose log carries no `FAILED <nodeid>` line and so can never be attributed,
# that made `examined > extracted` and the rail REFUSED a head whose own surface
# was green. The only remedy left was `gh run delete`: destroying CI records to
# satisfy a stale reading (PR #1354; both counted runs are deleted and 404
# today). The check-surface path (admin-merge.sh step 4.5) has always applied the
# same idea — the latest check run per (app, name) decides — so this is the lane
# path agreeing with it, not a new concept.
#
# WHAT MAY SUPERSEDE: only `success`. `cancelled` (what `cancel-in-progress`
# produces), `skipped` (it exercised nothing), `neutral`, `failure` and
# `startup_failure` are all terminal, and none of them is evidence that the commit
# is green, so none may drop a red. Fail CLOSED: an over-block costs a re-run; the
# other direction merges a broken tree.
#
# "LATER" MEANS CREATED LATER: a run's `databaseId` increases with creation, so
# the highest id in a group is the group's newest run — the same notion step 4.5
# uses for the check surface (the latest check run per (app, name) decides).
#
# A STATED LIMIT, deliberately not closed: a run RE-RUN long after a NEWER run of
# the same workflow was created is the fresher measurement but not the higher id,
# so its green does not clear the newer run's red and the rail refuses. That is
# the fail-CLOSED direction — the operator's remedy is to re-run the newer run
# too — and the only field that would close it is a completion clock, which is
# exactly the signal this pair of scripts forbids (`updatedAt` is frozen for the
# whole of a long step; §39/§40 pin that it is never ASKED for). An over-block
# with a named remedy is acceptable; a clock-driven certificate is not.
#
# ⛔ A SECOND STATED LIMIT, and the sharper one: A SUCCESS THAT MEASURED NOTHING IS
# STILL A CERTIFICATE HERE. This rule reads a run LISTING; whether a run's jobs
# actually EXECUTED lives in its jobs, which this projection does not carry — so a
# `completed`+`success` run whose jobs were ALL SKIPPED still drops a red. That is
# reachable by a PR author without touching the commit or the event (the workflow
# file is theirs, and `github.run_attempt` increments on re-run, so a job gated
# `if: github.run_attempt == 1` is skipped on the re-run while the run concludes
# success). Adversarial cycle 2 reproduced it at the rule level (PR #1394) and it is
# filed as #1401 rather than fixed here: closing it needs a jobs call per candidate,
# which is a design decision — and the rail's own direction is that ONE measurement
# predicate governs every surface (#1319), so inventing a second one here would be
# the same mistake one level up. Until then, `success` at the same commit, workflow
# and event means green, WHATEVER IT MEASURED. Say it out loud; do not assume it.
#
# THE GROUP KEY is (sha, workflowDatabaseId, workflowName, event) — every part
# required. The commit alone would collapse main's window, which spans commits BY
# DESIGN (the union over the last N runs), and silently shrink the baseline; a
# shrunken baseline is what EXCUSES a genuinely new PR failure, so on main this
# rule closes a fail-open rather than opening one. The workflow NAME alone would
# let two different files both called "CI" clear each other, so the ID is required
# too. The event, because one commit is often both a PR head and pushed to a
# branch, and the lane's jobs are event-conditioned — a `push` run is not the same
# measurement as the `pull_request` run it would replace.
#
# AN UNREADABLE LINE FAILS CLOSED IN BOTH DIRECTIONS: it supersedes nothing and is
# never superseded, and the refusal to decide is SAID OUT LOUD on stderr — a
# SILENT assumption about identity is how this class of defect starts. Such a line
# is still COUNTED as a failing run (it is a run, and it is red); what it cannot be
# is a CERTIFICATE that the commit is green, in either direction. A line with
# FEWER THAN 6 fields is not from this lister's projection at all (a caller using
# the canonical shape, or a fixture written before the projection grew): it is
# RE-EMITTED in the canonical shape and never grouped, because the rule cannot
# invent an identity it was not handed. A BLANK line is not a run and is not
# emitted at all — an empty line can carry no measurement, and passing it through
# as `\t\t` would be counted as a PENDING run. The rule's own tests fail loudly if
# this projection ever loses a field, so that path cannot rot into a silent no-op.
#
# Input: the RAW projection, one run per line. Output: the CANONICAL
# `<status>\t<conclusion>\t<sha>:<id>` projection with superseded FAILING runs
# removed — so the counters, the provenance, the union, the rate table, the
# signature table and the per-run rotation input all see ONE selection, and
# nothing downstream needs to know this rule exists.
#
drop_superseded_runs() {
  awk -F'\t' -v OFS='\t' '
    function is_failing(c) { return (c == "failure" || c == "timed_out" || c == "startup_failure") }
    function blank(v) { return (v == "" || v == "null") }
    {
      # A blank line is not a run: emitting `\t\t` would be counted as PENDING.
      if (NF == 0) { empty[NR] = 1; next }
      # The re-emitted CONSUMPTION FORM must carry the same non-empty sentinel the
      # canonical projection uses (#1368): admin-merge.sh reads these rows with
      # `IFS=$'\t' read -r status conclusion id`, and TAB is IFS WHITESPACE, so an
      # empty conclusion collapses the delimiter and shifts `sha:id` into `id`,
      # which the listing guard reads as a REFUSED listing rather than a pending
      # run. A pending run has status!=completed and an EMPTY conclusion, so this
      # is the COMMON case, not an edge one — the raw projection may leave the
      # conclusion empty, but nothing downstream of this rule may.
      out[NR] = $1 OFS (blank($2) ? "-" : $2) OFS $3
      ref[NR] = $3
      concl[NR] = $2
      cand[NR] = 0
      # EXACTLY six fields, or the line is OPAQUE (kept, never grouped). `NF < 6`
      # was the first spelling and it was a FAIL-OPEN (code-review cycle 1,
      # 2026-09-23): a workflow NAME containing a literal TAB — a >6-field line —
      # left `$5`/`$6` holding a fragment of the name, so the group key silently
      # DID NOT CARRY THE EVENT, and a green run under a different event could
      # supersede a red while the disclosure insisted the event matched. A field
      # separator that cannot be told from a field boundary is unreadable
      # identity (the same class as an empty field), so it fails closed.
      if (NF != 6) {
        if (NF > 6) unreadwide[NR] = 1
        next
      }
      split($3, parts, ":")
      sha = parts[1]; id = parts[2]
      if (blank(sha) || blank(id) || id !~ /^[0-9]+$/ || blank($4) || blank($5) || blank($6)) {
        unread[NR] = 1
        next
      }
      cand[NR] = 1
      idof[NR] = id; shaof[NR] = sha
      k[NR] = sha SUBSEP $4 SUBSEP $5 SUBSEP $6
      # A SUPERSEDE CERTIFICATE is a run that FINISHED and succeeded. Requiring
      # `completed` as well as `success` keeps the premise of the certificate true
      # (a conclusion on a non-completed run is a contradiction the producer cannot
      # emit, and cycle 2 showed a synthetic `queued<TAB>success` line would
      # otherwise drop a red).
      if ($1 == "completed" && concl[NR] == "success" && (!(k[NR] in best) || id + 0 > best[k[NR]] + 0)) {
        best[k[NR]] = id + 0
        bestid[k[NR]] = id
      }
    }
    END {
      for (i = 1; i <= NR; i++) {
        if (empty[i]) continue
        if (unreadwide[i]) {
          printf "ci-failure-set: note: %s carries MORE than the six fields this projection defines (status, conclusion, sha:id, workflow id, workflow name, event), so a TAB inside a workflow NAME cannot be told from a field boundary — the run can neither supersede nor be superseded; kept as a FAILING RUN, and never read as a certificate that the commit is green (fail closed)\n", ref[i] > "/dev/stderr"
        }
        if (unread[i]) {
          printf "ci-failure-set: note: %s carries an unreadable workflow/event field, so it can neither supersede nor be superseded — kept as a FAILING RUN, and never read as a certificate that the commit is green (fail closed)\n", ref[i] > "/dev/stderr"
        }
        if (cand[i] && is_failing(concl[i]) && (k[i] in best) && (idof[i] + 0) < (best[k[i]] + 0)) {
          printf "ci-failure-set: note: run %s (at %s) concluded %s but was superseded by run %s, a LATER run of the SAME workflow at the same commit and event — NOT counted as a failing run\n", idof[i], shaof[i], concl[i], bestid[k[i]] > "/dev/stderr"
          continue
        }
        print out[i]
      }
    }'
}

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

say_err() { printf '%s\n' "$*" >&2; }

# ── selectors ─────────────────────────────────────────────

# list_lane_runs <flag> <value> <limit> → tagged `<status>\t<conclusion>\t<sha>:<id>`
# lines for the selector's runs IN THE LANE, with SUPERSEDED failing runs dropped
# (#1358). <flag> is `--commit` or `--branch`. Exits 1 when gh fails (fail-closed:
# an unreadable run list must never read as "nothing ran") — `pipefail` carries
# gh's exit status through the filter.
list_lane_runs() {
  local flag="$1" value="$2" limit="$3"
  # shellcheck disable=SC2086
  $GH run list "$flag" "$value" --limit "$limit" \
    ${WORKFLOW_ARGS[@]+"${WORKFLOW_ARGS[@]}"} ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} \
    --json databaseId,status,conclusion,headSha,workflowDatabaseId,workflowName,event \
    --jq "$LANE_RUN_RAW_JQ" | drop_superseded_runs
}

# ── #9689: THE MAIN-SIDE WINDOW COUNTS MEASUREMENTS, NOT RUN OBJECTS ──────────
#
# `--main-runs N` is a STARTING WIDTH, and it used to be applied to the RAW
# listing, so a run that measured NOTHING spent one of the N — and a push burst
# spends all of them at once. Measured on daniel-ospina/tortoise main
# (2026-10-23, default lane, default N=10): the 10 newest `python-ci.yml` runs
# were 1 queued + 9 `completed/cancelled`, each with ZERO jobs (GitHub keeps ONE
# pending run per concurrency group, so every new push to main cancels the
# pending one and it never expands). `tested=0` followed, and admin-merge.sh
# refused EVERY merge with "the lane never TESTED main, so there is no
# baseline" — a statement about the WINDOW, not about the lane: the same query
# read 20 runs wide found a measured run at position 14.
#
# So the listing WIDENS (doubling, bounded by $MAIN_RUNS_MAX) until the
# exclusion-filtered window holds AT LEAST the requested number of MEASURED runs
# (a doubling step may OVERSHOOT it), or the listing is empty, or the history is
# exhausted, or the bound is reached — an early stop can leave the window holding
# FEWER than requested. This is the rule the rail's lane-coverage gate already
# follows for its own reference window (#4844, #7734: "N is a STARTING WIDTH, not a
# stopping rule"); the baseline pass was the one place still reading N as a
# stopping rule.
#
# ⛔ THE WIDENING CRITERION IS NOT THE GATE. `measured_run_count` reads only the
# listing's status/conclusion, so it cannot see a run's JOBS — but it decides only
# whether to read MORE, never that a baseline exists. The gate stays
# `collect_union_rates`/`collect_union_signatures`'s own `tested` counter (#1482).
#
# WHERE THE TWO AGREE, and where they do NOT (this asymmetry is the whole risk, so
# it is stated precisely rather than waved at):
#   · on a `completed/success` run they AGREE. The collectors credit `tested` for a
#     success WITHOUT probing its jobs, so a zero-job success is credited by both.
#   · on a `completed/failure|timed_out` run with an EMPTY job list they CAN
#     DISAGREE: the collectors credit it, then take the credit BACK once the log
#     fetch reports zero jobs, while the criterion has already counted it. In that
#     shape the loop can stop one width EARLY, so the consequence is the SAME
#     over-block this change exists to remove, reappearing one widening short — and
#     never a false PASS: a window of zero-job failures still blocks, because the
#     gate is what blocks. A false PASS would need the criterion to be the gate,
#     and it is not.
#
# Why that residual is stated rather than fixed: making the criterion agree would
# mean paying a job read for EVERY failing run in EVERY window (or widening until a
# success appears, i.e. reading to the bound on any main that is currently red) —
# on every merge, for a shape whose frequency is unmeasured. Over-blocking one
# widening short is the cheap side of that trade, and it is visible: the block
# message carries `tested` and the announced widening widths.
#
# ⚠️ STATED RESIDUAL, `--any-workflow` (#9689 follow-up): the criterion counts a
# completed run of ANY workflow, exactly as the gate's `tested` credit does. So in
# the union mode a chatty non-test lane can fill the requested width and keep a
# test lane's deeper failures out of the baseline. Fixing that needs LANE
# ATTRIBUTION the union listing does not carry (the workflow column is dropped by
# `drop_superseded_runs`, and a trigger-split repo has no single lane name to
# attribute to), so it is a design question and NOT part of this window fix. The
# symptom this change does cure in that mode is the `completed=0, tested=0`
# reading, where the width is spent on runs that never expanded at all.
#
# ⚠️ STATED RESIDUAL, `--main-union` (NOT widened, deliberately): that mode feeds
# the POST-merge detector, whose window must be the width the merge was certified
# over — a wider one would move what the detector considers pre-existing. So it
# keeps the raw-width read (only its exclusion helper is shared), and its dilution
# residual is unchanged: a window spent on `completed/cancelled` runs leaves main's
# failing set EMPTY, so EVERY failure of the merged commit reads as UNIQUE. The
# direction is an OVER-alarm — a redundant alert, never a false clean — which is
# why it is left stated rather than fixed here.

# measured_run_count <lane-file> → how many listed runs FINISHED A MEASUREMENT
# (completed with conclusion success|failure|timed_out). A widening criterion
# only — see the block above.
measured_run_count() {
  awk -F'\t' '$1 == "completed" && ($2 == "success" || $2 == "failure" || $2 == "timed_out") { n++ } END { print n + 0 }' "$1"
}

# exclude_runs <in> <sha|''> <out> → the listing minus runs whose headSha IS
# <sha>, prefix-tolerant both ways (callers pass a full sha, the API may return
# either). A line whose sha is EMPTY is KEPT: dropping runs we cannot identify
# would shrink the baseline and manufacture "unique" failures.
#
# It reads the TAGGED projection's sha field ($3) — never a bare `$1`. `$1` of a
# `status<TAB>conclusion<TAB>sha:id` line is `status<TAB>conclusion<TAB>sha`, so a
# blind `-F: '$1 != x'` matches nothing and `--exclude` becomes a silent no-op:
# the merged commit's own run stays in main's baseline, its failures equal the
# PR's, and the post-merge detector can never fire (review P0, cycle 2). ONE
# implementation, because the pre-merge and post-merge paths must not disagree
# about what `--exclude` removed.
exclude_runs() {
  local in="$1" x="$2" out="$3"
  if [ -n "$x" ]; then
    awk -F'\t' -v x="$x" '
      {
        n = split($3, a, ":")
        sha = a[1]
        if (sha == "") print
        else if (sha != x && index(sha, x) != 1 && index(x, sha) != 1) print
      }' "$in" > "$out"
  else
    cp "$in" "$out"
  fi
}

# list_main_baseline <requested-width> <exclude> <raw-out> <filtered-out>
#
# Lists main's lane runs at <requested-width> and WIDENS it (doubling, bounded
# by $MAIN_RUNS_MAX) until the exclusion-filtered listing holds at least the
# requested number of MEASURED runs — overshooting it by up to a doubling step — or
# stops early (empty listing, exhausted history, the bound), holding FEWER. The
# ORDINARY case — a requested window that already holds that many — reads exactly
# ONE listing, byte-identical to before.
# Returns 1 when a listing read fails (fail-closed: an unreadable run list must
# never read as "nothing ran").
list_main_baseline() {
  local want="$1" exclude="$2" raw="$3" out="$4"
  local width="$want" measured=0 listed=0 prev=0 read_once=0
  while :; do
    list_lane_runs --branch main "$width" > "$raw" || return 1
    exclude_runs "$raw" "$exclude" "$out"
    measured="$(measured_run_count "$out")"
    listed="$(awk 'END { print NR + 0 }' "$raw")"
    [ "$measured" -ge "$want" ] && break
    # STOP when more width cannot help. An EMPTY listing stays empty at any
    # width — main has no run of this lane at all — so there is nothing to widen
    # into and the announcement below would be noise. The policy bound is the
    # other hard stop.
    [ "$listed" -eq 0 ] && break
    [ "$width" -ge "$MAIN_RUNS_MAX" ] && break
    # …and when the history is exhausted: this read listed no more runs than the
    # last one, so a wider window would re-read the same runs forever. This is
    # checked on the LISTING (post-supersede, pre-exclusion) rather than by
    # comparing `listed` to `width`, because `drop_superseded_runs` may legitimately
    # return fewer lines than the window asked for while the history goes on —
    # stopping there would under-widen and re-create the very false block this
    # fixes. The price is ONE LISTING READ PER DOUBLING STEP — two on a 3-run
    # history, up to the bound on a long one, not the single extra read an earlier
    # draft of this comment claimed — and that is the correct side of the trade: an
    # extra listing read costs time, a premature stop costs a blocked merge.
    { [ "$read_once" -gt 0 ] && [ "$listed" -le "$prev" ]; } && break
    read_once=1; prev="$listed"
    width=$((width * 2))
    [ "$width" -gt "$MAIN_RUNS_MAX" ] && width="$MAIN_RUNS_MAX"
    # NAME the numbers, not a cause: `listed` is counted BEFORE `--exclude` while
    # `measured` is counted AFTER it, so "the rest measured nothing" would be a
    # false statement on the ordinary rail path (which always excludes the PR's
    # own head run).
    say_err "ci-failure-set: · main's ${want}-run baseline window held ${measured} MEASURED run(s) of ${listed} listed — widening to ${width} (#9689)"
  done
  return 0
}

# extract_failed_tests <run-id> → sorted-unique nodeids, one per line.
# A failing run whose failed-step log cannot be fetched is an EXTRACTION
# FAILURE (exit 1), not an empty contribution: silently dropping it is exactly
# the vacuous pass this rail exists to prevent.
#
# ⚠ THE ONE EXCEPTION, and why it does not weaken the rule (#1482). A run with
# ZERO JOBS is not "an unreadable failure set" — it is an EMPTY one, by
# construction: there were no steps, so there is no failure for a log to reveal.
# `gh run view --log-failed` fails IDENTICALLY for that run and for a genuine
# transport error (both exit 1), so the log fetch alone cannot tell them apart —
# and treating the empty case as an extraction failure is what made the rail
# unusable for EVERY merge. See `run_job_count` for the discrimination.
#
# Return: 0 = extracted (ids on stdout, possibly none) · 1 = FAIL CLOSED ·
#         2 = the run has ZERO jobs and contributed NOTHING (not an error).
# Callers MUST handle 2 explicitly: it is the only status meaning "this run
# carried no evidence AND that is not a defect".
extract_failed_tests() {
  local run_id="$1" log_file rc
  log_file="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
  fetch_failed_log "$run_id" "$log_file"
  rc=$?
  case "$rc" in
    0) ;;
    2) rm -f "$log_file"; return 2 ;;
    # #7131: the log is PRUNED (not merely unreadable). Degrade to the job-level
    # identities the jobs API still serves. If even that fails, return 1 and the
    # caller refuses exactly as before.
    3) rm -f "$log_file"; run_failed_job_ids "$run_id"; return $? ;;
    *) rm -f "$log_file"; return 1 ;;
  esac
  failed_ids_from_log "$log_file" "$run_id"
  rc=$?
  rm -f "$log_file"
  return $rc
}

# run_job_count <run-id> → the run's job count on stdout; exit 1 when it cannot
# be established (unknown repo, API failure, or a non-numeric answer).
#
# `gh api` has NO `--repo` flag — it resolves `{owner}/{repo}` from the CURRENT
# DIRECTORY, which is the cross-repo false result of #4027 — so the path is
# built from the RESOLVED slug taken from `--repo`. When that slug is absent the
# count is NOT guessed: the helper fails, and the caller fail-closes exactly as
# it did before this change.
run_job_count() {
  local run_id="$1" count slug
  # Same slug resolution the rest of the rail uses (admin-merge.sh:900/961): the
  # RESOLVED slug when --repo was given, else gh's own `{owner}/{repo}`
  # placeholder, which gh resolves from the repository containing the CWD.
  # Returning early here instead made the exemption INERT for the documented
  # invocation (`admin-merge <PR> --squash`, no --repo), so the fleet-wide
  # #1482 block persisted on exactly the path the fleet uses (review P1, cycle 2).
  if [ -n "${repo:-}" ]; then slug="repos/$repo"; else slug="repos/{owner}/{repo}"; fi
  count="$($GH api "$slug/actions/runs/${run_id}/jobs" --jq '.total_count' 2>/dev/null)" || return 1
  case "$count" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$count"
}

# run_is_unexpanded <run-id> — true (exit 0) ONLY when the Jobs API PROVES the run
# has ZERO jobs, i.e. GitHub never expanded it runner-side (#1623).
#
# GitHub can leave a workflow run `queued` FOREVER without ever creating a job for
# it: measured on agent-infra PR #1615 at 194f1d83 — three runs reporting
# `status=queued`, `conclusion=null`, `run_attempt=1` whose jobs API answered
# `{"jobs":[]}`, while `POST /actions/runs/<id>/cancel` refused with "Cannot cancel
# a workflow run that has not been queued yet". There is no delete-run API, so such
# a run is un-startable AND un-cancellable AND persistent: counting it as `pending`
# blocks a reviewed head permanently, and the printed remedy ("wait for CI, then
# re-run the rail") can never clear it. A run that has exercised NO job is, by
# GitHub's own admission, not in flight.
#
# FAIL CLOSED ON THE PROBE. A count that cannot be ESTABLISHED is not zero — the
# same rule `fetch_failed_log` applies in its three-way branch — so a run whose
# count is unreadable stays `pending`. No new API path: the count is
# `run_job_count`'s, the Jobs API this file already reads for #1482 and for the
# per-shard bound. It is spent ONE per run that is not `completed`, so a listing
# whose runs have all finished (the ordinary merge path) costs NOTHING new.
#
# NO AGE BOUND, DECIDED DELIBERATELY. `jobs == 0` cannot by itself tell "not
# expanded YET" from "never will be", and a clock could: only a run older than the
# jobs-materialisation delay would be suppressed. It is not added, for two reasons.
# (a) It would not buy safety. A run with no jobs is not TESTING the revision, so
# it cannot enter `tested`; a listing whose only non-completed runs are unexpanded
# therefore has `tested=0` and is REFUSED by the `tested > 0` precondition in
# admin-merge.sh §1b and by `check-lane-tested.sh` at the detector — independently
# of this counter. That holds for the LANE-FILTERED listing. It is qualified under
# `--any-workflow`, where `tested` counts ANY workflow's completed run at the head:
# there a suppressed test-lane run can be paired with an unrelated green workflow,
# so suppression CAN be the thing that lets a merge proceed. The net is therefore
# `tested > 0`, not this counter — see the qualification at the `any_workflow`
# branch below.
# (b) The only clock reachable here is a run-listing `createdAt`, which this file's
# projection deliberately does not carry: the canonical three fields ARE the whole
# of admin-merge.sh's mirrored `LANE_RUN_JQ`, and `drop_superseded_runs` fails
# closed on any arity it does not recognise. Adding a field to serve one caller
# would re-shape a shared, adversarially-hardened listing.
# STATED RESIDUAL: a run created moments ago that has not yet materialised its jobs
# is omitted from `pending` for that window. It is never credited to `tested`, and
# when it is the listing's only run the head is refused as untested — which is the
# over-block this defect is about, in the opposite (safe) direction.
run_is_unexpanded() {
  local id="$1" jobs
  jobs="$(run_job_count "$id")" || return 1
  [ "$jobs" = "0" ]
}

# run_failed_job_ids <run-id> → `job-unreadable::<slug>` for every failed job of
# the run, one per line (#7131).
#
# THE FALLBACK SURFACE. When GitHub has pruned a failing run's log, the test-level
# identity is not recoverable from ANY surface — the check-run annotations carry
# only `Process completed with exit code N.`, which is explicitly never an
# identity (`_RUNNER_GENERIC_ANNOTATIONS`). What the jobs API still serves is the
# failed JOB NAMES, so the failure can be attributed at that granularity instead
# of being refused as unknowable.
#
# WHY THIS IS SAFE AND NOT A FAIL-OPEN: the keys this emits carry no signature
# anywhere, and the decision's signature gate fails CLOSED on an empty overlap.
# A job-level key therefore BLOCKS rather than exempts — it can only convert an
# unreadable refusal into a NAMED block, never buy a merge. Admission to the key
# universe is what matters (a rejected PR row makes `decide` see an EMPTY set and
# certify a red PR — the silent false PASS the #6798 pair of predicates exists to
# prevent), which is why `job-unreadable::` is enumerated in
# `ci_exemption.py`'s `_NON_NODEID_KEY_RE`, gating BOTH doors.
#
# Fail-closed: an API error, or a run whose failed-job list comes back empty, is
# return 1 — the caller then refuses exactly as it did before this change.
#
# The slug is `[A-Za-z0-9_.-]` (whitespace-free, matching `_GUARD_KEY_RE`'s
# charset) so the key survives the `uniq -c | awk` rate table, and it is a pure
# function of the JOB NAME so a PR and main slug the same job to the same key.
# Runs of punctuation collapse to ONE dash and the ends are trimmed, so the
# matrix job `test (d)` reads as `job-unreadable::test-d` rather than `test--d-`.
# Two distinct job names CAN collide after slugging (`test (d)` / `test-d`); that
# is harmless here because the key asserts only "a job with this slug failed",
# which is exactly the granularity the fallback claims.
run_failed_job_ids() {
  local run_id="$1" slug names out
  # Same slug resolution as run_job_count (`gh api` has no `--repo`; it resolves
  # from the CWD), so the fallback cannot silently read the wrong repository.
  if [ -n "${repo:-}" ]; then slug="repos/$repo"; else slug="repos/{owner}/{repo}"; fi
  names="$($GH api "$slug/actions/runs/${run_id}/jobs" --paginate \
    --jq '.jobs[] | select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="startup_failure") | .name' 2>/dev/null)" || return 1
  [ -n "$names" ] || return 1
  # ⛔ DEDUPE PER RUN — THIS IS LOAD-BEARING, NOT TIDINESS (review cycle 1, P0).
  # `collect_union_rows` counts LINES per id against `runs` = the run count, so a
  # second emission of the same key in ONE run yields `failures > runs`. Two
  # distinct job names CAN slug alike by design (the comment on the slug below
  # says so), and `parse_failure_rows` REJECTS a row whose failures exceed its
  # runs — a rejected row is not a block, it is an ABSENCE, so `decide` would see
  # an EMPTY set and emit CLEAN for a red PR. One run contributes each key at
  # most once, exactly as the log path's `sorted(set(ids))` does.
  out="$(printf '%s\n' "$names" | while IFS= read -r one; do
    local s
    s="$(printf '%s' "$one" | sed 's/[^A-Za-z0-9_.-]/-/g; s/--*/-/g; s/^-//; s/-$//')"
    [ -n "$s" ] && printf 'job-unreadable::%s\n' "$s"
  done | sort -u)"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# fetch_failed_log <run-id> <out-file> — the RAW `gh run view --log-failed`
# capture, for the callers that need the failure TEXT and not only the ids.
#
# Same fail-closed rule as extract_failed_tests: a transport error is a FAILURE,
# never an empty capture — an unreadable log must not read as "nothing failed"
# (#3705).
#
# Return: 0 = captured · 1 = FAIL CLOSED (unknowable) · 2 = ZERO-JOB run, which
# contributes NOTHING and is not an error (the only non-zero status a caller may
# treat as benign — see #1482) · 3 = the log is PROVEN ABSENT (GitHub pruned it),
# which is #7131: absence is still not an empty set, but it is not UNKNOWABLE
# either — the run can be attributed at JOB granularity, so the callers degrade
# instead of refusing.
#
# ⚠ THE 1-vs-3 SPLIT IS LOAD-BEARING. Only the DEFINITIVE `log not found` earns 3.
# A transport error (auth, network, rate limit) stays 1 and keeps its refusal,
# because for those the log may well exist and a retry can recover it — treating
# them as pruned would trade a recoverable refusal for a permanent one.
#
# ⛔ #1574 — THE RETRY ACTS ON THAT SPLIT, AND ONLY ON THAT SPLIT. A transport
# failure is retried $LOG_FETCH_ATTEMPTS times (with backoff), because the split
# above already ESTABLISHES that such a failure is recoverable; a PROVEN-ABSENT
# log is never retried, because no amount of waiting creates it. Exhaustion is
# unchanged: the refusal below still fires, so `unreadable ⇒ refuse` — which is
# what stops a clipped baseline certifying a comparison — is NOT weakened. The
# retry changes HOW LONG the rail tries to read, never WHETHER an unread read is
# allowed to certify anything.
#
# ⚠ ONE MESSAGE PER RUN, EMITTED AFTER the discrimination. Printing the refusal
# first and then the exemption made the rail say "the failure set is UNKNOWABLE,
# refusing" and "contributing an EMPTY set" about the SAME run — the exact
# ambiguity #1482 exists to remove (review cycle 1, P2).
#
# The message also names WHICH failure this is. "gh error" used to be printed for
# every non-zero exit, including `log not found`, pointing the reader at
# auth/network for a run whose logs GitHub had simply pruned — so the natural
# responses (re-auth, retry, wait out a rate limit) could not possibly work.
fetch_failed_log() {
  local run_id="$1" out="$2" err jobs attempt=1 retry_note
  while :; do
    # shellcheck disable=SC2086
    if err="$($GH run view "$run_id" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --log-failed 2>&1 > "$out")"; then
      if [ "$attempt" -gt 1 ]; then
        # NAME the recovery. A silent retry would hide a sick read surface for
        # exactly as long as it keeps happening to work, and the operator's next
        # question is always "was this baseline actually readable?".
        say_err "ci-failure-set: · run $run_id — the failed-step log fetch failed $((attempt - 1)) attempt(s) with a TRANSIENT error and SUCCEEDED on attempt $attempt of ${LOG_FETCH_ATTEMPTS}; the log was read, so this is not a refusal (#1574)"
      fi
      return 0
    fi
    # PROVEN ABSENT is not a transient: GitHub said the log does not exist, so a
    # retry cannot produce it. Break out and let the #7131 discrimination below
    # attribute the run at job level.
    case "$err" in *"log not found"*) break ;; esac
    [ "$attempt" -lt "$LOG_FETCH_ATTEMPTS" ] || break
    attempt=$((attempt + 1))
    [ "$LOG_FETCH_BACKOFF_S" -gt 0 ] && sleep $(( LOG_FETCH_BACKOFF_S * (attempt - 1) ))
  done
  # Discriminate BEFORE fail-closing. Only a run that HAS jobs can be hiding a
  # failure in an unreadable log; a run with none contributes nothing.
  if jobs="$(run_job_count "$run_id")" && [ "$jobs" = "0" ]; then
    say_err "ci-failure-set: · run $run_id has ZERO jobs — nothing could have failed; contributing NOTHING for it (not an extraction failure)"
    return 2
  fi
  # THREE-WAY, because the count is not always PROVEN at this point. The old
  # wording asserted "DOES have jobs" whenever the count was not exactly 0 —
  # including when `run_job_count` FAILED, i.e. when nothing was established.
  # Only a proven count may be stated as fact; an unknown one is named as
  # unknown, which is also the reason the refusal stands.
  case "${jobs:-}" in
    '') jobs_note="could not be established (the jobs API did not answer)" ;;
    *)  jobs_note="DID answer with $jobs job(s), so a failure could be hidden in it" ;;
  esac
  case "$err" in
    *"log not found"*)
      say_err "ci-failure-set: · run $run_id has NO LOG (GitHub pruned it); its job count $jobs_note — falling back to the JOB-LEVEL failure set (#7131): the test-level identity does not exist on any surface, so the run is attributed by failed JOB NAME and, carrying no signature, cannot be exempted"
      return 3 ;;
    *)
      # ⛔ THE REMEDY MUST BE TRUE. `CI_FAILURE_SET_LOG_ATTEMPTS=1` disables the
      # retry, and a message that still says "a transient error is retried" then
      # points the operator at a remedy that does not exist — the same misleading-
      # remediation class this function's #1482/#7131 messaging exists to prevent
      # (review cycle 1, P2). State which one applies.
      if [ "$LOG_FETCH_ATTEMPTS" -gt 1 ]; then
        retry_note="${attempt} attempt(s) made of ${LOG_FETCH_ATTEMPTS} — a TRANSIENT error is retried (#1574)"
      else
        retry_note="1 attempt made — the retry is DISABLED (CI_FAILURE_SET_LOG_ATTEMPTS=1), so no transient was outlasted"
      fi
      say_err "ci-failure-set: ✗ could not fetch the failed-step log for run $run_id (gh error; ${retry_note}); its job count $jobs_note — refusing to read this as an empty failing set" ;;
  esac
  return 1
}

# failed_ids_from_log <log-file> [<run-id>] → the ids, via THE canonical parser.
#
# #3756 DEFECT 1: this used to be a second `awk` regex that printed whatever
# token followed a bare `FAILED` field — including `may` from log prose. `may` is
# not a test id, so it matched nothing on main, could never be subtracted or
# verified, and read as "unique to this PR" on every rail run forever. The id
# extraction now goes through the SAME module that runs the decision
# (`ci_exemption.py ids`), so there is exactly ONE definition of "is this a test
# id"; a candidate that fails it is DROPPED, COUNTED and REPORTED as
# UNATTRIBUTABLE on stderr (fail-closed, #3705) — never carried, never read as
# "no failures".
failed_ids_from_log() {
  local log_file="$1" out rc run_label="${2:-}"
  require_exemption_module || return 1
  out="$("$PYTHON_BIN" "$EXEMPTION_PY" ids --log "$log_file")"
  rc=$?
  case "$rc" in
    0) ;;
    # ── #3174 — A TRUNCATED RUN IS NOT A FAILURE SET ─────────────────────────────────────────
    # `run-bash-shards.sh` prints `⚠️ RECAP INCOMPLETE (k/n shards ran)` when it is killed mid-list
    # (its TERM/INT trap), and `ci_exemption.py ids` answers that capture with this exit code and
    # NO ids. The answer is neither "no failures" nor a shorter set: it is UNPROVEN, and folding it
    # into the baseline is the defect this fixes. Measured on main 2026-10-31: three consecutive
    # runs named 13 / 11 / 10 failing shards, so the reference set every batch verdict subtracts was
    # SHRINKING as the job got slower — a shard red on main drops out, reappears as "a new failure
    # caused by the batch", and gets a constituent dropped or reverted on a false signal.
    #
    # ⛔ NOT A HARD FAILURE OF THE WHOLE CAPTURE. One killed run must not make the reference
    # uncomputable (#3131's baseline would become permanently UNPROVEN on a fleet where the shard
    # step is the slowest thing main runs) — so the collectors EXCLUDE this run from BOTH the
    # numerator and the denominator of the rate table and say so out loud, and only refuse the
    # capture when NO failing run in the window could be measured. See `collect_union_rates`.
    4)
      say_err "ci-failure-set: ⚠️ UNPROVEN: run-bash-shards.sh's recap in this capture${run_label:+ (run $run_label)} is INCOMPLETE — the step was TERMINATED before its list finished, so the failures it names are a TRUNCATED SAMPLE, not a set. This run is EXCLUDED from the baseline rather than folded into it (#3174): its missing shards are missing from the rate table, so treating it as a set would report a real failure on main as new."
      return 4 ;;
    *)
      say_err "ci-failure-set: ✗ FAILED-id extraction FAILED for $log_file — refusing to read it as an empty failure set"
      return 1 ;;
  esac
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# nodeid_is_shaped was REMOVED with the shell `awk` (#3756 defect 1): it was a
# SECOND definition of the id shape, and the refusal it powered (abort the whole
# extraction on one bad token) is precisely the permanent-false-refusal shape the
# canonical parser replaces with DROP + COUNT + REPORT.

# require_exemption_module — the one dependency, checked BEFORE any gh call so a
# broken install refuses immediately instead of after minutes of fetching.
require_exemption_module() {
  if [ ! -f "$EXEMPTION_PY" ]; then
    say_err "ci-failure-set: ✗ the exemption decision module is ABSENT at $EXEMPTION_PY"
    say_err "ci-failure-set: ✗ the id parser is ABSENT at $EXEMPTION_PY"
    say_err "   The rail refuses to fall back to presence-based subtraction (the #3756"
    say_err "   category-A defect)."
    say_err "   The rail refuses to fall back to a second shell regex (the #3756"
    say_err "   defect): that is how an unparseable token became a failure id."
    say_err "   Restore the agent-infra checkout; do not merge."
    return 1
  fi
  return 0
}

# extract_failed_signatures <log-file> → `<nodeid>\t<signature>` rows.
# The CANONICAL extractor — the same Python module that runs the decision — so
# main's signatures and the PR's cannot drift into two parsers. Fail-closed: a
# nonzero extractor exit is an EXTRACTION FAILURE, never an empty table.
extract_failed_signatures() {
  local log_file="$1" out
  require_exemption_module || return 1
  if ! out="$("$PYTHON_BIN" "$EXEMPTION_PY" signatures --log "$log_file" 2>/dev/null)"; then
    say_err "ci-failure-set: ✗ signature extraction FAILED for this run — refusing to read it as unsigned (an empty signature table would fail the decision closed, but the caller must see the refusal)"
    return 1
  fi
  printf '%s\n' "$out"
}

# ── modes ─────────────────────────────────────────────────

# write_runs_report <report> <examined> <extracted> <completed> <tested> <pending>
#                   [unreadable]
#
# ONE writer for the `--runs-report` file, called on BOTH exits (#2569).
#
# ⛔ WHY THE FAIL-CLOSED PATH WRITES IT TOO. Every collector used to write the
# report ONLY after its loop completed, so a capture that returned 1 wrote NO
# report at all — and the rail, which prints `parser exit 1`, then had no counts
# to say HOW FAR it got. Measured on the fleet's own refusals (2026-10-23):
# `BLOCK — could not extract main's rate table (parser exit 1)` was the only line
# an operator got, and it is the same line whether main was GREEN and the table
# legitimately empty, or a single `gh` log fetch died. Those are opposite claims
# and the evidence could not tell them apart. `unreadable=` is that missing
# fourth state, and `tested=`/`completed=` are the measurement it was missing.
#
# ⛔ WHAT `unreadable` MAY AND MAY NOT SAY. Two labels, because two different
# things can fail once the window HAS been listed, and an operator's remedy
# differs (re-fetch the log vs fix/move the parser):
#   `log:<run-id>`   — the run's failed-step LOG could not be FETCHED (checked at
#                      the `fetch_failed_log` status, so this label is not a guess).
#   `parse:<run-id>` — the run's log was read but no failure IDS could be
#                      extracted from it: a missing/updated id parser, a moved log
#                      format, or a job-level fallback that failed. This label also
#                      covers the composite extractor (`extract_failed_tests`),
#                      whose rc=1 does not say which of the two it was — claiming
#                      `log:` there would name a remedy that cannot work.
# Either label means the window was fully LISTED and partially measured, so the
# counters are a real partial measurement of a real window, and nothing downstream
# can mistake them for a shrunken baseline: the capture still exits 1, so no
# consumer reads a table from it. Neither is written when the LISTING fails: a
# window that was never listed has no counters to publish, and writing `tested=0`
# there would let a partial window be read as a baseline — the assertion at the end
# of `tests/admin-merge/run.sh` ("a failed widened listing still wrote a
# runs-report") pins exactly that.
write_runs_report() {
  local report="$1" examined="$2" extracted="$3" completed="$4" tested="$5" pending="$6" unreadable="${7:-}"
  [ -n "$report" ] || return 0
  {
    printf 'examined=%s\nextracted=%s\ncompleted=%s\ntested=%s\npending=%s\n' \
      "$examined" "$extracted" "$completed" "$tested" "$pending"
    if [ -n "$unreadable" ]; then
      printf 'unreadable=%s\n' "$unreadable"
    fi
  } > "$report" 2>/dev/null || {
    # ⛔ NOT SILENT (#2569 review). A swallowed write makes "the report is absent" —
    # which the rail reads as "the LISTING failed" — also reachable from an unwritable
    # path, i.e. a local disk problem would be reported as an unread GitHub listing
    # and send triage at the wrong system. Say it out loud instead.
    say_err "ci-failure-set: ✗ could not write the runs report at '$report' — the counters will not reach the caller"
  }
  return 0
}

# Sets a union of the FAILED nodeids across every FAILING run in <lane-file>,
# and counts the lane's completion state from the SAME listing. Also writes
# provenance/counts when requested. Returns 1 on extraction failure.
collect_union() {
  local lane_file="$1" provenance="$2" report="$3"
  local tmp_set="" examined=0 extracted=0 completed=0 tested=0 pending=0 credited=0 run_id line truncated=0 truncated_id=""
  tmp_set="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
  : > "$tmp_set"
  # The provenance file must exist even when NOTHING failed — callers build the
  # evidence from it (`tr < file`), and a missing file is an error, not an empty
  # baseline.
  [ -n "$provenance" ] && : > "$provenance"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local status rest conclusion runref
    status="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    conclusion="${rest%%$'\t'*}"
    runref="${rest#*$'\t'}"
    run_id="${runref##*:}"
    credited=0
    # Completion is counted for EVERY run, failures included: a queued run is
    # exactly what a failures-only listing cannot see.
    if [ "$status" = "completed" ]; then
      completed=$((completed + 1))
      # Terminal != exercised. `cancelled`/`skipped`/`neutral` finished without
      # running the suite, so they must not count toward "this revision was
      # tested" (review P1, cycle 2).
      case "$conclusion" in
        success|failure|timed_out) tested=$((tested + 1)); credited=1 ;;
      esac
    else
      # #1623 — AN UNEXPANDED RUN IS NOT IN FLIGHT. GitHub can leave a run
      # `queued` with no job EVER created; counting it as `pending` blocks a
      # reviewed head permanently (see `run_is_unexpanded`). An unreadable probe
      # or a count > 0 still counts as pending (fail closed). A RUN THAT HAS MERELY
      # NOT EXPANDED YET IS STILL SAFE: while it is not being expanded it is not
      # being tested either, so it cannot enter `tested`, and a listing that holds
      # ONLY such runs leaves `tested=0` — refused by the independent `tested > 0`
      # precondition here and by `check-lane-tested.sh` at the detector. This
      # counter is not the gate that proves a revision was exercised.
      if run_is_unexpanded "$run_id"; then
        say_err "ci-failure-set: · run $run_id is NOT completed but has ZERO jobs — GitHub never expanded it into a job, so it cannot still be running; NOT counted as pending (#1623)"
      else
        pending=$((pending + 1))
      fi
    fi
    case "$conclusion" in
      failure|timed_out|startup_failure) ;;
      *) continue ;;
    esac
    examined=$((examined + 1))
    printf '%s\n' "$runref" >> "${provenance:-/dev/null}"
    local one rc
    one="$(extract_failed_tests "$run_id")"
    rc=$?
    case "$rc" in
      0) ;;
      # #1482: a zero-job run was counted as `tested` by the completion block
      # above, but it exercised NOTHING. `tested` is documented as "every run
      # that actually exercised the revision" and is the main-side gate's signal,
      # so the credit is taken back rather than left to dilute the rate table.
      2) [ "$credited" = "1" ] && tested=$((tested - 1)); continue ;;
      # #3174: a TRUNCATED capture (the shard runner was killed mid-list) is not a
      # failure set — it is excluded from BOTH sides of every comparison, and the
      # credit is taken back for the same reason as the zero-job arm: the run did
      # not FINISH exercising the revision, so counting it as measured would make
      # the set it did not produce look like an empty one. `collect_union_truncated`
      # publishes the exclusion so it is loud, never a silent shrink.
      4) [ "$credited" = "1" ] && tested=$((tested - 1)); truncated=$((truncated + 1)); truncated_id="$run_id"; continue ;;
      # #2569: the counters reached so far are PUBLISHED before failing closed, so
      # the refusal can name a measured window instead of reading like an empty one.
      # `parse:` — `extract_failed_tests` is COMPOSITE (fetch, then ids, then a
      # job-level fallback for a pruned log), so its rc=1 does not say which step
      # failed; see `write_runs_report`.
      *) rm -f "$tmp_set"; write_runs_report "$report" "$examined" "$extracted" "$completed" "$tested" "$pending" "parse:$run_id"; return 1 ;;
    esac
    if [ -n "$one" ]; then
      extracted=$((extracted + 1))
      printf '%s\n' "$one" >> "$tmp_set"
    fi
  done < "$lane_file"
  write_runs_report "$report" "$examined" "$extracted" "$completed" "$tested" "$pending"
  collect_union_truncated "$truncated" "$examined" "$extracted" "$report" "$completed" "$tested" "$pending" "$truncated_id" || { rm -f "$tmp_set"; return 1; }
  sort -u "$tmp_set"
  rm -f "$tmp_set"
}

# collect_union_truncated <truncated> <examined> <extracted> <report> <completed> <tested>
#                        <pending> <last-truncated-run-id>
#
# The ONE report for a baseline that had to EXCLUDE truncated runs (#3174), shared by every collector
# so the message, the runs-report label and the refusal rule cannot drift between the union, the rate
# table, the signature table and the row door.
#
# TWO OUTCOMES, both loud:
#   * SOME failing run was measured → say how many were excluded and that the table covers the rest.
#     Continuing is deliberate: a killed main run must not make the reference UNCOMPUTABLE on a fleet
#     where the shard step is the slowest thing main runs — that is the same class of harm as the
#     fail-open in the other direction, one permanent UNPROVEN instead of one silent shrink.
#   * NO failing run in the window could be measured → REFUSE (rc 1) and RE-WRITE the runs-report
#     with `unreadable=truncated:<run-id>`. An empty table is not "main is green": `decide()` would
#     carry no base rows and every PR failure would block against an unmeasured reference — and the
#     label is what lets `admin-merge.sh` name THIS cause instead of falling through to its
#     "main's run LISTING could not be read" message, which is the opposite of what happened (the
#     window WAS listed; its failing runs were killed mid-list).
#
# ⛔ EVERY ARM THAT REFUSES MUST PUBLISH A LABEL. The refusal is `rc 1`; without a label the rail's
# `case "$main_unreadable"` falls into its `*)` arm and names a remedy that cannot work — the #2569
# "two opposite states, one message" defect, one state further out.
collect_union_truncated() {
  local truncated="$1" examined="$2" extracted="$3" report="${4:-}" completed="${5:-0}"
  local tested="${6:-0}" pending="${7:-0}" last_id="${8:-unknown}"
  [ "$truncated" -gt 0 ] || return 0
  say_err "ci-failure-set: ⚠️ UNPROVEN: $truncated of $examined examined failing run(s) were EXCLUDED from this baseline because scripts/run-bash-shards.sh's recap in them is INCOMPLETE (the step was killed mid-list, #3174). A truncated run's failure set is a SAMPLE, not a set — it contributed to NEITHER side of the comparison, because a shard missing from the reference comes back as a new failure caused by whatever is being compared."
  if [ "$examined" -gt 0 ] && [ "$extracted" -eq 0 ]; then
    # ⛔ THE CLAIM IS BUILT FROM THE COUNTERS, never from the guard (review of this change, P2).
    # `extracted == 0` also holds for a run whose log was READ and yielded no ids, so a message
    # saying "every examined run was truncated" would assert a cause its own predicate does not
    # establish.
    say_err "ci-failure-set: ✗ UNPROVEN: NO failing run in this window could be MEASURED — of $examined examined failing run(s), $truncated were excluded as TRUNCATED (recap INCOMPLETE) and $((examined - truncated)) yielded no failure identity. Refusing to publish a baseline (an empty table would read as 'nothing fails on main'). Remedy: read a window that contains a run whose shard step FINISHED — raise the requested width (e.g. --main-union-rates <N> / --main-runs <N>): the widening heuristic credits a completed/failure run as MEASURED without fetching its log, so a window made of killed runs satisfies it while proving nothing. This is a measurement failure, not a parser failure, so re-running the parser is not the fix."
    write_runs_report "$report" "$examined" "$extracted" "$completed" "$tested" "$pending" "truncated:$last_id"
    return 1
  fi
  say_err "ci-failure-set: · UNPROVEN-EXCLUDED: the table below covers the measured run(s) only; the excluded run(s) named above are NOT evidence that their unfinished shards were green."
  return 0
}

# #3756 — per-id failure COUNTS across a lane's runs, not a union.
#
# Emits `<nodeid>\t<failures>\t<runs>` where `runs` is the number of runs that
# actually EXERCISED the suite (the declared K for the rate comparison). This is
# what makes the exemption decision an EFFECT measurement instead of the presence
# question — the question that excused `main 1/8` against `PR 8/8`.
#
# Fail-closed (#3705): propagation follows `collect_union` exactly — an extraction
# failure returns 1 rather than emitting an empty set, because an unreadable
# baseline must never read as "no failures".
collect_union_rates() {
  local lane_file="$1" provenance="$2" report="$3"
  local tmp_all="" examined=0 extracted=0 completed=0 tested=0 pending=0 credited=0 run_id line truncated=0 truncated_id=""
  tmp_all="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
  : > "$tmp_all"
  [ -n "$provenance" ] && : > "$provenance"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local status rest conclusion runref
    status="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    conclusion="${rest%%$'\t'*}"
    runref="${rest#*$'\t'}"
    run_id="${runref##*:}"
    credited=0
    if [ "$status" = "completed" ]; then
      completed=$((completed + 1))
      case "$conclusion" in
        success|failure|timed_out) tested=$((tested + 1)); credited=1 ;;
      esac
    else
      # #1623 — an unexpanded run is not in flight; see `collect_union`.
      if run_is_unexpanded "$run_id"; then
        say_err "ci-failure-set: · run $run_id is NOT completed but has ZERO jobs — GitHub never expanded it into a job, so it cannot still be running; NOT counted as pending (#1623)"
      else
        pending=$((pending + 1))
      fi
    fi
    case "$conclusion" in
      failure|timed_out|startup_failure) ;;
      *) continue ;;
    esac
    examined=$((examined + 1))
    printf '%s\n' "$runref" >> "${provenance:-/dev/null}"
    local one rc
    one="$(extract_failed_tests "$run_id")"
    rc=$?
    case "$rc" in
      0) ;;
      2) [ "$credited" = "1" ] && tested=$((tested - 1)); continue ;;
      # #3174 — a TRUNCATED capture is excluded from BOTH sides of the rate table (see
      # `collect_union_truncated`): the numerator would otherwise be a sample of the run while the
      # denominator still counted it as a full measurement, which is exactly the "main 1/8 vs PR 8/8"
      # shape the rate comparison was built to see through.
      4) [ "$credited" = "1" ] && tested=$((tested - 1)); truncated=$((truncated + 1)); truncated_id="$run_id"; continue ;;
      # #2569: publish the partial counters before failing closed — see
      # `write_runs_report` for why this is not a shrunken baseline. `parse:`
      # because `extract_failed_tests` is composite (fetch, ids, pruned fallback).
      *) rm -f "$tmp_all"; write_runs_report "$report" "$examined" "$extracted" "$completed" "$tested" "$pending" "parse:$run_id"; return 1 ;;
    esac
    if [ -n "$one" ]; then
      extracted=$((extracted + 1))
      printf '%s\n' "$one" >> "$tmp_all"
    fi
  done < "$lane_file"
  write_runs_report "$report" "$examined" "$extracted" "$completed" "$tested" "$pending"
  collect_union_truncated "$truncated" "$examined" "$extracted" "$report" "$completed" "$tested" "$pending" "$truncated_id" || { rm -f "$tmp_all"; return 1; }
  # No tested runs -> emit NOTHING. An empty rate table must never be read as
  # "main never fails anything", which would exempt every PR failure.
  if [ "$tested" -gt 0 ]; then
    sort "$tmp_all" | uniq -c \
      | awk -v k="$tested" '{ c = $1; $1 = ""; sub(/^ +/, ""); print $0 "\t" c "\t" k }'
  fi
  rm -f "$tmp_all"
}

# #3756 — main's per-id STABLE SIGNATURE over a lane's failing runs.
# Emits `<nodeid>\t<signature>`, the table `decide(main_signatures=…)` consumes.
# Mirrors the rates collector's shape: only FAILING runs contribute, extraction
# failure returns 1, and nothing is emitted when no run exercised the suite.
collect_union_signatures() {
  local lane_file="$1" provenance="$2" report="$3"
  local tmp_sigs="" examined=0 extracted=0 completed=0 tested=0 pending=0 credited=0 run_id line truncated=0 truncated_id=""
  tmp_sigs="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
  : > "$tmp_sigs"
  [ -n "$provenance" ] && : > "$provenance"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local status rest conclusion runref log_file
    status="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    conclusion="${rest%%$'\t'*}"
    runref="${rest#*$'\t'}"
    run_id="${runref##*:}"
    credited=0
    if [ "$status" = "completed" ]; then
      completed=$((completed + 1))
      case "$conclusion" in success|failure|timed_out) tested=$((tested + 1)); credited=1 ;; esac
    else
      # #1623 — an unexpanded run is not in flight; see `collect_union`.
      if run_is_unexpanded "$run_id"; then
        say_err "ci-failure-set: · run $run_id is NOT completed but has ZERO jobs — GitHub never expanded it into a job, so it cannot still be running; NOT counted as pending (#1623)"
      else
        pending=$((pending + 1))
      fi
    fi
    case "$conclusion" in failure|timed_out|startup_failure) ;; *) continue ;; esac
    examined=$((examined + 1))
    printf '%s\n' "$runref" >> "${provenance:-/dev/null}"
    log_file="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
    fetch_failed_log "$run_id" "$log_file"
    local frc=$?
    if [ "$frc" -eq 2 ]; then
      # Zero-job run: contributes no ids AND no signature, and must not be
      # credited as having exercised the suite (#1482).
      [ "$credited" = "1" ] && tested=$((tested - 1))
      rm -f "$log_file"
      continue
    fi
    if [ "$frc" -eq 3 ]; then
      # #7131: the log is PRUNED — there is no capture to sign. The job-level
      # fallback deliberately emits NO signature (that is what keeps the key
      # fail-closed at the decision), so this door contributes nothing and must
      # not abort the collection.
      rm -f "$log_file"
      continue
    fi
    if [ "$frc" -ne 0 ]; then
      # #2569: publish the partial counters before failing closed.
      rm -f "$log_file" "$tmp_sigs"
      write_runs_report "$report" "$examined" "$extracted" "$completed" "$tested" "$pending" "log:$run_id"
      return 1
    fi
    # A failing run with NO failure identity contributes nothing to either table
    # (no `FAILED <nodeid>` line AND no attributable guard-step annotation, #4469).
    # Skip the extractor for it: the `signatures` CLI exits 1 on a capture that
    # yields no ids, which is correct for a capture that PROVES nothing but wrong
    # for a run we already know carried no parseable failure (the
    # `extracted < examined` gate in admin-merge.sh owns that case).
    local ids="" one="" irc=0
    ids="$(failed_ids_from_log "$log_file" "$run_id")"; irc=$?
    if [ "$irc" -eq 4 ]; then
      # #3174 — TRUNCATED capture: excluded from the signature table for the same reason as every
      # other collector (see `collect_union_truncated`). The run is not credited as measured.
      [ "$credited" = "1" ] && tested=$((tested - 1))
      truncated=$((truncated + 1)); truncated_id="$run_id"
      rm -f "$log_file"
      continue
    fi
    if [ "$irc" -ne 0 ]; then
      rm -f "$log_file" "$tmp_sigs"
      write_runs_report "$report" "$examined" "$extracted" "$completed" "$tested" "$pending" "parse:$run_id"
      return 1
    fi
    if [ -n "$ids" ]; then
      extracted=$((extracted + 1))
      one="$(extract_failed_signatures "$log_file")" || {
        rm -f "$log_file" "$tmp_sigs"
        write_runs_report "$report" "$examined" "$extracted" "$completed" "$tested" "$pending" "parse:$run_id"
        return 1
      }
      [ -n "$one" ] && printf '%s\n' "$one" >> "$tmp_sigs"
    fi
    rm -f "$log_file"
  done < "$lane_file"
  write_runs_report "$report" "$examined" "$extracted" "$completed" "$tested" "$pending"
  collect_union_truncated "$truncated" "$examined" "$extracted" "$report" "$completed" "$tested" "$pending" "$truncated_id" || { rm -f "$tmp_sigs"; return 1; }
  # No tested run -> emit NOTHING. An empty signature table is not evidence; the
  # caller BLOCKS on it rather than exempting from it.
  if [ "$tested" -gt 0 ]; then
    sort -u "$tmp_sigs"
  fi
  rm -f "$tmp_sigs"
}

# #3756 — the PR-side decision input: `<nodeid>\t<failures>\t<runs>\t<signature>`.
# `<failures>` counts the commit's failing runs in which the id appeared, `<runs>`
# the runs that exercised the suite (the same K as the rate table). Every id is
# emitted, with a BLANK signature when the extractor produced none: an id that
# vanished here would be an id the decision never sees, which is fail-OPEN.
# `--per-run` writes the per-run id sets detect_rotating_identity() consumes.
# `--unattributed` (#2610) writes the examined failing runs that yielded NO identity —
# from THIS function, because it is the one that decides `extracted`. The arms below that
# leave a run unextracted AND let the capture continue write the runref there: the
# zero-job arm (#1482) and the ordinary empty-ids arm. `--provenance` cannot stand in: it
# holds every examined run, including the ones that DID contribute.
#
# ⛔ THE PRUNED-LOG ARM (#7131) IS NOT ONE OF THEM, and the comment on it says so rather
# than implying coverage: `run_failed_job_ids` returns 1 both for "the job list could not
# be read" and for "read fine, no failed job", and this function treats 1 as fatal — so a
# pruned log naming no failed job REFUSES THE WHOLE CAPTURE (the caller's extract gate),
# and no named 1c refusal is reached for it. Making that arm live needs a distinguishable
# status from `run_failed_job_ids` (2 = read, nothing failed), which is a behaviour change
# in the capture with its own test; it is deliberately NOT bundled here.
collect_union_rows() {
  local lane_file="$1" provenance="$2" report="$3" per_run="$4" unattr="${5:-}"
  local tmp_ids="" tmp_sigs="" examined=0 extracted=0 completed=0 tested=0 pending=0 credited=0 run_id line truncated=0 truncated_id=""
  tmp_ids="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
  tmp_sigs="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
  : > "$tmp_ids"; : > "$tmp_sigs"
  [ -n "$provenance" ] && : > "$provenance"
  [ -n "$per_run" ] && : > "$per_run"
  [ -n "$unattr" ] && : > "$unattr"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local status rest conclusion runref log_file ids one
    status="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    conclusion="${rest%%$'\t'*}"
    runref="${rest#*$'\t'}"
    run_id="${runref##*:}"
    credited=0
    if [ "$status" = "completed" ]; then
      completed=$((completed + 1))
      case "$conclusion" in success|failure|timed_out) tested=$((tested + 1)); credited=1 ;; esac
    else
      # #1623 — an unexpanded run is not in flight; see `collect_union`.
      if run_is_unexpanded "$run_id"; then
        say_err "ci-failure-set: · run $run_id is NOT completed but has ZERO jobs — GitHub never expanded it into a job, so it cannot still be running; NOT counted as pending (#1623)"
      else
        pending=$((pending + 1))
      fi
    fi
    case "$conclusion" in failure|timed_out|startup_failure) ;; *) continue ;; esac
    examined=$((examined + 1))
    printf '%s\n' "$runref" >> "${provenance:-/dev/null}"
    log_file="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
    fetch_failed_log "$run_id" "$log_file"
    local frc=$?
    if [ "$frc" -eq 2 ]; then
      # Zero-job run: contributes nothing (#1482). `examined` has already
      # advanced without `extracted`, so on the PR side the `examined >
      # extracted` gate in admin-merge.sh still refuses this run — the PR side
      # stays fail-closed by construction, which is deliberate.
      [ "$credited" = "1" ] && tested=$((tested - 1))
      [ -n "$unattr" ] && printf '%s\n' "$runref" >> "$unattr"
      rm -f "$log_file"
      continue
    fi
    if [ "$frc" -eq 3 ]; then
      # #7131: the log is PRUNED. Attribute at JOB granularity instead of
      # refusing as unknowable. `extracted` MUST advance when ids come back —
      # otherwise the `examined > extracted` gate in admin-merge.sh refuses the
      # run and the fallback buys nothing. NO signature is emitted, so the
      # decision's signature gate fails CLOSED and the key can never be exempted.
      rm -f "$log_file"
      ids="$(run_failed_job_ids "$run_id")" || {
        rm -f "$tmp_ids" "$tmp_sigs"
        write_runs_report "$report" "$examined" "$extracted" "$completed" "$tested" "$pending" "parse:$run_id"
        return 1
      }
      if [ -n "$ids" ]; then
        extracted=$((extracted + 1))
        printf '%s\n' "$ids" >> "$tmp_ids"
        if [ -n "$per_run" ]; then
          printf '%s\n' "$(printf '%s\n' "$ids" | tr '\n' ' ')" | sed 's/ *$//' >> "$per_run"
        fi
      fi
      # ⛔ NOTHING TO DO IN AN `else`, and the absent branch is stated rather than assumed:
      # `run_failed_job_ids` cannot return 0 with empty output (both its paths end
      # `[ -n … ] || return 1`), so a pruned log naming no failed job takes the `return 1`
      # above and FAILS THE CAPTURE CLOSED. It therefore never reaches `--unattributed` —
      # see the ⛔ block in this function's docblock.
      continue
    fi
    if [ "$frc" -ne 0 ]; then
      # #2569: publish the partial counters before failing closed.
      rm -f "$log_file" "$tmp_ids" "$tmp_sigs"
      write_runs_report "$report" "$examined" "$extracted" "$completed" "$tested" "$pending" "log:$run_id"
      return 1
    fi
    ids="$(failed_ids_from_log "$log_file" "$run_id")"; local irc=$?
    if [ "$irc" -eq 4 ]; then
      # #3174 — TRUNCATED capture: excluded from the row door (see `collect_union_truncated`), so a
      # partial failure set never reaches `decide()` as if it were the PR's (or main's) set.
      [ "$credited" = "1" ] && tested=$((tested - 1))
      truncated=$((truncated + 1)); truncated_id="$run_id"
      # ⛔ THE `--unattributed` WRITE IS NOT OPTIONAL HERE (review of this change, P2). Every other
      # arm that advances `examined` without `extracted` records the runref — the zero-job arm above
      # and the empty-ids arm below — and `admin-merge.sh` §1c CROSS-CHECKS it: the `examined >
      # extracted` refusal counts the runs it expects to be named, then requires the collector to
      # have published that many. Omitting this write made the two files disagree ("the collector
      # published 0 unattributable run(s) where the refusal counted 1 — this list is INCOMPLETE"),
      # blaming a collector whose exclusion was deliberate. The reason is NOT "yielded no identity"
      # — the ids exist and were refused — so the run is named in the UNPROVEN line by
      # `failed_ids_from_log` and listed here as the un-extracted run it is.
      [ -n "$unattr" ] && printf '%s\n' "$runref" >> "$unattr"
      rm -f "$log_file"
      continue
    fi
    if [ "$irc" -ne 0 ]; then
      rm -f "$log_file" "$tmp_ids" "$tmp_sigs"
      write_runs_report "$report" "$examined" "$extracted" "$completed" "$tested" "$pending" "parse:$run_id"
      return 1
    fi
    if [ -n "$ids" ]; then
      extracted=$((extracted + 1))
      printf '%s\n' "$ids" >> "$tmp_ids"
      if [ -n "$per_run" ]; then
        printf '%s\n' "$(printf '%s\n' "$ids" | tr '\n' ' ')" | sed 's/ *$//' >> "$per_run"
      fi
      # No shape guard here any more (#3756 defect 1): `failed_ids_from_log` has
      # ALREADY dropped, counted and reported every candidate that is not a test
      # id, so every id reaching this line is one the decision's parser accepts.
      # A run whose ids were ALL garbage yields an empty `ids`, so `extracted`
      # does not advance and the caller's `examined > extracted` gate refuses it
      # — fail-closed. The old in-shell refusal aborted the WHOLE extraction on
      # one stray token, which is the permanent-false-refusal shape itself.
      # Only a run that CARRIED ids is fed to the signature extractor: the
      # `signatures` CLI exits 1 on a capture with no ids (correct for a capture
      # that proves nothing, wrong for a run already known to carry none).
      one="$(extract_failed_signatures "$log_file")" || {
        rm -f "$log_file" "$tmp_ids" "$tmp_sigs"
        write_runs_report "$report" "$examined" "$extracted" "$completed" "$tested" "$pending" "parse:$run_id"
        return 1
      }
      [ -n "$one" ] && printf '%s\n' "$one" >> "$tmp_sigs"
    else
      # No ids from a readable log: THIS is the unattributable run (#2610).
      [ -n "$unattr" ] && printf '%s\n' "$runref" >> "$unattr"
    fi
    rm -f "$log_file"
  done < "$lane_file"
  write_runs_report "$report" "$examined" "$extracted" "$completed" "$tested" "$pending"
  collect_union_truncated "$truncated" "$examined" "$extracted" "$report" "$completed" "$tested" "$pending" "$truncated_id" || { rm -f "$tmp_ids" "$tmp_sigs"; return 1; }
  if [ "$tested" -gt 0 ]; then
    # Join per-id failure counts (and the id universe, so an UNSIGNED id still
    # gets a row) with the signature rows. awk only; no second signature parser.
    awk -F'\t' -v OFS='\t' -v k="$tested" '
      FNR == NR { fail[$1]++; seen[$1] = 1; next }
      { if ($1 in seen) sig_by[$1] = sig_by[$1] $2 "\n" }
      END {
        for (id in seen) {
          emitted = 0
          if (id in sig_by) {
            n = split(sig_by[id], parts, "\n")
            for (i = 1; i <= n; i++) if (parts[i] != "") { print id, fail[id] + 0, k, parts[i]; emitted = 1 }
          }
          if (!emitted) print id, fail[id] + 0, k, ""
        }
      }' "$tmp_ids" "$tmp_sigs" | sort
  fi
  rm -f "$tmp_ids" "$tmp_sigs"
}

# ── main ──────────────────────────────────────────────────

main() {
  local mode="" pr="" commit="" main_runs="$DEFAULT_MAIN_RUNS"
  local exclude="" repo="" provenance="" report="" diff_a="" diff_b="" per_run="" unattr=""
  local workflow="${CI_FAILURE_SET_WORKFLOW:-$DEFAULT_WORKFLOW}" any_workflow=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --pr) mode="pr"; pr="${2:-}"; shift 2 2>/dev/null || shift 1 ;;
      --commit) mode="commit"; commit="${2:-}"; shift 2 2>/dev/null || shift 1 ;;
      --main-union)
        mode="main-union"
        if [ $# -ge 2 ] && [ -n "${2:-}" ] && [ -z "${2##[0-9]*}" ]; then
          main_runs="$2"; shift 2
        else
          shift 1
        fi ;;
      --main-union-rates)
        mode="main-union-rates"
        if [ $# -ge 2 ] && [ -n "${2:-}" ] && [ -z "${2##[0-9]*}" ]; then
          main_runs="$2"; shift 2
        else
          shift 1
        fi ;;
      --main-union-signatures)
        mode="main-union-signatures"
        if [ $# -ge 2 ] && [ -n "${2:-}" ] && [ -z "${2##[0-9]*}" ]; then
          main_runs="$2"; shift 2
        else
          shift 1
        fi ;;
      --commit-rows) mode="commit-rows"; commit="${2:-}"; shift 2 2>/dev/null || shift 1 ;;
      --per-run) per_run="${2:-}"; shift 2 2>/dev/null || shift 1 ;;
      --unattributed) unattr="${2:-}"; shift 2 2>/dev/null || shift 1 ;;
      --diff) mode="diff"; diff_a="${2:-}"; diff_b="${3:-}"; shift 3 2>/dev/null || shift $# ;;
      --exclude) exclude="${2:-}"; shift 2 2>/dev/null || shift 1 ;;
      --repo) repo="${2:-}"; shift 2 2>/dev/null || shift 1 ;;
      --workflow) workflow="${2:-}"; shift 2 2>/dev/null || shift 1 ;;
      --any-workflow) any_workflow=1; shift ;;
      --provenance) provenance="${2:-}"; shift 2 2>/dev/null || shift 1 ;;
      --runs-report) report="${2:-}"; shift 2 2>/dev/null || shift 1 ;;
      --help|-h) usage; exit 0 ;;
      *) say_err "ci-failure-set: unknown argument '$1'"; usage >&2; exit 2 ;;
    esac
  done

  REPO_ARGS=()
  [ -n "$repo" ] && REPO_ARGS=(--repo "$repo")
  WORKFLOW_ARGS=()
  # An empty --workflow (or --any-workflow) means no filter. Filtering by the
  # TEST lane is the default because an unfiltered window is how the baseline
  # reads EMPTY while main is red — see THE BOGUS ZERO in the header.
  if [ "$any_workflow" -eq 0 ] && [ -n "$workflow" ]; then
    WORKFLOW_ARGS=(--workflow "$workflow")
  fi

  case "$mode" in
    diff)
      [ -n "$diff_a" ] && [ -n "$diff_b" ] || { say_err "ci-failure-set: --diff needs two files"; exit 2; }
      [ -r "$diff_a" ] || { say_err "ci-failure-set: cannot read $diff_a"; exit 1; }
      [ -r "$diff_b" ] || { say_err "ci-failure-set: cannot read $diff_b"; exit 1; }
      # One comparison, one implementation — the pre-merge gate and the
      # post-merge detector both shell out to this branch, so "unique failure"
      # cannot mean two different things.
      comm -23 <(sort -u "$diff_a") <(sort -u "$diff_b")
      ;;
    pr)
      [ -n "$pr" ] || { say_err "ci-failure-set: --pr needs a PR number"; exit 2; }
      local head runs
      # shellcheck disable=SC2086
      # `${repo_args[@]+…}` — bash 3.2 (macOS /bin/bash) errors on `"${arr[@]}"`
      # for an empty array under `set -u`.
      head="$($GH pr view "$pr" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --json headRefOid --jq .headRefOid 2>/dev/null)" || {
        say_err "ci-failure-set: ✗ could not resolve head of PR #$pr"; exit 1; }
      [ -n "$head" ] || { say_err "ci-failure-set: ✗ empty head for PR #$pr"; exit 1; }
      runs="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      list_lane_runs --commit "$head" 100 > "$runs" || { rm -f "$runs"; say_err "ci-failure-set: ✗ could not list runs for $head"; exit 1; }
      collect_union "$runs" "$provenance" "$report" || { rm -f "$runs"; exit 1; }
      rm -f "$runs"
      ;;
    commit)
      [ -n "$commit" ] || { say_err "ci-failure-set: --commit needs a SHA"; exit 2; }
      local runs
      runs="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      list_lane_runs --commit "$commit" 100 > "$runs" || { rm -f "$runs"; say_err "ci-failure-set: ✗ could not list runs for $commit"; exit 1; }
      collect_union "$runs" "$provenance" "$report" || { rm -f "$runs"; exit 1; }
      rm -f "$runs"
      ;;
    main-union-rates)
      # ⛔ A LISTING FAILURE WRITES NO `--runs-report`, deliberately (#2569). A window
      # that was never listed has no counters, and publishing `tested=0` for it would
      # hand a consumer a report it could read as a baseline — the assertion at the
      # end of `tests/admin-merge/run.sh` pins that no report exists on this path.
      # So the report's ABSENCE is the signal the rail reads for "no read window".
      # It is the most likely cause, not the only one: a capture killed mid-loop, or a
      # report that could not be WRITTEN (which `write_runs_report` now says out
      # loud), also leaves no report — which is why the rail's wording says "nothing
      # was measured that could be read" rather than naming the network as the cause.
      local runs filtered
      runs="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      filtered="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      list_main_baseline "$main_runs" "$exclude" "$runs" "$filtered" || { rm -f "$runs" "$filtered"; say_err "ci-failure-set: ✗ could not list main runs"; exit 1; }
      collect_union_rates "$filtered" "$provenance" "$report" || { rm -f "$runs" "$filtered"; exit 1; }
      rm -f "$runs" "$filtered"
      ;;
    commit-rows)
      [ -n "$commit" ] || { say_err "ci-failure-set: --commit-rows needs a SHA"; exit 2; }
      require_exemption_module || exit 1
      local runs
      runs="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      list_lane_runs --commit "$commit" 100 > "$runs" || { rm -f "$runs"; say_err "ci-failure-set: ✗ could not list runs for $commit"; exit 1; }
      collect_union_rows "$runs" "$provenance" "$report" "$per_run" "$unattr" || { rm -f "$runs"; exit 1; }
      rm -f "$runs"
      ;;
    main-union-signatures)
      require_exemption_module || exit 1
      local runs filtered
      runs="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      filtered="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      list_main_baseline "$main_runs" "$exclude" "$runs" "$filtered" || { rm -f "$runs" "$filtered"; say_err "ci-failure-set: ✗ could not list main runs"; exit 1; }
      collect_union_signatures "$filtered" "$provenance" "$report" || { rm -f "$runs" "$filtered"; exit 1; }
      rm -f "$runs" "$filtered"
      ;;
    main-union)
      local runs filtered
      runs="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      filtered="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      list_lane_runs --branch main "$main_runs" > "$runs" || { rm -f "$runs" "$filtered"; say_err "ci-failure-set: ✗ could not list main runs"; exit 1; }
      # ONE exclusion rule for every main mode (exclude_runs). The rule itself is
      # documented at its definition, and it is shared rather than re-written here
      # so a correction cannot land on this side only: `--main-union` feeds the
      # POST-merge detector while the widened modes feed the PRE-merge rail, and
      # the two must not disagree about what `--exclude` removed.
      exclude_runs "$runs" "$exclude" "$filtered"
      collect_union "$filtered" "$provenance" "$report" || { rm -f "$runs" "$filtered"; exit 1; }
      rm -f "$runs" "$filtered"
      ;;
    *)
      say_err "ci-failure-set: one of --pr, --commit, --main-union, --main-union-rates, --main-union-signatures, --commit-rows, --diff is required"
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
