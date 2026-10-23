#!/usr/bin/env bash
# ci-queue.sh — CI BACK-PRESSURE: how deep is the repo's CI queue, and may this box send it more
# work yet? Sourced by `orch-loop.sh` (the cycle's read, before dispatch), by `fix-one.sh` (the
# lane whose whole job is to PUSH a new head), and by `dispatch-merge.sh` (the batch dispatcher),
# and runnable STANDALONE (`bash ci-queue.sh status --repo owner/name`), because the same bytes must
# answer the question on whichever surface asks it. It never calls `set` — a sourced library must
# not mutate its caller's shell options.
#
# ── COVERAGE, AND THE ONE DELIBERATE EXCLUSION (#2296 review cycle 4) ───────────────────────────
# Gated: the controller's read before dispatch, the THREE fixer spawn arms whose product is a pushed
# head (the CONFLICTED, the CI-red and the review-gate ones), every pre-push check in `fix-one.sh`,
# the batch dispatcher, and the CI RERUN.
# ⛔ AND ONE FIXER ARM IS NOT GATED YET, DISCLOSED RATHER THAN IMPLIED: the RED-TREE fixer
# (`orch-loop.sh`'s `MAX_RED_FIX` spawn) books its attempt and spawns BEFORE any `ciq_push_ok` call,
# so on a deep queue that lane still starts, is deferred by `fix-one.sh` on its first push, and hands
# the attempt back through `fixbail` on a later cycle. The cost is CHURN — a fixer spawned to do work
# it then declines to push — not added CI; the refund line names BOTH causes (`another box holds the
# claim, or the CI-queue gate deferred the push`), so it does not misdirect anyone to a lease that
# never existed. It is the fourth pusher and the only ungated one; home agent-infra #2408.
# ⛔ NOT gated, on purpose: the merge rail's second-sample re-run (`admin-merge.sh`, the flake retry).
# It is not an omission — a rail that is MERGING removes a PR and its load from the system, and
# refusing the retry would replace a merge with a stuck red head; the retry happens only inside that
# merge decision. Stated here because a coverage claim a reader cannot check is a claim that rots.
#
# ── WHY THIS EXISTS (measured 2026-10-22 13:40 UTC, both repos) ─────────────────────────────────
#   tortoise      queued=92  in_progress=6  runners online=5 (busy=5)   ← queue 18x the runner count
#   agent-infra   queued=97  in_progress=7  (runner endpoint unreadable) ← 97 runs, 7 executing
#   job wait created->started:  tortoise P50 0.0m P90  2.5m max 11.2m
#                               agent-infra P50 5.0m P90 11.7m max 13.0m
#   single longest job:         agent-infra `bash-suites` 20.3m; tortoise `queue-health` 11.3m
# After a batch of rebases agent-infra went from 4 to 31 BLOCKED PRs at once, each needing a full CI
# pass, against 5 self-hosted runners. NOTHING FINISHES BECAUSE EVERYTHING STARTED: throughput
# (merges/hour) went DOWN while the work went up. This file is the reading that was missing: every
# existing gate in this harness — `load=`, `mem_avail=`, `swap_free=`, `capacity-placement` — measures
# THE BOX, and a box with 20 idle lane slots and a 90-deep CI queue looks perfectly healthy.
#
# ⛔ IT IS A MEASURED QUEUE READ, NOT A WORKER/LANE CAP — and that distinction is the recorded
# decision, not this file's preference. The owner ruled on 2026-10-17 "dispatch should be gated on
# capacity, not on number of lanes" (argued at `capacity.sh`'s ceiling section and at orch-loop.sh's
# MAX_LANES block), and re-stating that as a fixed lane ceiling here would reopen a settled
# decision through a side door. So the gate counts THE OTHER SIDE'S CAPACITY: how many runs are
# waiting, how many are executing, how many runners can execute them. A box that adds work when the
# queue is under the ceiling is allowed exactly as before; nothing here caps lanes.
#
# ── THE CEILING: DERIVED FROM THE RUNNERS AND THE JOB, NOT A MAGIC CONSTANT ────────────────────
# A self-hosted runner executes ONE job at a time, so a queue of Q runs in front of R runners drains
# in about (Q / R) job-durations. A push is worth making only if its own verdict will arrive within
# the horizon a lane is willing to wait for it — after that the push has bought nothing and it has
# DESTROYED the head-bound artifacts of the PR it touched (the review attestation is bound to a SHA,
# so a rebase/amend silently invalidates it: agent-infra#2148, `reviewer-preflight.sh`).
#
#     ceiling = ceil( runners * horizon_min / job_p90_min )
#
# With the measurement above — 5 runners, a 20-minute horizon (a lane's own re-review + merge chain
# has to fit inside one controller cycle's patience, and 20m is 2x the observed P90 job wait), and a
# 10-minute typical job (tortoise job duration P90 = 9.0m; agent-infra's `bash-suites` worst = 20.3m,
# which is why the horizon is not derived from the WORST job — a ceiling built on the worst job would
# never bind) — the ceiling is ceil(5 * 20 / 10) = 10 queued runs. The 2026-10-22 incident queue (92
# and 97) is 9-10x that; the pre-incident baseline (4) is comfortably under it. That is the check
# both arms must pass: a rule that defers on 4 would be a fleet-wide stop, and one that allows 92 is
# not a gate at all.
#
# ⛔ EVERY TUNING VALUE LIVES IN THIS FILE — FIVE OF THEM, NOT TWO (#2333 review, P2). The three
# functions below (`ciq_horizon_min`, `ciq_job_p90_min`, `ciq_hosted_concurrency`) plus the two
# cache bounds read inline in `ciq_read` (`CIQ_TTL`, `CIQ_STALE_MAX`) — each overridable by the
# matching env name, with the shipped default being the MEASURED one. `ciq_hosted_concurrency` is
# NAMED here because it is not cosmetic: on the GitHub-HOSTED shape (a repo whose `actions/runners`
# answers `total_count: 0`) it SUPPLIES the runner count, so it sets the ceiling through the same
# arithmetic — `ceil(20 * 20 / 10) = 40` at the defaults. An earlier version of this header said
# "THE TWO FUNCTIONS"; an operator retuning a hosted repo by it would have changed nothing, which
# is the class of claim this repository asks a review to catch. Nothing about this gate is rendered
# into the launchd plist, so there is no second copy to drift (install.sh does not source this file).
#
# ── FAIL-CLOSED, AND THE ONE PLACE THAT IS DELIBERATELY NOT ─────────────────────────────────────
#   * An UNREADABLE queue is **UNKNOWN**, and UNKNOWN defers CI-spending work. The alternative — an
#     unreadable read opening the gate — is the fail-open shape this repo has removed from every
#     other instrument: a `gh` outage would then be indistinguishable from an empty queue, and the
#     fleet would stampede on exactly the cycle it could not see. Because dispatch is what is being
#     gated, UNKNOWN stopping dispatch costs a cycle; the defect it prevents costs a night.
#   * The ONE fail-open is the CACHE: a read that succeeded within `CIQ_TTL` seconds is used for free
#     (a burst of N dispatches in one cycle must not become N reads), and a read that FAILS falls
#     back to the last successful record for up to `CIQ_STALE_MAX` seconds — reported as
#     `cache(<age>s)` in every line it produces, so a stale reading is never presented as a fresh
#     one. Past that window the record is dropped and the verdict is UNKNOWN again.
#   * `runners` is MEASURED when the repo endpoint answers with an online runner count. When no count
#     is measured there are THREE cases and they do not share one answer (#2333 review cycles 9-11):
#     the endpoint ANSWERING `total_count: 0` is the hosted-CI shape (GitHub-hosted runners never
#     appear in that list — it is agent-infra's measured shape) and derives from the account's
#     concurrent-job allowance; the endpoint answering with a DECLARED fleet nothing online, and the
#     endpoint REFUSING outright, both mean no parallelism was measured and fail CLOSED to the
#     measured floor (`max(1, in_progress)` — a runner is running, so a runner exists). The record
#     says `runners=<n>(busy)` when the endpoint answered with an online count, `runners=~<n>` when
#     it did not.

