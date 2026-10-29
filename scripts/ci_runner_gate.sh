#!/usr/bin/env bash
# ci_runner_gate.sh — route CI to GitHub-hosted runners, fall back to the local pool
# when GitHub-hosted is unhealthy, and notify on every transition.
#
# WHY THIS EXISTS
#   The self-hosted pool (`pi-runner-vm-*`) originally advertised the `ubuntu-latest`
#   label, so the 77 `runs-on: ubuntu-latest` jobs in daniel-ospina/tortoise raced
#   between GitHub-hosted and this Mac — and jobs landing here compete with the pi
#   fleet and the Tortoise graph (a local pytest run crashed FalkorDB at
#   src/reply.rs:655, 178 restarts, 2026-10-12).
#
#   The pool's CUSTOM label is now `self-hosted-arm64` (distinct), so `ubuntu-latest`
#   resolves to GitHub-hosted ONLY and CI runs on GitHub "where possible". This script
#   is the FALLBACK: when GitHub-hosted is unhealthy it re-adds `ubuntu-latest` to the
#   pool so the same workflows can land locally instead of queueing forever.
#
# ⛔ THE FALLBACK-ONLY DECISION ABOVE IS UNCHANGED (agent-infra#2327 did not touch it). The pool
#   serves CI only while GitHub-hosted is unhealthy — the arch fix below changes WHICH LABEL each
#   runner accepts, never WHEN the pool is offered to the queue. When the pool gained a second
#   architecture the marker became per-runner (`self-hosted-arm64` / `self-hosted-x64`), because
#   one pool-wide body deleted the x86 marker and the capacity silently stopped matching jobs.
#   The invariant the label code holds: A RUNNER'S LABELS MUST DESCRIBE THAT RUNNER, NOT THE POOL
#   IT JOINED FIRST.
#
# WHY IT RUNS OUTSIDE ACTIONS
#   If GitHub Actions itself is degraded, anything scheduled INSIDE Actions is dead
#   exactly when it is needed. This runs from launchd on the Mac. It only helps for
#   GitHub-hosted CAPACITY/queue problems — a full Actions control-plane outage also
#   disables self-hosted job dispatch (GitHub's scheduler is the same one).
#
# THE CAPACITY INSTRUMENT (agent-infra#2904 · #2897 · #2931)
#   This script is also the fleet's only CAPACITY instrument for the self-hosted pool, and it used
#   to report a COUNT of registrations. A count cannot tell `online-idle` from `online-busy` from
#   `registered-but-offline`, so the fleet read 9 busy runners while 7 were idle, and read
#   "healthy" while running at 2 of 8. The census below reads `status` and `busy` PER RUNNER and
#   says which of the three states each runner is in, and which of them can accept the queue's own
#   demand (`jobs[].labels`, readable without admin).
#
# ⛔ THE TOKEN IS NEVER WIDENED TO MAKE A GATE WORK (the constraint this fix is built on). The fleet
#   token is `gist, read:org, repo, workflow`; on the cell boxes the runner inventory answers
#   `403 Resource not accessible by personal access token`, and the billing endpoint answers 404
#   without `user` scope. Each unreadable endpoint therefore gets exactly one of two answers:
#     * the MODE question has a readable substitute — recent jobs' `runner_group_name`, which
#       `actions:read` DOES expose — so an inventory-blind box still knows who is serving;
#     * the CAPACITY question has no substitute, so it becomes `capacity=unknown` and the pass is
#       REFUSED (exit 2) with the missing capability and the 403 body named, plus an alarm.
#   A gate that cannot see capacity may not certify it. UNKNOWN is a verdict; "green" is a guess,
#   and guessing green is the whole defect: nothing pages, nothing reddens, and a human rediscovers
#   the shortage by hand every few hours.
#
# USAGE
#   ci_runner_gate.sh            # evaluate + act + notify
#   ci_runner_gate.sh --dry-run  # evaluate and report, change nothing
#   ci_runner_gate.sh --status   # print mode + capacity census, exit 0 (2 when either is unmeasured)
#
# EXIT: 0 ok · 1 usage · 2 could-not-measure / could-not-act (fail-closed: changes nothing)
#
# OUTPUT A SCHEDULER CAN BRANCH ON: `$STATE_DIR/ci-runner-gate.verdict`, one `key=value` line per
# run — `verdict=`, `capacity=`, the per-runner counts, `capability=`, `reason=` (last). The mode
# file (`ci-runner-gate.state`) keeps its single-word shape, so existing readers are unaffected.
set -uo pipefail

REPO="${CI_GATE_REPO:-daniel-ospina/tortoise}"
STATE_DIR="${CI_GATE_STATE_DIR:-$HOME/.pi/agent/state}"
STATE_FILE="$STATE_DIR/ci-runner-gate.state"
VERDICT_FILE="$STATE_DIR/ci-runner-gate.verdict"
LOG_FILE="$STATE_DIR/ci-runner-gate.log"
# ⛔ gh ITSELF WRITES DIAGNOSTICS TO STDERR, AND THIS SCRIPT READS gh's OUTPUT AS VALUES (agent-infra#2897,
# measured on this box). A wrapper on PATH printed
#   `gh-gate: the gate mutex is unavailable (lock_acquire spent 2000ms) — running this call UNGATED (announced)`
# on stderr while the call SUCCEEDED. Captured with `2>&1` — the pre-existing shape — that line joins the
# numeric read, the count fails its shape check, and the mode resolves `unknown`; against the CENSUS it
# is worse, because a non-row line reads as an unreadable inventory and raises a FALSE blind alarm. A
# diagnostic is not a measurement: stdout is read as data, stderr goes here and is quoted only when the
# call FAILED.
GH_ERR="$STATE_DIR/ci-runner-gate.gh.err"
QUEUE_THRESHOLD="${CI_GATE_QUEUE_THRESHOLD:-60}"   # queued runs = GitHub-hosted backlog
# The runs endpoint's maximum page size, and therefore the deepest queue one read can measure. The
# throughput leg's age is only the HEAD's age when the page held the WHOLE queue; a saturated page
# turns it into a lower bound (review P2 — see the saturated-page refusal inside `evaluate`).
QUEUE_PAGE=100
# ── the THROUGHPUT (absorption) leg — agent-infra#2904 ─────────────────────────────────────────
# ⛔ LENGTH IS NOT ABSORPTION. `queued < 60` says "not a stampede"; it cannot say "work is moving".
# Measured 2026-10-27, daniel-ospina/tortoise: a run sat QUEUED from 10:26Z to 13:28Z — 3 h — while
# all three existing legs read healthy (component operational, no incident, queue < 60), and every
# `runs-on: ubuntu-latest` job in the repo had no runner that could accept it. A CI stop the gate
# itself certifies as healthy is worse than a red check: nothing pages, nothing reddens.
#
# What the leg measures, and WHY IT IS NOT "oldest queued run age" ALONE. Measured on this repo,
# a long wait is NORMAL: over 13 sampled days (1,000 runs per day, 2026-10-14…27) the longest
# run-level queue wait was 388,923 s on 2026-10-15, 63,052 s on 2026-10-24 and 40,687 s on 2026-10-23,
# and a live sample of 21 consecutive readings (13:56-14:12Z on 2026-10-27) found the queue HEAD
# 3,943-12,583 s old WHILE HOSTED WAS SERVING (in_progress 2..14, queue draining 86 -> 25). A stale
# entry sits at the head while newer runs are dispatched, so a leg keyed on that age would have fired
# CONTINUOUSLY through a period in which hosted was demonstrably absorbing. So the leg is a
# CONJUNCTION: work is queued, the oldest queued run has waited past the floor, AND nothing at all
# is executing.
#
# ⛔ IN mode=github THIS IS A HOSTED READING. The pool's custom labels are `self-hosted-*`, so it
# never advertises `ubuntu-latest` in that mode, and no workflow in the repo asks for a
# `self-hosted` label (measured 2026-10-27: 0 of 39 files in .github/workflows name `self-hosted`
# in a `runs-on:`). So `in_progress > 0` in mode=github means hosted is executing.
#
# ⛔ IN FALLBACK MODE `in_progress > 0` IS NOT A HOSTED READING (review P1). The pool the gate has
# just engaged is the thing executing, and its jobs hold `in_progress` above zero, so counting them
# as "hosted is absorbing" is a claim this script cannot support. Two consequences, and the code
# only ever asserts what it can prove:
#   * the DENY direction stays valid in BOTH modes: `in_progress == 0` with a stuck head means
#     NOTHING at all is executing — hosted or pool — so the gate stays on the pool;
#   * the CERTIFY direction is suppressed in fallback mode: the reason line reports the absorption
#     numbers but says they are NOT ATTRIBUTABLE, and the healthy verdict is the pre-existing legs'
#     (the pool is re-tested every tick by design — #2327's fallback-only decision — and the length
#     leg, not this one, is what restores `github` once the queue has drained below QUEUE_THRESHOLD).
#
# THE FLOOR, AND THE CLOCK IT IS MEASURED ON — because queue time is not run time, and this repo
# has already burned that distinction (#3239). The number below is the age of a QUEUED run, i.e.
# `now - created_at` of a run that has never been assigned a runner: the queue-wait clock. It is
# NOT wall-clock duration of a run, and `run_started_at` is NOT usable as a dispatch marker — for a
# queued run GitHub sets it equal to `created_at` at queue entry (measured: run 40508520800 created
# 2026-10-27T13:01:55Z, `run_started_at` 13:01:55Z, first job dispatched 13:23:59Z on
# `GitHub Actions 1000636018`), so a run-level "wait" of hours reads identically to a run that
# started instantly.
#
# 1800 s = 2x the largest measured healthy silence. Measured across 13 days / 1,000 runs per day:
#   * dispatch is normally INSTANT: 12,624 of the 13,000 sampled runs had a zero-second queue wait
#     (only 376, 2.9%, waited at all) — a repo with work queued and NOTHING executing is nothing
#     like its own normal state, however old its queue head happens to be;
#   * the longest gap between consecutive run starts WHILE runs were still being created (so a
#     queue existed) was 920 s (2026-10-15), 830 s (2026-10-16), 598 s (2026-10-25), 492 s
#     (2026-10-14), 407 s (2026-10-27);
#   * the incident itself: the run created 2026-10-27T10:26:21Z was still queued 10,899 s later at
#     the issue's 13:28Z reading (and 12,583 s at a 13:56Z reading taken for this change), with
#     in_progress = 0.
# 1800 s is above every measured healthy gap and detects the recorded stall ~1/6th of the way
# through it. It is a health floor, not a target: a deep-but-serving queue (the 2..14 in_progress
# samples above) never trips it, because the leg requires NOTHING to be executing.
# ⛔ THE NAME IS DELIBERATE — do NOT rename it to `*_STALL_THRESHOLD` (agent-infra#2904, review).
# #847/#1068 make `stall_threshold` a SINGLE authority: the tier-config vocabulary owns that name,
# and `extensions/shared/heartbeat-progress-edges.ts`'s registry refuses a second term carrying
# `/stall_?threshold/i` AND a value (`extensions/shared/heartbeat-progress-edges.test.ts` §4). A
# queue-wait floor for CI health is a different bound from the agent stall threshold, so naming it
# `QUEUE_STALL_THRESHOLD` would either claim a `value: null` pointer to #847 (false — this value is
# owned here) or collide with that boundary. `STUCK` is a declared family token and `_S` a declared
# bound suffix, so the #1068 reverse scan SEES this declaration and its registry row is enforced
# (see `QUEUE_STUCK_AFTER_S` there) rather than escaping both scan directions.
QUEUE_STUCK_AFTER_S="${CI_GATE_QUEUE_STUCK_AFTER_S:-1800}"   # seconds of queue wait, see above
# How often the blind alarm may repeat while the capacity census stays unreadable. The gate runs
# every ~5 min from launchd; alarming every tick is noise nobody reads, alarming once and never
# again is the failure #2897 measured (`launchctl list` showed last exit status 2, silently, for as
# long as the state existed). 1800 s = at most one alarm per half hour, and it REPEATS.
BLIND_ALARM_EVERY_S="${CI_GATE_BLIND_ALARM_EVERY_S:-1800}"
# How many in-progress runs the mode substitute inspects. Bounded, and the bound is stated: an
# idle repo has none, which is the hole this substitute cannot fill — it says `unknown` there.
MODE_INFER_RUNS="${CI_GATE_MODE_INFER_RUNS:-3}"
# The custom label that makes a job land on the LOCAL pool.
FALLBACK_LABEL="ubuntu-latest"
# ⛔ THERE IS NO LONGER A SINGLE "pool label" (agent-infra#2327). The pool holds two
# architectures, and each runner carries the marker for ITS OWN: `ARM64` runners keep
# `self-hosted-arm64`, `X64` runners keep `self-hosted-x64`. Writing one pool-wide body to every
# runner was harmless only while the pool was homogeneous; it now stamps the ARM64 marker onto an
# x86 runner AND (because this endpoint REPLACES the custom label set) deletes the x86 marker, so
# the extra capacity stops matching anything and simply never picks a job — no error, no alert.
POOL_LABEL_ARM64="self-hosted-arm64"
POOL_LABEL_X64="self-hosted-x64"
# GitHub derives these from the HOST at registration; they are not part of the custom label set and
# cannot be set or removed through it. They are the ONLY trustworthy statement of a runner's arch.
HOST_LABEL_ARM64="ARM64"
HOST_LABEL_X64="X64"
# Never managed here: the scheduler's own automatic labels, and the one label this gate owns.
AUTO_LABELS=" self-hosted Linux $FALLBACK_LABEL "

