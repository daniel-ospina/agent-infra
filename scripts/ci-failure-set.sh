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
#
# THE RAW PROJECTION (#1358). The canonical three fields — which admin-merge.sh's
# own `LANE_RUN_JQ` also spells (that listing feeds its coverage gate and the
# pending-run probe) — PLUS the identity fields the supersede rule needs: which
# workflow, which event, and which ref. `drop_superseded_runs` re-emits exactly
# those three canonical fields, so no consumer of this script can observe the
# wider listing; the two spellings therefore agree on the RE-EMITTED form, which is
# the whole of what any consumer reads (code-review cycle 4: an earlier comment
# called the two constants byte-identical, which stopped being true when this file's
# constant became the wider one — the constant is not the contract, the emitted
# three fields are).
#
# EVERY FIELD IS NON-EMPTY, and the conclusion carries a SENTINEL ("-") when the
# API reports none (#1368). The re-emitted line is consumed by admin-merge.sh's
# `IFS=$'\t' read`, where an EMPTY field collapses the delimiter and SHIFTS the
# payload into the next variable — so a queued run (no conclusion) must not reach
# the rail as `queued\t\t<sha>:<id>`. The sentinel must not be a conclusion TOKEN, or
# `collect_union`'s `case "$conclusion"` would credit a queued run with
# `tested`/`examined`. An empty MIDDLE field (the conclusion) is therefore never
# emitted; an empty run REFERENCE is reported rather than silently repaired,
# because no value can be invented for it.
#
# NO CLOCK IS ASKED FOR, deliberately. `updatedAt` is frozen for the whole of a
# single long step, so this repo's tests forbid it as a liveness signal (§39/§40 in
# tests/admin-merge/run.sh) — and ordering does not need it either: a run's
# `databaseId` IS its creation order (#1358's own residual, stated there).
LANE_RUN_RAW_JQ='.[] | "\(.status)\t\(if (.conclusion // "") == "" then "-" else .conclusion end)\t\(.headSha // ""):\(.databaseId // "")\t\(.workflowDatabaseId // "")\t\(.workflowName // "")\t\(.event // "")\t\(.headBranch // "")"'
# THIS EXPRESSION IS EXECUTED BY A TEST, not only by production: test §60 (p)
# feeds a JSON listing through the REAL `--jq` and asserts the identity reaches the
# rule. Raising that test is what makes the claim "the projection cannot lose a
# field unnoticed" TRUE — the earlier comment said it while every fixture handed
# the rule its own 7-field shape, so a one-character regression here (a dropped
# `headBranch`, a renamed `--json` field) turned every line opaque, reverted the
# fix to its pre-#1358 behaviour, and left the tests green (code-review cycle 5,
# 2026-09-23).