# `is_num` — the shared shape predicate (no leading zeros, exactly like spawn-gate.sh: a value that
# reaches `$(( ))` must not be an invalid octal, and a non-number in a threshold makes `[ -gt ]`
# ERROR, which is FALSE, which OPENS a gate).
ciq_is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }

# `is_count` — the SHAPE **and** the MAGNITUDE. `is_num` accepts any number of digits, and a value
# above intmax makes `[ … -gt … ]` ERROR — an errored test is FALSE, and a FALSE comparison here
# falls through to `ok(...)`, i.e. it OPENS the gate whose whole purpose is to fail closed. The bound
# is 9 digits: ~7 orders above any real queue (the measured incident peaked at 97) and 10 orders
# below intmax's 19 digits (9.22e18), so no reading that could plausibly arrive can overflow the
# comparison, and a reading that does not fit is not a reading: it is UNKNOWN (the same verdict as
# unreadable), never "allowed". (#2333 review, P2: this sentence is the whole justification for the
# bound, and it used to claim "three orders" in BOTH clauses — 10^2 vs 10^9 and 10^9 vs 10^19.)
ciq_is_count() { ciq_is_num "${1:-}" && [ "${#1}" -le 9 ]; }

# ── the two tuning values (the ONE place) ───────────────────────────────────────────────────────
ciq_horizon_min() { # how long a lane will wait for its own CI verdict before the push is pointless
  local v="${CIQ_HORIZON_MIN:-20}"
  ciq_is_num "$v" && [ "$v" -ge 1 ] && [ "$v" -le 600 ] || v=20
  printf '%s' "$v"
}
ciq_job_p90_min() { # MEASURED typical job duration, minutes (see the header's measurement block)
  local v="${CIQ_JOB_P90_MIN:-10}"
  ciq_is_num "$v" && [ "$v" -ge 1 ] && [ "$v" -le 600 ] || v=10
  printf '%s' "$v"
}
ciq_hosted_concurrency() { # GitHub-HOSTED CI's concurrent-job allowance, jobs (20 on the Free plan)
  local v="${CIQ_HOSTED_CONCURRENCY:-20}"
  ciq_is_num "$v" && [ "$v" -ge 1 ] && [ "$v" -le 10000 ] || v=20
  printf '%s' "$v"
}

