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
#   3. extracts `FAILED <nodeid>` lines AND attributable GUARD-STEP failures
#      (#4469 — a substantive GitHub Actions error annotation in a step the
#      RUNNER marked failed, when the run's ROOT failing step also yields an
#      identity and no step showed an UNCLASSIFIED pytest failure), and emits a
#      sorted, unique, one-identity-per-line set.
#
# Guard-step attribution exists so a guard failure is COMPARED against main like a
# test nodeid instead of tripping the caller's fail-closed refusal. The refusal is
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
#   --main-union-rates [N]    (#3756) per-id failure COUNTS over the last N runs:
#                             `<nodeid>\t<failures>\t<runs>`. The rate table the
#                             exemption decision consumes — a union cannot express
#                             `main 1/8` vs `PR 8/8`, which is why presence-based
#                             subtraction excused an eight-fold regression. Emits
#                             NOTHING when no run exercised the suite (fail-closed).
#   --main-union-signatures [N]
#                             (#3756) main's per-id stable SIGNATURE over the last
#                             N runs: `<nodeid>\t<signature>`. The rate table alone
#                             leaves `main_signatures` empty, so the decision's
#                             subset rule fails CLOSED and nothing is ever exempt;
#                             this is the other half of the same measurement.
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
#   --runs-report <file>      write `examined=` / `extracted=` / `completed=` /
#                             `tested=` / `pending=` counts for the lane runs
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
#      failing runs whose failures carry no parseable identity: neither a
#      `FAILED <nodeid>` line nor an attributable guard-step annotation)
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
#              error annotation from the run's ROOT failing step
#   completed  lane runs that FINISHED (any conclusion)
#   tested     of `completed`, the runs that actually EXERCISED the code:
#              `success`, `failure`, `timed_out`. NOT `cancelled`/`skipped`
#              (finished without running the suite) and NOT `startup_failure`
#              (the workflow never started — nothing ran at all).
#   pending    lane runs still queued/in-progress
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

set -uo pipefail

GH="${CI_FAILURE_SET_GH:-gh}"
DEFAULT_MAIN_RUNS=10
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
    *) rm -f "$log_file"; return 1 ;;
  esac
  failed_ids_from_log "$log_file"
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

# fetch_failed_log <run-id> <out-file> — the RAW `gh run view --log-failed`
# capture, for the callers that need the failure TEXT and not only the ids.
#
# Same fail-closed rule as extract_failed_tests: a transport error is a FAILURE,
# never an empty capture — an unreadable log must not read as "nothing failed"
# (#3705).
#
# Return: 0 = captured · 1 = FAIL CLOSED (unknowable) · 2 = ZERO-JOB run, which
# contributes NOTHING and is not an error (the only non-zero status a caller may
# treat as benign — see #1482).
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
  local run_id="$1" out="$2" err jobs
  # shellcheck disable=SC2086
  if err="$($GH run view "$run_id" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --log-failed 2>&1 > "$out")"; then
    return 0
  fi
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
      say_err "ci-failure-set: ✗ run $run_id has NO LOG (GitHub pruned it); its job count $jobs_note — the failure set is UNKNOWABLE, refusing to read this as an empty failing set" ;;
    *)
      say_err "ci-failure-set: ✗ could not fetch the failed-step log for run $run_id (gh error); its job count $jobs_note — refusing to read this as an empty failing set" ;;
  esac
  return 1
}

# failed_ids_from_log <log-file> → the ids, via THE canonical parser.
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
  local log_file="$1" out
  require_exemption_module || return 1
  if ! out="$("$PYTHON_BIN" "$EXEMPTION_PY" ids --log "$log_file")"; then
    say_err "ci-failure-set: ✗ FAILED-id extraction FAILED for $log_file — refusing to read it as an empty failure set"
    return 1
  fi
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