# Set by `evaluate` for the reason line (a leg that fails must be NAMED, not just counted).
UNHEALTHY_LEG=""
ABSORPTION_OLDEST_S=""
ABSORPTION_IN_PROGRESS=""
ABSORPTION_QUEUED=""

# ── capacity census state (agent-infra#2904 · #2897 · #2931) ───────────────────────────────────
# CENSUS_VERDICT is the CAPACITY question's answer, kept separate from the MODE answer on purpose:
# "is the pool able to take this work" and "which pool should take it" are different questions with
# different fallbacks (see the header), and collapsing them is how "9 busy" got read while 7 were
# idle.
#   absorbing    nothing is queued, so capacity is not the question this pass
#   saturated    work is waiting and every ONLINE runner is busy — the busy reading is real
#   idle-unused  work is waiting and at least one ONLINE runner is IDLE — capacity exists and is
#                not being used. REPORTED, never certified as healthy.
#   all-offline  registrations exist, NONE is online (the third state the fleet needs)
#   stranded     mode=local, the POOL CLAIMS the queue's demand, and NOT ONE online runner can
#                accept it (see `pool_claims_demand` — a demand the pool never advertised is never
#                a fault of the pool, so it narrows instead of denying)
#   unknown      the inventory could not be read — no capacity claim is made at all
# `--status` prints ONE more word, `unmeasured`, for the same `capacity=` key: it is the manual read
# verb and computes no verdict, so it says so in the SAME vocabulary rather than inventing a seventh
# word (`measured`, which named neither a verdict nor an absence) that a scheduler would have to
# special-case (#3002 review P2).
CENSUS_VERDICT=""
CENSUS_BLIND=0         # 1 only when the CAPACITY read failed (the condition the alarm is about)
# ⛔ A LABEL'S CONTENT IS NOT ROW STRUCTURE (#3002 review P1). The census reads EVERY runner attached
# to the repo, so one runner labelled `my gpu box` — a name this gate can neither emit nor forbid —
# used to make the whole inventory UNREADABLE, i.e. exit 2 forever: the fleet's only CI routing
# instrument frozen, with an alarm blaming a permission problem on a read that answered perfectly.
# So labels are no longer character-policed at all; only the ROW shape is. The one thing label
# content can still spoil is the match, and it is DETECTED instead of refused: the inventory reports
# each runner's own label COUNT, and if the count disagrees with the comma-split we performed, a
# label contains the delimiter and `offers_all` cannot be trusted — `CENSUS_LABEL_AMBIGUOUS=1`, which
# NARROWS the claim (never a `stranded` deny) rather than voiding the pass.
CENSUS_LABEL_AMBIGUOUS=0
# ⛔ WHAT THE POOL CLAIMS TO OFFER, and why it is not the same question as what is ONLINE (#3002
# review P1). The queue's demand is the OLDEST queued run's label set, which can ask for something this
# pool never advertised — `macos-latest`, a `gpu` label, a matrix axis nobody registered. "No online
# runner can accept it" is then not a fault of the pool: it is work the pool was never supposed to
# serve, and denying on it pinned mode=local forever on a healthy repo (the pool keeps `ubuntu-latest`
# while hosted sits idle) with a reason line that read "GitHub-hosted UNHEALTHY". A registration —
# online OR offline — carrying the label IS a claim the pool makes, so an offline `gpu` runner plus a
# `gpu` demand still denies: that is #2931's mechanism, and it is the case this must keep.
CENSUS_OFFERED=""      # union of every label on every registration, comma-joined (as the API spelled them)
CENSUS_KV=""           # the measured counts, machine-readable
CENSUS_DETAIL=""       # the same counts as "2 of 8 online (idle=0 busy=2 offline=6)"
# The same eight census keys, for the writer that runs when the census could NOT be read (#3002 review
# P2): the 403 path used to emit a DIFFERENT key set, so a strict parser saw absent keys instead of an
# explicit `unmeasured` — the same defect that comment claimed to have fixed. Order matches CENSUS_KV.
CENSUS_KV_UNMEASURED="runners=unmeasured online_idle=unmeasured online_busy=unmeasured offline=unmeasured demanding_idle=unmeasured demanding_busy=unmeasured label_ambiguity=unmeasured demand=unmeasured"
CENSUS_ON_IDLE=0
CENSUS_ON_BUSY=0
CENSUS_OFFLINE=0
CENSUS_DEMAND_IDLE=0
CENSUS_DEMAND_BUSY=0
DEMAND_LABELS=""       # ONE LABEL SET PER LINE — one per QUEUED JOB ("" = not measured)
DEMAND_SHOWN=""        # the same sets on ONE line (`;`-joined), for the key=value surfaces
# ⛔ ONE SET PER JOB, NEVER THE UNION OF A RUN'S JOBS (#3002 review P2, round 3). A matrix run's queued
# jobs ask for DIFFERENT runners (`self-hosted-x64`, `self-hosted-arm64`), and `offers_all` implements
# GitHub's AND semantics — ONE runner must carry a whole set. Joined into a single set, no runner can
# ever match it, so a run nobody is stranded for read as `stranded` while both arch runners sat ONLINE
# AND IDLE. The union is a fine THING TO REPORT and a wrong thing to MATCH.
CAPABILITY=""          # which permission the inventory read needed, when it could not be read
MODE_SOURCE="runners"  # runners | jobs-inference | none — how `mode` was obtained
CAP_DENY=0             # set by capacity_verdict: 1 = this pass may not certify capacity

DRY=0; STATUS_ONLY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --status)  STATUS_ONLY=1 ;;
    *) echo "usage: $0 [--dry-run|--status]" >&2; exit 1 ;;
  esac
done

mkdir -p "$STATE_DIR"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || { log "FATAL: '$1' not on PATH"; exit 2; }; }
need gh; need curl; need python3

# ── runner capacity census ──────────────────────────────────────────────────────
# ONE paginated read of the runner inventory, reduced to the three fields that carry the answer.
# `<status> TAB <busy> TAB <labels,comma>`. ⛔ THE COMMA IS NOT ASSERTED SAFE (#3002 review P2): labels
# are no longer character-policed (:197-206 — policing them froze the fleet on somebody else's label
# name), so one CAN contain the delimiter, and the split is then untrustworthy. That is not ignored: it
# is DETECTED (`CENSUS_LABEL_AMBIGUOUS`) and it narrows every demand claim below. Do not restore a
# "can never contain one" claim here — it would re-justify deleting the only guard against a false
# `stranded` deny.
#
# ⛔ THIS READ IS THE ONE THAT NEEDS `Administration: read` (classic: `repo` on an owned repo), and
# the fleet token does not have it on every box (agent-infra#2897: `403 Resource not accessible by
# personal access token` from `launchctl`-run copies). The call is made anyway, because on the boxes
# that CAN read it, it is the only surface that distinguishes the three states — and on the boxes
# that cannot, the caller turns the failure into `capacity=unknown` rather than into a count of zero.
RUNNER_LIST_PATH="repos/$REPO/actions/runners"
runner_census() {
  # ⛔ TWO KINDS OF ROW, and the FIRST kind is what makes the read READABLE AT ALL (#3002 review P1).
  #
  #   <#page> TAB <type> TAB <count>                                    — one per page, FIRST on the page
  #   <status> TAB <busy> TAB <labels,comma> TAB <label count>          — one per registration
  #
  # The registration row's last field is OPTIONAL (see CENSUS_LABEL_AMBIGUOUS): the count is what lets
  # the reader tell a 3-label set from a 2-label set whose second label contains a comma, which the
  # join cannot distinguish.
  #
  # ⛔ WHY THE PAGE ROW EXISTS: `jq` over an EMPTY input stream emits NOTHING and exits 0, so "the pool
  # has no runners" and "the response body contained nothing at all" used to be BYTE-IDENTICAL output
  # (empty stdout, rc 0) — and this script resolved that ambiguity toward "measured zero". A blank 200
  # then read as `runners=0`, which in mode=local with a measured demand is a `stranded` DENY, i.e. a
  # relabel taken on a read with no value in it — while `current_mode` (:800) refuses the identical
  # body. A page row is emitted by JQ ITSELF the moment it parses a body whose `.runners` is an array,
  # so its presence distinguishes "answered, with N runners" (N may be 0) from "produced nothing"
  # without a second read. `.runners|type` is carried rather than assumed: a body that answers with
  # `.runners: null` is a SCHEMA change, not an empty pool, and must not be counted as one either.
  #
  # ⛔ `\(` IS THE INTERPOLATION TOKEN AND A BARE `\` IS NOT A jq TOKEN (#3002 review P1). Written as
  # `\(\.runners|type)` the whole program is a COMPILE error — jq exits 3 having read no input, so the
  # read produced NOTHING on every box and this gate could never relabel again, while reporting a
  # `runner_inventory:unreadable` alarm that blamed the token for our own grammar. Any edit here must
  # be COMPILED, not eyeballed: `scripts/ci_runner_gate.test.sh` now runs every `--jq` this script ships
  # through real `jq` (stub, "does not COMPILE"), so a recurrence reddens the suite instead of production.
  gh api --paginate "$RUNNER_LIST_PATH" \
    --jq '("#page\t\(.runners|type)\t\(.runners|length)"), (.runners[] | "\(.status)\t\(.busy)\t\([.labels[].name]|join(","))\t\(.labels|length)")' 2>"$GH_ERR"
}

# census_capability <body> — WHICH permission the read needed, named from the response itself.
# #2931's indicator 2: `cannot read runner labels` alone names our symptom, not the capability, so
# nobody can tell a scope problem from an outage from a schema change. Never used to demand a wider
# token — the token is not widened anywhere in this script (see the header).
census_capability() {
  case "$1" in
    *403*|*"not accessible"*)                      printf 'runner_inventory:needs-admin(read) http=403' ;;
    *404*|*"Not Found"*)                           printf 'runner_inventory:absent http=404' ;;
    *401*|*"Bad credentials"*)                     printf 'runner_inventory:unauthenticated http=401' ;;
    *5[0-9][0-9]*|*"upstream error"*|*"HTTP 500"*) printf 'runner_inventory:upstream http=5xx' ;;
    '')                                            printf 'runner_inventory:empty-response' ;;
    *)                                             printf 'runner_inventory:unreadable' ;;
  esac
}