# ciq_ceiling <runners> -> the queued-run ceiling this runner count implies (see the derivation).
# Prints nothing and returns 1 on an unusable runner count, so a caller can distinguish "no ceiling
# could be derived" from "the ceiling is 0" (which would be a lane-cap in disguise and is refused:
# a 0 ceiling would defer every push forever, so the floor is 1 runner).
# ⛔ THE MAGNITUDE BOUND, NOT JUST THE SHAPE (#2333 review round 2, P2). `is_num` accepts any number
# of digits, so `ciq_ceiling 9223372036854775807` overflowed `r * h` and PRINTED `-1` (rc 0) — the
# operator's sanity-check verb reporting a ceiling the arithmetic never produced, contradicting this
# function's own contract. Every gate path pre-validates with `ciq_is_count`, so the blast radius was
# the operator surface — which is the one surface that exists to verify the derivation.
ciq_ceiling() {
  local r="${1:-}" h j
  ciq_is_count "$r" || return 1
  [ "$r" -ge 1 ] || r=1
  h="$(ciq_horizon_min)" || return 1
  j="$(ciq_job_p90_min)" || return 1
  [ "$j" -ge 1 ] || j=1
  printf '%s' "$(( (r * h + j - 1) / j ))"
}

# ciq_slug <owner/repo> -> a filename-safe key (one record per repo, never one box's queue for all).
ciq_slug() { printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._-' '_' | tr -s '_' '_'; }

# ciq_state_dir -> where the cached record lives. `$O/state` on a controller; overridable so the
# suite (and an operator) can point it at a sandbox without touching the live state directory.
ciq_state_dir() {
  local d="${CIQ_STATE_DIR:-${O:-$HOME/orchestrator}/state}"
  printf '%s' "$d"
}

# ciq_gh -> the reader. DELIBERATELY a function with an override: the suite stubs it, so the tests
# exercise the SHIPPED parsing and arithmetic against a canned feed instead of asserting on prose.
ciq_gh() { # <args...> -> JSON on stdout, non-zero when the read failed
  local ghbin="${CIQ_GH:-gh}"
  command -v "$ghbin" >/dev/null 2>&1 || return 127
  "$ghbin" api "$@" 2>/dev/null
}

# ciq_now -> epoch seconds (one seam, so the TTL is drivable in the suite).
ciq_now() { date +%s; }

# ciq_record_usable <record> <repo> -> 0 iff the record was written FOR <repo>.
# ⛔ THE RECORD FILENAME IS LOSSY, SO THE RECORD MUST CARRY ITS OWN IDENTITY (#2333 review, P2).
# `ciq_slug` maps `/` to `_`, so `a/b_c` and `a_b/c` collapse onto one `ci-queue-*` file: without
# this check the cache arms would decode one repo's `queued/running/runners` as the other's and
# decide a push with them, printing `state=cache` and a number the module believed it had
# validated. A record with NO `repo=` line (written by an older module) is also not usable — the
# direction of that refusal is a LIVE READ, and if that read fails the verdict is UNKNOWN (defer),
# so an unverifiable record can never widen the gate.
ciq_record_usable() {
  local rec="${1:-}" want="${2:-}" got
  [ -n "$rec" ] && [ -n "$want" ] || return 1
  got="$(printf '%s\n' "$rec" | sed -n 's/^repo=//p' | head -1)"
  [ -n "$got" ] && [ "$got" = "$want" ]
}

# ciq_read <owner/repo> [<state-dir>] -> sets the CIQ_* record; 0 = usable reading, 2 = UNKNOWN.
# Record fields (all set on every call, so a caller never reads a previous call's leftovers):
#   CIQ_QUEUED  runs waiting for a runner
#   CIQ_RUNNING runs executing now
#   CIQ_RUNNERS runners that can execute them (measured; `~` lower bound when inferred)
#   CIQ_BUSY    runners currently busy (blank when the endpoint did not answer)
#   CIQ_CEILING the derived ceiling for CIQ_RUNNERS
#   CIQ_STATE   fresh | cache | unknown
#   CIQ_AGE     seconds the record has been standing (0 for a fresh read)
#   CIQ_REPO    the repo the read was made against — and a RECORD carries its own `repo=` field,
#               so this is a real wrong-surface guard, not a label: a record whose `repo=` differs
#               from the repo being read is NOT usable (see ciq_record_usable), because the record
#               FILENAME is lossy — ciq_slug maps `/` to `_`, so `a/b_c` and `a_b/c` collide onto
#               one `ci-queue-*` file and one repo's queue would otherwise answer for the other's
#               (#2333 review, P2: this field was documented as the guard while nothing read it)
ciq_read() {
  local repo="${1:-}" dir="${2:-}" f cached="" at="" queued="" running="" runners="" busy="" now age ttl stale_max _rn declared="" rn_answered="" floor=""
  CIQ_QUEUED=""; CIQ_RUNNING=""; CIQ_RUNNERS=""; CIQ_BUSY=""; CIQ_CEILING=""; CIQ_STATE=unknown; CIQ_AGE=""; CIQ_REPO="$repo"
  [ -n "$repo" ] || return 2
  dir="${dir:-$(ciq_state_dir)}"
  f="$dir/ci-queue-$(ciq_slug "$repo")"
  ttl="${CIQ_TTL:-90}";        ciq_is_num "$ttl" || ttl=90
  stale_max="${CIQ_STALE_MAX:-900}"; ciq_is_num "$stale_max" || stale_max=900
  now="$(ciq_now)"; ciq_is_num "$now" || now=0

  # A fresh record answers for free. This is the ONLY fail-open here, and it is bounded by `ttl`.
  if [ -f "$f" ]; then
    cached="$(cat "$f" 2>/dev/null || true)"
    at="$(printf '%s\n' "$cached" | sed -n 's/^at=//p' | head -1)"
    if ciq_is_num "${at:-}"; then
      age=$(( now - at ))
      # ⛔ A FUTURE `at=` IS NOT A FRESH RECORD (#2333 review cycle 2, P2). Clamping a negative age to
      # 0 made ANY record written under a forward-stepped clock (or after a step-back) answer
      # `state=cache age=0s` for ever — neither `ttl` nor `stale_max` could ever bind, so the ONE
      # fail-open here was unbounded. The record is simply not usable; the live read decides, and if
      # that fails the staleness arm applies the same rule and the verdict is UNKNOWN (fail closed).
      if [ "$age" -ge 0 ] && [ "$ttl" -ge 1 ] && [ "$age" -le "$ttl" ] \
         && ciq_record_usable "$cached" "$repo"; then
        CIQ_QUEUED="$(printf '%s\n' "$cached" | sed -n 's/^queued=//p' | head -1)"
        CIQ_RUNNING="$(printf '%s\n' "$cached" | sed -n 's/^running=//p' | head -1)"
        CIQ_RUNNERS="$(printf '%s\n' "$cached" | sed -n 's/^runners=//p' | head -1)"
        CIQ_BUSY="$(printf '%s\n' "$cached" | sed -n 's/^busy=//p' | head -1)"
        if ciq_is_count "${CIQ_QUEUED:-}" && ciq_is_count "${CIQ_RUNNERS#\~}"; then
          # ⛔ `cache`, NOT `fresh` (#2333 review P1). A TTL hit is a RECORD — up to `ttl` seconds
          # old — and calling it fresh is the exact claim this module exists to refuse: the token
          # then renders `state=cache age=<n>s` on every line that acts on it. `fresh` is reserved
          # for a live read (age 0).
          CIQ_STATE=cache; CIQ_AGE="$age"
          CIQ_CEILING="$(ciq_ceiling "${CIQ_RUNNERS#\~}")" || CIQ_CEILING=""
          return 0
        fi
      fi
    fi
  fi

  # A live read: three cheap counts. `per_page=1` because only `total_count` is wanted — the array is
  # not read at all, so a capped page can never truncate the number that matters.
  queued="$(ciq_gh "repos/$repo/actions/runs?status=queued&per_page=1" \
            | sed -n 's/.*"total_count":[ ]*\([0-9][0-9]*\).*/\1/p' | head -1)" || queued=""
  running="$(ciq_gh "repos/$repo/actions/runs?status=in_progress&per_page=1" \
            | sed -n 's/.*"total_count":[ ]*\([0-9][0-9]*\).*/\1/p' | head -1)" || running=""
  busy=""; runners=""; declared=""; rn_answered=""
  # ⛔ `--paginate` LAST, AFTER THE ENDPOINT (#2333 review P1). The endpoint returns ONE page by
  # default (30 objects), so a fleet bigger than that had its count TRUNCATED into an under-derived
  # ceiling that defers a queue which would have drained inside the horizon. The flag MUST come after
  # the endpoint: the rigs' `gh` stubs dispatch on `$2` (`case "$2" in … *actions/runners*)` in
  # ci-queue.test.sh, harness-refresh.test.sh, spawn-gate.test.sh and test-crossbox.sh), so a leading
  # flag shifts the URL into `$3`, every stub takes its `*) exit 1` arm, and the count would silently
  # go unmeasured — with the suite red for a reason that hides the parse it exists to cover.
  # Concatenated pages still count correctly: the OBJECTS are counted, never `total_count`.
  if _rn="$(ciq_gh "repos/$repo/actions/runners" --paginate)"; then
    # ANSWERED. `rn_answered` is what separates a measured hosted zero from an unreadable endpoint
    # (see the three-branch decision below); without it both collapse into the permissive arm.
    rn_answered=1
    # Count the online/busy runner objects. The endpoint returns `{"total_count":N,"runners":[…]}`;
    # a repo with no runners of its own (agent-infra, measured) yields 0 and is NOT an error — it
    # simply does not answer the question, so the inference below takes over.
    # ⛔ WHITESPACE-TOLERANT, AND THAT IS THE WHOLE POINT (#2333 review P1): `gh api` JSON is
    # PRETTY-PRINTED by default (`"status": "online"`), so a `'"status":"online"'` match finds
    # NOTHING in production and `runners` silently degrades to `~in_progress` — a ceiling derived
    # from the wrong quantity, three times too permissive on the measured box, i.e. exactly the
    # over-dispatch this module exists to stop. The suite's stubs emit compact JSON, so no arm could
    # have caught it; one stub now emits the pretty shape on purpose.
    runners="$(printf '%s' "$_rn" | tr ',' '\n' | grep -cE '"status":[[:space:]]*"online"' 2>/dev/null || true)"
    busy="$(printf '%s' "$_rn" | tr ',' '\n' | grep -cE '"busy":[[:space:]]*true' 2>/dev/null || true)"
    # The DECLARED fleet size, which distinguishes the two different zeroes below (#2333 review P1).
    declared="$(printf '%s' "$_rn" | tr ',' '\n' \
      | sed -n 's/.*"total_count":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
    ciq_is_num "${declared:-}" || declared=""
    ciq_is_num "${runners:-}" || runners=""
    ciq_is_num "${busy:-}" || busy=""
    [ "${runners:-0}" -ge 1 ] 2>/dev/null || { runners=""; busy=""; }
  fi
  if ! ciq_is_num "${queued:-}" || ! ciq_is_num "${running:-}"; then
    queued=""; running=""
  fi
  if [ -z "${queued:-}" ]; then
    # The read failed. Fall back to the last good record inside the staleness window, and SAY so.
    if ciq_is_num "${at:-}" && [ -n "${cached:-}" ]; then
      age=$(( now - at ))
      # …and the same rule on the staleness fallback: a record stamped in the FUTURE is not evidence
      # of a recent reading (see the TTL arm above).
      if [ "$age" -ge 0 ] && [ "$age" -le "$stale_max" ] \
         && ciq_record_usable "$cached" "$repo"; then
        CIQ_QUEUED="$(printf '%s\n' "$cached" | sed -n 's/^queued=//p' | head -1)"
        CIQ_RUNNING="$(printf '%s\n' "$cached" | sed -n 's/^running=//p' | head -1)"
        CIQ_RUNNERS="$(printf '%s\n' "$cached" | sed -n 's/^runners=//p' | head -1)"
        CIQ_BUSY="$(printf '%s\n' "$cached" | sed -n 's/^busy=//p' | head -1)"
        if ciq_is_count "${CIQ_QUEUED:-}" && ciq_is_count "${CIQ_RUNNERS#\~}"; then
          CIQ_STATE=cache; CIQ_AGE="$age"
          CIQ_CEILING="$(ciq_ceiling "${CIQ_RUNNERS#\~}")" || CIQ_CEILING=""
          return 0
        fi
      fi
    fi
    # ⛔ AND THE RECORD IS CLEARED, NOT LEFT HOLDING THE REJECTED CACHE VALUES (#2333 cycle 7, P2).
    # The cache arms above assign `CIQ_QUEUED`/`CIQ_RUNNERS` BEFORE `ciq_is_count` decides they are
    # not a reading, so the early `return 2` used to leave a caller holding a number this module had
    # already REJECTED while `state=unknown` said it had measured nothing — the "a caller never reads
    # a previous call's leftovers" contract stated at the top of this function, broken on the one
    # path a reader is least likely to check.
    CIQ_QUEUED=""; CIQ_RUNNING=""; CIQ_RUNNERS=""; CIQ_BUSY=""; CIQ_CEILING=""; CIQ_AGE=""
    CIQ_STATE=unknown
    return 2
  fi
  if [ -z "${runners:-}" ]; then
    # ⛔ THREE WAYS TO HAVE NO MEASURED RUNNER COUNT, AND THEY MUST NOT SHARE ONE ANSWER
    # (#2333 review cycles 9-11, P1). The distinctions are the whole fail-direction of this gate:
    #
    # (a) ANSWERED, `total_count == 0` — no self-hosted fleet of its own: the HOSTED-CI shape, and
    #     agent-infra's MEASURED shape (`{"total_count":0,"runners":[]}` while 7 runs executed: those
    #     jobs run on GitHub-hosted runners, which never appear in this list). Hosted throughput is
    #     the account's CONCURRENT-JOB allowance, so derive from that (declared and overridable here,
    #     like every other tuning value). Deriving it from `in_progress` instead made the ceiling
    #     SMALLEST when the box was idle: queued=4 running=1 => ceiling 2 => DEFERRED — the "a rule
    #     that defers on 4 would be a fleet-wide stop" failure this module's header names as
    #     unacceptable, on the very repo the gate was built for.
    # (b) ANSWERED, `total_count >= 1` with nothing online — a SELF-HOSTED FLEET THAT CANNOT RUN.
    #     NOT the hosted shape: claiming the allowance here quadruples the ceiling and ALLOWS the
    #     incident's own 31-deep queue with nothing able to drain it (measured on
    #     `{"total_count":5,"runners":[{"status":"offline"}]}`). Fail CLOSED to the measured floor.
    # (c) REFUSED / unparseable — nothing was measured at all, so the allowance is a GUESS in the
    #     permissive direction: measured, one refused `actions/runners` call turned `queued=31`
    #     running=5 (a 5-runner fleet) into `~20`/ceiling 40 => ALLOWED, and OVERWROTE a good record
    #     with the poisoned one for TTL+STALE_MAX (~16 min) — the one shape where the gate reports
    #     `fresh` while permitting 4x its true ceiling. Fail CLOSED to the measured floor too.
    #
    # The measured floor applies to EVERY branch: every executing run occupies a runner, so `running`
    # is parallelism that demonstrably exists — bounded by the allowance, because a garbled count must
    # not become a ceiling the gate can never reach (9 digits pass `ciq_is_count` and would yield
    # ceiling 999999998, switching back-pressure off while the token still reads like a measurement).
    # ⛔ CLAMPED, NEVER DISCARDED (#2333 review, P2). This test used to DISCARD a measured count that
    # exceeded the allowance, which is not what the sentence above asks for and carried a 20x CLIFF with
    # no disclosure: on the unmeasured branches ((b) declared-but-offline, (c) refused) a repo running 19
    # or 20 concurrent jobs derived ceiling 38/40 and ALLOWED, while 21 — ONE MORE executing job — fell to
    # `runners=~1`/ceiling 2 and DEFERRED every CI-spending act on the box, still printing `state=fresh` as
    # though 1 runner were the measurement. That is the fleet-wide stop this module's header names as
    # unacceptable, reached by a change of one digit, and arm (b6c) encoded it while its own label said
    # "bounded by the allowance". Clamping keeps the garble bound and bounds it at the module's OWN
    # accepted maximum ceiling (2x the hosted allowance — the same width the allowance path already
    # yields), so `running=21` derives 42 and a 9-digit garble derives 40, never 999999998.
    floor=1
    if ciq_is_count "${running:-}" && [ "${running:-0}" -ge 1 ]; then
      floor="$running"
      if [ "$floor" -gt "$(ciq_hosted_concurrency)" ]; then floor="$(ciq_hosted_concurrency)"; fi
    fi
    # ⛔ THE ALLOWANCE DEMANDS POSITIVE EVIDENCE: A **PARSED** `total_count == 0` (#2333 review
    # cycle 12, P1). Until this cycle the test was `[ -z "$declared" ] || [ "$declared" -eq 0 ]`, and
    # `declared` is EMPTY exactly when the answered page carried no parseable `total_count` — i.e.
    # branch (c), unparseable — so an ANSWERED-but-unusable body took the hosted ALLOWANCE, and the
    # shape the (c) comment above records as measured-dangerous came back through the front door:
    # `queued=31` on a repo with nothing online became `~20`/ceiling 40 => ALLOWED, the gate
    # reporting a measurement it never made. Only a parsed zero selects the allowance; anything else
    # unmeasured fails CLOSED to the floor, which is what (b) and (c) both say.
    if [ "${rn_answered:-0}" = 1 ] && [ "${declared:-x}" = "0" ]; then
      runners="$(ciq_hosted_concurrency)"
    else
      runners="$floor"
    fi
    if [ "$floor" -gt "$runners" ]; then runners="$floor"; fi
    runners="~$runners"
  fi
  CIQ_QUEUED="$queued"; CIQ_RUNNING="${running:-0}"; CIQ_RUNNERS="$runners"; CIQ_BUSY="$busy"
  CIQ_STATE=fresh; CIQ_AGE=0
  CIQ_CEILING="$(ciq_ceiling "${CIQ_RUNNERS#\~}")" || CIQ_CEILING=""
  mkdir -p "$dir" 2>/dev/null || true
  { printf 'repo=%s\nqueued=%s\nrunning=%s\nrunners=%s\nbusy=%s\nat=%s\n' \
      "$repo" "$CIQ_QUEUED" "$CIQ_RUNNING" "$CIQ_RUNNERS" "${CIQ_BUSY:-}" "$now"; } > "$f" 2>/dev/null || true
  return 0
}

# ciq_eval -> the DECISION, from the record already in CIQ_* (no read, no subshell, so a caller
# that captured nothing still sees the numbers that produced the token). Prints one token:
#   deep(...)   rc 0 — do NOT send more CI-spending work
#   ok(...)     rc 1 — allowed
#   unknown(…)  rc 2 — unreadable: DEFER (fail closed)
# The token is the whole decision, so a caller cannot read the numbers and reach its own conclusion
# differently from the gate that is logged (the "printed decision vs acted-on decision" class this
# harness has already fixed twice).
ciq_eval() {
  local q r n c sm
  if [ "${CIQ_STATE:-unknown}" = unknown ]; then
    # …and the number PRINTED is the one that DECIDED (#2333 review cycle 2, P2): `ciq_read`
    # normalises a garbage `CIQ_STALE_MAX` to 900, so echoing the raw variable claimed a window the
    # module never used.
    sm="${CIQ_STALE_MAX:-900}"; ciq_is_num "$sm" || sm=900
    printf 'unknown(queue unreadable: no fresh read and no record inside %ss — CI capacity is UNKNOWN, which defers CI-spending work rather than opening the gate)' "$sm"
    return 2
  fi
  q="$CIQ_QUEUED"; r="$CIQ_RUNNING"; n="${CIQ_RUNNERS#\~}"; c="${CIQ_CEILING:-}"
  if [ -z "${c:-}" ]; then
    printf 'unknown(no ceiling derivable from runners=%s)' "${CIQ_RUNNERS:-?}"
    return 2
  fi
  # ⛔ A NUMBER THAT DOES NOT FIT IS NOT A READING (#2333 review P2). Above intmax `[ … -gt … ]`
  # ERRORS, an errored test is FALSE, and a FALSE test lands on the `ok(...)` branch — the gate
  # OPENING on the one value it could not compare. Out of range is therefore UNKNOWN, the same
  # verdict as unreadable: the fail-CLOSED direction, which is the only direction this gate has.
  if ! ciq_is_count "${q:-}" || ! ciq_is_count "${r:-}" || ! ciq_is_count "${n:-}" || ! ciq_is_count "${c:-}"; then
    printf 'unknown(not a comparable reading: queued=%s running=%s runners=%s ceiling=%s)' \
      "${q:-?}" "${r:-?}" "${CIQ_RUNNERS:-?}" "${c:-?}"
    return 2
  fi
  if [ "$q" -gt "$c" ]; then
    # ⛔ STATE AND AGE RIDE THE `deep` TOKEN TOO (#2333 review P1). The cached record is the ONE
    # fail-open here, and a `deep(...)` that said neither `state=cache` nor `age=<n>s` presented a
    # minutes-old reading exactly as it presents a fresh one — on the branch that then DEFERS.
    printf 'deep(queued=%s running=%s runners=%s%s ceiling=%s derived=ceil(%s*%s/%s) state=%s%s)' \
      "$q" "$r" "${CIQ_RUNNERS}" "$( { [ "${CIQ_RUNNERS#\~}" = "$CIQ_RUNNERS" ] && [ -n "${CIQ_BUSY:-}" ]; } && printf ' busy=%s' "$CIQ_BUSY" )" \
      "$c" "$n" "$(ciq_horizon_min)" "$(ciq_job_p90_min)" "${CIQ_STATE}" \
      "$( [ "${CIQ_STATE}" = cache ] && printf ' age=%ss' "${CIQ_AGE}" )"
    return 0
  fi
  printf 'ok(queued=%s running=%s runners=%s ceiling=%s state=%s%s)' \
    "$q" "$r" "${CIQ_RUNNERS}" "$c" "${CIQ_STATE}" "$( [ "${CIQ_STATE}" = cache ] && printf ' age=%ss' "${CIQ_AGE}" )"
  return 1
}

# ciq_verdict <owner/repo> [<state-dir>] -> read, then evaluate IN THIS SHELL (a `$( )` here would
# end the subshell immediately and leave every caller with an empty record — the exact defect class
# `lo_select` carries a ⛔ comment about).
ciq_verdict() {
  ciq_read "${1:-}" "${2:-}" || { ciq_eval; return $?; }
  ciq_eval
}

# ciq_defer_line — THE ONE printer. Silence is what makes a deferral look like a bug, so this is the
# only place the harness is allowed to render a deferral: it names the queue depth, the runner count,
# the ceiling it was measured against, and WHAT was deferred. rc 0 (deep) and rc 2 (unknown) both
# produce a line; rc 1 (allowed) produces none.
ciq_defer_line() { # <what> <verdict-token> <rc>
  local what="${1:-work}" v="${2:-}" rc="${3:-1}"
  case "$rc" in
    0) printf '[ci-queue] DEFERRED %s — %s; ceiling=ceil(runners*%sm/%sm) so this push would queue behind the backlog and invalidate the head'"'"'s review record (a SHA-bound attestation); NOTHING IS LOST: the item keeps its place and is re-decided on the next cycle, and the deferral consumed no attempt\n' \
         "$what" "$v" "$(ciq_horizon_min)" "$(ciq_job_p90_min)"
       return 0 ;;
    2) printf '[ci-queue] DEFERRED %s — %s; CI capacity is UNKNOWN, and an unreadable queue is not an empty one, so CI-spending work is held rather than sent into a queue nobody could read. NOTHING IS LOST: it is re-decided on the next cycle and the deferral consumed no attempt\n' \
         "$what" "$v"
       return 0 ;;
    *) return 1 ;;
  esac
}

# ciq_defer_note <what> [<state-dir>] -> RE-READ, then print. ⛔ NOT WIRED, AND IT MUST NOT BE
# (#2333 merge review, P3). No shipping surface calls it: `ciq_cli` reads in-shell and calls
# `ciq_eval` directly, and every wiring site calls `ciq_defer_note_here`. It survives ONLY as the
# re-reading REFERENCE the suite checks the in-shell path against — the differential arm that proves
# `ciq_defer_note_here` cannot disagree with the decision it was handed. The docstring used to call
# it "the standalone/CLI entry point", which invited exactly the re-wiring this module removed: a
# second read can DISAGREE with the decision whenever the queue moves between the two calls, and on
# a disagreement the old code printed NOTHING — a deferral with no line, the single failure this
# module exists to prevent. `ci-queue.test.sh` (e15) asserts no shipping file calls it.
ciq_defer_note() {
  local v rc
  v="$(ciq_verdict "${CIQ_REPO_ARG:-${OR:-}}" "${CIQ_STATE_DIR:-}")"; rc=$?
  ciq_defer_line "${1:-work}" "$v" "$rc"
}

# ciq_defer_note_here <what> -> print the line for a caller that has ALREADY read (the wiring).
# ⛔ IT MUST NOT RE-READ, AND THIS IS THE WHOLE REASON IT EXISTS (#2333 review P1): the predicate
# `ciq_ci_allowed` reads in the CALLER'S shell, so the CIQ_* here are that decision's own reading. A
# second read could DISAGREE with it whenever the queue moved between the two calls — and on a
# disagreement the old code printed NOTHING (`*) return 1`), i.e. a deferral with no line at all,
# the single failure this module exists to prevent. It also cost three extra `gh` calls per deferred
# PR, which on a 90-deep queue multiplied across every CONFLICTED and CI-red PR in a sweep.
ciq_defer_note_here() {
  local v rc
  v="$(ciq_eval)"; rc=$?
  ciq_defer_line "${1:-work}" "$v" "$rc"
}

# ciq_ci_allowed <owner/repo> [<state-dir>] -> 0 = send CI-spending work, 1 = defer (and the caller
# must print ciq_defer_note_here's line). This is the predicate the wiring calls; it never prints,
# so a
# caller inside a `$( )` cannot swallow the log.
ciq_ci_allowed() {
  ciq_verdict "${1:-${OR:-}}" "${2:-${CIQ_STATE_DIR:-}}" >/dev/null 2>&1
  case $? in 1) return 0 ;; *) return 1 ;; esac
}

