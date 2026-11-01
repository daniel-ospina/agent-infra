#!/usr/bin/env bash
# ci-queue.sh — CI BACK-PRESSURE: how deep is the repo's CI queue, and may this box send it more
# work yet? Sourced by `orch-loop.sh` (the cycle's read, before the ISSUE dispatch, plus the CI rerun
# site) and by `dispatch-merge.sh` (the batch dispatcher) — and NOT by `fix-one.sh`, which stopped
# reading it in #2927 because a fixer is REPAIR — and runnable STANDALONE
# (`bash ci-queue.sh status --repo owner/name`), because the same bytes must answer the question on
# whichever surface asks it. It never calls `set` — a sourced library must
# not mutate its caller's shell options.
#
# ── COVERAGE (#2296 review cycle 4, revised by #2927) ───────────────────────────────────────────
# Gated, because each one ADDS a run to the queue: the ISSUE path (`orch-loop.sh`'s dispatch block,
# which reads before dispatch), the CI RERUN, and the batch dispatcher `dispatch-merge.sh`.
# ⛔ AND EVERY FIXER SURFACE IS *NOT* GATED, BY DESIGN — A FIXER IS REPAIR (#2927). This block used to
# list the THREE fixer spawn arms (CONFLICTED, CI-red, review-gate) and every pre-push check in
# `fix-one.sh` as GATED; that census outlived the gate. It is the class of coverage claim a reader
# trusts and then stops checking (#2540) — read from the other side, an operator would have believed
# the repair path was protected when this module no longer sees it at all. Repair acts on a PR that
# already exists, so its bound is this box's lane slots (`MAX_LANES` vs lanes alive) and the
# load/disk/headroom gate, which is what a lane actually consumes; the depth this gate prices is
# CI concurrency belonging to NEW-PR work. See the class rule below for the basis, and #2927 for the
# measurement (41 consecutive repair dispatches skipped while 8 runners and ~11 lane slots sat idle).
# ⛔ THE FOURTH-ARM CHURN IS GONE WITH IT (#2408's disclosure, superseded). `orch-loop.sh`'s RED-TREE
# fixer used to book its attempt, spawn, and then be turned away at `fix-one.sh`'s first push, so the
# cost was CHURN. Nothing on the repair path reads this module now, so that refusal cannot happen,
# and the refund line no longer has to name a second cause — it reads `another box holds the claim`,
# not `another box holds the claim, or the CI-queue gate deferred the push`. A lane that is started
# will push.
# ⛔ AND IT IS NOT THE ONLY UNGATED PUSHER — this paragraph used to claim it was, which is the class
# of coverage claim a reader trusts and then stops checking (#2540). `pr-doctor`'s `prfix` workers
# are the other one, and they are not an orch-loop arm at all: `pr-doctor.py` spawns up to `MAX_FIX`
# of them (`spawn_argv(..., "prfix")`, :2151) with briefs that end in `git push origin …`
# (:1723-1733) or `gh run rerun …` (:1898), through `nonblocking-dispatch.sh`/`spawn-gate.sh`,
# neither of which reads this module — `rg -c 'ciq|ci-queue' scripts/pr-doctor.py` is 0. The `prfix`
# kind is declared for the CREATION back-pressure gate (#2409), not this one, so on the repo whose
# 92-deep queue this header opens with, a launchd job still adds CI behind it. ⛔ THAT SURFACE STAYS
# UNGATED BY DECISION, NOT BY OMISSION: #2540 asks for it to be gated, and #2927 rules repair — of
# which a `prfix` worker is one — out of this gate on purpose (its bound is the box's lane slots and
# the load/disk gate). So wiring it is a RE-OPEN OF #2927, argued there with the measurement, and NOT
# an execution of #2540; the README's §CI back-pressure says the same thing, because two opposite
# instructions in two files this change touches is how the next lane picks the wrong one. The
# standalone verb below (`status`, rc 0 deep / 1 ok / 2 unknown) exists so a caller that is not bash
# can branch on it — it does not by itself decide that anything should be wired to it.
# ⛔ NOT gated, on purpose: the merge rail's second-sample re-run (`admin-merge.sh`, the flake retry).
# It is not an omission — a rail that is MERGING removes a PR and its load from the system, and
# refusing the retry would replace a merge with a stuck red head; the retry happens only inside that
# merge decision. Stated here because a coverage claim a reader cannot check is a claim that rots.
#
# ── WHY THIS EXISTS (measured 2026-10-22 13:40 UTC, both repos) ─────────────────────────────────
#   tortoise      queued=92  in_progress=6  runners online=5 (busy=5)   ← queue 18x the runner count
#   agent-infra   queued=97  in_progress=7  runners `total_count: 0`    ← 97 runs, 7 executing on
#                                                                          GitHub-HOSTED runners (a)
#   job wait created->started:  tortoise P50 0.0m P90  2.5m max 11.2m
#                               agent-infra P50 5.0m P90 11.7m max 13.0m
#   single longest job:         agent-infra `bash-suites` 20.3m; tortoise `queue-health` 11.3m
# After a batch of rebases agent-infra went from 4 to 31 BLOCKED PRs at once, each needing a full CI
# pass. ⛔ The 5-runner self-hosted fleet is TORTOISE's, not agent-infra's: agent-infra's own
# `actions/runners` answers `total_count: 0` because its jobs run on GitHub-HOSTED runners, and
# which of those two shapes a repo is in selects the fail-direction below (a)/(b)/(c) — see
# `ciq_ceiling`'s hosted arm, the ONE place the reading is interpreted. NOTHING FINISHES BECAUSE
# EVERYTHING STARTED: throughput
# (merges/hour) went DOWN while the work went up. This file is the reading that was missing: every
# existing gate in this harness — `load=`, `mem_avail=`, `swap_free=`, `capacity-placement` — measures
# THE BOX, and a box with 20 idle lane slots and a 90-deep CI queue looks perfectly healthy.
#
# ⛔ IT IS A MEASURED QUEUE READ, NOT A WORKER/LANE CAP — and that distinction is the recorded
# decision, not this file's preference. The owner ruled on 2026-10-17 "dispatch should be gated on
# capacity, not on number of lanes" (argued at `capacity.sh`'s ceiling section and at orch-loop.sh's
# MAX_LANES block), and re-stating that as a fixed lane ceiling here would reopen a settled
# decision through a side door. So the gate counts THE OTHER SIDE'S CAPACITY: how many runs are
# QUEUED — the GitHub enum value `status=queued`, EXACTLY and only that one (residual (i) below:
# `waiting`/`requested`/`pending` are deliberately NOT counted, and the direction is stated) — how
# many are executing (`status=in_progress`), how many runners can execute them. A box that adds work when the
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
#     `state=cache age=<n>s` in every line it produces, so a stale reading is never presented as a
#     fresh one. (This sentence used to promise a `cache(<age>s)` form that NO line emits: the
#     tokens are `deep(… state=cache age=Ns)` and `ok(… state=cache age=Ns)`, and the CLI line is
#     `state=cache source=record(cache) age=Ns` — a grep for `cache(` matched only this comment.
#     #2333 review, P2.) Past that window the record is dropped and the verdict is UNKNOWN again.
#   * `runners` is the FLEET SIZE — the supply side of the derivation, never the demand side. It is
#     MEASURED when the repo endpoint answers with an online runner count.
#     ⛔ NEVER THE IN-PROGRESS COUNT (#2927). `running` is how many JOBS are executing; deriving the
#     ceiling's runner term from it made the gate read the box's own load as the world's capacity and
#     printed it in the same `runners=` field a real measurement uses — measured 2026-10-27 on cell 4:
#     `queued=33 running=2 runners=~2 => ceiling=4 => DEEP`, on an agent-infra whose jobs run on
#     GitHub-HOSTED runners while its own 8-runner self-hosted fleet sat all-online and all-idle, and
#     41 consecutive PR-repair dispatches were skipped by that one number. When no count is measured
#     there are THREE cases and they do not share one answer (#2333 review cycles 9-11, revised by
#     #2927):
#       (a) the endpoint ANSWERING `total_count: 0` is the hosted-CI shape (GitHub-hosted runners
#           never appear in that list — agent-infra's measured shape) and derives from the account's
#           concurrent-job allowance;
#       (b) the endpoint answering with a DECLARED fleet and nothing online means the hosted jobs ARE
#           the running parallelism, so `running` is a legitimate SUPPLY LOWER BOUND (and dropping it
#           was measured to pin the ceiling at 2 on a repo that runs on hosted capacity — arm (b12));
#       (c) the endpoint REFUSING outright or answering with no parseable `total_count` means NOTHING
#           was measured, so the count falls to the module's own documented floor of ONE runner (the
#           same value `ciq_ceiling` floors at — a 0 ceiling would defer every push for ever) and the
#           token NAMES the reading that failed (`fleet=unreadable(<the endpoint's words>)`), because
#           an inference presented as a measurement is the defect this gate exists to avoid.
#     The record says `runners=<n>(busy)` when the endpoint answered with an online count,
#     `runners=~<n>` when it did not.
#   * ⛔ WHAT THIS GATE IS ALLOWED TO GATE IS TWO CLASSES, AND THE LINE IS THE ACTION'S COST (#2927).
#     ONLY work that ADDS A NEW CI RUN is queue-gated: opening a PR from an issue (agent-infra's
#     `dispatch-merge.sh`, and `orch-loop.sh`'s ISSUE path) and the CI RERUN (`orch-loop.sh`'s rerun
#     site — the one verb in the sweep that queues a fresh run for the same head). REPAIR — acting on a
#     PR that already exists (a red-check fixer, a review-findings fixer, a conflict/rebase fixer, the
#     PR-sickness queue) — is NOT queue-gated by this module and must
#     not become so again: its real bounds are the lane slots (`MAX_LANES` vs lanes alive) and the
#     load/headroom gate.
#     ⛔ THE BASIS IS A DECISION PLUS A MEASUREMENT, NOT A COST CLAIM — and it used to be stated as a
#     cost claim, which is what made it refutable. "Its pass is already spent" is NOT true: a repair
#     push does start a fresh CI run. Two things are true, and they are what carry the exclusion:
#       (i) the NUMBER was the wrong quantity — `queued=33 running=2` derived `ceiling=4` and read
#           DEEP off demand-as-supply, so the gate was refusing repair on a reading of the box's own
#           load rather than of the world's capacity; and
#       (ii) ON THIS REPO SOME REPAIR PUSHES SUPERSEDE — AND SUPERSESSION IS A PROPERTY OF THE
#           WORKFLOW, NOT OF "A REPAIR PUSH". A `pull_request` / `pull_request_target` workflow
#           supersedes its PR's earlier run only if it declares a `concurrency:` GROUP; a workflow
#           with NO `concurrency:` block STACKS, and a repair push adds a run to it. ⛔ SO ENUMERATE
#           BY TRIGGER + CONCURRENCY, NEVER BY MEMORY: the previous revision of this paragraph
#           named ONE stacking workflow and there are TWO — a hand-maintained list of filenames is
#           the defect that produced that round, which is why the PROPERTY above is the rule and
#           the four names below are only its measurement at this commit. Every workflow in
#           `.github/workflows/` that fires on a PR push:
#             ci.yml                     `pull_request` (default opened/synchronize/reopened),
#                                        `group: ci-${{ github.ref }}`, cancel-in-progress: true
#                                                                             → SUPERSEDES
#             harness-single-source.yml  `pull_request` (same defaults), `group:
#                                        harness-single-source-${{ github.ref }}`, same flag
#                                                                             → SUPERSEDES
#             pipeline-compliance.yml    `pull_request` on main, types [opened, synchronize,
#                                        reopened, edited], NO `concurrency:` block
#                                                                             → STACKS (#2474)
#             workflow-lock.yml          `pull_request_target`, the same four types, NO
#                                        `concurrency:` block                    → STACKS (#2474)
#           BOTH stacking files omit the block deliberately (#2474): a per-PR group cannot tell a
#           head from its successor, and a cancelled leg reads NON-RED — which on
#           `pipeline-compliance` means the repo's ONLY required check (#646) would read
#           green-with-no-verdict on the newest tree, and on `workflow-lock` would satisfy the
#           guard-generation wait while contributing no verdict. So the required check is one of the
#           two that DOES stack, and a repair push costs a run there every time.
#           NOT in the set, and why: `ci-main.yml` (`push` to `main`, plus `integration/**` since
#           #3131 — never a PR push) and `enforce-skills.yml`
#           (`schedule` + `push: [main]`) never fire on a PR push, and `admin-merge-detector.yml`
#           fires on `workflow_run` of main's CI. The four reusable `workflow_call` files
#           (`docs-ci`, `drift-check`, `node-ci`, `python-ci`) run as JOBS inside a caller's RUN,
#           so they inherit the CALLER's concurrency group and add no run of their own.
#           That is why the exclusion does not rest on supersession — it rests on the decision plus
#           (i): the reading that skipped 41 deploys was wrong about the QUANTITY, not merely
#           silent about one of the two stacking workflows.
#     What does NOT change, and a fixer must still expect: the push voids that PR's head-bound review
#     attestation (#2148), so the review chain re-runs.
#     Gating repair on this number is what produced 41 skips while 11 lane slots and 8 runners sat
#     idle. If a future change wants to defer a repair dispatch, it is not a tuning change — it
#     re-opens #2927.
#   * TWO DECLARED RESIDUALS ON THE MEASUREMENT ITSELF — both stated, neither closed by reading
#     harder:
#     (i) ONLY `status=queued` IS COUNTED (#2333 review, P2). A run parked behind an environment
#         approval or a concurrency group is `waiting` (`requested` and `pending` are the adjacent
#         pre-execution states), and none of the three is in the count — so a queue whose work is
#         PARKED reads SHALLOW, i.e. the fail-open direction. Counting them costs one `gh` request
#         per state, and a mandatory read that can fail is a new path to `unknown(...)`: three more
#         ways for a GitHub blip to defer EVERY CI-spending act on the box, which is the fleet-wide
#         stop this header forbids. The ceiling models a queue DRAINING through `R` runners, and a
#         parked run has no drain time to model — so the exclusion is deliberate, and its direction
#         is stated rather than fixed. Home: agent-infra #2497.
#     (ii) THE WINDOW IS THE READ, NOT THE PUSH (#2333 review, P3). `fix-one.sh` reads ONCE when the
#         LANE STARTS, and its agent pushes up to `FIX_TIMEOUT` (default 2400 s) later, so a lane can
#         be allowed on a shallow queue and push into a deep one — a window 2.7x `CIQ_STALE_MAX`,
#         which no cache bound describes. A re-read at the push site would close it; it is disclosed
#         instead because the push runs in the AGENT's own shell and a second reading there has to
#         answer what a refusal would do to work that is already done.

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

