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
# USAGE
#   ci_runner_gate.sh            # evaluate + act + notify
#   ci_runner_gate.sh --dry-run  # evaluate and report, change nothing
#   ci_runner_gate.sh --status   # print current mode, exit 0 (2 when the pool read fails)
#
# EXIT: 0 ok · 1 usage · 2 could-not-measure / could-not-act (fail-closed: changes nothing)
set -uo pipefail

REPO="${CI_GATE_REPO:-daniel-ospina/tortoise}"
STATE_DIR="${CI_GATE_STATE_DIR:-$HOME/.pi/agent/state}"
STATE_FILE="$STATE_DIR/ci-runner-gate.state"
LOG_FILE="$STATE_DIR/ci-runner-gate.log"
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
      --jq '[.total_count, (([.workflow_runs[].created_at]|min)//"")]|@tsv' 2>/dev/null)" \
    || { log "queue probe FAILED (gh api)"; return 2; }
  queued="${queue_row%%$'\t'*}"; oldest_created="${queue_row#*$'\t'}"
  # ⛔ THE SECOND READ IS THE ABSORPTION FIELD, and it is the ONLY input the throughput leg adds
  # (#2904). `in_progress` is the count of runs GitHub is currently executing for this repo; in
  # mode=github that is hosted executing, because the pool does not advertise `ubuntu-latest` and no
  # workflow asks for a `self-hosted` label. One extra API call per scheduled pass. gh's stderr is
  # captured so a failed read CARRIES ITS REASON (the #1704 enumeration lesson: a failure reported
  # without what the API said is a failure nobody can act on).
  in_progress_raw="$(gh api "repos/$REPO/actions/runs?status=in_progress&per_page=1" --jq '.total_count' 2>&1)" \
    || { log "in-progress probe FAILED (gh api) — FAIL-CLOSED, changing nothing; ${in_progress_raw:0:300}"; return 2; }
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
  ABSORPTION_OLDEST_S="$oldest_queued_s"; ABSORPTION_IN_PROGRESS="$in_progress"

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
  if ! rows="$(runner_rows 2>&1)"; then
    log "WARNING: runner enumeration FAILED — no labels changed; ${rows:0:300}"
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
        --jq "[.runners[] | select([.labels[].name] | index(\"$FALLBACK_LABEL\"))] | length" 2>&1)" || { log "gh api failed: ${pages:0:300}"; return 1; }
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

# ── main ────────────────────────────────────────────────────────────────────────
mode="$(current_mode)" || { log "cannot read runner labels"; exit 2; }
if [ "$STATUS_ONLY" = 1 ]; then echo "mode=$mode repo=$REPO"; exit 0; fi

evaluate; healthy=$?          # 0 = github, 1 = unhealthy, 2 = cannot measure
if [ "$healthy" = 2 ]; then
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
  reason="GitHub Actions healthy (component operational, no Actions incident, queue < $QUEUE_THRESHOLD, $absorption)"
else
  want="local"
  reason="GitHub-hosted UNHEALTHY — ${UNHEALTHY_LEG:-unknown leg}; routed CI to the local pool"
fi

prev="$(cat "$STATE_FILE" 2>/dev/null || echo unknown)"

# ⛔ LOG THE REASON ON THE PATH THAT ACTS, not only in --dry-run (#2904). The reason names the LEG
# that decided — "not absorbing" vs "queue over threshold" — and without it the durable log records
# what the gate did while the reader has to reconstruct why. The transition notification carries the
# same text; this is the copy that survives when the notification's transport does not.
log "reason=$reason"

if [ "$DRY" = 1 ]; then
  echo "dry-run: mode=$mode want=$want prev=$prev reason=$reason"
  exit 0
fi

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