# offers_all <runner-label-set> <job-label-set> — GitHub's semantics are AND: a job runs on a runner
# that carries EVERY label the job requires. Empty demand is NOT a match (it would claim a match this
# function never checked).
# ⛔ GITHUB'S LABEL MATCHING IS CASE-INSENSITIVE, so this is too (#3002 review P2). Compared literally,
# a workflow writing `runs-on: Ubuntu-Latest` selected exactly the runners this function said offered
# nothing: `demanding_idle=0 demanding_busy=0`, and in mode=local a FALSE `stranded` deny whose reason
# claimed "not one online runner can accept the queue's demand" about runners that would have taken it.
# `tr` rather than `${x,,}`, because the harness still runs on macOS bash 3.2 (#2976).
offers_all() {
  local have want l
  have=",$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]'),"
  want="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  [ -n "$want" ] || return 1
  for l in ${want//,/ }; do
    case "$have" in *",$l,"*) ;; *) return 1 ;; esac
  done
  return 0
}

# census_classify <rows> — the three states, PER RUNNER, and the demand match.
# rc 0 = measured, and that includes a pool of ZERO runners — but ONLY when a page row said so.
# rc 1 = unreadable: a schema change, a truncated body, gh's own error text — or a stream with NO page
# row in it at all, which is what an empty response body produces. Never counted as zero runners.
# offers_any <runner-label-set> <newline-separated job label sets> — does this runner satisfy ANY one
# queued job's whole set? (Per job, never per union — see DEMAND_LABELS.)
offers_any() {
  local have="$1" set
  while IFS= read -r set; do
    [ -n "$set" ] || continue
    offers_all "$have" "$set" && return 0
  done <<<"$2"
  return 1
}

census_classify() {
  local rows="$1" row st busy rest labels lcount nl commas n=0
  local pages=0 declared=0 ptype pcount
  CENSUS_ON_IDLE=0; CENSUS_ON_BUSY=0; CENSUS_OFFLINE=0; CENSUS_DEMAND_IDLE=0; CENSUS_DEMAND_BUSY=0
  CENSUS_LABEL_AMBIGUOUS=0
  # ⛔ THE DERIVED FIELDS ARE CLEARED AT ENTRY, not only written on success (#3002 review P2): after an
  # early `return 1` the counters were half-counted and the KV still described the PREVIOUS body — an
  # artifact that does not match its measurement, which is the shape this change removes elsewhere.
  CENSUS_KV=""; CENSUS_DETAIL=""
  # The per-registration label sets are built here, from the same rows, so a CLAIM can be a statement
  # about ONE machine and can never drift into a second read that disagrees (CENSUS_REGISTRATIONS).
  CENSUS_REGISTRATIONS=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    # ⛔ A PAGE ROW IS THE PROOF THE BODY ANSWERED (#3002 review P1) — see runner_census. It is
    # consumed here and never counted as a registration; without at least one of them the stream is a
    # read that produced nothing, and "nothing" is NOT "no runners" (:391 below).
    case "$row" in
      '#'*)
        case "$row" in '#page'$'\t'*$'\t'*) ;; *) return 1 ;; esac
        ptype="${row#*$'\t'}"; pcount="${ptype#*$'\t'}"; ptype="${ptype%%$'\t'*}"
        [ "$ptype" = array ] || return 1
        case "$pcount" in ''|*[!0-9]*) return 1 ;; esac
        pages=$((pages+1)); declared=$((declared+pcount))
        continue ;;
    esac
    case "$row" in *$'\t'*) ;; *) return 1 ;; esac
    st="${row%%$'\t'*}"; rest="${row#*$'\t'}"
    case "$rest" in *$'\t'*) ;; *) return 1 ;; esac
    busy="${rest%%$'\t'*}"; labels="${rest#*$'\t'}"
    case "$st" in online|offline) ;; *) return 1 ;; esac
    case "$busy" in true|false) ;; *) return 1 ;; esac
    # The 4th field is OPTIONAL so a body that has only ever carried three still parses (#3002): an
    # absent count leaves the ambiguity check with nothing to compare and it is simply not run.
    lcount=""
    case "$labels" in
      *$'\t'*) lcount="${labels#*$'\t'}"; labels="${labels%%$'\t'*}"
               case "$lcount" in ''|*[!0-9]*) return 1 ;; esac ;;
    esac
    # A TAB left in the label field is still a broken ROW (it means a label carries the row separator
    # and the columns after it are lost). Every OTHER character is allowed — see CENSUS_LABEL_AMBIGUOUS.
    case "$labels" in *$'\t'*) return 1 ;; esac
    if [ -n "$lcount" ]; then
      # Count the labels we actually split out: 0 for an empty field, else commas + 1. Pure bash, so
      # no per-runner subprocess and no dependence on anything the harness may not ship.
      nl=0
      if [ -n "$labels" ]; then commas="${labels//[!,]/}"; nl=$(( ${#commas} + 1 )); fi
      [ "$nl" = "$lcount" ] || CENSUS_LABEL_AMBIGUOUS=1
    fi
    # Every registration contributes its OWN label set — an offline runner's labels are still something
    # the pool says it serves, and that is what makes a stranded deny meaningful.
    if [ -n "$labels" ]; then
      case "$CENSUS_REGISTRATIONS" in
        '') CENSUS_REGISTRATIONS="$labels" ;;
        *)  CENSUS_REGISTRATIONS="$CENSUS_REGISTRATIONS
$labels" ;;
      esac
    fi
    n=$((n+1))
    if [ "$st" = online ]; then
      # ⛔ THE THREE STATES COME FROM THE API, PER RUNNER — never from a count of registrations.
      if [ "$busy" = true ]; then CENSUS_ON_BUSY=$((CENSUS_ON_BUSY+1)); else CENSUS_ON_IDLE=$((CENSUS_ON_IDLE+1)); fi
      if offers_any "$labels" "$DEMAND_LABELS"; then
        if [ "$busy" = true ]; then CENSUS_DEMAND_BUSY=$((CENSUS_DEMAND_BUSY+1)); else CENSUS_DEMAND_IDLE=$((CENSUS_DEMAND_IDLE+1)); fi
      fi
    else
      # ⛔ `offline` IS THE FACT; "never online" IS NOT (#3002 review P2). The runner object carries
      # `id os status busy labels` and NOTHING that says a registration has EVER connected — `status`
      # is validated to be `online|offline` (:302). Measured 2026-10-28 on this repo: 5 of 8 offline,
      # and they are long-standing pool members (cell3-x64-4, cell4-1), i.e. runners that were online
      # earlier and dropped. Reporting those as "never came online" states a fact the read cannot
      # establish, and it was used as the operational diagnosis in the PR body.
      CENSUS_OFFLINE=$((CENSUS_OFFLINE+1))
    fi
  done <<<"$rows"
  # ⛔ NO PAGE ROW ⇒ THE READ PRODUCED NOTHING ⇒ UNREADABLE (#3002 review P1). This is the arm that
  # used to fall through to `runners=0`: one blank 200 body became a measured zero, and in mode=local
  # with a demand that is a `stranded` DENY — a relabel taken on a read with no value in it. An empty
  # POOL still reads as a readable zero, because a body carrying `"runners": []` makes jq emit the page
  # row with count 0; a body carrying nothing makes jq emit nothing at all.
  [ "$pages" -gt 0 ] || return 1
  # …and the registrations COUNTED must be the registrations the pages DECLARED. Every page row and
  # every registration row are emitted by the same jq run, so a mismatch can only mean the stream was
  # TRUNCATED between them (a proxy cutting the body, a partial read) — i.e. an UNDERCOUNT, which is
  # the failure shape that reads as a healthy pool. Refused, not counted.
  [ "$n" = "$declared" ] || return 1
  CENSUS_KV="runners=$n online_idle=$CENSUS_ON_IDLE online_busy=$CENSUS_ON_BUSY offline=$CENSUS_OFFLINE demanding_idle=$CENSUS_DEMAND_IDLE demanding_busy=$CENSUS_DEMAND_BUSY label_ambiguity=$CENSUS_LABEL_AMBIGUOUS demand=${DEMAND_SHOWN:-unknown}"
  CENSUS_DETAIL="$((CENSUS_ON_IDLE+CENSUS_ON_BUSY)) of $n online (idle=$CENSUS_ON_IDLE busy=$CENSUS_ON_BUSY offline=$CENSUS_OFFLINE)"
  return 0
}

# queue_demand <run id> — WHAT THE QUEUE IS ASKING FOR, from the jobs endpoint.
# ⛔ THIS IS THE READABLE SUBSTITUTE, and it is readable on the boxes where the inventory is not:
# `GET /repos/{o}/{r}/actions/runs/{id}/jobs` needs `actions:read` (measured 200 with the fleet
# token), and each job carries the `labels` it requires. Measured 2026-10-28: the head job of
# daniel-ospina/tortoise's 74-deep queue asked for exactly `ubuntu-latest`.
# BOUND, stated: the demand is the label set of the QUEUED jobs of ONE run — normally the head (the
# run that has waited longest, the one that decides whether the queue can move at all), with the
# NEWEST queued run as a one-shot fallback when the head is a stale entry with no queued job left.
# A queue whose other runs ask for something else is not measured here, and the KV says `demand=`
# per run, not "the whole queue".
queue_demand() {
  local rid="$1" out l sets=0
  case "$rid" in ''|*[!0-9]*) return 1 ;; esac
  out="$(gh api "repos/$REPO/actions/runs/$rid/jobs" \
        --jq '[.jobs[]|select(.status=="queued")|.labels|sort|join(",")]|unique|.[]' 2>"$GH_ERR")" || return 1
  # An empty answer is NOT "no demand": a matrix/`runs-on` form this read does not resolve leaves
  # the demand unmeasured, and an unmeasured demand must not become a claim about matching.
  [ -n "$out" ] || return 1
  # Every LINE is one QUEUED JOB's set, and each must be spellable on its own: a job whose set cannot
  # be spelled is an UNMEASURED demand, never a claim about matching (checked per line, because a
  # multi-job run is now several lines — see DEMAND_LABELS).
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case "$l" in *[!A-Za-z0-9._,+-]*) return 1 ;; esac
    sets=$((sets+1))
  done <<<"$out"
  [ "$sets" -gt 0 ] || return 1
  printf '%s' "$out"
}

# capacity_verdict <mode> — the CAPACITY answer from the counts above.
# rc 0 = no capacity deny · rc 1 = DENY (this pass may not certify healthy capacity).
# ⛔ THE MODE GATES THE DENY, and that is not incidental — it is what keeps the gate from fighting
# the recorded #2327 decision. In mode=github the pool is STRIPPED ON PURPOSE, so "no online runner
# offers ubuntu-latest" is the CORRECT state and denying on it would re-engage the fallback on every
# healthy tick, forever. Only in mode=local is the pool supposed to serve, and only there is
# "nothing online can take the demand" a conclusive fault.
# pool_claims_demand — is there ONE registration that could serve ONE queued job's whole label set?
# rc 0 = yes, the pool claims this work (so "nobody online can take it" is a fault of the pool).
# rc 1 = no / cannot tell, so the deny must NOT be made.
# ⛔ THE CLAIM AND THE MATCH ARE STATEMENTS ABOUT THE SAME MACHINE (#3002 review P2, round 3). Testing
# the demand against the UNION of every registration's labels made a demand that NO SINGLE machine could
# ever take read as claimed — `gpu,ubuntu-latest` "covered" by an idle `ubuntu-latest` runner plus an
# offline `gpu` one — so the deny fired for work the pool could never serve. That is the same defect the
# claim rule was carved out to prevent, re-entered through the union. Both sides are now per set.
# ⛔ A MATCH WE CANNOT TRUST IS NOT A CLAIM (#3002 review P1): an ambiguous label set makes the split
# untrustworthy, and a truncated label must never be read as "the pool does not offer this" — refuse
# rather than guess.
# ⛔ THE FALLBACK LABEL is the one label the gate ITSELF stamps, so a POOL MEMBER (a registration
# carrying a pool marker — the only kind `managed_ids` will relabel) may claim a job that asks for it
# before the relabel lands, and must, or a just-engaged fallback would read as `stranded` in the window
# before the PUTs land. A registration with NO marker is never relabelled, so it gets no such credit.
pool_claims_demand() {
  local set have
  [ -n "$DEMAND_LABELS" ] || return 1
  [ "$CENSUS_LABEL_AMBIGUOUS" = 0 ] || return 1
  [ -n "$CENSUS_REGISTRATIONS" ] || return 1
  while IFS= read -r set; do
    [ -n "$set" ] || continue
    while IFS= read -r have; do
      [ -n "$have" ] || continue
      if offers_all "$have" "$set"; then return 0; fi
      case "$have" in
        *"$POOL_LABEL_ARM64"*|*"$POOL_LABEL_X64"*)
          offers_all "$have,$FALLBACK_LABEL" "$set" && return 0 ;;
      esac
    done <<<"$CENSUS_REGISTRATIONS"
  done <<<"$DEMAND_LABELS"
  return 1
}