# ── the tuning functions (the ONE place) ────────────────────────────────────────────────────────
# FIVE knobs total: the THREE functions below (`ciq_horizon_min`, `ciq_job_p90_min`,
# `ciq_hosted_concurrency`) plus the two cache bounds read inline in `ciq_read` (`CIQ_TTL`,
# `CIQ_STALE_MAX`). See the header's ⛔ block — an earlier version of THIS banner said "two".

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
  # ⛔ STDERR IS NO LONGER DISCARDED (#2333 review round 5, P2). The caller redirects it into a
  # per-state-dir scratch file so the failure's CAUSE can be named: with `2>/dev/null` a transient
  # 500, a rate limit and a definitive 403/404 all reached the operator as the same anonymous
  # `unknown(...)`, and a gate that cannot say why it is stuck reads the same on cycle 3 and cycle
  # 900. The exit status and the stdout contract are unchanged.
  local ghbin="${CIQ_GH:-gh}"
  command -v "$ghbin" >/dev/null 2>&1 || return 127
  "$ghbin" api "$@"
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

# ciq_fleet_restore <record> -> the value for CIQ_FLEET, with its `fleet=` key re-attached.
# ⛔ THE RECORD STORES THE DISCLOSURE WITHOUT ITS KEY (#2927 review, P3). The writer printed
# `fleet=%s` from a value that ALREADY began `fleet=`, so every on-disk record read
# `fleet=fleet=unreadable(…)`. It round-tripped (a reader stripped one) and a test pinned the doubled
# form, so nothing broke — but an on-disk record is permanent text an operator reads, and a doubled
# key is a small permanent tax on the one field whose whole job is to be read by a human. The
# record's own `fleet=` line IS the key; this re-attaches it. An EMPTY stored value (the honest value
# for every branch that DID measure, and for every older record that has no `fleet=` line at all)
# restores as empty, never as `fleet=`.
# ⛔ THE RECORD OUTLIVES THE MODULE, SO THIS READ ACCEPTS BOTH SHAPES (#2928 review, P3). A record is
# permanent text in a state dir shared with whatever else runs out of it, so a `fleet=fleet=…` line
# written by the PRE-FIX writer can still be read HERE, after the writer changed — the mixed-version
# direction (old record, new reader) that a reader CAN close from its own side. `${v#fleet=}` strips
# a STORED key before this function attaches its own, so an old-format and a new-format record both
# restore keyed exactly ONCE. It is a tolerance rather than a version field because the strip can
# never eat a real payload: `CIQ_FLEET`'s only producer is branch (c), whose text always begins
# `unreadable(`, so a value that itself starts `fleet=` can only be the doubled legacy form.
# The OPPOSITE direction — an OLD reader meeting a NEW record — needs nothing here and cannot
# mis-decide: that reader strips one `fleet=` and prints the disclosure WITHOUT its label
# (`unreadable(…) fallback=…`); `fleet=` is a human-facing disclosure that no branch of `ciq_eval`
# does arithmetic on, so the numbers, the ceiling and the verdict are byte-identical, only a label is
# lost, and it returns by itself when the reader is upgraded. That is why the window is tolerable
# rather than a version negotiation.
ciq_fleet_restore() {
  local v
  v="$(printf '%s\n' "${1:-}" | sed -n 's/^fleet=//p' | head -1)"
  v="${v#fleet=}"
  if [ -n "$v" ]; then printf 'fleet=%s\n' "$v"; fi
}