# Sets a union of the FAILED nodeids across every FAILING run in <lane-file>,
# and counts the lane's completion state from the SAME listing. Also writes
# provenance/counts when requested. Returns 1 on extraction failure.
collect_union() {
  local lane_file="$1" provenance="$2" report="$3"
  local tmp_set="" examined=0 extracted=0 completed=0 tested=0 pending=0 credited=0 run_id line
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
      pending=$((pending + 1))
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
      *) rm -f "$tmp_set"; return 1 ;;
    esac
    if [ -n "$one" ]; then
      extracted=$((extracted + 1))
      printf '%s\n' "$one" >> "$tmp_set"
    fi
  done < "$lane_file"
  if [ -n "$report" ]; then
    printf 'examined=%s\nextracted=%s\ncompleted=%s\ntested=%s\npending=%s\n' \
      "$examined" "$extracted" "$completed" "$tested" "$pending" > "$report"
  fi
  sort -u "$tmp_set"
  rm -f "$tmp_set"
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
  local tmp_all="" examined=0 extracted=0 completed=0 tested=0 pending=0 credited=0 run_id line
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
      pending=$((pending + 1))
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
      *) rm -f "$tmp_all"; return 1 ;;
    esac
    if [ -n "$one" ]; then
      extracted=$((extracted + 1))
      printf '%s\n' "$one" >> "$tmp_all"
    fi
  done < "$lane_file"
  if [ -n "$report" ]; then
    printf 'examined=%s\nextracted=%s\ncompleted=%s\ntested=%s\npending=%s\n' \
      "$examined" "$extracted" "$completed" "$tested" "$pending" > "$report"
  fi
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
  local tmp_sigs="" examined=0 extracted=0 completed=0 tested=0 pending=0 credited=0 run_id line
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
      pending=$((pending + 1))
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
    if [ "$frc" -ne 0 ]; then
      rm -f "$log_file" "$tmp_sigs"; return 1
    fi
    # A failing run with NO failure identity contributes nothing to either table
    # (no `FAILED <nodeid>` line AND no attributable guard-step annotation, #4469).
    # Skip the extractor for it: the `signatures` CLI exits 1 on a capture that
    # yields no ids, which is correct for a capture that PROVES nothing but wrong
    # for a run we already know carried no parseable failure (the
    # `extracted < examined` gate in admin-merge.sh owns that case).
    local ids="" one=""
    ids="$(failed_ids_from_log "$log_file")" || { rm -f "$log_file" "$tmp_sigs"; return 1; }
    if [ -n "$ids" ]; then
      extracted=$((extracted + 1))
      one="$(extract_failed_signatures "$log_file")" || { rm -f "$log_file" "$tmp_sigs"; return 1; }
      [ -n "$one" ] && printf '%s\n' "$one" >> "$tmp_sigs"
    fi
    rm -f "$log_file"
  done < "$lane_file"
  if [ -n "$report" ]; then
    printf 'examined=%s\nextracted=%s\ncompleted=%s\ntested=%s\npending=%s\n' \
      "$examined" "$extracted" "$completed" "$tested" "$pending" > "$report"
  fi
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
collect_union_rows() {
  local lane_file="$1" provenance="$2" report="$3" per_run="$4"
  local tmp_ids="" tmp_sigs="" examined=0 extracted=0 completed=0 tested=0 pending=0 credited=0 run_id line
  tmp_ids="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
  tmp_sigs="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
  : > "$tmp_ids"; : > "$tmp_sigs"
  [ -n "$provenance" ] && : > "$provenance"
  [ -n "$per_run" ] && : > "$per_run"
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
      pending=$((pending + 1))
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
      rm -f "$log_file"
      continue
    fi
    if [ "$frc" -ne 0 ]; then
      rm -f "$log_file" "$tmp_ids" "$tmp_sigs"; return 1
    fi
    ids="$(failed_ids_from_log "$log_file")" || { rm -f "$log_file" "$tmp_ids" "$tmp_sigs"; return 1; }
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
      one="$(extract_failed_signatures "$log_file")" || { rm -f "$log_file" "$tmp_ids" "$tmp_sigs"; return 1; }
      [ -n "$one" ] && printf '%s\n' "$one" >> "$tmp_sigs"
    fi
    rm -f "$log_file"
  done < "$lane_file"
  if [ -n "$report" ]; then
    printf 'examined=%s\nextracted=%s\ncompleted=%s\ntested=%s\npending=%s\n' \
      "$examined" "$extracted" "$completed" "$tested" "$pending" > "$report"
  fi
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
  local exclude="" repo="" provenance="" report="" diff_a="" diff_b="" per_run=""
  local workflow="${CI_FAILURE_SET_WORKFLOW:-$DEFAULT_WORKFLOW}" any_workflow=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --pr) mode="pr"; pr="${2:-}"; shift 2 ;;
      --commit) mode="commit"; commit="${2:-}"; shift 2 ;;
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
      --commit-rows) mode="commit-rows"; commit="${2:-}"; shift 2 ;;
      --per-run) per_run="${2:-}"; shift 2 ;;
      --diff) mode="diff"; diff_a="${2:-}"; diff_b="${3:-}"; shift 3 ;;
      --exclude) exclude="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --workflow) workflow="${2:-}"; shift 2 ;;
      --any-workflow) any_workflow=1; shift ;;
      --provenance) provenance="${2:-}"; shift 2 ;;
      --runs-report) report="${2:-}"; shift 2 ;;
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
      local runs filtered
      runs="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      filtered="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      list_lane_runs --branch main "$main_runs" > "$runs" || { rm -f "$runs" "$filtered"; say_err "ci-failure-set: ✗ could not list main runs"; exit 1; }
      if [ -n "$exclude" ]; then
        awk -F'\t' -v x="$exclude" '
          {
            n = split($3, a, ":")
            sha = a[1]
            if (sha == "") print
            else if (sha != x && index(sha, x) != 1 && index(x, sha) != 1) print
          }' "$runs" > "$filtered"
      else
        cp "$runs" "$filtered"
      fi
      collect_union_rates "$filtered" "$provenance" "$report" || { rm -f "$runs" "$filtered"; exit 1; }
      rm -f "$runs" "$filtered"
      ;;
    commit-rows)
      [ -n "$commit" ] || { say_err "ci-failure-set: --commit-rows needs a SHA"; exit 2; }
      require_exemption_module || exit 1
      local runs
      runs="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      list_lane_runs --commit "$commit" 100 > "$runs" || { rm -f "$runs"; say_err "ci-failure-set: ✗ could not list runs for $commit"; exit 1; }
      collect_union_rows "$runs" "$provenance" "$report" "$per_run" || { rm -f "$runs"; exit 1; }
      rm -f "$runs"
      ;;
    main-union-signatures)
      require_exemption_module || exit 1
      local runs filtered
      runs="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      filtered="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      list_lane_runs --branch main "$main_runs" > "$runs" || { rm -f "$runs" "$filtered"; say_err "ci-failure-set: ✗ could not list main runs"; exit 1; }
      if [ -n "$exclude" ]; then
        awk -F'\t' -v x="$exclude" '
          {
            n = split($3, a, ":")
            sha = a[1]
            if (sha == "") print
            else if (sha != x && index(sha, x) != 1 && index(x, sha) != 1) print
          }' "$runs" > "$filtered"
      else
        cp "$runs" "$filtered"
      fi
      collect_union_signatures "$filtered" "$provenance" "$report" || { rm -f "$runs" "$filtered"; exit 1; }
      rm -f "$runs" "$filtered"
      ;;
    main-union)
      local runs filtered
      runs="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      filtered="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
      list_lane_runs --branch main "$main_runs" > "$runs" || { rm -f "$runs" "$filtered"; say_err "ci-failure-set: ✗ could not list main runs"; exit 1; }
      if [ -n "$exclude" ]; then
        # Parse the TAGGED projection's sha field — never a bare `$1`. `$1` of a
        # `status<TAB>conclusion<TAB>sha:id` line is `status<TAB>conclusion<TAB>sha`,
        # so a blind `-F: '$1 != x'` matches nothing and `--exclude` becomes a
        # silent no-op: the merged commit's own run stays in main's baseline, its
        # failures equal the PR's, and the post-merge detector can never fire
        # (review P0, cycle 2). Prefix-tolerant both ways: callers pass a full sha
        # from an event payload, the API may return either. A line with an EMPTY
        # sha is KEPT — dropping runs we cannot identify would shrink the baseline
        # and manufacture "unique" failures (VGATE cycle 2).
        awk -F'\t' -v x="$exclude" '
          {
            n = split($3, a, ":")
            sha = a[1]
            if (sha == "") print
            else if (sha != x && index(sha, x) != 1 && index(x, sha) != 1) print
          }' "$runs" > "$filtered"
      else
        cp "$runs" "$filtered"
      fi
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