capacity_verdict() {
  local m="$1" online demand_usable demand_usable_early
  online=$((CENSUS_ON_IDLE + CENSUS_ON_BUSY))
  # A demand is usable as EVIDENCE only when it was measured AND the split that matched it is sound
  # (an ambiguous label set makes every MATCH untrustworthy — never the deny's evidence).
  demand_usable_early=0
  [ -n "$DEMAND_LABELS" ] && [ "$CENSUS_LABEL_AMBIGUOUS" = 0 ] && demand_usable_early=1
  if [ "$queued" -eq 0 ]; then CENSUS_VERDICT=absorbing; return 0; fi
  if [ "$online" -eq 0 ]; then
    # Registrations that never came online. This is the third state, and it is the one a count of
    # registrations hides: measured 2026-10-28 12:54Z, daniel-ospina/agent-infra held 8
    # registrations with 2 online and 6 offline, and every reading the gate made was compatible
    # with healthy.
    # ⛔ THE CLAIM RULE APPLIES TO THIS ARM TOO (#3002 review P1, third round): a demand the pool never
    # advertised (a `macos-latest` head, say) is not "registration exists, nothing online can serve the
    # work" — it is work this pool was never supposed to serve, and denying on it pins mode=local on a
    # healthy repo for as long as that run heads the queue. One rule, both deny candidates.
    if [ "$m" = local ] && [ "$demand_usable_early" = 1 ] && pool_claims_demand; then CENSUS_VERDICT=stranded; return 1; fi
    CENSUS_VERDICT=all-offline; return 0
  fi
  # ⛔ AN AMBIGUOUS LABEL SET NEVER DENIES (#3002 review P1). `label_ambiguity=1` means a label carried
  # the comma this pass splits on, so the split — and therefore every demand MATCH and every claim made
  # from the OFFERED union — is untrustworthy. A match we cannot trust must not become the evidence for
  # a `stranded` deny; it NARROWS the claim to the runner STATES instead, which is exactly the reading
  # the mode=github arm below already takes for a demand that could not be measured. Fail-closed here
  # means "make no deny", not "refuse the pass".
  demand_usable="$demand_usable_early"
  # ── THE ONE DENY ARM, and its scope is two conditions, not one ────────────────────────────────
  # mode=local: the pool is SUPPOSED to serve. And `pool_claims_demand`: the work it is supposed to
  # serve is THIS work. "Not one online runner can accept the queue's demand" is a fault of the pool
  # only when the pool advertised that demand; otherwise it is a `macos-latest`/`gpu`/matrix job the
  # pool never claimed, and denying on it pinned mode=local on a healthy repo forever (#3002 review
  # P1). When the deny does not apply the reading narrows to the runner STATES, which is exactly the
  # narrowing the unmeasurable-demand arm already takes — no claim is invented, and none is dropped.
  # This is #2931's mechanism, made measurable without admin.
  if [ "$m" = local ] && [ "$demand_usable" = 1 ]; then
    if [ "$CENSUS_DEMAND_IDLE" -eq 0 ] && [ "$CENSUS_DEMAND_BUSY" -eq 0 ] && pool_claims_demand; then
      CENSUS_VERDICT=stranded; return 1
    fi
  fi
  # ── THE STATE READING, ONE ARMSET FOR EVERY ARM THAT DOES NOT DENY ────────────────────────────
  # mode=github (pool stripped by design, #2327), an unmeasurable/untrustworthy demand, or mode=local
  # with a demand the pool never claimed: the pool's LABEL SET is not evidence, so the verdict is the
  # pool's own state.
  # ⛔ IDLE IS TESTED BEFORE BUSY (#3002 review P1, and again in round 3). `saturated` means EVERY
  # ONLINE runner is busy, so a pool with idle runners must never be labelled with it — and `saturated`
  # is a CERTIFYING word (:1049 routes it to "GitHub Actions healthy"), so the mislabel is not
  # cosmetic: it restores the very "9 busy while 7 idle" reading this instrument exists to remove.
  # ⛔ THE TWO ARMS USED TO READ THE STATES SEPARATELY, and that divergence produced the same defect
  # twice: the demand arm returned `saturated` whenever no DEMAND-matching runner was idle, even with
  # other online runners idle — so 1 busy + 7 idle printed `capacity=saturated` and certified. There is
  # now ONE state reading for every non-denying arm, so the two cannot disagree again. `DEMAND_IDLE`
  # needs no test of its own: a demand-matching idle runner IS an idle runner (census_classify only
  # counts it for `online` rows), so it is a SUBSET of `ON_IDLE`, and `demand_usable && DEMAND_IDLE>0`
  # was subsumed rather than kept as dead code.
  if [ "$CENSUS_ON_IDLE" -gt 0 ]; then CENSUS_VERDICT=idle-unused; return 0; fi
  if [ "$CENSUS_ON_BUSY" -gt 0 ]; then CENSUS_VERDICT=saturated; return 0; fi
  # Unreachable while online>0 (idle+busy == online), and deliberately NON-CERTIFYING: if a future
  # count ever became inconsistent, the one thing this default must never do is certify.
  CENSUS_VERDICT=idle-unused; return 0
}

# ── health probe ────────────────────────────────────────────────────────────────
# Unhealthy if: the Actions component is not operational, OR an incident mentions
# Actions, OR the queued backlog exceeds the threshold, OR the queue is NOT BEING
# ABSORBED (agent-infra#2904 — work queued past the stall floor while nothing at all
# is executing). The component alone is NOT sufficient — a live Actions incident has
# been observed with the component still reading "operational" — and neither are
# length-and-status alone: a run sat queued 3 h against an operational component, no
# incident and a queue under the length threshold, with no runner able to take it.
probe_status() {
  curl -fsS --max-time 20 https://www.githubstatus.com/api/v2/summary.json 2>/dev/null || return 1
}

evaluate() {
  local summary queued comp incident parsed
  summary="$(probe_status)" || { log "status probe FAILED (network/status api)"; return 2; }

  parsed="$(printf '%s' "$summary" | python3 -c '
import json,sys
d=json.load(sys.stdin)
comp="?"
for c in d.get("components",[]):
    if c.get("name")=="Actions":
        comp=c.get("status","?")
inc=[i for i in d.get("incidents",[]) if "actions" in (i.get("name","")+i.get("impact","")).lower()]
print(comp, len(inc))
' 2>/dev/null)" || { log "status summary parse FAILED (python)"; return 2; }
  # ⛔ SHAPE-CHECK THE CAPTURED VALUE. `read -r a b <<<""` returns 0 for an empty here-string, so the
  # guard that used to hang off `read` could never fire: a json.load failure left comp="" — which
  # is NOT "operational", so the gate returned 1 (unhealthy) and ACTED on it, relabelling the pool
  # and routing CI onto this box. That is the opposite of what the header promises (`2
  # could-not-measure (fail-closed: changing nothing)`). It also catches python's `comp="?"`
  # fallback, so a githubstatus schema change is unreadable rather than "not operational".
  #
  # ⛔ `[:blank:]`, NOT `[:space:]` (review B1). The inline python prints `comp` and the incident
  # count SPACE-separated, so a status that is `null`/`""` yields `" 0"` — and `read`, which strips
  # leading IFS whitespace, turns that into `comp="0"`, not `""`. Admitting a newline let a status
  # containing one truncate the line so the incident field vanished. Neither is a readable summary.
  case "$parsed" in ''|*[!A-Za-z0-9_[:blank:]]*) log "status summary unreadable: ${parsed:0:120}"; return 2 ;; esac
  read -r comp incident <<<"$parsed"

  # ⛔ BOTH FIELDS MUST BE STRICTLY READABLE (review B1). `comp` was compared verbatim and
  # `incident` was never checked at all — `${incident:-0}` read an EMPTY count as "0 incidents", so
  # a summary whose second field did not parse reported HEALTHY while an Actions incident was live
  # (`fallback_off` would then relabel the pool off `ubuntu-latest` exactly when GitHub-hosted is
  # degraded). A component status outside GitHub's documented set — `None`, `""`, `"?"`, or any
  # future value — is a schema change, i.e. could-not-measure (2), never "unhealthy" (1): acting on
  # an unread status relabels the pool. Only the four non-operational statuses fall through to 1.
  # `comp` is checked FIRST: when the status is unreadable the space-separated print leaves the
  # incident field empty too, and naming the status is the more useful of the two reasons.
  case "$comp" in
    operational|degraded_performance|partial_outage|major_outage|under_maintenance) ;;
    *) log "actions component UNREADABLE ('${comp}') — FAIL-CLOSED, changing nothing"; return 2 ;;
  esac
  case "$incident" in '' | *[!0-9]*) log "incident count UNREADABLE ('${incident}') — FAIL-CLOSED, changing nothing"; return 2 ;; esac
  # ⛔ ONE READ CARRIES BOTH QUEUE FACTS (agent-infra#2904): the count the existing leg already
  # used, and the `created_at` of the OLDEST queued run the throughput leg needs. `per_page=$QUEUE_PAGE`
  # rather than 1 so the page holds the whole queue and `min(created_at)` is the true head of it.
  # ⛔ THE PAGE CAP CAN HIDE THE OLDEST RUN (review P2 — this used to be asserted in prose only).
  # The runs endpoint is newest-first, so a queue LARGER than the page yields the newest page's min,
  # i.e. a LOWER BOUND on the head age. That was previously claimed to be harmless because "such a
  # queue is already >= QUEUE_THRESHOLD" — true at the shipped 60, FALSE whenever an operator raises
  # QUEUE_THRESHOLD above the page size, and the operator-invisible result was a gate that read a
  # 150-deep queue as healthy on a 60 s head. The length leg still decides first (it returns 1 on
  # `queued >= QUEUE_THRESHOLD`), so the saturated page only matters where NOTHING can decide —
  # that case is now refused by name, before the throughput leg, further down.
  queue_row="$(gh api "repos/$REPO/actions/runs?status=queued&per_page=$QUEUE_PAGE" \
      --jq '[.total_count, (([.workflow_runs[]]|min_by(.created_at)|.created_at)//""), (([.workflow_runs[]]|min_by(.created_at)|.id)//""), ((.workflow_runs[0].id)//"")]|@tsv' 2>/dev/null)" \
    || { log "queue probe FAILED (gh api)"; return 2; }
  # FOUR fields from one read: the count the length leg uses, the head's age for the throughput leg,
  # and TWO run ids for the DEMAND read (agent-infra#2931 — "which label is the queue asking for" is
  # answerable with `actions:read`, which the fleet token HAS, even where the runner inventory is
  # 403): the OLDEST queued run (the head that has waited longest) and the NEWEST one. Both are
  # needed because a STALE head has nothing to ask — measured 2026-10-28, daniel-ospina/agent-infra's
  # queue head was 20.9 days old and its run returned ZERO jobs, so a head-only demand read reported
  # `demand=unknown` over a queue that was asking for `ubuntu-latest` all along. Extra fields are
  # optional: a two-field body still parses, and an absent id leaves the demand unmeasured instead of
  # failing a pass that needs nothing else from it.
  local q1 q2 q3 q4
  IFS=$'\t' read -r q1 q2 q3 q4 <<<"$queue_row"
  queued="${q1:-}"; oldest_created="${q2:-}"; head_run_id="${q3:-}"; newest_run_id="${q4:-}"
  # ⛔ THE SECOND READ IS THE ABSORPTION FIELD, and it is the ONLY input the throughput leg adds
  # (#2904). `in_progress` is the count of runs GitHub is currently executing for this repo; in
  # mode=github that is hosted executing, because the pool does not advertise `ubuntu-latest` and no
  # workflow asks for a `self-hosted` label. One extra API call per scheduled pass. gh's stderr is
  # captured so a failed read CARRIES ITS REASON (the #1704 enumeration lesson: a failure reported
  # without what the API said is a failure nobody can act on).
  in_progress_raw="$(gh api "repos/$REPO/actions/runs?status=in_progress&per_page=1" --jq '.total_count' 2>"$GH_ERR")" \
    || { log "in-progress probe FAILED (gh api) — FAIL-CLOSED, changing nothing; $(head -c 300 "$GH_ERR" 2>/dev/null)"; return 2; }
  in_progress="${in_progress_raw%%$'\n'*}"
  # THE QUEUE-WAIT CLOCK, computed here so the log line can carry seconds rather than a timestamp.
  # Empty when there is no queued run to age (a readable zero, not a failed read); a timestamp that
  # cannot be parsed, or one in the FUTURE (a clock skew no reading can resolve), leaves it empty and
  # the shape check below refuses the whole pass — it is never rounded down to "recently queued" and
  # never rounded up to "stalled".
  oldest_queued_s=""
  case "$oldest_created" in
    '') : ;;
    *)  oldest_queued_s="$(python3 -c '