# ── drop_superseded_runs — THE SUPERSEDE RULE (#1358) ────
#
# A failing run that a LATER run of the SAME workflow, at the SAME commit, under
# the SAME event AND the SAME ref, replaced is NOT a failing run. Without this, a run re-run green
# on the same head left the old red in the failing set — and for a GATE failure,
# one whose log carries no `FAILED <nodeid>` line and so can never be attributed,
# that made `examined > extracted` and the rail REFUSED a head whose own surface
# was green. The only remedy left was `gh run delete`: destroying CI records to
# satisfy a stale reading (PR #1354; both counted runs are deleted and 404
# today). The check-surface path (admin-merge.sh step 4.5) has always applied the
# same idea — the latest check run per (app, name) decides — so this is the lane
# path agreeing with it, not a new concept.
#
# WHAT MAY SUPERSEDE: only a run that FINISHED and SUCCEEDED (`completed`
# `success`). `cancelled` (what `cancel-in-progress` produces), `skipped` (it
# exercised nothing), `neutral`, `failure`, `timed_out` and `startup_failure` are all
# terminal, and none of them is evidence that the commit is green, so none may drop
# a red — a later red is another red, not a certificate (test §60 (o)). Fail CLOSED:
# an over-block costs a re-run; the other direction merges a broken tree.
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
# THE GROUP KEY is (sha, workflowDatabaseId, workflowName, event, headBranch) —
# every part required. The commit alone would collapse main's window, which spans
# commits BY DESIGN (the union over the last N runs), and silently shrink the
# baseline; a shrunken baseline is what EXCUSES a genuinely new PR failure, so on
# main this rule closes a fail-open rather than opening one. The workflow NAME alone
# would let two different files both called "CI" clear each other, so the ID is
# required too. The event, because one commit is often both a PR head and pushed to
# a branch, and the lane's jobs are event-conditioned. And the REF, for exactly the
# same reason one level down: two `push` runs of one workflow at the SAME commit on
# different branches are different measurements, because a job is routinely
# `if: github.ref …` (code-review cycle 4 — the same class as the tab-in-name
# fail-open cycle 1 found: the key must carry everything the jobs are conditioned
# on).
#
# AN UNREADABLE LINE FAILS CLOSED IN BOTH DIRECTIONS: it supersedes nothing and is
# never superseded, and the refusal to decide is SAID OUT LOUD on stderr, NAMING THE
# ACTUAL unreadable part — a SILENT assumption about identity is how this class of
# defect starts. Such a line is still COUNTED as a failing run (it is a run, and it
# is red); what it cannot be is a CERTIFICATE that the commit is green, in either
# direction. A line that is not this lister's 7-field projection is RE-EMITTED in the
# canonical shape and never grouped, because the rule cannot invent an identity it
# was not handed — and it is named too, EXCEPT for the one shape a caller may
# legitimately hand us: the 3-field canonical line itself. A BLANK line is not a run
# and is not emitted at all — an empty line can carry no measurement, and passing it
# through as `\t\t` would be counted as a PENDING run. The rule's own tests fail
# loudly if this projection ever loses a field, so that path cannot rot into a
# silent no-op.
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
      # #1368: an absent conclusion becomes the SENTINEL, never an empty field —
      # the canonical line is split downstream with `IFS=$'\t' read`, where an
      # empty field collapses the delimiter and shifts the payload.
      concl[NR] = (blank($2) ? "-" : $2)
      out[NR] = $1 OFS concl[NR] OFS $3
      ref[NR] = $3
      cand[NR] = 0
      # EXACTLY seven fields, or the line is OPAQUE (kept, never grouped, and NAMED
      # unless it is the documented 3-field canonical shape). `NF < 6` was the first
      # spelling and it was a FAIL-OPEN (code-review cycle 1, 2026-09-23): a workflow
      # NAME containing a literal TAB left `$5`/`$6` holding a fragment of the name,
      # so the group key silently DID NOT CARRY THE EVENT. A field separator that
      # cannot be told from a field boundary is unreadable identity (the same class as
      # an empty field), so it fails closed.
      if (NF == 3) {
        # The canonical shape a caller may hand us (or a fixture written before the
        # projection grew): opaque BY DESIGN, so there is nothing to report — but an
        # empty run reference is not that shape, and is named.
        if (blank($3)) opaque[NR] = "an empty run reference"
        next
      }
      if (NF != 7) {
        opaque[NR] = "a " NF "-field line (this projection defines 7 fields: status, conclusion, sha:id, workflow id, workflow name, event, head branch)"
        next
      }
      # EXACTLY ONE colon. The consumers take the LAST colon-separated segment
      # (`${runref##*:}`, ci-failure-set.sh:498/556/608/668), so a reference with a
      # second colon would have THIS rule rank the id it read first while the log
      # fetch used a different one — the rule would be reasoning about a run that is
      # not the one it later inspected. Unreadable identity, named, fail closed
      # (code-review cycle 5; the live projection cannot emit it, so this is
      # defence in depth, not a fix for an observed failure).
      split($3, parts, ":")
      sha = parts[1]; id = parts[2]
      if (length(parts) != 2 || blank(sha) || blank(id) || id !~ /^[0-9]+$/) { opaque[NR] = "an unparsable run reference (" $3 ")"; next }
      if (blank($4)) { opaque[NR] = "an empty workflow id"; next }
      if (blank($5)) { opaque[NR] = "an empty workflow name"; next }
      if (blank($6)) { opaque[NR] = "an empty event"; next }
      if (blank($7)) { opaque[NR] = "an empty head branch"; next }
      cand[NR] = 1
      idof[NR] = id; shaof[NR] = sha
      # THE GROUP KEY IS EVERYTHING THE JOBS OF THE LANE CAN BE CONDITIONED ON: the commit,
      # the workflow (id AND name), the event, AND THE REF. Two `push` runs of one
      # workflow at the SAME COMMIT on DIFFERENT branches are different measurements —
      # a job is routinely `if: github.ref …`, so a green on `main` says nothing about
      # a red on a release branch at the same commit (code-review cycle 4, 2026-09-23;
      # the same class as the tab-in-name fail-open the cycle-1 review found).
      # THE REF IS CARRIED AS `headBranch`: `gh run list --json` serves no `ref` field,
      # and for the run this rail governs (a `push` lane) the head branch and the ref are
      # the same string. The stated residual — two `pull_request` runs at one commit whose
      # heads share a branch name are two refs carrying the same field — is in the note
      # below and in the PR (code-review cycle 5).
      k[NR] = sha SUBSEP $4 SUBSEP $5 SUBSEP $6 SUBSEP $7
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
        if (opaque[i]) {
          printf "ci-failure-set: note: %s carries %s, so it can neither supersede nor be superseded — kept as a FAILING RUN, and never read as a certificate that the commit is green (fail closed)\n", (ref[i] == "" ? "line " i : ref[i]), opaque[i] > "/dev/stderr"
        }
        if (cand[i] && is_failing(concl[i]) && (k[i] in best) && (idof[i] + 0) < (best[k[i]] + 0)) {
          # The disclosure names the HEAD BRANCH, which is what the key carries: `gh run
          # list --json` exposes no `ref`. For the lane this rail runs (a `push` run) the
          # head branch IS the ref (`refs/heads/<headBranch>`) and the correspondence is
          # exact. For a `pull_request` run it is not: two PRs whose heads share a branch
          # NAME are two refs (`refs/pull/N/merge`) carrying the same field, so this note
          # would over-claim. That residual is STATED rather than papered over — no field
          # served by `gh run list` can close it (code-review cycle 5).
          printf "ci-failure-set: note: run %s (at %s) concluded %s but was superseded by run %s, a LATER run of the SAME workflow at the same commit, event and head branch — NOT counted as a failing run\n", idof[i], shaof[i], concl[i], bestid[k[i]] > "/dev/stderr"
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
    --json databaseId,status,conclusion,headSha,workflowDatabaseId,workflowName,event,headBranch \
    --jq "$LANE_RUN_RAW_JQ" | drop_superseded_runs
}

