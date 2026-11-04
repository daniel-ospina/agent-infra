#!/usr/bin/env bash
# ci_runner_starvation.sh — detect and heal a STARVED CI runner pool (agent-infra#2875).
#
# WHY THIS EXISTS. Measured 2026-10-27 on tortoise: 11 registered · 10 online · busy=0 · 46 queued
# runs, every runner advertising `self-hosted,Linux,X64,self-hosted-x64` while every workflow asks
# `runs-on: ubuntu-latest`. No job could ever be assigned, nothing errored, and the merge rail read
# as merely "slow". The datum that settles it — queued>0 AND busy==0 — is one API call nobody made,
# because a starved queue and a busy queue look identical in every dashboard.
#
# THE INVARIANT. `queued_runs > 0 AND busy_runners == 0` ⇒ STARVED (a supply/assignment failure),
# not demand. Persistent across N consecutive samples (~2 min apart) ⇒ heal.
#
# THE THREE STATES STARVATION IS NOT, AND MUST SAY SO:
#   * DEMAND   — queued>0 AND busy>0 (the queue is deep; the answer is capacity, not repair);
#   * IDLE     — queued==0 (nothing to do);
#   * OFFLINE  — online==0 (a different signal with its own owner).
# A detector that fires on demand gets muted, and a muted detector is the failure this was built to
# catch — so every sample prints its classification by name.
#
# THE HEAL LADDER (each step logged with runner + before/after, each stopped on success):
#   1. Assert the canonical label set on every ONLINE runner — ADDITIVE POST …/labels (never a
#      replace: a replace is how the label goes missing), then RE-READ and verify.
#   2. Restart the runner service ONE at a time on this Linux cell, waiting for busy>0 between
#      attempts. ⛔ NEVER restart a runner whose busy is true — that kills a job mid-flight.
#   3. Reconcile registrations: delete ghosts (an offline GitHub registration with no local
#      instance dir and no systemd unit), then re-register/restart via `ci_runner_pool.sh reconcile`
#      (fresh token, canonical labels).
#   4. FILE AND SHOUT: post to the tracker (once) and fail visible. A healer that cannot heal must
#      not go quiet — silence is the failure mode being fixed.
#
# GUARDS (a naive healer becomes a new incident):
#   * never raises CORES_PER_RUNNER / adds capacity as a heal step (starvation is not sizing);
#   * never cancels queued runs (that removes DEMAND; the invariant is about SUPPLY);
#   * never touches a busy runner (step 2);
#   * no-op when healthy (a non-starved sample only writes the state file);
#   * cannot self-heal through the thing that is broken: it reads GitHub directly, restarts systemd
#     units directly, and only delegates re-registration to `ci_runner_pool.sh`; it refuses to run
#     on a Mac (the runners live on the Linux cells).
#
# USAGE
#   ci_runner_starvation.sh            # the scheduled pass: one sample, persist, heal if starved
#   ci_runner_starvation.sh probe      # one sample, print the classification, change nothing
#   ci_runner_starvation.sh --help
#
# ENV (knobs; tests override every seam):
#   STARVE_REPO             owner/repo (default daniel-ospina/tortoise)
#   STARVE_GH               the gh to call (default gh)
#   STARVE_STATE_DIR        state/log dir (default $HOME/.pi/agent/state)
#   STARVE_SAMPLES          consecutive starved samples before healing (default 3)
#   STARVE_SYSTEMCTL        systemctl (default systemctl)
#   STARVE_RUNNER_UNIT_PREFIX  systemd unit prefix (default actions.runner)
#   STARVE_RUNNER_ROOT      dir CONTAINING the local instance dirs (default /opt, where
#                           /opt/gh-runner-* live)
#   STARVE_POOL             ci_runner_pool.sh for step 3 (default beside this script)
#   STARVE_WAIT_BUSY_S      seconds to wait for busy>0 after a restart (default 45)
#   STARVE_WAIT_BUSY_POLL_S poll interval (default 5)
#   STARVE_PLATFORM         override `uname -s` (tests)
#
# EXIT: 0 ok (healthy, or starved below threshold, or healed) · 1 usage · 2 cannot-measure
#       (fail-closed: changes nothing) · 4 starved and NOT healed (filed + visible)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABELS_LIB="${CI_RUNNER_LABELS_LIB:-$SELF_DIR/lib/ci-runner-labels.sh}"
# shellcheck source=lib/ci-runner-labels.sh
. "$LABELS_LIB" || { printf 'cannot-measure why=labels-lib-absent path=%s\n' "$LABELS_LIB" >&2; exit 2; }