import datetime, sys
t = sys.argv[1]
try:
    d = datetime.datetime.strptime(t, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
except ValueError:
    sys.exit(1)
age = int(datetime.datetime.now(datetime.timezone.utc).timestamp() - d.timestamp())
if age < 0:
    sys.exit(1)
print(age)
' "$oldest_created" 2>/dev/null)" || oldest_queued_s="" ;;
  esac

  # A queue with NOTHING in it has no head to age. That is a readable zero (an idle repo), not a
  # failed read: it leaves the leg inert instead of refusing the pass. Guarded as a STRING compare so
  # it cannot run before `queued` has been shape-checked as a number.
  if [ "$queued" = "0" ] && [ -z "$oldest_queued_s" ]; then oldest_queued_s=0; fi

  log "probe: actions_component=$comp actions_incidents=$incident queued=$queued threshold=$QUEUE_THRESHOLD oldest_queued_s=$oldest_queued_s in_progress=$in_progress queue_stuck_after_s=$QUEUE_STUCK_AFTER_S"
  ABSORPTION_OLDEST_S="$oldest_queued_s"; ABSORPTION_IN_PROGRESS="$in_progress"; ABSORPTION_QUEUED="$queued"

  # ⛔ SHAPE-CHECK THE COUNT TOO (agent-infra#1704). `comp` was shape-checked; `queued` was not, so
  # a successful probe that yielded `null`/empty (a schema change, a proxy body, a truncated read)
  # made `[ "$queued" -ge "$QUEUE_THRESHOLD" ]` ERROR (status 2) — and the `||` chain reads a failed
  # test as FALSE, i.e. HEALTHY. "Healthy" means want=github -> `fallback_off`, which RELABELS the
  # local pool: a state change taken on a value that was never read. A count that is not a
  # non-negative integer is unreadable, so this is could-not-measure (return 2) — never healthy.
  case "$queued" in
    '' | *[!0-9]*) log "queued count UNREADABLE ('${queued}') — FAIL-CLOSED, changing nothing"; return 2 ;;
  esac

  # ⛔ THE THRESHOLD IS THE OTHER OPERAND OF THE SAME NUMERIC TEST (review D1), so an unreadable
  # value makes `[ "$queued" -ge "$QUEUE_THRESHOLD" ]` ERROR — and the `||` chain reads that as
  # false, i.e. HEALTHY — relabelling the pool, advancing the state file and notifying on a value
  # that was never read. The launchd job never sets CI_GATE_QUEUE_THRESHOLD (the plist carries only
  # PATH/HOME), so this is reachable from an env-overriding caller rather than from the schedule;
  # the read is refused either way.
  #
  # ⛔ DIGITS ALONE IS NOT THE PREDICATE `[ -ge ]` NEEDS (review B2-2). A digit string longer than
  # `intmax` passes a character-class guard and STILL errors the comparison, which the `||` chain
  # reads as false — the same fail-open one step later (measured: a 26-digit threshold relabelled
  # the pool, advanced the state file and notified, exit 0). So the bound is the number of digits,
  # on BOTH operands: 9 digits cannot exceed intmax on any platform bash's `[` supports, and no real
  # queued-run count approaches it. Anything larger is out of range, not a measurement.
  case "$queued" in ??????????*) log "queued count OUT OF RANGE ('${queued}') — FAIL-CLOSED, changing nothing"; return 2 ;; esac
  case "$QUEUE_THRESHOLD" in
    '' | *[!0-9]*) log "queue threshold UNREADABLE ('${QUEUE_THRESHOLD}') — FAIL-CLOSED, changing nothing"; return 2 ;;
    ??????????*) log "queue threshold OUT OF RANGE ('${QUEUE_THRESHOLD}') — FAIL-CLOSED, changing nothing"; return 2 ;;
  esac

  # ⛔ THE THROUGHPUT LEG'S OPERANDS ARE SHAPE-CHECKED EXACTLY AS THE EXISTING ONES ARE, for the
  # same reason (agent-infra#1704): an unreadable number makes `[ … -gt … ]` ERROR, and the `||`
  # chain reads a failed test as FALSE — i.e. HEALTHY — which RELABELS the pool off `ubuntu-latest`
  # on a value that was never read. A leg that errors is could-not-measure (2): here that means the
  # gate takes NO action at all, neither "healthy" nor "unhealthy-but-act" (#2904's fail-closed
  # requirement).
  case "$in_progress" in
    '' | *[!0-9]*) log "in_progress count UNREADABLE ('${in_progress}') — FAIL-CLOSED, changing nothing"; return 2 ;;
    ??????????*)  log "in_progress count OUT OF RANGE ('${in_progress}') — FAIL-CLOSED, changing nothing"; return 2 ;;
  esac
  # A queued run exists, so its age MUST be a measurement: empty here means the timestamp did not
  # parse (or was in the future), which is a failed read of the queue head, not "young queue".
  if [ "$queued" -gt 0 ] && [ -z "$oldest_queued_s" ]; then
    log "oldest queued timestamp UNREADABLE ('${oldest_created}') — FAIL-CLOSED, changing nothing"; return 2
  fi
  case "$oldest_queued_s" in
    '' | *[!0-9]*) log "oldest queued age UNREADABLE ('${oldest_queued_s}') — FAIL-CLOSED, changing nothing"; return 2 ;;
    ??????????*)  log "oldest queued age OUT OF RANGE ('${oldest_queued_s}') — FAIL-CLOSED, changing nothing"; return 2 ;;
  esac
  case "$QUEUE_STUCK_AFTER_S" in
    '' | *[!0-9]*) log "queue stuck-after floor UNREADABLE ('${QUEUE_STUCK_AFTER_S}') — FAIL-CLOSED, changing nothing"; return 2 ;;
    ??????????*)  log "queue stuck-after floor OUT OF RANGE ('${QUEUE_STUCK_AFTER_S}') — FAIL-CLOSED, changing nothing"; return 2 ;;
  esac
  # ⛔ THE ALARM'S OWN FLOOR IS A BOUND LIKE ANY OTHER, and it was the one operand in this script never
  # shape-checked (#3002 review P2). `[ "$((now-last))" -lt "$BLIND_ALARM_EVERY_S" ]` on a non-numeric
  # value ERRORS, the `if` reads that as FALSE, and the alarm fires on EVERY pass — the exact unbounded
  # alarm the bound exists to prevent, with a diagnostic that renders as `one per abcs`. Reachable from
  # an env-overriding caller, which is the same reachability class every other bound here guards.
  case "$BLIND_ALARM_EVERY_S" in
    '' | *[!0-9]*) log "blind-alarm floor UNREADABLE ('${BLIND_ALARM_EVERY_S}') — FAIL-CLOSED, changing nothing"; return 2 ;;
    ??????????*)  log "blind-alarm floor OUT OF RANGE ('${BLIND_ALARM_EVERY_S}') — FAIL-CLOSED, changing nothing"; return 2 ;;
  esac

  # ⛔ THE CAPACITY CENSUS IS READ BEFORE ANY LEG DECIDES, AND ITS FAILURE IS A VERDICT (#2897).
  # The healthy verdict now DEPENDS on a per-runner capacity reading, so a pass that cannot read it
  # has no capacity claim to make — and the answer to "I cannot see" is UNKNOWN + an alarm, never
  # the silent `exit 2` with one log line that the fleet read as "nothing to say" for hours.
  # ⛔ THE PASS IS REFUSED EVEN WHEN THE QUEUE LEGS WOULD DENY: the read and the WRITE are the same
  # admin-only endpoint, so a blind box cannot relabel anything either — refusing loses no capability
  # and gains no false claim. Uniform with every other unread operand in this script.
  local census_rows census_err
  if census_rows="$(runner_census)"; then
    if ! census_classify "$census_rows"; then
      CAPABILITY="$(census_capability "$census_rows")"
      log "runner census UNREADABLE (schema/body): ${census_rows:0:300} — capacity=unknown capability=${CAPABILITY} — FAIL-CLOSED, changing nothing"
      CENSUS_VERDICT=unknown; CENSUS_BLIND=1
      return 2
    fi
  else
    census_err="$(cat "$GH_ERR" 2>/dev/null)"
    CAPABILITY="$(census_capability "$census_err")"
    census_rows="$census_err"
    log "runner census FAILED endpoint=$RUNNER_LIST_PATH capability=${CAPABILITY} — capacity=unknown; probe: queued=$queued in_progress=$in_progress; FAIL-CLOSED, changing nothing; gh said: ${census_rows:0:300}"
    CENSUS_VERDICT=unknown; CENSUS_BLIND=1
    return 2
  fi
  # ⛔ THE DEMAND READ NEEDS `actions:read`, NOT `Administration: read` — that asymmetry is the whole
  # reason the queue's side of the question stays measurable on a box whose inventory is 403. It does
  # NOT fail the pass: an unmeasured demand narrows the capacity claim (`demand=unknown`) instead of
  # erasing it, because the three STATES are still measured and are still worth reporting.
  DEMAND_LABELS=""
  if [ "$queued" -gt 0 ] && [ -n "$head_run_id" ]; then
    DEMAND_LABELS="$(queue_demand "$head_run_id")" || DEMAND_LABELS=""
    if [ -z "$DEMAND_LABELS" ] && [ -n "$newest_run_id" ] && [ "$newest_run_id" != "$head_run_id" ]; then
      DEMAND_LABELS="$(queue_demand "$newest_run_id")" || DEMAND_LABELS=""
      [ -n "$DEMAND_LABELS" ] && log "demand: the queue HEAD (run $head_run_id) has no QUEUED job — read from the newest queued run ($newest_run_id) instead"
    fi
    [ -n "$DEMAND_LABELS" ] || log "demand: UNMEASURED for queued=$queued (neither the head nor the newest queued run reported a queued job's labels) — the capacity claim is narrowed to the runner states only"
  fi
  # ONE LINE FOR THE KEY=VALUE SURFACES (`demand=` in the census KV, the log, the deny's reason), because
  # DEMAND_LABELS is one set per line now. `;` between sets, so the union that is WRONG to match is still
  # READABLE to a human: a matrix run reads `self-hosted-arm64;self-hosted-x64`.
  DEMAND_SHOWN=""
  [ -n "$DEMAND_LABELS" ] && DEMAND_SHOWN="${DEMAND_LABELS//$'\n'/;}"
  # Re-classify with the demand now known: the first pass classified the label sets before there was
  # anything to match them against. Cheap (it reads the rows already in memory) and it keeps the
  # counts and the matches derived from ONE body rather than two reads that could disagree.
  # ⛔ THIS CANNOT FAIL INDEPENDENTLY: the same rows passed `census_classify` at the top of this leg and
  # returned 2 there, and nothing about them changes in between — the only input that moves is
  # DEMAND_LABELS, which affects the MATCH counts and never the shapes. The guard stays so a future
  # caller cannot reach the deny arms having skipped a classification, but it is a guard, not a second
  # check — it does not make the unreadable-body arm more proven than the one above (#3002 review P2).
  census_classify "$census_rows" || { log "runner census UNREADABLE on re-classify — FAIL-CLOSED, changing nothing"; CENSUS_VERDICT=unknown; CENSUS_BLIND=1; return 2; }
  # The counts AND the verdict are computed on EVERY pass, before any leg decides: this line is the
  # instrument's raw reading, so "why did it say that" is answerable from the durable log alone —
  # including on the paths where a QUEUE leg denies first and the capacity verdict is only reported.
  CAP_DENY=0
  capacity_verdict "${mode:-unknown}" || CAP_DENY=1
  log "capacity: verdict=${CENSUS_VERDICT} ${CENSUS_KV} (${CENSUS_DETAIL})"

  if [ "$comp" != "operational" ] || [ "$incident" != "0" ] || [ "$queued" -ge "$QUEUE_THRESHOLD" ]; then
    UNHEALTHY_LEG="queue/component/incident leg: queued=$queued (threshold $QUEUE_THRESHOLD), component=$comp, incidents=$incident"
    return 1   # unhealthy -> prefer local
  fi
  # ⛔ A SATURATED PAGE LEAVES NO TRUSTWORTHY READING, so the pass is REFUSED rather than certified
  # (review P2). Reaching here means the length leg did NOT fire (`queued < QUEUE_THRESHOLD`), yet the
  # queue is deeper than one page — which can only happen when an operator has raised
  # QUEUE_THRESHOLD above the page size. In that state `oldest_queued_s` is a LOWER BOUND on the
  # head's age (newest-first page), so a stalled queue can read young and the gate would certify
  # healthy and strip the pool during a full stop. Could-not-measure (2) is this script's answer for
  # every other unread operand; it is the answer here too, and the message names BOTH values so the
  # misconfiguration is visible instead of silent.
  if [ "$queued" -gt "$QUEUE_PAGE" ]; then
    log "queue ($queued) is DEEPER than the read page ($QUEUE_PAGE) while the length leg did not decide (threshold $QUEUE_THRESHOLD) — the queue head cannot be measured (the page is newest-first, so its min is only a lower bound); FAIL-CLOSED, changing nothing"
    return 2
  fi

  # ⛔ THE THROUGHPUT LEG (agent-infra#2904). Work is queued, the oldest queued run has waited past
  # the floor, AND nothing is executing. The conjunction is the point: measured on this repo, a
  # queue head 12,583 s (3 h 29 m) old coexists with 14 runs executing (hosted serving normally), so
  # an age clause alone would fire continuously on a healthy repo; and `in_progress == 0` alone fires
  # for the few seconds between a push and its first dispatch, so it needs the age floor. Fail ⇒
  # "hosted is not absorbing", which is precisely the state whose sanctioned exit is this script's
  # own fallback path — NOT a change to when the pool is offered (see the header's decision).
  # ⛔ IT IS A DENY-ONLY LEG, and the deny holds in BOTH modes: `in_progress == 0` with a stuck head
  # says nothing at all is executing (hosted or pool), so the pool stays engaged. It never CERTIFIES
  # absorption — falling through to `return 0` is the other legs' verdict, and the reason line says
  # the absorption figures are not attributable while the pool is the thing executing (review P1).
  if [ "$queued" -gt 0 ] && [ "$in_progress" -eq 0 ] && [ "$oldest_queued_s" -gt "$QUEUE_STUCK_AFTER_S" ]; then
    UNHEALTHY_LEG="throughput leg: queued=$queued and NO run executing while the oldest queued run has waited ${oldest_queued_s}s > ${QUEUE_STUCK_AFTER_S}s — GitHub-hosted is not absorbing the queue"
    return 1   # not absorbing -> prefer local
  fi

  # ⛔ THE CAPACITY LEG (agent-infra#2904 · #2931). The legs above read the QUEUE and the PLATFORM;
  # none of them can see the POOL — which is how a fleet ran at 2 of 8 while every reading said
  # healthy. This leg answers from per-runner state plus the queue's own demand, and it denies only
  # where the deny is conclusive AND mode-appropriate (`capacity_verdict` documents the mode gate:
  # in mode=github the pool is stripped by design, so "nothing offers ubuntu-latest" is CORRECT
  # there and denying on it would re-engage the fallback on every healthy tick).
  if [ "$CAP_DENY" = 1 ]; then
    UNHEALTHY_LEG="capacity leg: mode=${mode:-unknown} and ${CENSUS_DETAIL}, not one online runner can accept the queue's demand (${DEMAND_SHOWN:-unknown}) while queued=$queued — the pool cannot take the work it is supposed to be serving"
    return 1
  fi
  return 0     # healthy   -> prefer GitHub
}