# extract_failed_tests <run-id> → sorted-unique nodeids, one per line.
# A failing run whose failed-step log cannot be fetched is an EXTRACTION
# FAILURE (exit 1), not an empty contribution: silently dropping it is exactly
# the vacuous pass this rail exists to prevent.
extract_failed_tests() {
  local run_id="$1" log_file rc
  log_file="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
  if ! fetch_failed_log "$run_id" "$log_file"; then rm -f "$log_file"; return 1; fi
  failed_ids_from_log "$log_file"
  rc=$?
  rm -f "$log_file"
  return $rc
}

# fetch_failed_log <run-id> <out-file> — the RAW `gh run view --log-failed`
# capture, for the callers that need the failure TEXT and not only the ids.
# Same fail-closed rule as extract_failed_tests: a gh error is a FAILURE, never
# an empty capture — an unreadable log must not read as "nothing failed" (#3705).
fetch_failed_log() {
  local run_id="$1" out="$2"
  # shellcheck disable=SC2086
  if ! $GH run view "$run_id" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --log-failed > "$out" 2>/dev/null; then
    say_err "ci-failure-set: ✗ could not fetch the failed-step log for run $run_id (gh error) — refusing to read this as an empty failing set"
    return 1
  fi
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
  local tmp_set="" examined=0 extracted=0 completed=0 tested=0 pending=0 run_id line
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
    # Completion is counted for EVERY run, failures included: a queued run is
    # exactly what a failures-only listing cannot see.
    if [ "$status" = "completed" ]; then
      completed=$((completed + 1))
      # Terminal != exercised. `cancelled`/`skipped`/`neutral` finished without
      # running the suite, so they must not count toward "this revision was
      # tested" (review P1, cycle 2).
      case "$conclusion" in
        success|failure|timed_out) tested=$((tested + 1)) ;;
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
    local one
    one="$(extract_failed_tests "$run_id")" || { rm -f "$tmp_set"; return 1; }
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
  local tmp_all="" examined=0 extracted=0 completed=0 tested=0 pending=0 run_id line
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
    if [ "$status" = "completed" ]; then
      completed=$((completed + 1))
      case "$conclusion" in
        success|failure|timed_out) tested=$((tested + 1)) ;;
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
    local one
    one="$(extract_failed_tests "$run_id")" || { rm -f "$tmp_all"; return 1; }
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
  local tmp_sigs="" examined=0 extracted=0 completed=0 tested=0 pending=0 run_id line
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
    if [ "$status" = "completed" ]; then
      completed=$((completed + 1))
      case "$conclusion" in success|failure|timed_out) tested=$((tested + 1)) ;; esac
    else
      pending=$((pending + 1))
    fi
    case "$conclusion" in failure|timed_out|startup_failure) ;; *) continue ;; esac
    examined=$((examined + 1))
    printf '%s\n' "$runref" >> "${provenance:-/dev/null}"
    log_file="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
    if ! fetch_failed_log "$run_id" "$log_file"; then rm -f "$log_file" "$tmp_sigs"; return 1; fi
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
  local tmp_ids="" tmp_sigs="" examined=0 extracted=0 completed=0 tested=0 pending=0 run_id line
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
    if [ "$status" = "completed" ]; then
      completed=$((completed + 1))
      case "$conclusion" in success|failure|timed_out) tested=$((tested + 1)) ;; esac
    else
      pending=$((pending + 1))
    fi
    case "$conclusion" in failure|timed_out|startup_failure) ;; *) continue ;; esac
    examined=$((examined + 1))
    printf '%s\n' "$runref" >> "${provenance:-/dev/null}"
    log_file="$(mktemp "${TMPDIR:-/tmp}/ci-failure-set.XXXXXX")"
    if ! fetch_failed_log "$run_id" "$log_file"; then
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
