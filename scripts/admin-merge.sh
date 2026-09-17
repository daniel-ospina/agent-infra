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
#   pr-fails.txt   ← scripts/ci-failure-set.sh --commit <head>   # the head SHA,
#                    the exact revision the evidence marker binds to
#   main-fails.txt ← scripts/ci-failure-set.sh --main-union N
#   unique         ← scripts/ci-failure-set.sh --diff pr-fails.txt main-fails.txt
#   unique EMPTY            → post head-bound evidence, then merge
#   unique NON-EMPTY        → re-run the PR's failed jobs ONCE; anything that
#                             passes on retry is flaky, not new (recorded in the
#                             evidence). Residual unique still non-empty →
#                             BLOCK, print the list, exit non-zero, NO merge.
#
# THREE PRECONDITIONS THE FAILING SETS ALONE CANNOT EXPRESS:
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
#   3. THE LANE MUST BASELINE BOTH SIDES. `main-fails.txt` is `comm -23`'s right
#      operand, so if it is EMPTY every failure the PR carries reads as new —
#      including ones already red on main, which turns a safe merge into a false
#      block. A lane is therefore usable only if it has TESTED runs on main too
#      (the same `tested` counter as precondition 1). Repos that split their
#      lanes by TRIGGER (a `pull_request`-only lane and a `push`-only lane) have
#      no single --workflow spanning both sides; `--any-workflow` compares
#      against every lane on main (#1003).
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
#                        when absent the bound is DERIVED at rail runtime from
#                        the run's own observed PER-SHARD job durations (each
#                        shard's 2 x max, floored). There is deliberately NO
#                        GLOBAL constant: B4's population falsifies one —
#                        main-side `test (a)` n=5 median 18.8m / max 24.2m
#                        against `test (b)` n=5 median 46.6m / max 49.9m, so
#                        `test (b)`'s MEDIAN green run is 2.5x `test (a)`'s.
#                        One number is wrong in BOTH directions: it blocks the
#                        slow shard mid-distribution while being far
#                        over-generous for a fast one. This wait separates
#                        STILL-RUNNING (keep waiting) from STALLED (no
#                        `updatedAt` progress for ADMIN_MERGE_STALL_SECONDS) —
#                        only a STALL is a failure.
#   --no-rerun           skip the flake re-run classification (a non-empty
#                        unique set then blocks immediately)
#   --print-bounds [<run-id>]
#                        print the re-run ceiling + stall window, the per-shard
#                        table (shard, n, max(D), ceiling) and the source of the
#                        derivation, then exit. With NO run id there is nothing
#                        to derive from, so it prints the FAIL-SAFE (3900s) and
#                        makes no gh call at all.
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
#       run that is still RUNNING. A still-RUNNING job is NOT a failure; only a
#       STALL is. It prints STILL-RUNNING progress, and its ceiling is DERIVED
#       PER SHARD from the run's own observed durations — never a global
#       constant — with the derivation named in the message.
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
#   ADMIN_MERGE_STALL_SECONDS            no-progress window, STALLED (default 600)
#   ADMIN_MERGE_RERUN_FLOOR              per-shard ceiling floor (default 2 x the
#                                         stall window, i.e. 1200 at the default
#                                         600 — deliberately NOT a round 900, so
#                                         STALLED always fires before CEILING)
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
POLL_INTERVAL="${ADMIN_MERGE_POLL_INTERVAL:-10}"
# A run that is still RUNNING is not a failure — only a STALL is. This is the
# real failure signal: the run is not `completed` and `updatedAt` has not moved
# for this long. 600s = 10 min: 10x the observed ~2s queue, and far below the
# fastest OBSERVED shard (22m10s), whose step updates land far more often than
# once every ten minutes. Env seam: ADMIN_MERGE_STALL_SECONDS (tests only).
RERUN_STALL_SECONDS="${ADMIN_MERGE_STALL_SECONDS:-600}"