# ── label control ───────────────────────────────────────────────────────────────
# ⛔ --paginate is REQUIRED: `gh api` returns at most 30 runners per page, so a pool larger than
# that was relabelled only in part, and `set_labels` reported ok=N over a truncated set.
#
# One `<id> TAB <label>` line per label, not just the ids: the label body is now derived PER RUNNER
# (agent-infra#2327), so the read has to carry each runner's own labels. TAB is the delimiter
# because a runner label cannot contain one, so `id<TAB>label` can never be ambiguous; and a
# newline-separated pair list keeps every field checkable on its own line, unlike a joined string.
runner_rows() {
  gh api --paginate "repos/$REPO/actions/runners" \
    --jq '.runners[] | .id as $id | .labels[] | "\($id)\t\(.name)"'
}

# managed_ids <rows> — the runners this gate owns: those carrying a pool marker.
#
# ⛔ SELECT THE POOL, NOT "EVERY RUNNER IN THE REPO" (agent-infra#2327). The old code PUT to every
# id it could enumerate, so any self-hosted runner — this pool's or not — was rewritten. A runner
# carrying neither marker is not ours to relabel, and leaving it untouched is the conservative
# reading. (A runner the legacy gate already stamped ARM64 onto carries a marker, so this still
# selects it and the derivation below repairs it.)
managed_ids() { # $1 = rows (newline-separated `<id>TAB<label>`)
  local rid name
  while IFS=$'\t' read -r rid name; do
    case "$name" in
      "$POOL_LABEL_ARM64"|"$POOL_LABEL_X64") printf '%s\n' "$rid" ;;
    esac
  done <<<"$1" | awk '!seen[$0]++'
}

# labels_for <rows> <id> <on|off> — the label body for ONE runner, derived from ITS OWN HOST.
#
# ⛔ **A RUNNER'S LABELS MUST DESCRIBE THAT RUNNER, NOT THE POOL IT JOINED FIRST.** That is the
# invariant this function exists to hold. The architecture is not an opinion the caller supplies:
# it is the `ARM64` / `X64` label GitHub stamps from the host at registration, and it is the only
# per-runner fact available here. So:
#   own = the marker for THIS host's arch  +  any other custom label the runner already carries
#         (never dropped: a label the gate did not add is not the gate's to remove)
#   body = own (+ `ubuntu-latest` when the fallback is engaged)
# The one label this gate owns is `ubuntu-latest`; it is added on fallback and omitted otherwise,
# so both states are byte-identical to the pre-#2327 body for an ARM64 runner.
#
# Returns 1 (and changes nothing) when the runner cannot be classified from its own host label, or
# carries a custom label that cannot be emitted safely into JSON: an unclassifiable runner is a
# named failure the caller counts, never a guess. Note the `self-hosted-arm64` marker on an x64 box
# (what the old code stamped) is NOT consulted — the host label wins, so a stamped runner heals.
labels_for() { # $1 = rows, $2 = runner id, $3 = on|off
  local rows="$1" id="$2" eng="$3" rid name arch="" extra="" out="" l json=""
  while IFS=$'\t' read -r rid name; do
    [ "$rid" = "$id" ] || continue
    case "$name" in
      "$HOST_LABEL_ARM64"|"$HOST_LABEL_X64") arch="$name" ;;      # the host, not the pool
      "$POOL_LABEL_ARM64"|"$POOL_LABEL_X64") ;;                    # a marker: the host decides which
      *) case "$AUTO_LABELS" in *" $name "*) ;;                    # automatic label this gate owns
         *) case "$name" in
              ''|*[!A-Za-z0-9._-]*) return 1 ;;                      # cannot be emitted safely
              *) extra="$extra $name" ;;
            esac ;;
         esac ;;
    esac
  done <<<"$rows"
  case "$arch" in
    "$HOST_LABEL_ARM64") out="$POOL_LABEL_ARM64" ;;
    "$HOST_LABEL_X64")   out="$POOL_LABEL_X64" ;;
    *) return 1 ;;                                                    # no host arch label: refuse
  esac
  for l in $extra; do out="$out $l"; done
  [ "$eng" = on ] && out="$out $FALLBACK_LABEL"
  for l in $out; do
    if [ -z "$json" ]; then json="\"$l\""; else json="$json,\"$l\""; fi
  done
  printf '{"labels":[%s]}' "$json"
}

# set_labels <on|off> — engage or disengage the fallback label, PER RUNNER.
#
# ⛔ THE ENUMERATION'S FAILURE MUST SURVIVE TO THE RETURN VALUE (agent-infra#1704). The shape
# `for id in $(runner_ids)` DISCARDED the command-substitution status, so a failed `gh api` iterated
# zero ids, left ok=0 fail=0, and `[ "$fail" -eq 0 ]` reported SUCCESS. `main` then wrote the new
# mode to the state file and sent a TRANSITION notification — as if the pool had been relabelled.
# So the read is captured FIRST: a non-zero status is a named failure and NOTHING is relabelled,
# and a payload that is not a list of `<id>TAB<label>` rows (gh's error text, an API error body) is
# refused the same way rather than iterated as a runner id. "The pool has zero runners" is still a
# success — that is a readable zero, not a failed read.
set_labels() { # $1 = on|off
  local eng="$1" id row rid name ok=0 fail=0 rows body bad=0
  if ! rows="$(runner_rows 2>"$GH_ERR")"; then
    rows="$(cat "$GH_ERR" 2>/dev/null)"
    CAPABILITY="$(census_capability "$rows")"
    log "WARNING: runner enumeration FAILED endpoint=repos/$REPO/actions/runners capability=${CAPABILITY} — no labels changed; ${rows:0:300}"
    return 1
  fi
  # SHAPE-CHECK EVERY ROW before anything is PUT: `<digits> TAB <label>`. A row without a tab has no
  # readable runner id (`${row%%$'\t'*}` is then the whole line); a label outside the charset a
  # runner label can hold would emit a broken JSON body. Either is unreadable, not a runner.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    case "$row" in *$'\t'*) ;; *) bad=1 ;; esac
    rid="${row%%$'\t'*}"; name="${row#*$'\t'}"
    case "$rid" in ''|*[!0-9]*) bad=1 ;; esac
    case "$name" in ''|*[!A-Za-z0-9._-]*) bad=1 ;; esac
  done <<<"$rows"
  if [ "$bad" -eq 1 ]; then
    log "WARNING: runner enumeration unreadable — no labels changed; ${rows:0:300}"
    return 1
  fi
  for id in $(managed_ids "$rows"); do
    if ! body="$(labels_for "$rows" "$id" "$eng")"; then
      log "WARNING: runner $id is not classifiable from its own host label — left as-is"
      fail=$((fail+1)); continue
    fi
    # ⛔ log the DERIVED body per runner: this is what makes "which labels did the gate write to
    # which runner" answerable from the log, instead of one pool-wide `body=` line that claimed the
    # same thing about every runner (#2327).
    log "set_labels runner=$id body=$body"
    if printf '%s' "$body" | gh api -X PUT "repos/$REPO/actions/runners/$id/labels" --input - >/dev/null 2>&1; then
      ok=$((ok+1))
    else
      fail=$((fail+1))
    fi
  done
  log "set_labels ok=$ok fail=$fail engagement=$eng"
  [ "$fail" -eq 0 ]
}

fallback_on()  { set_labels on; }
fallback_off() { set_labels off; }