# ── standalone: `bash ci-queue.sh status [--repo owner/name]` ───────────────────────────────────
# Prints the verdict, the record and the derivation. Exit code follows the verdict (0 deep, 1 ok,
# 2 unknown) so an operator (or a hook) can branch on it without parsing.
ciq_cli() {
  local repo="" verb="${1:-status}" operand=""
  # ⛔ `shift 2>/dev/null` IS NOT `shift 2` WITH STDERR SILENCED (#2333 review cycle 2, P2): bash parses
  # `2>` as an FD redirect, so that spelling shifts ONE positional and drops the verb — accidentally
  # right here, and a trap for the next editor who adds a second `shift`. Drop the verb explicitly.
  [ $# -ge 1 ] && shift
  # ⛔ `shift 2` WITH ONE ARGUMENT LEFT DOES NOTHING and leaves the parameters unchanged, so
  # `--repo` as the last word looped forever (#2333 review P2 — measured: `timeout 5 ci-queue.sh
  # status --repo` → rc 124). Every option that takes a value now proves the value exists.
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)      [ $# -ge 2 ] || { printf 'ci-queue: --repo needs a value\n' >&2; return 64; }; repo="$2"; shift 2 ;;
      --state-dir) [ $# -ge 2 ] || { printf 'ci-queue: --state-dir needs a value\n' >&2; return 64; }; CIQ_STATE_DIR="$2"; shift 2 ;;
      --runners)   [ $# -ge 2 ] || { printf 'ci-queue: --runners needs a value\n' >&2; return 64; }; operand="$2"; shift 2 ;;
      *) [ -n "$operand" ] || operand="$1"; shift ;;
    esac
  done
  [ -n "$repo" ] || repo="${OR:-}"
  case "$verb" in
    status|check|defer)
      CIQ_REPO_ARG="$repo"
      if ciq_read "$repo"; then :; fi
      ciq_eval; rc=$?; printf '\n'
      # ⛔ `source` is DERIVED FROM WHAT HAPPENED, not hard-printed (#2333 review P2: CIQ_TYPE was
      # assigned nowhere in the repo, so it said `source=gh` on the run where gh had failed), and the
      # record's PATH is labelled a path — `at=` in the record is an epoch second, so printing a
      # path under that label was a second unmeasured claim.
      printf 'repo=%s state=%s source=%s age=%ss\n' "${repo:-?}" "${CIQ_STATE}" \
        "$( case "${CIQ_STATE}" in fresh) printf 'gh' ;; cache) printf 'record(cache)' ;; *) printf 'unknown' ;; esac )" \
        "${CIQ_AGE:-?}"
      printf 'record: queued=%s running=%s runners=%s busy=%s record-file=%s\n' \
        "${CIQ_QUEUED:-?}" "${CIQ_RUNNING:-?}" "${CIQ_RUNNERS:-?}" "${CIQ_BUSY:-?}" "$(ciq_state_dir)/ci-queue-$(ciq_slug "${repo:-}")"
      printf 'derivation: ceiling = ceil(runners * horizon / job_p90) = ceil(%s * %s / %s) = %s\n' \
        "${CIQ_RUNNERS:-?}" "$(ciq_horizon_min)" "$(ciq_job_p90_min)" "${CIQ_CEILING:-?}"
      if [ "$verb" = defer ] && [ "$rc" != 1 ]; then
        # ⛔ IN-SHELL, NOT A SECOND READ (#2333 cycle 3, P2). `ciq_defer_note` re-reads, so on a queue
        # that moved between line 371's read and this one the second verdict could be `ok` — and then
        # NOTHING was printed while the command still exited 0/2: a deferral with no line, the one
        # failure the wiring's `ciq_defer_note_here` was introduced to eliminate. It also printed the
        # `record:`/`derivation:` block from one read beside a line derived from another.
        v="$(ciq_eval)"; drc=$?
        ciq_defer_line "CI-spending work (manual check)" "$v" "$drc"
      fi
      return "$rc" ;;
    ceiling)
      # ⛔ THE OPERAND SURVIVED THE OPTION LOOP (#2333 review P2: it was `"${2:-1}"` AFTER the loop,
      # so `ci-queue.sh ceiling 5` printed the 1-runner floor every time — the one operator surface
      # for sanity-checking the derivation always answered 2).
      ciq_ceiling "${operand:-1}" || return 1
      printf '\n'; return 0 ;;
    *) printf 'usage: ci-queue.sh status|defer|ceiling [--repo owner/name] [--state-dir DIR] [--runners N]\n' >&2; return 64 ;;
  esac
}

# Executed (not sourced)? run the CLI. `BASH_SOURCE` is unset when the file is piped to a shell, in
# which case the CLI is the only sensible reading.
if [ "${BASH_SOURCE:-}" = "$0" ] || { [ -z "${BASH_SOURCE+x}" ] && [ -n "${0:-}" ]; }; then
  ciq_cli "$@"
  exit $?
fi