# ── THE RE-RUN CEILING IS DERIVED PER SHARD, AT RAIL RUNTIME ────────────
# There is deliberately NO GLOBAL CONSTANT. B4's population falsifies one:
# on main, `test (a)` is n=5 median 18.8m / max 24.2m while `test (b)` is
# n=5 median 46.6m / max 49.9m — so `test (b)`'s MEDIAN green run is 2.5x
# `test (a)`'s. A single number is wrong in BOTH directions: the old
# `observed_slowest_shard` (1563s) ceiling blocked `test (b)` mid-
# distribution while being many times over-generous for a 1.6m shard.
#
# Per shard s, over the run's own jobs:
#     ceiling(s) = max(FLOOR, 2 * max(D(s)))   # D(s) = a completed job's duration
# The run ceiling C is the max over the shards the rail might still WAIT ON —
# the NOT-completed ones. When every shard is completed (the normal case: the
# run a re-run is about to replace is terminal), C is the max over ALL shards.
#
# FLOOR is load-bearing twice over: a shard with NO completed sample (a
# brand-new shard, or a job that has not finished) must never receive a tiny
# bound; AND it must exceed RERUN_STALL_SECONDS BY CONSTRUCTION so the stall
# check can never be transposed with the ceiling. At a flat 900 the ordering
# held only while the stall window stayed under 900 — an operator raising
# ADMIN_MERGE_STALL_SECONDS past ~450 would let the CEILING fire first and
# re-create B7 (a stall reported as a still-running job: opposite remedies)
# . Hence the default is 2 x the stall window, not a round number. The
# fail-safe is larger still and applies to ANY derivation failure — a
# derivation that failed must never produce a SMALL bound, because a too-tight
# bound is the original defect this replaces.
RERUN_FLOOR="${ADMIN_MERGE_RERUN_FLOOR:-$((2 * RERUN_STALL_SECONDS))}"
FAILSAFE_RERUN_TIMEOUT="${ADMIN_MERGE_RERUN_TIMEOUT_FALLBACK:-3900}"

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
# was not supplied.
fetch_run_jobs() {
  local run_id="$1" slug
  if [ -n "$REPO" ]; then
    slug="repos/$REPO/actions/runs/$run_id/jobs?per_page=100"
  else
    slug="repos/{owner}/{repo}/actions/runs/$run_id/jobs?per_page=100"
  fi
  "$GH" api "$slug" --paginate
}

# derive_rerun_timeout <run-id> — set DERIVED_RERUN_TIMEOUT / _SOURCE / _TABLE
# from the run's observed per-shard job durations. NEVER fails the caller: every
# failure path installs the fail-safe and says so loudly.
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
  local run_id="$1" json_file="" out="" rc=0 line tag name n maxd ceil unfin
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
  out="$("$PYTHON_BIN" -c 'import datetime, json, re, sys
path, floor = sys.argv[1], int(sys.argv[2])
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
        raise SystemExit(2)
    docs.append(obj)
saw = any(isinstance(d, dict) and isinstance(d.get("jobs"), list) for d in docs)
if not saw:
    raise SystemExit(2)
shards = {}
for d in docs:
    if not isinstance(d, dict) or not isinstance(d.get("jobs"), list):
        continue
    for job in d["jobs"]:
        if not isinstance(job, dict):
            continue
        name = norm(job.get("name"))
        if not name:
            continue
        rec = shards.setdefault(name, {"n": 0, "max": 0, "unfinished": False})
        if job.get("status") and job.get("status") != "completed":
            rec["unfinished"] = True
        a, b = ts(job.get("started_at")), ts(job.get("completed_at"))
        if a is not None and b is not None:
            secs = int((b - a).total_seconds())
            if secs >= 0:
                rec["n"] += 1
                if secs > rec["max"]:
                    rec["max"] = secs
total = sum(r["n"] for r in shards.values())
if total == 0:
    raise SystemExit(3)
def ceil(rec):
    return max(floor, 2 * rec["max"])
for name in sorted(shards):
    rec = shards[name]
    print("SHARD\t%s\t%d\t%d\t%d\t%d" % (name, rec["n"], rec["max"], ceil(rec), 1 if rec["unfinished"] else 0))
unfinished = [s for s in shards if shards[s]["unfinished"]]
if unfinished:
    pool, reason = unfinished, "slowest unfinished shard"
else:
    pool, reason = list(shards), "slowest shard (every shard completed)"