current_mode() {  # github | local | unknown
  # ⛔ PER-PAGE COUNTS, SUMMED. Without --paginate the read stops at the default 30 runners, so a
  # fallback-labelled runner that lands on a later page is invisible and the mode resolves `github`
  # while the fallback is still attached — the gate then leaves the stale fallback in place and
  # reports the wrong mode. `--jq` cannot aggregate across pages (a `length` emits one number PER
  # PAGE, which the numeric guard below would reject rather than sum), and gh 2.97 refuses `--slurp`
  # together with `--jq` (verified: "the `--slurp` option is not supported with `--jq`"), so the
  # per-page counts are summed here instead. The failure signal is unchanged: a failed or
  # non-numeric read still returns 1 (unknown), never a guessed mode.
  local n pages
  pages="$(gh api --paginate "repos/$REPO/actions/runners" \
        --jq "[.runners[] | select([.labels[].name] | index(\"$FALLBACK_LABEL\"))] | length" 2>"$GH_ERR")" || {
    # ⛔ NAME THE MISSING CAPABILITY, NOT JUST OUR SYMPTOM (agent-infra#2931 indicator 2). `gh api
    # failed: …` left the reader unable to tell a scope problem from an outage, and the token is
    # NEVER widened to fix it — the caller narrows the claim instead (see the header).
    local mode_err; mode_err="$(cat "$GH_ERR" 2>/dev/null)"
    log "gh api failed endpoint=repos/$REPO/actions/runners capability=$(census_capability "$mode_err"): ${mode_err:0:300}"
    return 1
  }
  # ⛔ SHAPE-CHECK, AND REQUIRE A DIGIT (review B2-1). `[:space:]` alone admits a read that contains
  # NO number at all (a blank/whitespace body from a proxy or a gh change) — the `awk` reduction then
  # sums nothing to 0 and the mode resolves `github` at exit 0, i.e. a verdict AND a recorded
  # transition from a read with no value in it. The line below it promises the opposite ("a failed or
  # non-numeric read still returns 1 (unknown), never a guessed mode"). The `awk` SUBSTITUTION's
  # status is captured too: a broken/absent `awk` left `${n:-0}` to read as `0`.
  case "$pages" in ''|*[!0-9[:space:]]*) log "gh api returned non-numeric: ${pages:0:300}"; return 1 ;; esac
  case "$pages" in *[0-9]*) : ;; *) log "gh api returned NO COUNT: ${pages:0:300}"; return 1 ;; esac
  n="$(printf '%s\n' "$pages" | awk '{s+=$1} END{printf "%d", s+0}')" || { log "runner-count reduction FAILED (awk)"; return 1; }
  case "$n" in ''|*[!0-9]*) log "runner-count reduction unreadable: '${n}'"; return 1 ;; esac
  if [ "$n" -gt 0 ]; then echo local; else echo github; fi
}

# mode_from_jobs — the READABLE SUBSTITUTE for the MODE question (agent-infra#2897 option B).
# ⛔ WHAT IT CANNOT DO, stated where it is used: it answers "which pool is serving", NOT "how much
# capacity is online". `runner_group_name` is populated from `actions:read` (measured 200 with the
# fleet token) where the runner INVENTORY is 403, so an inventory-blind box can still SAY which mode
# it is in — but it cannot count idle/busy/offline runners, so the capacity verdict stays
# `unknown` and the pass stays refused. Narrow the claim; do not widen the token.
# GitHub's hosted group is named exactly `GitHub Actions` — WITH A SPACE — so the group list is joined
# on `|` and split on IFS: a space-separated list splits that name into `GitHub` + `Actions` and reads
# every hosted group as "not hosted". (Caught by the suite's github arm, which is why that arm exists.)
# ANY other group name is not hosted. A job with no group yet (`-`, `""`) is ambiguous and is skipped
# rather than guessed.
# BOUND: at most MODE_INFER_RUNS in-progress runs are inspected (one jobs read each). An IDLE repo
# has no in-progress run, which is the hole this substitute cannot fill — it returns 1 (unknown).
mode_from_jobs() {
  local ids id groups out="" g IFS_SAVE
  ids="$(gh api "repos/$REPO/actions/runs?per_page=20" \
        --jq '[.workflow_runs[]|select(.status=="in_progress")|.id]|.[0:'"$MODE_INFER_RUNS"']|map(tostring)|join(" ")' 2>/dev/null)" || return 1
  [ -n "${ids// /}" ] || return 1          # nothing executing ⇒ nothing to infer from
  for id in $ids; do
    case "$id" in ''|*[!0-9]*) return 1 ;; esac
    groups="$(gh api "repos/$REPO/actions/runs/$id/jobs" \
          --jq '[.jobs[]|select(.status=="in_progress")|(.runner_group_name // "-")]|join("|")' 2>/dev/null)" || return 1
    out="$out|$groups"
  done
  IFS_SAVE="$IFS"; IFS='|'
  for g in $out; do
    case "$g" in 'GitHub Actions'|'-'|'') ;; *) IFS="$IFS_SAVE"; echo local; return 0 ;; esac
  done
  IFS="$IFS_SAVE"
  case "|$out|" in *"|GitHub Actions|"*) echo github; return 0 ;; esac
  return 1
}

# ── notify ──────────────────────────────────────────────────────────────────────
# NO external service (Slack is deprecated — it was a maintenance burden). Two
# transports, both already in the fleet, neither needs a credential we do not have:
#   1. the orchestrator inbox  — durable, append-only, read by the fleet (always works)
#   2. the cmux orchestrator lane — immediate, where the owner actually is (best-effort)
ORCH_WS="${CI_GATE_ORCH_WS-C2C97E96-0CBC-4DFE-BC91-FEF44F09B5BD}"   # ORCHESTRATOR (never dispatch here)
# ⛔ `${VAR-…}`, NOT `${VAR:-…}` (review E1): with `:-` an explicitly EMPTY value is replaced by the
# default, so `CI_GATE_ORCH_WS=""` — the obvious way to switch the cmux leg off, and what the test
# suite sets to keep the leg out of the picture — actually SENT messages to the live orchestrator
# lane. Empty now means disabled.

notify() { # $1 = text
  local text="$1"
  # 1. durable local inbox — no dependencies, cannot fail silently.
  printf '[%s] [ci-runner-gate] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$text" \
    >> "$STATE_DIR/orchestrator-inbox.log"
  log "notified -> orchestrator-inbox.log"

  # 2. cmux — best effort. A message that is not delivered must NOT fail the gate.
  #    AGENTS.md: never a bare `cmux send`; confirm the artifact, and a queued
  #    (delivered-but-not-consumed) message still counts as delivered.
  if command -v cmux >/dev/null 2>&1 && [ -n "${ORCH_WS:-}" ]; then
    if cmux agent message "$ORCH_WS" --from ci-runner-gate "$text" >/dev/null 2>&1; then
      log "notified -> cmux orchestrator lane"
    else
      log "cmux notify unavailable (inbox record stands)"
    fi
  fi
  return 0
}

# alarm_blind — THE GATE MUST SAY SO ON EVERY CYCLE IT CANNOT MEASURE (agent-infra#2897).
# ⛔ The defect was not the fail-closed exit; it was that the failure never left the log. `launchctl
# list` showed the job at last exit status 2 for as long as the state existed, and nobody knew,
# because a gate that cannot measure looked identical to a gate with nothing to say. So a blind pass
# ALARMS: through `notify()` (the durable inbox + the orchestrator lane), at most once per
# BLIND_ALARM_EVERY_S — repeating, because a one-shot alarm on a condition that lasts hours is the
# same silence one step later. The stamp file means a restarting job cannot spam the lane.
alarm_blind() { # $1 = the signature (what could not be measured, and why)
  local sig="$1" now last=0 stamp="$STATE_DIR/ci-runner-gate.blind"
  now="$(date -u +%s)"
  if [ -f "$stamp" ]; then
    last="$(sed -n 1p "$stamp" 2>/dev/null)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
  fi
  if [ "$last" -gt 0 ] && [ "$((now - last))" -lt "$BLIND_ALARM_EVERY_S" ]; then
    log "BLIND alarm SUPPRESSED (sent $((now - last))s ago, floor ${BLIND_ALARM_EVERY_S}s) — ${sig}"
    return 0
  fi
  printf '%s\n' "$now" > "$stamp"
  notify ":warning: CI runner gate is BLIND — ${sig}. It is refusing to certify capacity (exit 2, changing nothing). Repo: ${REPO}."
  log "BLIND alarm SENT (at most one per ${BLIND_ALARM_EVERY_S}s while the condition lasts)"
}

# ── main ────────────────────────────────────────────────────────────────────────
# ⛔ THE MODE READ HAS A SUBSTITUTE; THE CAPACITY READ DOES NOT (agent-infra#2897). `current_mode()`
# needs the admin-only inventory. When that 403s, the gate does NOT fall back to `unknown` and stop
# talking — it reads WHO IS SERVING from the jobs endpoint (`actions:read`, which the token has) and
# labels the answer as a NARROWED claim (`source=jobs-inference`), so an inventory-blind box still
# reports a real mode instead of `cannot read runner labels` forever. The capacity question is left
# UNKNOWN on purpose: no substitute can see per-runner idle/busy, and a guessed capacity is the
# defect this change exists to remove.
mode=""
if mode="$(current_mode)"; then
  MODE_SOURCE="runners"
else
  if mode="$(mode_from_jobs)"; then
    MODE_SOURCE="jobs-inference"
    log "runner inventory UNREADABLE — mode INFERRED from recent jobs: mode=$mode source=jobs-inference (narrowed claim: the inventory was not read, so capacity is not claimed from it)"
  else
    mode="unknown"; MODE_SOURCE="none"
    log "runner inventory UNREADABLE and no in-progress job to infer from — mode=unknown source=none"
  fi
fi

if [ "$STATUS_ONLY" = 1 ]; then
  # The census is the three states, PER RUNNER, and `--status` reports them — but a manual read verb
  # does not ALARM (the scheduled pass does). Exit 2 whenever either answer required a substitute or
  # could not be read: a narrowed claim is never exit 0.
  status_rc=0
  [ "$MODE_SOURCE" = runners ] || status_rc=2
  # ⛔ "THE READ FAILED" AND "THE READ ANSWERED WITH A BODY THIS PASS CANNOT CLASSIFY" ARE TWO
  # DIFFERENT FAILURES, and collapsing them threw away the body (#3002 review P2). The old `&&` sent
  # BOTH into a branch that then read `$GH_ERR` — which the SUCCESSFUL call had just truncated to empty
  # — so the operator's diagnostic verb reported `capability=runner_inventory:empty-response` with no
  # body, inventing a cause for a read that answered. `evaluate` gets this right; this surface did not.
  if census_rows="$(runner_census)"; then
    if ! census_classify "$census_rows"; then
      CAPABILITY="$(census_capability "$census_rows")"
      # ⛔ THE EIGHT CENSUS KEYS ARE CARRIED AS `unmeasured`, NOT DROPPED (#3002 review P2). Both
      # unreadable branches used to set `CENSUS_KV=""`, so this surface printed
      # `capacity=unknown  capability=…` — a key set NO other writer emits, which a parser reads as
      # "this writer does not report those" instead of "they were not measured". `CENSUS_KV_UNMEASURED`
      # exists for exactly this and the success/blind writers already use it.
      CENSUS_VERDICT=unknown; CENSUS_KV="$CENSUS_KV_UNMEASURED"; CENSUS_DETAIL="(unread)"
      status_rc=2
      log "runner census UNREADABLE endpoint=$RUNNER_LIST_PATH capability=${CAPABILITY}; body said: ${census_rows:0:300}"
    fi
  else
    census_rows="$(cat "$GH_ERR" 2>/dev/null)"
    CAPABILITY="$(census_capability "$census_rows")"
    CENSUS_VERDICT=unknown; CENSUS_KV="$CENSUS_KV_UNMEASURED"; CENSUS_DETAIL="(unread)"
    status_rc=2
    log "runner census FAILED endpoint=$RUNNER_LIST_PATH capability=${CAPABILITY}; gh said: ${census_rows:0:300}"
  fi
  # `unmeasured`, not `measured`: this verb reports the STATES and computes no verdict, and inventing a
  # word outside the documented vocabulary made the two schedulable surfaces disagree about `capacity=`.
  echo "mode=$mode repo=$REPO source=$MODE_SOURCE capacity=${CENSUS_VERDICT:-unmeasured} ${CENSUS_KV} capability=${CAPABILITY:-none} detail=\"${CENSUS_DETAIL}\""
  exit "$status_rc"