STARVE_REPO="${STARVE_REPO:-daniel-ospina/tortoise}"
STARVE_GH="${STARVE_GH:-gh}"
STARVE_STATE_DIR="${STARVE_STATE_DIR:-$HOME/.pi/agent/state}"
STARVE_SAMPLES="${STARVE_SAMPLES:-3}"
STARVE_SYSTEMCTL="${STARVE_SYSTEMCTL:-systemctl}"
STARVE_RUNNER_UNIT_PREFIX="${STARVE_RUNNER_UNIT_PREFIX:-actions.runner}"
STARVE_RUNNER_ROOT="${STARVE_RUNNER_ROOT:-/opt}"
STARVE_POOL="${STARVE_POOL:-$SELF_DIR/ci_runner_pool.sh}"
STARVE_WAIT_BUSY_S="${STARVE_WAIT_BUSY_S:-45}"
STARVE_WAIT_BUSY_POLL_S="${STARVE_WAIT_BUSY_POLL_S:-5}"
STARVE_PLATFORM="${STARVE_PLATFORM:-$(uname -s 2>/dev/null || printf unknown)}"

STATE_FILE="$STARVE_STATE_DIR/ci-runner-starvation.state"
FILED_FILE="$STARVE_STATE_DIR/ci-runner-starvation.filed"
LOG_FILE="$STARVE_STATE_DIR/ci-runner-starvation.log"

# globals filled by probe()
QUEUED=""; BUSY=""; ONLINE=""; OFFLINE=""; PROBE_STATE=""

say() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }
log() { mkdir -p "$STARVE_STATE_DIR" 2>/dev/null || true; printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_FILE" 2>/dev/null || true; }

is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0|0*) return 1 ;; *) [ "${#1}" -le 9 ] || return 1 ;; esac; return 0; }

usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

# ── GitHub reads ───────────────────────────────────────────────────────────────────────────────
# ⛔ --paginate is REQUIRED: `gh api` returns at most 30 runners per page, so a pool larger than that
# would be read in part and the busy/online counts would describe a fraction of the pool as if it
# were all of it (the same defect ci_runner_gate.sh records).
gh_queued() { "$STARVE_GH" api "repos/$STARVE_REPO/actions/runs?status=queued&per_page=1" --jq '.total_count' 2>/dev/null; }
gh_runners() {
  "$STARVE_GH" api --paginate "repos/$STARVE_REPO/actions/runners" \
    --jq '.runners[] | [.id, .name, .status, (.busy|tostring), ([.labels[].name] | join(","))] | @tsv' 2>/dev/null
}

# ── probe: one sample, one classification ──────────────────────────────────────────────────────
# Sets QUEUED/BUSY/ONLINE/OFFLINE/PROBE_STATE. rc 0 measured · 2 cannot-measure (fail-closed).
probe() {
  local queued rows id name status busy labels bad=0
  QUEUED=""; BUSY=""; ONLINE=""; OFFLINE=""; PROBE_STATE=""
  if ! queued="$(gh_queued)"; then
    err "cannot-measure why=queue-unreadable repo=$STARVE_REPO"; return 2
  fi
  # ⛔ SHAPE-CHECK EVERY COUNT. `[ "$queued" -gt 0 ]` over a null/empty/errbody value ERRORS, and an
  # errored test is FALSE under `set -uo pipefail` (no -e) — so an unreadable count would classify as
  # IDLE, i.e. HEALTHY, and the detector would never fire on the exact failure it exists to catch.
  case "$queued" in ''|*[!0-9]*) err "cannot-measure why=queue-unreadable value=${queued:0:40}"; return 2 ;; esac
  if ! rows="$(gh_runners)"; then
    err "cannot-measure why=runners-unreadable repo=$STARVE_REPO"; return 2
  fi
  BUSY=0; ONLINE=0; OFFLINE=0
  while IFS=$'\t' read -r id name status busy labels; do
    [ -n "$id" ] || continue
    case "$id" in ''|*[!0-9]*) bad=1 ;; esac
    case "$status" in online|offline) ;; *) bad=1 ;; esac
    case "$busy" in true|false) ;; *) bad=1 ;; esac
    case "$status" in
      online) ONLINE=$((ONLINE + 1)); [ "$busy" = true ] && BUSY=$((BUSY + 1)) ;;
      offline) OFFLINE=$((OFFLINE + 1)) ;;
    esac
  done <<<"$rows"
  if [ "$bad" = 1 ]; then
    err "cannot-measure why=runners-unreadable repo=$STARVE_REPO (a runner row was not <id>\\t<name>\\t<online|offline>\\t<true|false>\\t<labels>)"; return 2
  fi
  QUEUED="$queued"
  # Order matters: OFFLINE is its own signal (own owner) even when the queue is empty; IDLE is an
  # empty queue; DEMAND is a busy pool; what is left is the one state this detector exists to name.
  if [ "$ONLINE" -eq 0 ]; then PROBE_STATE=OFFLINE
  elif [ "$QUEUED" -eq 0 ]; then PROBE_STATE=IDLE
  elif [ "$BUSY" -gt 0 ]; then PROBE_STATE=DEMAND
  else PROBE_STATE=STARVED
  fi
  return 0
}