win = max(sorted(pool), key=lambda s: ceil(shards[s]))
rec = shards[win]
print("C\t%d\t%s\t%d\t%d\t%s" % (ceil(rec), win, rec["n"], rec["max"], reason))' "$json_file" "$RERUN_FLOOR" 2>/dev/null)"
  rc=$?
  rm -f "$json_file"
  case "$rc" in
    0) [ -n "$out" ] || { fail_safe_rerun_timeout "unparsable jobs response"; return 0; } ;;
    3) fail_safe_rerun_timeout "no job durations observed"; return 0 ;;
    *) fail_safe_rerun_timeout "unparsable jobs response"; return 0 ;;
  esac
  local table="" c_line="" c="" win="" winn="" winmax="" wreason="" state
  while IFS= read -r line; do
    case "$line" in
      C$'\t'*) c_line="$line" ;;
      SHARD$'\t'*)
        IFS=$'\t' read -r tag name n maxd ceil unfin <<< "$line"
        state="finished"
        [ "$unfin" = "1" ] && state="unfinished"
        table="${table}shard ${name}	n=${n}	max=${maxd}s	ceiling=${ceil}s	state=${state}"$'\n'
        ;;
    esac
  done <<< "$out"
  DERIVED_TABLE="${table%$'\n'}"
  IFS=$'\t' read -r tag c win winn winmax wreason <<< "$c_line"
  counter_is_number "$c" || { fail_safe_rerun_timeout "unparsable jobs response"; return 0; }
  DERIVED_RERUN_TIMEOUT="$c"
  DERIVED_RERUN_SOURCE="derived per-shard ceiling ${c}s (${wreason}: ${win}, n=${winn}, max=${winmax}s)"
}

# iso_age_seconds <iso-8601> → whole seconds since that instant, or EMPTY when it
# cannot be read. `date -d` is GNU-only and `date -j -f` is BSD-only, and python
# is already a rail dependency, so it is the portable reader. An unreadable
# timestamp is reported as unknown — NEVER as "not moving".
iso_age_seconds() {
  "$PYTHON_BIN" -c '
import datetime, sys
raw = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
if not raw:
    raise SystemExit(1)
try:
    ts = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
except ValueError:
    raise SystemExit(1)
if ts.tzinfo is None:
    ts = ts.replace(tzinfo=datetime.timezone.utc)
age = int((datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds())
print(age if age >= 0 else 0)
' "$1" 2>/dev/null
}

# pending_run_id <head> — the first NON-COMPLETED lane run id for this head, or
# empty. Only the lane-terminal diagnostic needs it: the parser's provenance file
# records the FAILING runs, and a pending run has no conclusion, so its id never
# reaches that file.
pending_run_id() {
  local head="$1" line
  # shellcheck disable=SC2086
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in completed$'\t'*) continue ;; esac
    printf '%s' "${line##*:}"
    return 0
  done < <($GH run list --commit "$head" --limit 100 \
      ${wf_args[@]+"${wf_args[@]}"} ${repo_args[@]+"${repo_args[@]}"} \
      --json databaseId,status,conclusion,headSha --jq "$LANE_RUN_JQ" 2>/dev/null || true)
  return 0
}

# wait_for_run <run-id> — poll until the run is `completed`.
#   return 0  completed.
#   return 1  STALLED — not completed and `updatedAt` has not moved for
#             RERUN_STALL_SECONDS. THIS is the failure signal.
#   return 2  CEILING — still RUNNING at the derived RERUN_TIMEOUT. NOT a
#             failure verdict: a still-running job is not a failure; the
#             derived bound was simply reached.
#   return 3  UNOBSERVABLE — gh could not be read for RERUN_STALL_SECONDS, so
#             the run's state was NEVER OBSERVED. Deliberately distinct from
#             STALLED (1): "no progress" is a claim about a field we read; an
#             outage is the absence of that reading. Opposite remedies.
# A still-RUNNING run prints progress (status, elapsed/ceiling, and the
# derivation) instead of a verdict — the old flat message read as a failure
# when it was only impatience (B5).
wait_for_run() {
  local run_id="$1" waited=0 idle=0 unobs=0 step status upd line last_upd=""
  # Wall-clock accounting must advance even when the test seam sets the interval
  # to 0 — a 0-step loop can never reach its own bound and spins forever.
  step="$POLL_INTERVAL"; [ "$step" -gt 0 ] 2>/dev/null || step=1
  while [ "$waited" -lt "$RERUN_TIMEOUT" ]; do
    # ONE gh call for both fields (status + the progress clock), so a poll does
    # not double its process cost.
    # shellcheck disable=SC2086
    line="$($GH run view "$run_id" ${repo_args[@]+"${repo_args[@]}"} \
      --json status,updatedAt --jq '.status + " " + .updatedAt' 2>/dev/null || echo 'unknown ')"
    status="${line%% *}"; upd="${line#* }"
    [ "$status" = "completed" ] && return 0
    # "Could not read the run" is NOT "the run made no progress". A gh failure
    # yields status=unknown and an empty clock; counting that as idle made a
    # transient gh/auth/network outage report STALLED — a claim ("updatedAt
    # never moved") the code cannot support, because it never read the field.
    # The two faults have OPPOSITE remedies — repair gh, vs escalate a wedged
    # run — so they must not share a diagnosis. Fail-closed either way: an
    # unreadable run still blocks. (Field evidence: a loaded host produced a
    # FALSE stall from frozen metadata while the child was still working; a
    # frozen clock cannot distinguish running-but-quiet from wedged.)
    if [ -z "$upd" ] || [ "$status" = "unknown" ]; then
      unobs=$((unobs + step))
      [ "$unobs" -ge "$RERUN_STALL_SECONDS" ] && return 3
      sleep "$POLL_INTERVAL"; waited=$((waited + step)); continue
    fi
    unobs=0
    if [ "$upd" != "$last_upd" ]; then
      idle=0; last_upd="$upd"
    else
      idle=$((idle + step))
    fi
    if [ "$idle" -ge "$RERUN_STALL_SECONDS" ]; then
      return 1
    fi
    info "admin-merge: … run $run_id STILL RUNNING (status=${status:-unknown}, ${waited}s of the ${RERUN_TIMEOUT}s ceiling — ${RERUN_TIMEOUT_SOURCE}). A running job is not a failure — waiting."
    sleep "$POLL_INTERVAL"
    waited=$((waited + step))
  done
  return 2
}