fi

evaluate; healthy=$?          # 0 = github, 1 = unhealthy, 2 = cannot measure
if [ "$healthy" = 2 ]; then
  # ⛔ A BLIND PASS ALARMS (#2897): the fail-closed exit is right and it is also INVISIBLE, so the
  # one thing that must not happen again is a gate that spends a morning at exit 2 while the fleet
  # reads the absence of a complaint as health.
  # ⛔ SCOPED TO THE CAPACITY READ, deliberately: every other could-not-measure path in this script
  # already refuses correctly and must keep writing no inbox record and sending no notification
  # (the suite pins that, e.g. an unreadable queue count). "BLIND" means *cannot see capacity*, which
  # is the condition nobody could see; it is not a synonym for "could not measure something".
  # ⛔ THE MEASURED FIGURES COME FROM THE ABSORPTION GLOBALS, NOT FROM `queued` (#3002 review P1).
  # `queued` is declared `local` INSIDE `evaluate`, so out here it is unset and `${queued:-unmeasured}`
  # structurally ALWAYS took the default: the alarm and the verdict file — the two artifacts this pass
  # exists to produce — could not tell a 0-deep queue from an 80-deep one, and the scheduler key §5
  # advertises was a constant on exactly the path that needs it. `ABSORPTION_*` are globals set by the
  # probe, and they are what the success path already reads, so both paths now speak from one source.
  blind_queued="${ABSORPTION_QUEUED:-unmeasured}"
  blind_in_progress="${ABSORPTION_IN_PROGRESS:-unmeasured}"
  blind_oldest="${ABSORPTION_OLDEST_S:-unmeasured}"
  if [ "$CENSUS_BLIND" = 1 ]; then
    if [ "$DRY" = 1 ]; then
      # ⛔ A READ VERB CHANGES NOTHING (#3002 review P1): `--dry-run` is documented as "evaluate and
      # report, change nothing", and it used to send a real alarm, create the stamp file and overwrite
      # the verdict file — because `evaluate` runs before the DRY gate below. The consequence was worse
      # than untidy: the next SCHEDULED pass then logged `BLIND alarm SUPPRESSED (sent 1s ago)`, so an
      # operator triaging a blind box silenced the alarm for up to BLIND_ALARM_EVERY_S — the #2897
      # silence, reintroduced by a human poking the gate. `--status`, the sibling read verb, already
      # exits before this branch; the two now agree.
      log "BLIND alarm SUPPRESSED: --dry-run reports and changes nothing (capacity=unknown capability=${CAPABILITY:-runner_inventory:unreadable} queued=$blind_queued) — a read verb must not consume the ${BLIND_ALARM_EVERY_S}s alarm window the scheduled pass needs"
    else
      alarm_blind "capacity=unknown capability=${CAPABILITY:-runner_inventory:unreadable} endpoint=$RUNNER_LIST_PATH queued=$blind_queued in_progress=$blind_in_progress oldest_queued_s=$blind_oldest (see ${LOG_FILE})"
      # ⛔ FIELD PARITY WITH `write_verdict` (#3002 review P1): the unknown verdict used to carry a
      # DIFFERENT key set than the success verdict, so a strict parser saw MISSING keys rather than an
      # explicit `unmeasured`. Same keys, same order, in both writers — INCLUDING the eight census
      # keys, which this writer used to omit outright (#3002 review P2, measured: the blind line
      # carried `verdict mode mode_source capacity queued in_progress oldest_queued_s capability
      # reason` while the success line also carried `runners online_idle online_busy offline
      # demanding_idle demanding_busy label_ambiguity demand`). A census that was not read is
      # `unmeasured` — recorded, never assumed, and never absent.
      printf 'verdict=unknown mode=%s mode_source=%s capacity=unknown %s queued=%s in_progress=%s oldest_queued_s=%s capability=%s reason=cannot measure — capacity was not read\n' \
        "$mode" "$MODE_SOURCE" "$CENSUS_KV_UNMEASURED" "$blind_queued" "$blind_in_progress" "$blind_oldest" "${CAPABILITY:-runner_inventory:unreadable}" \
        > "$VERDICT_FILE" 2>/dev/null || true
    fi
  else
    # ⛔ A COULD-NOT-MEASURE PASS MUST NOT LEAVE THE PREVIOUS PASS'S ANSWER STANDING (#3002 review P2).
    # Only the CENSUS_BLIND branch wrote `verdict=unknown`; the script's other could-not-measure exits
    # (a failed queue probe, an unreadable queued/in_progress/age/threshold/floor operand, a saturated
    # page) wrote nothing and deleted nothing, so the file went on saying `verdict=github … queued=5
    # in_progress=2` after every pass since had failed to measure. This file's own contract is "the
    # CURRENT verdict, not a log", so a consumer could not tell a current green from a stale one.
    # The line is written on the same shape as the other two writers (same keys, same order), and the
    # capacity fields are the ones this pass actually reached — `CENSUS_KV_UNMEASURED` where the census
    # never ran, `unmeasured` where the probe never answered. `--dry-run` still changes nothing.
    if [ "$DRY" = 1 ]; then
      log "verdict NOT updated: --dry-run reports and changes nothing (the previous verdict file is left untouched; this pass measured nothing it could stand behind)"
    else
      printf 'verdict=unknown mode=%s mode_source=%s capacity=%s %s queued=%s in_progress=%s oldest_queued_s=%s capability=%s reason=cannot measure — a leg could not be read, so this pass changed nothing (the FAIL-CLOSED line in the log names which)\n' \
        "$mode" "$MODE_SOURCE" "${CENSUS_VERDICT:-unknown}" "${CENSUS_KV:-$CENSUS_KV_UNMEASURED}" \
        "$blind_queued" "$blind_in_progress" "$blind_oldest" "${CAPABILITY:-none}" \
        > "$VERDICT_FILE" 2>/dev/null || true
    fi
  fi
  log "cannot measure — FAIL-CLOSED, changing nothing (leaving mode=$mode)"
  exit 2
fi

if [ "$healthy" = 0 ]; then
  want="github"
  # ⛔ THE ABSORPTION FIGURES ARE QUOTED, THE CLAIM IS NOT (review P1). In fallback mode the
  # `in_progress` count includes the pool's own runs, so the reading cannot certify that HOSTED is
  # absorbing — the pre-existing legs are what decided, and the reason says so instead of borrowing
  # the absorption leg's authority for a verdict it did not reach.
  if [ "$mode" = github ]; then
    absorption="queue absorbing: oldest_queued_s=$ABSORPTION_OLDEST_S in_progress=$ABSORPTION_IN_PROGRESS"
  else
    absorption="absorption NOT attributable in mode=$mode (in_progress includes pool runs): oldest_queued_s=$ABSORPTION_OLDEST_S in_progress=$ABSORPTION_IN_PROGRESS"
  fi
  # ⛔ THE CAPACITY READING IS QUOTED IN EVERY VERDICT, AND IT CAN VETO THE WORD "healthy" (#2904).
  # The legs above can pass while the pool is at 2 of 8 with 6 registrations OFFLINE (and the read
  # cannot say whether any of them ever connected — see `offline` above),
  # and calling that "healthy" is what sent a human out to rediscover the shortage by hand. Where
  # capacity is IDLE while work waits — or where no registration is online at all — the verdict still
  # routes to GitHub (nothing a relabel could fix, and in mode=github the pool is stripped by design)
  # but it must NOT be certified, and the reason says so instead.
  case "$CENSUS_VERDICT" in
    idle-unused|all-offline|unknown)
      reason="GitHub-hosted legs pass BUT CAPACITY NOT CERTIFIED (capacity=$CENSUS_VERDICT: $CENSUS_DETAIL; $absorption)" ;;
    *)
      reason="GitHub Actions healthy (component operational, no Actions incident, queue < $QUEUE_THRESHOLD, $absorption; capacity=$CENSUS_VERDICT: $CENSUS_DETAIL)" ;;
  esac
else
  want="local"
  reason="GitHub-hosted UNHEALTHY — ${UNHEALTHY_LEG:-unknown leg}; routed CI to the local pool (capacity=$CENSUS_VERDICT: $CENSUS_DETAIL)"
fi

# ⛔ THE VERDICT FILE IS WHAT MAKES THE INSTRUMENT READABLE BY SOMETHING OTHER THAN A HUMAN (#2931):
# one `key=value` line per pass, so a scheduler or a fleet report can branch on `capacity=` and on the
# per-runner counts instead of parsing prose. `ci-runner-gate.state` keeps its single-word shape (its
# readers compare it verbatim), and this file is OVERWRITTEN — it is the CURRENT verdict, not a log;
# the log is the history.
write_verdict() { # $1 = the verdict word (want); all other fields come from the run's globals
  printf 'verdict=%s mode=%s mode_source=%s capacity=%s %s queued=%s in_progress=%s oldest_queued_s=%s capability=%s reason=%s\n' \
    "$1" "$mode" "$MODE_SOURCE" "$CENSUS_VERDICT" "$CENSUS_KV" \
    "${ABSORPTION_QUEUED:-unmeasured}" "${ABSORPTION_IN_PROGRESS:-unmeasured}" "${ABSORPTION_OLDEST_S:-unmeasured}" \
    "${CAPABILITY:-none}" "$reason" > "$VERDICT_FILE" 2>/dev/null || true
}

prev="$(cat "$STATE_FILE" 2>/dev/null || echo unknown)"

# ⛔ LOG THE REASON ON THE PATH THAT ACTS, not only in --dry-run (#2904). The reason names the LEG
# that decided — "not absorbing" vs "queue over threshold" — and without it the durable log records
# what the gate did while the reader has to reconstruct why. The transition notification carries the
# same text; this is the copy that survives when the notification's transport does not.
log "reason=$reason"

if [ "$DRY" = 1 ]; then
  echo "dry-run: mode=$mode want=$want prev=$prev reason=$reason"
  echo "dry-run: capacity=${CENSUS_VERDICT} ${CENSUS_KV} mode_source=${MODE_SOURCE}"
  exit 0
fi

# The current verdict is recorded BEFORE the action, so a relabel that fails still leaves the
# measurement it acted on visible to whoever reads the state next.
write_verdict "$want"

# ⛔ RE-CONVERGE UNTIL THE TRANSITION IS RECORDED (review B2-3). `mode != want` is a cheap
# approximation of "the pool matches the desired labels", and it is not equivalent: a PARTIAL relabel
# (one PUT failed) leaves one runner labelled, so the next pass reads `mode == want` and would skip
# the relabel entirely — recording the transition while the un-relabelled runner is never retried
# and never mentioned. The state file records convergence, so its absence is the trigger to converge:
# `prev != want` re-applies the (idempotent) labels until the transition is actually recorded.
if [ "$mode" != "$want" ] || [ "$prev" != "$want" ]; then
  relabel_ok=1
  if [ "$want" = local ]; then fallback_on || relabel_ok=0; else fallback_off || relabel_ok=0; fi
  # ⛔ DO NOT RECORD A TRANSITION THAT DID NOT HAPPEN (agent-infra#1704). The old code logged a
  # WARNING and CONTINUED, so a failed enumeration still wrote the new mode to $STATE_FILE and sent
  # the transition notification — a state file and an alert claiming the pool had been relabelled.
  # Stop here instead: mode not advanced, nothing notified, fail-closed.
  if [ "$relabel_ok" -ne 1 ]; then
    log "relabel FAILED — mode NOT advanced (mode=$mode want=$want prev=$prev), state file unchanged"
    exit 2
  fi
fi

# Notify only on TRANSITION into a new desired mode (dedupe by state file).
if [ "$prev" != "$want" ]; then
  notify ":rotating_light: CI runner gate: mode *${mode}* -> *${want}*. ${reason}. Repo: ${REPO}."
  printf '%s\n' "$want" > "$STATE_FILE"
  log "TRANSITION $prev -> $want"
else
  log "no change (mode=$mode want=$want)"
fi
exit 0