# ── label assertion (step 1) ────────────────────────────────────────────────────────────────────
labels_json() { # $1 = space-separated labels -> a JSON labels body
  local l json=""
  for l in $1; do
    [ -z "$json" ] && json="\"$l\"" || json="$json,\"$l\""
  done
  printf '{"labels":[%s]}' "$json"
}

runner_labels_for_id() { # $1 = id -> comma-joined labels; rc 1 when absent/unreadable
  local rows id name status busy labels
  rows="$(gh_runners)" || return 1
  while IFS=$'\t' read -r id name status busy labels; do
    [ "$id" = "$1" ] && { printf '%s' "$labels"; return 0; }
  done <<<"$rows"
  return 1
}

step1_assert_labels() {
  local rows id name status busy labels missing before after ok
  rows="$(gh_runners)" || { err "step1: runner read failed — nothing asserted"; return 1; }
  while IFS=$'\t' read -r id name status busy labels; do
    [ -n "$id" ] || continue
    [ "$status" = online ] || continue
    missing="$(ci_runner_missing_canonical_labels "${labels//,/ }")"
    [ -n "$missing" ] || continue
    before="$labels"
    say "step1: runner=$id name=$name before=[$labels] adding=[$missing]"
    if printf '%s' "$(labels_json "$missing")" | "$STARVE_GH" api -X POST "repos/$STARVE_REPO/actions/runners/$id/labels" --input - >/dev/null 2>&1; then
      # ⛔ RE-READ AND VERIFY — a write that "succeeded" is not a label the runner advertises.
      if after="$(runner_labels_for_id "$id")" && ci_runner_labels_have_canonical "${after//,/ }"; then
        say "step1: runner=$id name=$name after=[$after] verified"
      else
        err "step1: runner=$id name=$name after=[${after:-unreadable}] NOT verified — continuing"
      fi
    else
      err "step1: runner=$id name=$name POST failed — continuing"
    fi
  done <<<"$rows"
  return 0
}

# ── service restart (step 2) ────────────────────────────────────────────────────────────────────
busy_count() {
  local rows id name status busy labels n=0
  rows="$(gh_runners)" || { printf '%s' '-1'; return 0; }
  while IFS=$'\t' read -r id name status busy labels; do
    [ "$busy" = true ] && n=$((n + 1))
  done <<<"$rows"
  printf '%s' "$n"
}

wait_for_busy() { # rc 0 when busy>0 appears within the bound
  local waited=0 n
  while [ "$waited" -lt "$STARVE_WAIT_BUSY_S" ]; do
    n="$(busy_count)"
    [ "$n" = "-1" ] && { err "step2: cannot re-read busy count — stop waiting"; return 1; }
    [ "$n" -gt 0 ] && return 0
    sleep "$STARVE_WAIT_BUSY_POLL_S"
    waited=$((waited + STARVE_WAIT_BUSY_POLL_S))
  done
  return 1
}

step2_restart_services() {
  local rows id name status busy labels unit owner_repo
  owner_repo="${STARVE_REPO//\//-}"
  rows="$(gh_runners)" || { err "step2: runner read failed — nothing restarted"; return 1; }
  while IFS=$'\t' read -r id name status busy labels; do
    [ -n "$id" ] || continue
    [ "$status" = online ] || continue
    # ⛔ NEVER RESTART A BUSY RUNNER — a restart during a job is a red the healer caused.
    if [ "$busy" = true ]; then
      say "step2: runner=$id name=$name busy — skipped (never restart a busy runner)"
      continue
    fi
    unit="$STARVE_RUNNER_UNIT_PREFIX.$owner_repo.$name.service"
    say "step2: restarting runner=$id name=$name unit=$unit"
    if "$STARVE_SYSTEMCTL" restart "$unit" >/dev/null 2>&1; then
      say "step2: restarted runner=$id name=$name unit=$unit"
    else
      err "step2: restart FAILED runner=$id name=$name unit=$unit — continuing"
      continue
    fi
    # ⛔ ONE AT A TIME: wait for busy>0 before touching the next runner.
    if wait_for_busy; then
      say "step2: busy>0 appeared after restarting $name — stopping the restart arm"
      return 0
    fi
  done <<<"$rows"
  return 1
}

# ── reconcile registrations (step 3) ───────────────────────────────────────────────────────────
step3_reconcile() {
  local rows id name status busy labels unit owner_repo out rc
  owner_repo="${STARVE_REPO//\//-}"
  rows="$(gh_runners)" || { err "step3: runner read failed — nothing reconciled"; return 1; }
  while IFS=$'\t' read -r id name status busy labels; do
    [ -n "$id" ] || continue
    [ "$status" = offline ] || continue
    [ "$busy" = false ] || continue
    unit="$STARVE_RUNNER_UNIT_PREFIX.$owner_repo.$name.service"
    # A ghost: GitHub holds the registration but this box has neither an instance dir nor a unit.
    if [ ! -e "$STARVE_RUNNER_ROOT/$name/.runner" ] && [ ! -L "$STARVE_RUNNER_ROOT/$name/.runner" ] \
       && ! "$STARVE_SYSTEMCTL" cat "$unit" >/dev/null 2>&1; then
      say "step3: ghost runner=$id name=$name (no local dir, no unit) — deleting"
      if "$STARVE_GH" api -X DELETE "repos/$STARVE_REPO/actions/runners/$id" >/dev/null 2>&1; then
        say "step3: deleted ghost runner=$id name=$name"
      else
        err "step3: delete FAILED ghost runner=$id name=$name — continuing"
      fi
    fi
  done <<<"$rows"
  # Re-register dead listeners / add to ceiling from a fresh token, with the canonical labels now
  # coming from the provisioning path itself (the actual fix).
  if [ -x "$STARVE_POOL" ]; then
    say "step3: delegating re-registration to $STARVE_POOL reconcile"
    out="$("$STARVE_POOL" reconcile 2>&1)"; rc=$?
    say "step3: reconcile rc=$rc"
    [ -z "$out" ] || say "$out"
  else
    # ⛔ NAME THE GAP, never a silent skip: ghost deletion above still ran; re-registration is the
    # one arm this box cannot do without the provisioning path, and the shout at step 4 will say so.
    err "step3: $STARVE_POOL is not executable here — re-registration skipped (ghosts were still deleted above)"
  fi
  return 0
}

# ── file and shout (step 4) ─────────────────────────────────────────────────────────────────────
step4_shout() {
  local msg
  msg="STARVED-UNHEALED repo=$STARVE_REPO queued=$QUEUED busy=$BUSY online=$ONLINE offline=$OFFLINE — the heal ladder exhausted (labels asserted, services restarted, registrations reconciled); the pool is still starved. FILE + FAIL VISIBLE."
  # durable inbox first — no dependencies, cannot fail silently
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >>"$STARVE_STATE_DIR/orchestrator-inbox.log"
  # tracker: file ONCE (a permanently broken pool must not spam a new issue every tick)
  if [ ! -f "$FILED_FILE" ]; then
    if "$STARVE_GH" issue create --repo "$STARVE_REPO" --title "ci: starved runner pool (queued>0 AND busy==0) not self-healed" --body "$msg" >/dev/null 2>&1; then
      : >"$FILED_FILE"
      err "step4: tracker issue filed for repo=$STARVE_REPO"
    else
      err "step4: tracker filing FAILED (the inbox record above stands)"
    fi
  else
    err "step4: tracker issue already filed — not re-filing"
  fi
  err "$msg"
  return 4
}

# ── the ladder ──────────────────────────────────────────────────────────────────────────────────
after_step() { # $1 = step name — rc 0 when the invariant cleared
  local rc
  rc=0; probe || rc=$?
  if [ "$rc" != 0 ]; then
    err "heal: cannot measure after step $1 — continuing the ladder"
    return 1
  fi
  if [ "$PROBE_STATE" = STARVED ]; then
    say "heal: step $1 did NOT clear the invariant (state=$PROBE_STATE queued=$QUEUED busy=$BUSY online=$ONLINE)"
    return 1
  fi
  say "heal: step $1 CLEARED the invariant (state=$PROBE_STATE queued=$QUEUED busy=$BUSY online=$ONLINE)"
  return 0
}

run_ladder() {
  say "heal: STARVED persistent — running the ladder (queued=$QUEUED busy=$BUSY online=$ONLINE offline=$OFFLINE)"
  step1_assert_labels
  if after_step 1; then write_streak 0; return 0; fi
  step2_restart_services
  if after_step 2; then write_streak 0; return 0; fi
  step3_reconcile
  if after_step 3; then write_streak 0; return 0; fi
  step4_shout
}

# ── persistence ─────────────────────────────────────────────────────────────────────────────────
read_streak() {
  local v
  v="$(sed -n 's/^starved_streak=//p' "$STATE_FILE" 2>/dev/null)"
  case "$v" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$v" ;; esac
}

write_streak() { mkdir -p "$STARVE_STATE_DIR" 2>/dev/null || true; printf 'starved_streak=%s\n' "$1" >"$STATE_FILE" 2>/dev/null || true; }

validate_knobs() {
  is_uint "$STARVE_SAMPLES" || { err "cannot-measure why=samples-unreadable value=${STARVE_SAMPLES:-<empty>}"; return 2; }
  is_uint "$STARVE_WAIT_BUSY_S" || { err "cannot-measure why=wait-busy-unreadable value=${STARVE_WAIT_BUSY_S:-<empty>}"; return 2; }
  is_uint "$STARVE_WAIT_BUSY_POLL_S" || { err "cannot-measure why=poll-unreadable value=${STARVE_WAIT_BUSY_POLL_S:-<empty>}"; return 2; }
  case "$STARVE_REPO" in */*) ;; *) err "cannot-measure why=repo-unreadable value=$STARVE_REPO"; return 2 ;; esac
  return 0
}

# ── verbs ───────────────────────────────────────────────────────────────────────────────────────
cmd_probe() {
  local rc
  rc=0; probe || rc=$?
  [ "$rc" != 0 ] && return 2
  say "state=$PROBE_STATE queued=$QUEUED busy=$BUSY online=$ONLINE offline=$OFFLINE"
  return 0
}

cmd_check() {
  validate_knobs || return 2
  # ⛔ THIS HEALER RUNS ON THE LINUX CELLS, NEVER THE MAC. The Mac's runner pool is a different
  # surface; this script restarts systemd units, which do not exist there.
  if [ "$STARVE_PLATFORM" = "Darwin" ]; then
    err "REFUSING: this healer runs on the Linux cells only (the Mac's pool is a different surface); nothing changed"
    return 2
  fi
  local rc streak
  rc=0; probe || rc=$?
  if [ "$rc" != 0 ]; then
    err "cannot measure — FAIL-CLOSED, changing nothing (state file untouched)"
    return 2
  fi
  log "state=$PROBE_STATE queued=$QUEUED busy=$BUSY online=$ONLINE offline=$OFFLINE"
  say "state=$PROBE_STATE queued=$QUEUED busy=$BUSY online=$ONLINE offline=$OFFLINE"
  if [ "$PROBE_STATE" != STARVED ]; then
    write_streak 0
    return 0
  fi
  streak="$(read_streak)"
  streak=$((streak + 1))
  # cap so a hand-driven streak cannot overflow into an implausible count
  [ "$streak" -le 999 ] || streak=999
  write_streak "$streak"
  say "state=STARVED streak=$streak/$STARVE_SAMPLES"
  if [ "$streak" -ge "$STARVE_SAMPLES" ]; then
    # ⛔ THE LADDER'S EXIT IS THE PASS'S EXIT WHEN IT RAN. A starved pool that the ladder could not
    # heal is exit 4 (filed + visible), never a quiet 0 — silence is the failure mode being fixed.
    run_ladder
    return $?
  fi
  return 0
}

main() {
  local verb="${1:-}"; shift 2>/dev/null || true
  case "$verb" in
    # ⛔ NO ARGS IS THE SCHEDULED PASS (the systemd unit runs `bash <this>` with no args), never help:
    # a unit that execs the help text every tick is the inert-enforcer shape this family exists to
    # remove — it would print usage forever and never sample.
    '') cmd_check "$@" ;;
    check) cmd_check "$@" ;;
    probe) cmd_probe "$@" ;;
    -h|--help|help) usage 0 ;;
    *) err "ci_runner_starvation: unknown command '$verb' (try: probe)"; return 1 ;;
  esac
}

main "$@"