# print_bounds [<run-id>] — the re-run ceiling, its per-shard table (each figure
# carrying its n), the source, and the stall window. `rerun-timeout=` stays the
# FIRST line: existing greps depend on the key. With NO run id there is nothing to
# derive from, so this is the one path that prints the fail-safe and makes no call.
print_bounds() {
  local run_id="$1"
  if [ "$RERUN_TIMEOUT_EXPLICIT" -eq 1 ]; then
    printf 'rerun-timeout=%s\n' "$RERUN_TIMEOUT"
    printf 'source=explicit --rerun-timeout\n'
    printf 'stall=%s\n' "$RERUN_STALL_SECONDS"
    return 0
  fi
  if [ -z "$run_id" ]; then
    printf 'rerun-timeout=%s\n' "$FAILSAFE_RERUN_TIMEOUT"
    printf 'source=fail-safe %ss — no run id supplied; the derivation needs a run (pass one: --print-bounds <run-id>)\n' "$FAILSAFE_RERUN_TIMEOUT"
    printf 'stall=%s\n' "$RERUN_STALL_SECONDS"
    return 0
  fi
  derive_rerun_timeout "$run_id"
  printf 'rerun-timeout=%s\n' "$DERIVED_RERUN_TIMEOUT"
  [ -n "$DERIVED_TABLE" ] && printf '%s\n' "$DERIVED_TABLE"
  printf 'source=%s\n' "$DERIVED_RERUN_SOURCE"
  printf 'stall=%s\n' "$RERUN_STALL_SECONDS"
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
  local pr_fails="$9" main_fails="${10}" final_unique_raw="${11:-}"

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
  printf 'PR failing: %s | main failing: %s | unique to this PR: 0\n' "$pr_count" "$main_count"
  printf '%s\n' "$analyzed"
  # THE AUDITABLE DIFF, not just its verdict (#3467 item 2): with a zero
  # residual the PR's own failing set IS the pre-existing set, so recording it is
  # what lets a reviewer reach `unique: 0` from the comment instead of taking it
  # on faith — and what distinguishes a real "all N were already red on main"
  # from a comparison that never happened.
  evidence_list "the $pr_count failure(s) this PR carries — all pre-existing on main" \
    "$(cat "$pr_fails")" "(none — this PR carries no failure of its own)"
  evidence_list "main baseline: $main_count pre-existing failure(s), for comparison" \
    "$(cat "$main_fails")" "(none)"
  # The PRE-rerun residual, when the flake path ran. Labelled for what it IS: it
  # is NOT the diff of the two sets above (those are POST-rerun), so it must not
  # be presented under a "must be empty" heading.
  if [ -n "$unique_raw" ]; then
    evidence_list 'residual BEFORE the flake re-run — reclassified as flaky, NOT new failures' \
      "$unique_raw" "(none)"
  fi
  evidence_list 'final residual (`comm -23` pr-fails main-fails) — must be empty' \
    "$final_unique_raw" "(empty — nothing unique to this PR)"
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
  # NO GLOBAL CEILING. An explicit --rerun-timeout (or $RERUN_TIMEOUT) is a
  # verbatim override; otherwise the bound is DERIVED per run from that run's own
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
      # Make the DERIVATION visible on demand: the re-run ceiling is not a round
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
  run_failure_set --commit "$head" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
    --provenance "$TMP/pr-runs.txt" --runs-report "$TMP/pr-report.txt" > "$TMP/pr-fails.txt" || pr_status=$?
  if [ "$pr_status" -ne 0 ]; then
    say_err "admin-merge: ✗ BLOCK — could not extract the PR's failing set (parser exit $pr_status)."
    say_err "   Refusing to certify a comparison computed over an unreadable set."
    exit 1
  fi

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
    # `gh run view` call, ONLY here, on the pending run: its status and the age of
    # its progress clock. A run that is moving reads as a WAIT; a run whose clock
    # has stopped for the stall window reads as STALLED — and NEITHER is the
    # re-run ceiling, which has not started. The parser COUNTS pending runs but
    # does not record their ids (a pending run has no conclusion), so the id is
    # looked up here; this is the failure path, so the extra list costs nothing.
    if counter_is_positive "$pr_pending"; then
      local pend_id="" vline="" vstatus="" vupd="" idle=""
      pend_id="$(pending_run_id "$head")"
      if [ -n "$pend_id" ]; then
        # shellcheck disable=SC2086
        vline="$($GH run view "$pend_id" ${repo_args[@]+"${repo_args[@]}"} --json status,updatedAt --jq '.status + " " + .updatedAt' 2>/dev/null || true)"
        vstatus="${vline%% *}"; vupd="${vline#* }"
        if [ -n "$vstatus" ] && [ "$vstatus" != "completed" ]; then
          idle="$(iso_age_seconds "$vupd")"
          if [ -n "$idle" ] && [ "$idle" -ge "$RERUN_STALL_SECONDS" ]; then
            say_err "   the lane run $pend_id is STALLED — no progress for ${idle}s (status=$vstatus, updatedAt=$vupd, stall window ${RERUN_STALL_SECONDS}s)."
          else
            say_err "   the lane run $pend_id reports status=$vstatus, updatedAt=$vupd — this is a WAIT, not a stall; the re-run bound is a different wait."
          fi
        elif [ "$vstatus" = "completed" ]; then
          say_err "   the lane run $pend_id now reports status=completed — re-run the rail to re-list the lane."
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
    say_err "   set and 'unique to this PR: 0' would be a false certificate (lane: $lane)."
    say_err "   Either the run failed outside the test step (fix it), or the log format moved"
    say_err "   and the parser needs updating. This is a refusal, not a comparison."
    exit 1
  fi

  info "admin-merge: lane finished for $head (${pr_tested} tested of ${pr_completed} completed run(s))"

  # ── 2. main's baseline: the UNION over the last N runs ───────────────────
  local main_status=0
  run_failure_set --main-union "$MAIN_RUNS" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
    --exclude "$head" --provenance "$TMP/main-runs.txt" --runs-report "$TMP/main-report.txt" \
    > "$TMP/main-fails.txt" || main_status=$?
  if [ "$main_status" -ne 0 ]; then
    say_err "admin-merge: ✗ BLOCK — could not extract main's failing set (parser exit $main_status)."
    say_err "   Refusing to certify a comparison computed over an unreadable baseline."
    exit 1
  fi

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

  # ── 3. the shared comparison (one implementation, two consumers) ─────────
  # Its OWN exit status is checked: a failed `--diff` leaves an EMPTY file, which
  # reads as "no unique failures" and merges. That is fail-open (review P2).
  if ! run_failure_set --diff "$TMP/pr-fails.txt" "$TMP/main-fails.txt" > "$TMP/unique.txt"; then
    say_err "admin-merge: ✗ BLOCK — the shared comparison failed (parser exit). No merge."
    exit 1
  fi
  local unique_before
  unique_before="$(count_lines "$TMP/unique.txt")"

  local flake_line="Flake classification: none needed (no unique failures before re-run)"
  local rerun_residual=0

  if [ "$unique_before" -gt 0 ]; then
    info "admin-merge: $unique_before failure(s) look unique to this PR — re-run classification:"
    sed 's/^/   /' "$TMP/unique.txt"
    if [ "$NO_RERUN" -eq 1 ]; then
      say_err "admin-merge: ✗ BLOCK — unique failures present and --no-rerun given. No merge."
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
      # ceiling is the slow shard's own 2 x max. Deriving AFTER the re-run would
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
        say_err "admin-merge: ✗ BLOCK — run $run_id STALLED: no progress for ${RERUN_STALL_SECONDS}s (status stayed non-completed and updatedAt never moved). A still-running job is not a failure; a STALL is. No merge."
        exit 1
      fi
      if [ "$wait_rc" -eq 3 ]; then
        say_err "admin-merge: ✗ BLOCK — run $run_id UNOBSERVABLE: gh could not be read for ${RERUN_STALL_SECONDS}s (neither status nor updatedAt was ever obtained). This is NOT a stall — a stall is a claim about progress, and this rail never saw the field. Remedy differs: check gh auth/network, then re-run. No merge."
        exit 1
      fi
      if [ "$wait_rc" -ne 0 ]; then
        say_err "admin-merge: ✗ BLOCK — run $run_id still RUNNING at the ${RERUN_TIMEOUT}s ceiling — ${RERUN_TIMEOUT_SOURCE}. Not a stall — the ceiling was reached. No merge."
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
    run_failure_set --commit "$head" ${repo_args[@]+"${repo_args[@]}"} ${wf_args[@]+"${wf_args[@]}"} \
      --runs-report "$TMP/pr-report2.txt" > "$TMP/pr-fails2.txt" || pr_status2=$?
    [ "$pr_status2" -eq 0 ] || { say_err "admin-merge: ✗ BLOCK — PR failing set unreadable after re-run"; exit 1; }
    if ! run_failure_set --diff "$TMP/pr-fails2.txt" "$TMP/main-fails.txt" > "$TMP/unique2.txt"; then
      say_err "admin-merge: ✗ BLOCK — the shared comparison failed after the re-run (parser exit). No merge."
      exit 1
    fi
    rerun_residual="$(count_lines "$TMP/unique2.txt")"

    if [ "$rerun_residual" -gt 0 ]; then
      say_err "admin-merge: ✗ BLOCK — $rerun_residual unique failure(s) SURVIVED the re-run:"
      attribute_residual "$TMP/unique2.txt" "$TMP/main-fails.txt" >&2
      say_err "   The attribution above separates MEASURED-ABSENT (main's lane demonstrably"
      say_err "   measures this file and does not show this test red) from NOT-MEASURABLE"
      say_err "   (main's baseline carries no measurement of the file, so absence is NOT"
      say_err "   evidence of novelty). BOTH block; no label here clears a failure."
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

  # A vacuous comparison is STATED, never implied. Both sides empty is usually a
  # correct outcome (the lane is green on both sides) — but it is also exactly
  # what a WRONG lane selector looks like, so the two must be distinguishable by
  # a reader of the evidence. See the bogus-zero trap in ci-failure-set.sh.
  if [ "$pr_count" -eq 0 ] && [ "$main_count" -eq 0 ]; then
    analyzed="$analyzed
⚠️ vacuous comparison: no failing runs were observed on EITHER side, so nothing was actually compared. Correct when the lane is green on both sides — but if the lane selector is wrong (--workflow), this certifies nothing."
    info "admin-merge: ⚠️  vacuous comparison — no failing runs on either side; nothing was compared (lane: $lane)"
  fi

  info "admin-merge: PR failing: $pr_count | main failing: $main_count | unique to this PR: 0"

  # The set the "must be empty" claim is actually ABOUT: after a flake re-run,
  # unique2.txt is the post-rerun residual (pr-fails2 vs main-fails), while
  # unique.txt is the PRE-rerun one. Showing the pre-rerun set under a "must be
  # empty" heading contradicts the displayed (post-rerun) sets. (VGATE round 2.)
  local final_unique="$TMP/unique.txt"
  if [ -f "$TMP/unique2.txt" ]; then final_unique="$TMP/unique2.txt"; fi
  build_evidence "$head" "$TMP/main-runs.txt" "$pr_count" "$main_count" \
    "$(cat "$TMP/unique.txt")" "$flake_line" "$analyzed" "$lane" \
    "$TMP/pr-fails.txt" "$TMP/main-fails.txt" "$(cat "$final_unique")" > "$TMP/evidence.md"

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