# ciq_read <owner/repo> [<state-dir>] -> sets the CIQ_* record; 0 = usable reading, 2 = UNKNOWN.
# Record fields (all set on every call, so a caller never reads a previous call's leftovers):
#   CIQ_QUEUED  runs waiting for a runner
#   CIQ_RUNNING runs executing now
#   CIQ_RUNNERS runners that can execute them (measured; `~` lower bound when inferred)
#   CIQ_BUSY    runners currently busy (blank when the endpoint did not answer)
#   CIQ_FLEET   the fleet read's OWN disclosure — set ONLY on branch (c), where nothing was measured
#               (`fleet=unreadable(<the endpoint's words>) fallback=…`). Empty when a count WAS
#               measured. It is persisted in the record and restored by both cache arms, because a
#               disclosure that survives only in memory is absent on exactly the path (cache) an
#               operator reads it from (#2927).
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
  # ⛔ EVERY NAME THIS FUNCTION ASSIGNS IS `local` (#2333 review, P2). `_errf` and `_sf` were the two
  # that were not, so a sourced `ciq_read` leaked them into the CALLER's shell — and this module is
  # sourced into `orch-loop.sh`'s single 4,600-line cycle body and `dispatch-merge.sh` (it was sourced
  # into `fix-one.sh` too until #2927 removed the repair path's last read). Nothing collides today; the module's own contract ("a sourced library must
  # not mutate its caller's shell") is what this list exists to honour, and a future local in the
  # caller would be silently clobbered mid-cycle.
  local repo="${1:-}" dir="${2:-}" f cached="" at="" queued="" running="" runners="" busy="" now age ttl stale_max _rn declared="" rn_answered="" floor="" _errf="" _rerrf="" _sf="" _fleetwhy=""
  CIQ_QUEUED=""; CIQ_RUNNING=""; CIQ_RUNNERS=""; CIQ_BUSY=""; CIQ_CEILING=""; CIQ_STATE=unknown; CIQ_AGE=""; CIQ_REPO="$repo"
  CIQ_STREAK=""; CIQ_CAUSE=""; CIQ_FLEET=""
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
        # ⛔ THE FLEET DISCLOSURE RIDES THE RECORD TOO (#2927). `CIQ_FLEET` is the ONE place branch (c)
        # says WHICH reading failed (`fleet=unreadable(...)`), and both cache arms reset it — so on a
        # TTL or staleness hit the token used to drop the disclosure and keep only `runners=~1`, i.e.
        # exactly the "inference presented as a measurement" the field exists to prevent, on the path
        # cache exists for. `busy=` is the precedent: a disclosure field carried through the record.
        # The key is re-attached on the way back (ciq_fleet_restore): the record stores the VALUE, so
        # the line reads `fleet=unreadable(…)` on disk and not `fleet=fleet=unreadable(…)`.
        # An older record has no `fleet=` line, which reads as empty — no behaviour change.
        CIQ_FLEET="$(ciq_fleet_restore "$cached")"
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
  # ⛔ THE FAILURE'S CAUSE IS CAPTURED, NOT DISCARDED (#2333 review round 5, P2): stderr is collected
  # into one scratch file in the state dir, so the `unknown(...)` token can carry the HTTP status the
  # endpoint actually returned together with the length of the streak.
  mkdir -p "$dir" 2>/dev/null || true
  _errf="$dir/ciq-err"; : > "$_errf" 2>/dev/null || true
  # ⛔ THE FLEET READ GETS ITS OWN SCRATCH FILE (#2927). The queue reads and the runner read shared
  # one, so the `unknown(...)` cause named the first HTTP status in the file — which is the QUEUED
  # read's, not the runner read's. Branch (c) below has to say WHICH reading failed, so it needs the
  # runner call's own words.
  _rerrf="$dir/ciq-rerr"; : > "$_rerrf" 2>/dev/null || true
  queued="$(ciq_gh "repos/$repo/actions/runs?status=queued&per_page=1" 2>>"$_errf" \
            | sed -n 's/.*"total_count":[ ]*\([0-9][0-9]*\).*/\1/p' | head -1)" || queued=""
  running="$(ciq_gh "repos/$repo/actions/runs?status=in_progress&per_page=1" 2>>"$_errf" \
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
  if _rn="$(ciq_gh "repos/$repo/actions/runners" --paginate 2>>"$_rerrf")"; then
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
        CIQ_FLEET="$(ciq_fleet_restore "$cached")"
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
    # ⛔ AND THE WHY, AND FOR HOW LONG (#2333 review round 5, P2). `unknown(...)` used to be
    # anonymous and unbounded: an outage on cycle 3 and a permanently unanswerable endpoint on cycle
    # 900 printed the identical line, so the one question an operator has ("is this a blip or is
    # this stuck?") had no answer, and the header's "UNKNOWN costs a cycle" only ever justified the
    # blip. The streak is COUNTED here and CARRIED in the token; the cause is the endpoint's own
    # words (first HTTP status, else the first stderr line), truncated so a token stays one line.
    CIQ_CAUSE=""
    CIQ_CAUSE="$(grep -o 'HTTP [0-9][0-9][0-9]' "$_errf" 2>/dev/null | head -1)"
    [ -n "$CIQ_CAUSE" ] || CIQ_CAUSE="$(sed -n '1s/[[:space:]]*//p' "$_errf" 2>/dev/null | cut -c1-60)"
    _sf="$dir/ciq-unknown-$(ciq_slug "$repo")"
    CIQ_STREAK="$(cat "$_sf" 2>/dev/null || printf '0')"
    ciq_is_num "${CIQ_STREAK:-}" || CIQ_STREAK=0
    CIQ_STREAK=$(( CIQ_STREAK + 1 ))
    printf '%s' "$CIQ_STREAK" > "$_sf" 2>/dev/null || true
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
    # (c) REFUSED / unparseable — NOTHING was measured. The allowance is a GUESS in the permissive
    #     direction: measured, one refused `actions/runners` call turned `queued=31` running=5 (a
    #     5-runner fleet) into `~20`/ceiling 40 => ALLOWED, and OVERWROTE a good record with the
    #     poisoned one for TTL+STALE_MAX (~16 min) — the shape where the gate reports `fresh` while
    #     permitting 4x its true ceiling. Fail CLOSED.
    #
    # ⛔ AND IT MUST NOT BE CLOSED WITH THE IN-PROGRESS COUNT — THAT IS THE DEFECT THIS ARM EXISTS
    # FOR NOW (#2927, measured 2026-10-27 on cell 4). This branch used to take `floor="$running"`:
    # with nothing measured, the number of jobs EXECUTING stood in for the size of the FLEET. That is
    # DEMAND answering a SUPPLY question, and the two are not even correlated in the direction the
    # gate needs — a box measured `queued=33 running=2 runners=~2 => ceiling 4 => DEFERRED` while its
    # repo's 8-registered, all-online, all-idle fleet could not appear in the number at all (the
    # queue it was gating belonged to GitHub-HOSTED concurrency), and 41 consecutive PR-repair
    # dispatches were skipped by it with 11 lane slots idle. So this branch now uses the module's OWN
    # documented floor — ONE runner, the same value `ciq_ceiling` floors at, because a ceiling of 0
    # would defer every push for ever — and it NAMES the reading it could not take, in the token
    # (`CIQ_FLEET`), so an operator sees an inference and not a measurement.
    #
    # The in-progress count is still a legitimate SUPPLY LOWER BOUND on the two ANSWERED branches,
    # where it is bounded by the allowance so a garbled count cannot become a ceiling the gate can
    # never reach (9 digits pass `ciq_is_count` and would yield ceiling 999999998, switching
    # back-pressure off while the token still reads like a measurement). ⛔ IT IS CLAMPED, NEVER
    # DISCARDED (#2333 review, P2): DISCARDING a count that exceeded the allowance carried a 20x CLIFF
    # with no disclosure — a repo running 19 or 20 concurrent jobs derived ceiling 38/40 and ALLOWED,
    # while 21 — ONE MORE executing job — fell to `runners=~1`/ceiling 2 and DEFERRED every
    # CI-spending act on the box, still printing `state=fresh` as though 1 runner were the
    # measurement. That is the fleet-wide stop this module's header names as unacceptable, reached by
    # a change of one digit. The clamp keeps the garble bound at the module's OWN accepted maximum
    # ceiling (2x the hosted allowance — the same width the allowance path already yields).
    floor=1
    # ⛔ THE ALLOWANCE DEMANDS POSITIVE EVIDENCE: A **PARSED** `total_count == 0` (#2333 review
    # cycle 12, P1). Until that cycle the test was `[ -z "$declared" ] || [ "$declared" -eq 0 ]`, and
    # `declared` is EMPTY exactly when the answered page carried no parseable `total_count` — i.e.
    # branch (c), unparseable — so an ANSWERED-but-unusable body took the hosted ALLOWANCE, and the
    # shape the (c) comment above records as measured-dangerous came back through the front door:
    # `queued=31` on a repo with nothing online became `~20`/ceiling 40 => ALLOWED, the gate
    # reporting a measurement it never made. Only a parsed zero selects the allowance.
    if [ "${rn_answered:-0}" = 1 ] && [ "${declared:-x}" = "0" ]; then
      runners="$(ciq_hosted_concurrency)"
    elif [ "${rn_answered:-0}" = 1 ] && [ -n "${declared:-}" ]; then
      # (b) AN ANSWERED READ: the fleet is declared and nothing of it is online. `running` is a
      # genuine SUPPLY LOWER BOUND here — jobs are executing, so that much capacity exists somewhere
      # — and dropping it was MEASURED to be worse than keeping it (arm (b12): a stale/decommissioned
      # self-hosted entry on a repo that actually runs on hosted capacity pinned the ceiling at 2, so
      # a 4-deep queue deferred for ever).
      if ciq_is_count "${running:-}" && [ "${running:-0}" -ge 1 ]; then
        floor="$running"
        if [ "$floor" -gt "$(ciq_hosted_concurrency)" ]; then floor="$(ciq_hosted_concurrency)"; fi
      fi
      runners="$floor"
    else
      # (c) NOTHING was measured — see the ⛔ above. Name the reading that failed, in the endpoint's
      # own words, so `fleet=unreadable(HTTP 404)` is not confused with a fleet of one runner.
      runners="$floor"
      if [ "${rn_answered:-0}" != 1 ]; then
        _fleetwhy="$(grep -o 'HTTP [0-9][0-9][0-9]' "$_rerrf" 2>/dev/null | head -1)"
        [ -n "${_fleetwhy:-}" ] || _fleetwhy="$(sed -n '1s/[[:space:]]*//p' "$_rerrf" 2>/dev/null | cut -c1-60)"
        [ -n "${_fleetwhy:-}" ] || _fleetwhy="no answer"
        CIQ_FLEET="fleet=unreadable(the actions/runners endpoint refused: ${_fleetwhy}) fallback=runners=~${runners} (the 1-runner floor, NOT the in-progress count)"
      else
        CIQ_FLEET="fleet=unreadable(the actions/runners page carried no parseable total_count) fallback=runners=~${runners} (the 1-runner floor, NOT the in-progress count)"
      fi
    fi
    runners="~$runners"
  fi
  CIQ_QUEUED="$queued"; CIQ_RUNNING="${running:-0}"; CIQ_RUNNERS="$runners"; CIQ_BUSY="$busy"
  CIQ_STATE=fresh; CIQ_AGE=0
  CIQ_STREAK=0; CIQ_CAUSE=""
  rm -f "$dir/ciq-unknown-$(ciq_slug "$repo")" 2>/dev/null || true
  CIQ_CEILING="$(ciq_ceiling "${CIQ_RUNNERS#\~}")" || CIQ_CEILING=""
  mkdir -p "$dir" 2>/dev/null || true
  # `fleet=` is written even when empty: the cache arms restore whatever is here, and an EMPTY field
  # is the honest value for every branch that DID measure (only branch (c) has something to disclose).
  # ⛔ THE VALUE GOES IN WITHOUT ITS OWN `fleet=` PREFIX (#2927 review, P3): `CIQ_FLEET` already begins
  # `fleet=`, so `${CIQ_FLEET#fleet=}` is what stops the record reading `fleet=fleet=unreadable(…)`.
  { printf 'repo=%s\nqueued=%s\nrunning=%s\nrunners=%s\nbusy=%s\nfleet=%s\nat=%s\n' \
      "$repo" "$CIQ_QUEUED" "$CIQ_RUNNING" "$CIQ_RUNNERS" "${CIQ_BUSY:-}" "${CIQ_FLEET#fleet=}" "$now"; } > "$f" 2>/dev/null || true
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
  # ⛔ THE UNKNOWN TOKEN CARRIES ITS AGE AND ITS CAUSE (#2333 review round 5, P2). `unknown(…)` was
  # anonymous, so "cycle 3 of a blip" and "cycle 900 of an endpoint that will never answer" printed
  # the same line — the one question an operator has had no answer. `streak=` is how many CONSECUTIVE
  # reads failed (a successful read clears it), and `cause=` is the endpoint's own words. Both are
  # appended only when known, so a caller's `unknown(`/`state=unknown` matching is unaffected.
  ciq_unknown_suffix() {
    [ -n "${CIQ_STREAK:-}" ] && [ "${CIQ_STREAK}" != 0 ] && printf ' streak=%s' "$CIQ_STREAK"
    [ -n "${CIQ_CAUSE:-}" ] && printf ' cause=%s' "$CIQ_CAUSE"
  }
  if [ "${CIQ_STATE:-unknown}" = unknown ]; then
    # …and the number PRINTED is the one that DECIDED (#2333 review cycle 2, P2): `ciq_read`
    # normalises a garbage `CIQ_STALE_MAX` to 900, so echoing the raw variable claimed a window the
    # module never used.
    sm="${CIQ_STALE_MAX:-900}"; ciq_is_num "$sm" || sm=900
    printf 'unknown(queue unreadable: no fresh read and no record inside %ss — CI capacity is UNKNOWN, which defers CI-spending work rather than opening the gate%s)' "$sm" "$(ciq_unknown_suffix)"
    return 2
  fi
  q="$CIQ_QUEUED"; r="$CIQ_RUNNING"; n="${CIQ_RUNNERS#\~}"; c="${CIQ_CEILING:-}"
  if [ -z "${c:-}" ]; then
    printf 'unknown(no ceiling derivable from runners=%s%s)' "${CIQ_RUNNERS:-?}" "$(ciq_unknown_suffix)"
    return 2
  fi
  # ⛔ A NUMBER THAT DOES NOT FIT IS NOT A READING (#2333 review P2). Above intmax `[ … -gt … ]`
  # ERRORS, an errored test is FALSE, and a FALSE test lands on the `ok(...)` branch — the gate
  # OPENING on the one value it could not compare. Out of range is therefore UNKNOWN, the same
  # verdict as unreadable: the fail-CLOSED direction, which is the only direction this gate has.
  if ! ciq_is_count "${q:-}" || ! ciq_is_count "${r:-}" || ! ciq_is_count "${n:-}" || ! ciq_is_count "${c:-}"; then
    printf 'unknown(not a comparable reading: queued=%s running=%s runners=%s ceiling=%s%s)' \
      "${q:-?}" "${r:-?}" "${CIQ_RUNNERS:-?}" "${c:-?}" "$(ciq_unknown_suffix)"
    return 2
  fi
  if [ "$q" -gt "$c" ]; then
    # ⛔ STATE AND AGE RIDE THE `deep` TOKEN TOO (#2333 review P1). The cached record is the ONE
    # fail-open here, and a `deep(...)` that said neither `state=cache` nor `age=<n>s` presented a
    # minutes-old reading exactly as it presents a fresh one — on the branch that then DEFERS.
    printf 'deep(queued=%s running=%s runners=%s%s ceiling=%s derived=ceil(%s*%s/%s) state=%s%s%s)' \
      "$q" "$r" "${CIQ_RUNNERS}" "$( { [ "${CIQ_RUNNERS#\~}" = "$CIQ_RUNNERS" ] && [ -n "${CIQ_BUSY:-}" ]; } && printf ' busy=%s' "$CIQ_BUSY" )" \
      "$c" "$n" "$(ciq_horizon_min)" "$(ciq_job_p90_min)" "${CIQ_STATE}" \
      "$( [ "${CIQ_STATE}" = cache ] && printf ' age=%ss' "${CIQ_AGE}" )" \
      "$( [ -n "${CIQ_FLEET:-}" ] && printf ' %s' "$CIQ_FLEET" )"
    return 0
  fi
  printf 'ok(queued=%s running=%s runners=%s ceiling=%s state=%s%s%s)' \
    "$q" "$r" "${CIQ_RUNNERS}" "$c" "${CIQ_STATE}" "$( [ "${CIQ_STATE}" = cache ] && printf ' age=%ss' "${CIQ_AGE}" )" \
    "$( [ -n "${CIQ_FLEET:-}" ] && printf ' %s' "$CIQ_FLEET" )"
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
  local repo="" verb="${1:-status}" operand="" v drc rc src
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
      # ⛔ NO `case` INSIDE A `$( )` HERE (#2969). On bash 3.2 — macOS's `/bin/bash`, and the
      # interpreter the launchd controller is started with — the `)` that closes a `case` PATTERN is
      # read as the closer of the SUBSTITUTION: the substitution is re-parsed at EXECUTION, bash
      # reports `syntax error near unexpected token 'newline'` against this line, and substitutes the
      # LITERAL remainder of the line instead of a value. Measured on this box: `source=` printed
      # ` printf 'gh' ;; cache) printf 'record(cache)' ;; *) printf 'unknown' ;; esac )` while the
      # command still exited 0 — a corrupted field under a green exit, so every consumer read the
      # `source` of the reading as script text. `bash -n` is blind to it (it parses the outer script
      # only) and bash 4.4+ parse it correctly, which is why only 3.2 boxes were wrong.
      # ⛔ PARENTHESISING THE PATTERN IS NOT THE FIX: bash counts parens, so `(fresh)` only helps
      # until the `*)` catch-all, whose own `)` closes the substitution (measured: the shape
      # `in (fresh) … *) …` still fails). Hoisting the `case` out of the substitution removes the
      # ambiguity for every bash instead of for the ones that happen to parse it.
      case "${CIQ_STATE}" in
        fresh) src='gh' ;;
        cache) src='record(cache)' ;;
        *)     src='unknown' ;;
      esac
      printf 'repo=%s state=%s source=%s age=%ss\n' "${repo:-?}" "${CIQ_STATE}" "$src" "${CIQ_AGE:-?}"
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
