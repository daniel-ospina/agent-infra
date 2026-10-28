#!/usr/bin/env bash
# cloud-cell-doctor.sh — the cell's REPAIR / LAND / REAP roles (agent-infra#1989).
#
# WHY THIS EXISTS (measured 2026-10-18, pi-cell-2 / pi-cell-3). A cloud cell ran exactly one loop —
# `orch-loop.sh` — and the supervisor could only answer "is the tmux session up?". So a cell that had
# dispatched its backlog looked identical to a cell that was working: `lanes=0` + `controller:
# RUNNING` is also what a stopped controller prints, and nothing on the box recorded that a repair
# pass, a merge attempt or a reap had EVER run. The two consequences this file exists to remove:
#
#   * A green PR with a review recorded at head sat unlanded until a human (or a manually dispatched
#     lane) ran the rail. The cell could CREATE work and could not FINISH it.
#   * A wedged `lane-*` / `fix-*` / `merge-*` session held its lane slot until someone noticed. The
#     controller's own reaper only runs while the controller is alive, and it has one signal
#     (log mtime) — the same shape README §6.5.1 says is not enough.
#
# WHAT IS REUSED, DELIBERATELY (the issue's non-goal: no second, divergent implementation)
#   * the standard merge rail — `scripts/admin-merge.sh` — is EXECUTED, never re-implemented. This
#     file does not classify a PR's checks and does not merge on its own evidence: it only decides
#     whether the rail is worth calling (a clean attestation exists for THIS head), and records the
#     rail's own refusal verbatim when it declines.
#   * the review record — `~/.pi/agent/reviews/<owner>-<repo>-<pr>.json` — is the shipped
#     `record-review.sh` artifact, read at the cell's own `$HOME` (= `$CELL_HOME`), so a cell's
#     attestation state is its own and not the Mac's.
#   * PR repair/review dispatch is the shipped `orch-loop.sh` sweep (it spawns `fix-one.sh` /
#     `merge-one.sh` with the cell's claim identity). ⛔ It is NOT re-implemented here: #1872
#     measured two classifiers disagreeing on 4 of 11 live PRs. The doctor's dispatch action is to
#     guarantee that ONE dispatcher runs — restart it when its session is gone — and to keep
#     landing ready PRs on the rail even while it is stalled.
#   * the worktree reaper is the shipped `pi-reap-worktrees.sh` (dry-run by default; it preserves
#     anything dirty / unreferenced / unreachable).
#
# ROLES (each idempotent; each writes its own last-pass record under `$O/state/roles/`)
#   reap      one wedged-session pass (the safety core; see REAP below)
#   doctor    reap + controller supervision (restart the dispatcher when its session is gone)
#   merge     land PRs that have a clean attestation at head, through the standard rail
#   hygiene   package cache + worktree-root caches + stale worktrees + the cross-box review-record
#             registry (`registry-sync.sh union`, hourly, best-effort — a failed sync LOGS and the pass
#             continues, because a blind box may still merge its own records; #2577)
#   loop      the timer the supervisor starts: doctor / merge / hygiene on their own intervals
#   status    print the per-role liveness table; exit 1 when a role never ran / went stale
#
# Usage:
#   bash cloud-cell-doctor.sh reap|doctor|merge|hygiene|status [--dry-run]
#   bash cloud-cell-doctor.sh loop
#
# Exit codes: 0 = pass completed (including "nothing to do"); 2 = usage; 3 = the read a pass needs
# could not be taken (cannot-verify is never a pass); 4 = POLICY-INERT — the pass COMPLETED and judged
# nothing because the reaper's ancestry policy refuses this surface's lanes (the Linux-cell steady
# state, docs/ops/fleet-liveness.md §11.4). 4 is a named verdict, NOT a failure: `status` prints it and
# stays green, and the `doctor` role never lets it mask a controller that is down (rc=1) or a real
# cannot-verify (rc=3).

set -uo pipefail

CELL_HOME="${CELL_HOME:-/tmp/cell-home}"
O="${O:-$CELL_HOME/orchestrator}"
REPO="${REPO:-/tmp/cell}"
OR="${OR:-}"
SESSION="${SESSION:-orch}"
SUPERVISOR="${DOCTOR_SUPERVISOR:-}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# ── the rail-refusal RECORD (agent-infra#2223) ──────────────────────────────────────────────────
# The doctor's `merge` role EXECUTES the same `scripts/admin-merge.sh` the controller does, so its
# refusals must leave the same head-bound record — otherwise a cell whose doctor is the only actor
# running the rail produces refusals nothing can repair. The CLASSIFIER is shared (`rail-refusal.sh`,
# one definition), the writers are two, and the reader is the controller's sweep.
#
# NOT fatal when absent: this role's job is to land attested PRs, and refusing to run because the
# RECORD of a refusal cannot be written would turn a new observability path into an outage. The
# degraded state is logged at the refusal instead, once per pass, which is where an operator looks.
_declared=""
if [ -f "$O/rail-refusal.sh" ]; then _declared="$O/rail-refusal.sh"
elif [ -f "$SELF_DIR/rail-refusal.sh" ]; then _declared="$SELF_DIR/rail-refusal.sh"
fi
if [ -n "$_declared" ]; then
  # shellcheck source=/dev/null
  . "$_declared"
fi
# No startup warning here on purpose: `log()` is defined further down, and a message emitted before
# it exists would be a bare "command not found" on the operator's terminal. The degraded state is
# named at the REFUSAL instead (see the merge role), which is the moment it costs something.

# The PROCESS reaper (#2163), resolved ONCE. It is the lane-reap.sh shipped beside this file (or
# seeded into $O, which is what a running cell executes). It is deliberately NOT a second
# implementation of the gates below: `lane-reap.sh` owns the process population (a `pi` tree holding
# a fleet log open, judged on zero CPU + no human + a stale artefact) and this role only SCHEDULES
# it. A cell whose $O predates it says so in the pass line rather than silently skipping the class
# the session pass cannot see.
# `DOCTOR_LANE_REAP_BIN` is the tool seam (one per external tool, like DOCTOR_PS_BIN): the suite
# stands a stub in front of the process pass so it can assert the DELEGATION without letting a
# second reaper loose on the fixture's process table. Production leaves it unset.
LANE_REAP_BIN="${DOCTOR_LANE_REAP_BIN:-}"
if [ -z "$LANE_REAP_BIN" ]; then
  for _lr in "${O%/}/lane-reap.sh" "$SELF_DIR/lane-reap.sh"; do
    [ -n "$_lr" ] && [ -f "$_lr" ] && { LANE_REAP_BIN="$_lr"; break; }
  done
fi

# The tool seams. Every external command a pass depends on is overridable so the suite can drive the
# DECISIONS hermetically (and so the real tmux server is never touched by a test). They are not a
# security boundary — a value here names the same tool the shipped path names.
TMUX_BIN="${DOCTOR_TMUX_BIN:-tmux}"
PS_BIN="${DOCTOR_PS_BIN:-ps}"
GH_BIN="${DOCTOR_GH_BIN:-gh}"
SLEEP_BIN="${DOCTOR_SLEEP_BIN:-sleep}"

# Intervals and bounds. Every one is a NUMBER: a non-number either disables the thing it bounds or
# aborts the arithmetic, and both have been measured as a silent fail-open in this tree (see
# orch-loop.sh's is_num/is_limit rationale). Leading zeros are rejected because `$(( ))` reads them
# as OCTAL on /bin/bash 3.2 — the interpreter a cell's non-interactive shell may be.
#
# ⛔ This predicate is deliberately LOCAL. It must not be mistaken for the fleet's shared spawn
# predicate (`orch-loop.sh`'s is_num), which selftest counts: nothing here feeds a `pi` launch, a
# claim or a spawn. It validates only this file's own timers.
num_ok() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) [ "${#1}" -le 9 ] ;; esac; }
DOCTOR_INTERVAL="${DOCTOR_INTERVAL:-120}"
MERGE_INTERVAL="${MERGE_INTERVAL:-300}"
HYGIENE_INTERVAL="${HYGIENE_INTERVAL:-3600}"
LOOP_TICK="${LOOP_TICK:-10}"
# A wedged lane must show NO progress for this long before it can be touched. 45 min is above
# orch-loop's own STALE_MIN=40 and above the harness's TASK_STREAM_STALL bound (1200 s): a long
# model call is not a wedge, and a bound below the fleet's own stall bound cannot be justified by it.
REAP_MIN_S="${REAP_MIN_S:-2700}"
REAP_SAMPLE_S="${REAP_SAMPLE_S:-15}"
# ⛔ THE READ MUST ITSELF BE BOUNDED (README §6.5.2). `REAP_TIMEOUT` is the budget for the WHOLE
# pass, not per call: a per-call bound lets the total grow with the number of lanes, and the measured
# failure is a lane read taking >60 s under load and turning its caller into "refused itself". A pass
# that runs out of budget STOPS and records cannot-verify (rc 3) — it never reports a clean read of
# the lanes it did not reach. READ_CALL_TIMEOUT bounds any single tmux/ps call inside that budget.
REAP_TIMEOUT="${REAP_TIMEOUT:-300}"
READ_CALL_TIMEOUT="${READ_CALL_TIMEOUT:-15}"
# A controller whose heartbeat is older than this is REPORTED, never killed (see run_doctor).
CONTROLLER_STALE_S="${CONTROLLER_STALE_S:-900}"
CONTROLLER_START_TIMEOUT="${CONTROLLER_START_TIMEOUT:-600}"
# The rail can take ~30 s on a healthy PR and longer when it re-runs a flaky job. It is bounded so
# one PR cannot stall the merge role for the whole interval.
RAIL_TIMEOUT="${DOCTOR_RAIL_TIMEOUT:-900}"
MERGE_MAX_PRS="${MERGE_MAX_PRS:-100}"
# ⛔ The merge pass is bounded too, for the same reason as the reap read: without this, a queue of
# MERGE_MAX_PRS candidates each allowed RAIL_TIMEOUT would block the ONE loop for hours, and the
# doctor pass (which shares the loop) would fall past its stale bound while the cell was healthy but
# busy. Checked before each candidate; a pass that spends it records rc=3 and names what it skipped.
MERGE_BUDGET_S="${MERGE_BUDGET_S:-2400}"
# The open-PR listing is ONE read (bounded by MERGE_MAX_PRS), and it happens INSIDE the pass budget:
# a hung `gh api` must not outlive the budget or block the doctor's supervision behind it.
MERGE_READ_TIMEOUT="${MERGE_READ_TIMEOUT:-60}"
# A refusal is RECORDED and not retried blind: the same head is not offered to the rail again inside
# this window. A push moves the head, which re-arms it naturally.
MERGE_RETRY_S="${MERGE_RETRY_S:-3600}"
HYGIENE_TIMEOUT="${HYGIENE_TIMEOUT:-600}"
STALE_WORKTREE_DAYS="${STALE_WORKTREE_DAYS:-7}"
# auto = reap stale worktrees only when the box is under pressure (the measured failure is a FULL
# disk, not an untidy one); dry-run = report only; apply = always armed. The shipped reaper's own
# gates (clean / unreferenced / reachable / aged) still decide every individual removal.
HYGIENE_WORKTREES="${HYGIENE_WORKTREES:-auto}"
MIN_FREE_MB="${MIN_FREE_MB:-500}"
# ── the sinks this harness's OWN family fills (agent-infra#2573) ─────────────────────────────────
# THE TEMP DIRS. `cloud-cell-<pid>.<rand>` is what this family's `mktemp -d` leaves under $TMPDIR, and
# a run killed by ENOSPC never reaches its trap — so they accumulate for the life of the box. MEASURED
# 2026-10-21 on cell-3: removing ONE stale `/tmp/cloud-cell-1718.SmGtAK` (plus a docker prune) took
# the box from 2,506 MB to 27,134 MB free, and the same two steps took cell-4 from 678 MB (below the
# dispatcher's 1500 MB floor, so every dispatch there was refused) to 11,756 MB.
HYGIENE_TMP_DIR="${HYGIENE_TMP_DIR:-${TMPDIR:-/tmp}}"
# ⛔ THE PID IN THE NAME IS THE PROOF, AND IT IS NOT ALWAYS A PID. The token before the first `.` is
# a pid for `mktemp -d …/cloud-cell-<pid>.XXXXXX`, and then `kill -0` answers it exactly — but the SAME
# spelling comes from `mktemp -d …/cloud-cell-1718.XXXXXX` (`scripts/cloud-cell-bringup.test.sh`, where
# 1718 is an ISSUE number) and `…/cloud-cell-test.XXXXXX` (`scripts/cloud-cell-supervisor.test.sh`).
# On the numeric ones a RECYCLED pid could authorise deleting a LIVE suite's fixture, so a second,
# independent gate is required: nothing may have been written into the directory for this long. A name
# that carries no number at all has no liveness proof, so it is REPORTED and never reaped.
HYGIENE_TMP_MIN_AGE_S="${HYGIENE_TMP_MIN_AGE_S:-3600}"
# The docker CLI, overridable like every other tool seam here (so the suite can drive the DECISIONS
# without a daemon). See `hygiene_docker_sweep` for the two verbs this role is allowed to run and the
# one it is not.
DOCKER_BIN="${DOCTOR_DOCKER_BIN:-docker}"
# ── the CROSS-BOX REVIEW-RECORD REGISTRY, on the clock (agent-infra#2577) ────────────────────────
# `~/.pi/agent/reviews/` is PER BOX, and the merge role decides which PRs to rail from what it can
# see HERE — so a verdict minted on a peer box is invisible, and its PR is skipped as `NO-RECORD`
# while the fleet already holds a clean record for it (measured on this box: the store carried 3201
# `refs/reviews/*` records, the local registry 366, and the merge role logged
# `candidates=11 attempted=1 landed=0 skipped=11`). `scripts/registry-sync.sh union` is the
# converging verb — its own header says so — but nothing ran it on a schedule: `atomic-land.sh` runs
# it only when a PR is ALREADY being railed, and the merge role will never offer a PR it cannot see a
# record for. That is a fixed point, and this sub-step is what breaks it.
#
# Hourly, inside `hygiene`, is the right order of magnitude for a registry (every pass would be
# wasteful: the verb costs one `ls-remote`, one fetch and a per-record comparison).
#
#   DOCTOR_REGISTRY_STEP_TIMEOUT the bound for the WHOLE step, so it cannot starve the roles behind
#                             it. The first convergence after a blind period can outspend it; the verb
#                             is idempotent and makes DURABLE per-record progress, so the next hourly
#                             pass continues instead of restarting (nothing is lost, nothing retried
#                             in a storm — one attempt per pass, by construction).
# ⛔ NOT `REGISTRY_SYNC_TIMEOUT`: that name is ALREADY TAKEN by the verb this step execs, where it
# means the PER-NETWORK-OP bound (`registry-sync.sh:116`, default 60). Two meanings on one name is a
# silent collision in the worst direction — a box that exports it for its documented purpose (say 20)
# would collapse this step's whole-step bound below the `--timeout` it passes, so every hourly pass
# would be killed mid-record and log `SYNC FAILED rc=124` for ever, leaving the box blind with a
# permanently failing line. The whole surface is therefore named in THIS file's namespace.
#   DOCTOR_REGISTRY_NET_TIMEOUT the bound registry-sync.sh puts on EACH network op (its `--timeout`),
#                             which is what makes an offline / rate-limited box cost one bound and
#                             not a hang.
#   DOCTOR_REGISTRY_SYNC      the script seam: a PATH, or `off`/`none`/`0` to skip (the suite's
#                             hermetic switch — exec'ing the real verb there would make two real
#                             round trips to github.com, the #2374 lesson atomic-land.sh records).
#   DOCTOR_REGISTRY_STORE     the WORKTREE to sync FROM (see `registry_store`); an operator override
#                             and the suite's fixture seam.
REGISTRY_SYNC_SCRIPT="${DOCTOR_REGISTRY_SYNC:-}"
REGISTRY_STEP_TIMEOUT="${DOCTOR_REGISTRY_STEP_TIMEOUT:-300}"
REGISTRY_SYNC_NET_TIMEOUT="${DOCTOR_REGISTRY_NET_TIMEOUT:-30}"
REGISTRY_SYNC_STORE="${DOCTOR_REGISTRY_STORE:-}"
# A role that has not passed inside this window is STALE in `status`. The roles run IN SEQUENCE in
# one loop, so the bound must cover the WORST PASS IN FRONT OF IT — not two intervals, and not one
# call: a merge pass is bounded by MERGE_BUDGET_S (checked between candidates, so the last candidate
# may overrun it by one RAIL_TIMEOUT), and a hygiene pass by HYGIENE_TIMEOUT. Round 1 derived this
# from one RAIL_TIMEOUT and round 2 showed a legitimate multi-candidate pass still read STALE.
# Computed after those constants; an operator may narrow it.
DOCTOR_STALE_S="${DOCTOR_STALE_S:-}"
# A loop that has JUST started has not passed yet — its first doctor pass includes a real sampling
# window per lane, so `start && status` must not report a healthy cell as dead in the first seconds.
# NEVER RAN fails `status` only once the loop is older than this grace; a cell with NO loop-age
# record (an older tree, a hand-made fixture) is judged immediately, i.e. the fail-closed direction.
DOCTOR_GRACE_S="${DOCTOR_GRACE_S:-300}"
for _v in DOCTOR_INTERVAL MERGE_INTERVAL HYGIENE_INTERVAL LOOP_TICK REAP_MIN_S REAP_SAMPLE_S \
          CONTROLLER_STALE_S CONTROLLER_START_TIMEOUT RAIL_TIMEOUT MERGE_MAX_PRS MERGE_RETRY_S \
          HYGIENE_TIMEOUT STALE_WORKTREE_DAYS MIN_FREE_MB DOCTOR_GRACE_S REAP_TIMEOUT \
          READ_CALL_TIMEOUT MERGE_BUDGET_S MERGE_READ_TIMEOUT HYGIENE_TMP_MIN_AGE_S \
          REGISTRY_STEP_TIMEOUT REGISTRY_SYNC_NET_TIMEOUT; do
  num_ok "${!_v}" || { printf 'FATAL: %s must be a whole number 0..999999999 (got "%s")\n' "$_v" "${!_v}" >&2; exit 2; }
done
case "$HYGIENE_WORKTREES" in auto|dry-run|apply) ;; *) printf 'FATAL: HYGIENE_WORKTREES must be auto|dry-run|apply (got "%s")\n' "$HYGIENE_WORKTREES" >&2; exit 2 ;; esac
# ⛔ A zero TIMEOUT is not "no bound configured": `timeout 0` runs the command with NO timeout at
# all, so a `=0` here silently removes the very bound the variable exists to impose, and every read
# in this file becomes unbounded while the configuration looks deliberate. Refuse it.
# ⛔ The same "0 disables the bound" misconfiguration governs the two knobs the REAP's safety rests
# on, and they were the only ones left out of this loop:
#   REAP_SAMPLE_S=0 — the two CPU observations become simultaneous, so "CPU unchanged" is true of
#     EVERY lane, including a LIVE one sitting in a long model call (quiet log, flat CPU). That gate
#     is what this file's header names as the thing separating a wedge from a long call; at 0 the
#     wedge test is vacuous and the reaper KILLS the live lane it exists to spare.
#   REAP_MIN_S=0 — removes the age floor outright, so a lane younger than the window is eligible.
for _v in READ_CALL_TIMEOUT REAP_TIMEOUT RAIL_TIMEOUT HYGIENE_TIMEOUT CONTROLLER_START_TIMEOUT MERGE_READ_TIMEOUT \
          REAP_SAMPLE_S REAP_MIN_S HYGIENE_TMP_MIN_AGE_S REGISTRY_STEP_TIMEOUT REGISTRY_SYNC_NET_TIMEOUT; do
  [ "${!_v}" -gt 0 ] || { printf 'FATAL: %s must be > 0 (0 makes the bound vacuous: `timeout 0` runs with no timeout at all, a zero REAP_SAMPLE_S makes the two CPU observations simultaneous, a zero REAP_MIN_S removes the age floor, a zero HYGIENE_TMP_MIN_AGE_S leaves a recycled pid as the ONLY proof a temp dir is idle, and a zero registry bound would kill every sync mid-record) — got "%s"\n' "$_v" "${!_v}" >&2; exit 2; }
done
# The roles run IN SEQUENCE in ONE loop, so the legitimate gap between two passes of the same role is
# not that role's own duration — it is the sum of everything that can run in between. Building each
# stale bound from only its own role's cost made a healthy-but-busy cell read STALE (and `status`
# exit 1): merge N could be followed by a 600 s hygiene pass, a tick, then a 300 s reap plus a 600 s
# controller restart inside the next doctor pass, BEFORE merge N+1 even started.
# ⛔ The hygiene term includes the registry sub-step's own bounds: it is a sub-step of THAT pass and it
# is TWO bounded calls (the provisioning git write and the verb), so a healthy hygiene pass now
# legitimately lasts HYGIENE_TIMEOUT + 2 * REGISTRY_STEP_TIMEOUT. Leaving it out
# reintroduced exactly the defect this line's comment describes — a busy-but-healthy cell reading
# STALE — one sub-step over.
WORST_PASS_S=$(( MERGE_BUDGET_S + RAIL_TIMEOUT + HYGIENE_TIMEOUT + REGISTRY_STEP_TIMEOUT + REGISTRY_STEP_TIMEOUT ))
DOCTOR_PASS_S=$(( REAP_TIMEOUT + CONTROLLER_START_TIMEOUT ))
ALL_PASSES_S=$(( WORST_PASS_S + DOCTOR_PASS_S ))
[ -n "$DOCTOR_STALE_S" ] || DOCTOR_STALE_S=$(( ALL_PASSES_S + DOCTOR_INTERVAL * 2 ))
num_ok "$DOCTOR_STALE_S" || { printf 'FATAL: DOCTOR_STALE_S must be a whole number 0..999999999 (got "%s")\n' "$DOCTOR_STALE_S" >&2; exit 2; }

ROLES_DIR="$O/state/roles"
WORKER_LOG_DIR="$O/logs"
DESIRED="$ROLES_DIR/.desired"

# ── a stop that arrives MID-PASS (agent-infra#1989) ─────────────────────────────────────────────
# `end_loop_pid` TERMs the loop and KILLs it if it does not go — but the loop's destructive steps run
# in the FOREGROUND (the merge rail, `uv cache prune`, the worktree sweep/reaper), and bash DEFERS a
# TERM trap while it waits on a foreground child. So a TERM+KILL lands on a loop that was mid-rail:
# the child is orphaned and runs to completion — a merge that lands, a reaper that keeps deleting, up
# to RAIL_TIMEOUT later, after the operator's `stop` returned 0. The loop cannot make its child
# un-orphanable, so it refuses to START a destructive step once the cell has been stopped: each pass
# snapshots `.desired` + the stop generation, and re-checks them immediately before every destructive
# call. (A stop arriving INSIDE an already-running rail still lets that rail finish — killing a merge
# mid-flight is worse — but nothing NEW is started.)
PASS_WAS_DESIRED=0; PASS_STOP_GEN=""
begin_pass() {
  PASS_STOP_GEN="$(cat "$ROLES_DIR/.stop-generation" 2>/dev/null)"
  case "${PASS_STOP_GEN:-}" in ''|*[!0-9]*) PASS_STOP_GEN="0" ;; esac
  PASS_WAS_DESIRED=0
  [ -f "$DESIRED" ] && PASS_WAS_DESIRED=1
  return 0
}
cell_stopped_midpass() { # 0 = a stop arrived since this pass began
  if [ "$PASS_WAS_DESIRED" = 1 ] && [ ! -f "$DESIRED" ]; then return 0; fi
  local now; now="$(cat "$ROLES_DIR/.stop-generation" 2>/dev/null)"
  case "${now:-}" in ''|*[!0-9]*) now="0" ;; esac
  [ "$now" != "$PASS_STOP_GEN" ] && return 0
  return 1
}

# ── liveness record ──────────────────────────────────────────────────────────────────────────────
# One file per role, key=value, written ATOMICALLY (tmp + rename): a reader must see a whole pass
# record or the previous one, never a half-written line that parses as "never ran".
log_line() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
log() {
  mkdir -p "$WORKER_LOG_DIR" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$WORKER_LOG_DIR/doctor.log"
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"
}

state_get() { # <role> <key>
  sed -n "s/^$2=//p" "$ROLES_DIR/$1.state" 2>/dev/null | head -1
}

# state_write <role> <rc> <result...> — last_pass_* / passes / last_rc / last_result.
# `passes` carries forward; a missing/corrupt previous value restarts at 1 rather than failing the
# pass (a pass that did real work must not be lost because its own record was unreadable).
state_write() {
  local role="$1" rc="$2"; shift 2
  local f tmp prev passes now at
  mkdir -p "$ROLES_DIR" || return 1
  f="$ROLES_DIR/$role.state"; tmp="$f.tmp.$$"
  prev="$(state_get "$role" passes)"
  num_ok "${prev:-}" && [ "${prev:-0}" -gt 0 ] && passes=$((prev + 1)) || passes=1
  now="$(date +%s)"
  at="$(date -u +%FT%TZ)"
  {
    printf 'role=%s\n' "$role"
    printf 'last_pass_at=%s\n' "$at"
    printf 'last_pass_epoch=%s\n' "$now"
    printf 'passes=%s\n' "$passes"
    printf 'last_rc=%s\n' "$rc"
    printf 'last_result=%s\n' "$*"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# ⛔ A REHEARSAL IS NOT A VERDICT — the ONE owner of that rule, for EVERY role that rehearses.
# `--dry-run` is the verb an operator is told to run FIRST and it performs no action at all (every step
# is logged as WOULD), so a rehearsal cannot know whether a previous failure is fixed. Recording its
# own rc overwrote a stored `cannot-verify` with a clean row, and the row-level verdict then read that
# as health for a whole interval (measured: a pass recording `uv prune FAILED rc=1` — status rc=1 —
# followed by `hygiene --dry-run` gave `last_rc=0`, status rc=0).
# The rule was first written inside `run_hygiene` only, which left the exact defect one role over:
# `reap`, `merge` and `doctor` each end on an unconditional write of their own rc, so a clean rehearsal
# cleared a `KILL FAILED`, an unanswered rail, or a failed controller restart.
#
# Two things every rehearsing role must therefore get from here:
#   1. the record is MARKED as a rehearsal — a `status` reader has to be able to tell "nothing was
#      wedged / no PR was queued" from "nothing was attempted";
#   2. it keeps the WORSE of (stored verdict, its own). Keeping only the stored one fails the other
#      way: a rehearsal that itself hit cannot-verify (an unreadable session list, an unreadable disk)
#      would record a clean row for the very "box is wedged, operator runs the documented first verb"
#      case.
# ⛔ AND ABSENT IS NOT UNREADABLE. `state_get` answers the SAME empty string for "there is no record
# yet" and "the record holds no readable rc". Folding both into 3 recorded a failure that never
# happened on a FRESH cell — which is exactly when an operator runs the documented first verb — writing
# `last_rc=3` from a clean rehearsal that had nothing to preserve, so `status` reported FAILED over
# `dry-run (a rehearsal, no action taken)`. No record ⇒ nothing to overwrite ⇒ the rehearsal's own rc
# stands. A record that EXISTS but holds no readable rc ⇒ fail-closed at 3.
state_write_rehearsal() { # <role> <own_rc> <result...>
  local role="$1" own="$2" prev _sr_prev_fail _sr_own_fail; shift 2
  if [ -f "$ROLES_DIR/$role.state" ]; then
    prev="$(state_get "$role" last_rc)"
    case "${prev:-}" in ''|*[!0-9]*) prev=3 ;; esac
  else
    prev="$own"
  fi
  num_ok "${own:-}" || own=3
  # ⛔ rc=4 IS A POLICY VERDICT, NOT A SEVERITY (#2163 review r8, P1). "Keep whichever rc is larger"
  # ranked a policy-inert pass (4) ABOVE a stored cannot-verify (3) and a failed restart (1), so a
  # rehearsal recorded INERT over a failure that was still true — the same defect this function exists
  # to prevent, one arm over. Only a FAILING rc (1/2/3) supersedes; 4 is carried only when neither
  # side is failing, and a clean 0 still never clears a failure.
  case "${prev:-}" in 1|2|3) _sr_prev_fail=1 ;; *) _sr_prev_fail=0 ;; esac
  case "$own" in 1|2|3) _sr_own_fail=1 ;; *) _sr_own_fail=0 ;; esac
  if [ "$_sr_own_fail" = 1 ]; then
    prev="$own"
  elif [ "$_sr_prev_fail" = 0 ] && [ "$own" -gt "$prev" ]; then
    prev="$own"
  fi
  state_write "$role" "$prev" "dry-run (a rehearsal, no action taken): $*"
}

# One pass at a time per role. The loop and an operator verb can meet; the loser SKIPS (and says so)
# rather than running a second pass — two reaps sampling each other, or two rails on one PR, are the
# double-dispatch the harness's claim layer exists to prevent. A lock whose owner is gone is
# reclaimed (the same fail-closed direction orch-loop's `acq()` uses for a dead pid).
# Write this process's ownership of a freshly-created lock dir: `pid|ident` in ONE file, so a reader
# never sees a pid without its identity.
lock_claim() {
  local d="$1" tmp="$1/.own.tmp.$$"
  printf '%s|%s\n' "$$" "$(pid_ident "$$")" > "$tmp" 2>/dev/null && mv -f "$tmp" "$d/own" 2>/dev/null \
    && return 0
  rm -f "$tmp" 2>/dev/null
  return 1
}
# Reclaim a lock whose owner is gone — ATOMICALLY. `rm -rf "$d"; mkdir "$d"` is a two-step race: with
# two reclaimers (a fresh loop's first pass and an operator's manual verb, both seeing a lock leaked by
# a SIGKILLed loop), A's rm removes the dead lock, A's mkdir claims it, then B's rm deletes A's FRESH
# lock and B claims it too — both believe they hold it, and two reaps sample each other / two rails hit
# one PR. Renaming the dead dir to a unique tombstone first is indivisible: only ONE reclaimer can
# move that exact directory, so the loser's `mkdir` fails and it backs off.
reclaim_lock() { # <lock dir>
  # ⛔ A RECLAIM MUST NOT REMOVE THE LOCK DIRECTORY. `rm -rf "$d"; mkdir "$d"` re-opens the window
  # between the two steps, and `mv "$d" tomb` is no better: a loser whose `mv` finds the winner has not
  # re-created `$d` yet will move the winner's FRESH lock away and claim it too (measured: 4 racers, 2
  # winners; 6 racers, 3). So the directory stays and only its `own` record is replaced — under an
  # exclusive meta-lock (`mkdir $d.reclaim`), which is the single atomic primitive that decides who
  # may rewrite it. Everyone else backs off and retries on a later pass.
  local d="$1" meta="$d.reclaim" own pid ident age i
  if ! mkdir "$meta" 2>/dev/null; then
    # A reclaimer killed mid-flight leaves the meta-lock behind. Bound it, or the role wedges.
    age=$(( $(date +%s) - $(mtime_epoch "$meta" || printf 0) ))
    [ -n "${age:-}" ] && [ "$age" -ge 0 ] && [ "$age" -lt 60 ] && return 1
    rm -rf "$meta" 2>/dev/null || return 1
    mkdir "$meta" 2>/dev/null || return 1
  fi
  # Re-verify UNDER the meta-lock: the owner may have been reclaimed (or come back) meanwhile.
  own="$(cat "$d/own" 2>/dev/null)"
  pid="${own%%|*}"; ident="${own#*|}"
  if num_ok "${pid:-}" && kill -0 "$pid" 2>/dev/null && [ "$ident" = "$(pid_ident "$pid")" ]; then
    rmdir "$meta" 2>/dev/null || true
    return 1
  fi
  i=0
  while [ "$i" -lt 2 ]; do
    i=$((i + 1))
    if lock_claim "$d"; then
      [ "$(cat "$d/own" 2>/dev/null)" = "$$|$(pid_ident "$$")" ] && { rmdir "$meta" 2>/dev/null || true; return 0; }
    fi
    # The directory is gone (its owner released it mid-reclaim): re-create it atomically, then retry
    # the claim once. A third party that beat us here simply wins the `mkdir`.
    mkdir "$d" 2>/dev/null || true
  done
  rmdir "$meta" 2>/dev/null || true
  return 1
}
role_lock() {
  # ⛔ ONE `local` per value: `local role="$1" d="…$role…"` reads `$role` before bash has assigned it
  # in this scope, so it resolves to the CALLER's variable — fine when the caller happens to have one
  # (run_role_pass does, by dynamic scoping), and an unbound-variable abort under `set -u` from any
  # other caller. The lock must not depend on who called it.
  local role="$1"
  local d="$ROLES_DIR/.$role.lock" own pid ident age
  mkdir -p "$ROLES_DIR" || return 1
  if mkdir "$d" 2>/dev/null; then lock_claim "$d" && return 0; rm -rf "$d"; return 1; fi
  own="$(cat "$d/own" 2>/dev/null)"
  pid="${own%%|*}"; ident="${own#*|}"
  if num_ok "${pid:-}" && kill -0 "$pid" 2>/dev/null; then
    # ⛔ `kill -0` alone is not identity: a lock leaked by a killed pass holds a DEAD pid, and if the
    # OS recycles it the role would be wedged FOREVER (every pass SKIPs). Reclaim only when the
    # recorded incarnation no longer matches — or when the lock predates `own` in this version and is
    # old enough that no live pass can still be between `mkdir` and the write.
    if [ -n "$ident" ] && [ "$ident" = "$(pid_ident "$pid")" ]; then return 1; fi
    reclaim_lock "$d" && return 0
    return 1
  fi
  if [ -z "$own" ]; then
    age=$(( $(date +%s) - $(mtime_epoch "$d" || printf 0) ))
    [ -n "${age:-}" ] && [ "$age" -ge 0 ] && [ "$age" -lt 60 ] && return 1
  fi
  reclaim_lock "$d" && return 0
  return 1
}
# ⛔ Only the OWNER removes the lock directory. An unfenced `rm -rf` races a reclaimer that has just
# taken the lock over (its owner looked dead for a moment), deleting the new holder's lock and letting a
# third pass in.
role_unlock() {
  local d="$ROLES_DIR/.$1.lock"
  [ "$(cat "$d/own" 2>/dev/null)" = "$$|$(pid_ident "$$")" ] && rm -rf "$d" 2>/dev/null
  return 0
}

# ── portable probes ─────────────────────────────────────────────────────────────────────────────
# Epoch mtime. GNU stat first, BSD second (never the reverse: GNU `stat -f %m` prints a whole
# filesystem block before failing, and the caller would read that as a number — report.sh's note).
mtime_epoch() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null)"
  case "$m" in ''|*[!0-9]*) m="" ;; esac
  if [ -z "$m" ]; then
    m="$(stat -f %m "$1" 2>/dev/null)"
    case "$m" in ''|*[!0-9]*) m="" ;; esac
  fi
  printf '%s' "$m"
}

# Bound ONE external read (tmux/ps/gh). ⛔ `timeout(1)` is used when present, but its ABSENCE must
# not silently drop the bound: a single hung read would then block the one loop that supervises
# everything else (§6.5.2's measured >60 s read), and `REAP_TIMEOUT` is only checked BETWEEN reads.
# The fallback bounds the call in the shell itself: run it in the background, arm a watchdog that
# TERMs it, and wait on the child. `DOCTOR_TIMEOUT_BIN` exists so a test can drive the fallback.
BOUND_TIMEOUT_BIN="${DOCTOR_TIMEOUT_BIN:-timeout}"
# `timeout`'s own TERM does NOT end a shell that is waiting on a foreground child (the common hang:
# admin-merge.sh blocked on `gh`/`git`): bash defers the trap until that child returns, so a bare
# `timeout` would let the hang outlive its bound. `-k` adds the KILL that actually ends it.
BOUND_KILL_S="${DOCTOR_TIMEOUT_KILL_S:-15}"
bounded() {
  local s="$1"; shift
  local p w rc tmp tmpe
  if [ -n "$BOUND_TIMEOUT_BIN" ] && command -v "$BOUND_TIMEOUT_BIN" >/dev/null 2>&1; then
    "$BOUND_TIMEOUT_BIN" -k "$BOUND_KILL_S" "$s" "$@"; return $?
  fi
  # BOTH of the read's streams go to FILES, and the watchdog's to /dev/null. A killed read can leave
  # a grandchild behind, and any inherited descriptor of the caller's `$( … )` pipe would then hold it
  # open for the hang's full length — the bound would be defeated by the very process it killed. The
  # parent replays both files, so the caller sees exactly the output it would have seen.
  # ⛔ A failed `mktemp` must NOT run the read in the foreground: that silently removes the only bound
  # this fallback has, and a hung `tmux`/`ps`/`gh` would then block the one loop that supervises the
  # cell for ever (no REAP_TIMEOUT / MERGE_BUDGET_S check can fire inside it). Fail closed — the
  # caller records cannot-verify — the same direction every other unreadable read takes.
  tmp="$(mktemp "${TMPDIR:-/tmp}/cell-doctor-read.XXXXXX" 2>/dev/null)" || return 1
  tmpe="$tmp.err"
  "$@" >"$tmp" 2>"$tmpe" &
  p=$!
  # TERM is not enough on its own: a shell waiting on its OWN foreground child (the common case for a
  # wrapper that hangs) defers the trap until that child returns. KILL after a short grace ends the
  # wait; the orphaned grandchild is a read tool that exits on its own.
  ( "$SLEEP_BIN" "$s"; kill -TERM "$p" 2>/dev/null; "$SLEEP_BIN" 1; kill -KILL "$p" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait "$p"; rc=$?
  # Do NOT wait on the watchdog: its foreground is the bound itself, so waiting would cost `s` on
  # every healthy read. KILL it (its orphaned `sleep` cannot fire the kill commands — the subshell
  # that runs them is gone), and never leave a delayed signal aimed at a recycled pid.
  kill -TERM "$w" 2>/dev/null || true
  kill -KILL "$w" 2>/dev/null || true
  cat "$tmp" 2>/dev/null
  cat "$tmpe" >&2 2>/dev/null
  rm -f "$tmp" "$tmpe"
  return "$rc"
}

# Free MiB. `df -Pk`'s 4th column is 1KiB blocks; `printf %d` (never awk's OFMT, which prints
# scientific notation for large values on mawk, i.e. on the cell). Empty when it cannot answer —
# every caller reads that as cannot-verify, never as "enough".
free_mb() { df -Pk "${1:-.}" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%d\n", $4 / 1024}'; }

# A bound for a SUBPROCESS whose output must stream (the rail, uv, the reaper, a supervisor restart):
# `timeout -k` when available, else the same shell fallback `bounded` uses. Without `timeout(1)` the
# call is buffered through a file by `bounded` — a long rail log is worth a bounded call.
run_bounded() {
  local s="$1"; shift
  if [ -n "$BOUND_TIMEOUT_BIN" ] && command -v "$BOUND_TIMEOUT_BIN" >/dev/null 2>&1; then
    "$BOUND_TIMEOUT_BIN" -k "$BOUND_KILL_S" "$s" "$@"; return $?
  fi
  bounded "$s" "$@"
}

# ── REAP ─────────────────────────────────────────────────────────────────────────────────────────
# The gates. A lane is reaped ONLY when ALL hold; anything unclear means REPORT, never act (README
# §6.5.1/§6.5.3, and the measured lane-killers behind it):
#
#   1. NAMESPACE. Only the sessions THIS harness creates: `lane-*`, `fix-*`, `merge-*`, `chain-*`.
#      A human's tmux session is never a candidate by name — the guard is positive identification,
#      not a deny-list. (orch-loop's reaper has the same namespace scope.)
#   2. A PROGRESS SIGNAL EXISTS. The session's log (`$O/logs/<session>.log`, the file `run_agent`
#      tees) must exist and be readable. No log = no basis = skip; orch-loop's own reaper skips it
#      too, for the same reason.
#   3. TWO OBSERVATIONS, not one. A wedged lane must show an unchanged log mtime AND unchanged
#      cumulative CPU over the subtree across a sample window. A child that is still writing (a
#      build, a test run, a tool call) advances one of the two, and is never touched. A single
#      reading cannot tell a long model call from a freeze — that is why the fleet's watchdog uses
#      two ticks, and why this one does too.
#   4. THE AGE BOUND IS A NUMBER, above the fleet's own stall bound (REAP_MIN_S, see above).
#   5. NO HUMAN ANYWHERE. A session with an ATTACHED tmux client is being watched, and a process
#      whose ancestry reaches a human terminal / login / ssh session is a human's, however parked it
#      looks. `ppid 1` proves nothing on its own (a daemonising service reparents to 1 by design).
#   6. THE SIGNAL LANDS ON THE PROCESS THAT WAS MEASURED. `tmux kill-session` HUPs the pane's group;
#      the extra TERM/KILL is fenced on the pane pid's `lstart` re-read, so a recycled pid cannot
#      receive a signal meant for a corpse (the fleet's one identity rule, #1178).

# Names of the sessions in this harness's namespace. A `tmux ls` that fails with NO SERVER is an
# empty list (nothing to reap); a MISSING tmux, or any other failing read, is CANNOT-VERIFY and is
# signalled with SESS_UNREADABLE_MARK — never an empty list, because "I could not look" and "nothing
# is there" must not render identically (README §6.5.2). The mark cannot collide with a session: the
# names are namespace-filtered to lane-|chain-|merge-|fix- below.
SESS_UNREADABLE_MARK='__sessions_unreadable__'
harness_sessions() {
  local s out rc
  if ! command -v "$TMUX_BIN" >/dev/null 2>&1; then
    printf '%s\n' "$SESS_UNREADABLE_MARK"; return 0
  fi
  out="$(bounded "$READ_CALL_TIMEOUT" "$TMUX_BIN" ls -F '#{session_name}' 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      # tmux's own words when NO SERVER exists: nothing is running, which IS an empty list. The
      # socket-missing variant is matched WITH its cause — a bare "error connecting to" also covers
      # permission and protocol failures, which are cannot-verify, not "nothing there".
      *"no server running"*) return 0 ;;
      *"error connecting to"*"No such file or directory"*) return 0 ;;
      *) printf '%s\n' "$SESS_UNREADABLE_MARK"; return 0 ;;
    esac
  fi
  for s in $out; do
    case "$s" in
      lane-*|fix-*|merge-*|chain-*) ;;
      *) continue ;;
    esac
    # Defensive: an API value must never reach a tmux target unvalidated.
    case "$s" in *[!A-Za-z0-9_-]*) continue ;; esac
    printf '%s\n' "$s"
  done
}

# THREE-VALUED, like the other safety probes: a pane pid, or `NA` when the read itself failed. A real
# tmux session always has a pane pid, so an empty answer is a READ FAILURE — counting it as a benign
# "no usable pane" made a cell whose `list-panes` fails (while `tmux ls` still works) record a clean
# rc=0 reap pass over N skipped lanes it never judged.
pane_pid() {
  local out
  out="$(bounded "$READ_CALL_TIMEOUT" "$TMUX_BIN" list-panes -t "=$1" -F '#{pane_pid}' 2>/dev/null)" || { printf 'NA\n'; return 0; }
  out="$(printf '%s\n' "$out" | head -1)"
  case "${out:-}" in ''|*[!0-9]*) printf 'NA\n' ;; *) printf '%s\n' "$out" ;; esac
}
# ONE bounded read of the WHOLE session list, classified once: 0 = read (names on stdout), 1 = NO
# SERVER (an EMPTY list — the normal state of a stopped cell), 3 = the read could not be taken
# (CANNOT-VERIFY). `has-session` cannot make that distinction: it answers rc=1 for "no such session"
# and for every client/server error alike, so a failed read arrives as positive evidence of ABSENCE —
# and in `run_reap` and `run_doctor` the absence branch KILLS or RESTARTS. `tmux ls` exits non-zero
# for both conditions too, so the tool's OWN message decides it: the two benign spellings are matched
# at the START of the line only, which is what keeps a broken BINARY (`/nonexistent/tmux: No such
# file or directory`, rc=127) in cannot-verify instead of turning every role on a fresh box into an
# empty list.
# ⛔ No logging in here: this runs inside `$( )` at every call site, so a log line would become part of
# the answer. Callers log; this function only answers.
tmux_session_list() {
  local out rc err
  # ⛔ mktemp, never `$$`: the old predictable path let ANY local user pre-create a symlink there and
  # have the doctor truncate (and, via the grep below, READ) an arbitrary file the doctor can write —
  # and that file carries the classification this function exists to get right. `bounded` two
  # functions up already uses mktemp for exactly this reason. A failed mktemp must NOT fall through
  # to an unbounded/unclassified read: 3 = cannot-verify, the direction every other unreadable read
  # here takes.
  err="$(mktemp "${TMPDIR:-/tmp}/cell-doctor-tmux-ls.XXXXXX" 2>/dev/null)" || return 3
  out="$(bounded "$READ_CALL_TIMEOUT" "$TMUX_BIN" ls -F '#{session_name}' 2>"$err")"; rc=$?
  if [ "$rc" -eq 0 ]; then rm -f "$err"; printf '%s\n' "$out" | sed '/^$/d'; return 0; fi
  if grep -qiE '^(no server running|error connecting to .*\(No such file or directory\))' "$err" 2>/dev/null; then
    rm -f "$err"; return 1
  fi
  rm -f "$err"
  return 3
}

# 0 = the session is PRESENT, 1 = ABSENT, 3 = CANNOT-VERIFY (the distinction `has-session` loses).
# ⛔ `grep -F` (LITERAL), and grep's own answer classified: `$SESSION` is unvalidated env, so a name
# carrying an ERE metacharacter (`orch[`) made `grep -qx` exit 2 — invalid regex — which a caller
# reading only `-eq 0`/`-eq 1` took as ABSENT and restarted; and an unescaped `.` (`orch.2`) matched a
# live `orchX2`, so the doctor reported RUNNING for a controller that did not exist. A pattern is not
# a name. ⛔ A HERE-STRING, never `printf … | grep -q`: the quiet grep exits at its first match, the
# writer takes SIGPIPE, and under `set -uo pipefail` the pipeline reads non-zero — so a session that
# IS present would answer "absent" (scripts/check-no-sigpipe-grep.sh reds the pipe form).
session_present() {
  local list rc
  list="$(tmux_session_list)"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  grep -Fqx -- "$1" <<<"$list"
  rc=$?
  [ "$rc" -le 1 ] && return "$rc"   # 0 = present, 1 = absent
  return 3                          # grep could not answer -> cannot-verify, never "absent"
}

attached_clients() { # prints a count, or NA when the read could not be taken
  local out
  out="$(bounded "$READ_CALL_TIMEOUT" "$TMUX_BIN" list-clients -t "=$1" 2>/dev/null)" || { printf 'NA\n'; return 0; }
  printf '%s\n' "$out" | awk 'NF{n++} END{printf "%d\n", n+0}'
}
# A process's IDENTITY. `/proc/<pid>/stat` field 22 is the start time in clock ticks since boot —
# second-resolution `lstart` is not enough to fence a signal: a pid recycled inside the SAME second
# produces an identical string, and the fence would pass for an innocent process (review round 3).
# macOS has no /proc, so `lstart` remains the fallback there. Every identity comparison (the reap
# fence, the loop record, the role lock) goes through this one function.
pid_ident() {
  local pid="$1" st f22
  st="$(cat "/proc/$pid/stat" 2>/dev/null)"
  if [ -n "$st" ]; then
    # The `comm` field can contain spaces and parentheses, so cut through the LAST ')' and count from
    # the field after it (stat field 3 = state, so starttime = the 20th token there).
    f22="$(printf '%s' "$st" | sed 's/.*) //' | awk '{print $20}')"
    case "$f22" in
      ''|*[!0-9]*) ;;
      *) printf 'proc:%s\n' "$f22"; return 0 ;;
    esac
  fi
  bounded "$READ_CALL_TIMEOUT" "$PS_BIN" -p "$pid" -o lstart= 2>/dev/null
}

# Seconds of cumulative CPU time for <pid> and every descendant. Prints "NA" when the root is not in
# the table (an unreadable/empty `ps`: cannot-verify, never "0 seconds of progress").
subtree_cpu_secs() {
  # ⛔ THE READ'S OWN STATUS, not just its output. A `ps` cut at READ_CALL_TIMEOUT can still have
  # emitted the ROOT's line and lost later rows — and the lost tail is exactly the DESCENDANTS' CPU
  # (a wedged lane has a low pane pid, its working children higher ones), so the `c1 > c0` gate would
  # pass on a lane that is still working and reap it. An incomplete table is NA, like every other
  # unreadable safety read here.
  local out rc
  out="$(bounded "$READ_CALL_TIMEOUT" "$PS_BIN" -A -o pid=,ppid=,time= 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { printf 'NA\n'; return 0; }
  printf '%s\n' "$out" | awk -v root="$1" '
    function secs(t,   n,a,i,d,h,m,s) {
      sub(/\..*/, "", t)
      d = 0
      i = index(t, "-"); if (i > 0) { d = substr(t, 1, i-1) + 0; t = substr(t, i+1) }
      n = split(t, a, ":")
      if (n >= 3)      { h = a[1] + 0; m = a[2] + 0; s = a[3] + 0 }
      else if (n == 2) { h = 0;         m = a[1] + 0; s = a[2] + 0 }
      else             { h = 0;         m = 0;         s = a[1] + 0 }
      return d * 86400 + h * 3600 + m * 60 + s
    }
    {
      rows++
      # ⛔ EVERY row of pid, ppid and `time` must match the ps shape, or the whole answer is
      # cannot-verify. A table this code cannot parse (a truncated row, a `??:??` sentinel, a widened
      # field) otherwise parses to 0 seconds via the `+0` coercion on BOTH observations, and two EQUAL
      # readings are indistinguishable from a frozen subtree — so a failed READ would arrive at the
      # reaper as evidence of a wedge. `[0-9][0-9]`, not `[0-9]{2}`: mawk 1.3.4 (the awk on a Linux
      # cell) PANICS on the interval form inside this alternation, and a panicking awk answers nothing
      # at all — an inert reaper on exactly the boxes it runs on.
      if ($1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^([0-9]+-)?([0-9]+:)?[0-9]+:[0-9][0-9](\.[0-9]+)?$/) bad = 1
      ppid[$1] = $2; cpu[$1] = secs($3)
    }
    END {
      if (bad || rows == 0) { print "NA"; exit }
      if (!(root in ppid)) { print "NA"; exit }
      found[root] = 1; changed = 1
      while (changed) {
        changed = 0
        for (p in ppid) {
          if (!(p in found) && (ppid[p] in found)) { found[p] = 1; changed = 1 }
        }
      }
      total = 0
      for (p in found) total += cpu[p]
      printf "%d\n", total
    }'
}

# 0 = a HUMAN is above <pid>. Walks to the top (bounded), matching the terminal/login markers the
# fleet's reapers use. ⛔ Plain `tmux` is NOT a marker: every harness lane lives in tmux, so matching
# it would make the reaper inert. A human *watching* a session is caught by attached_clients().
human_above() { # 0 = a human is above; 1 = none; 2 = the ancestry could not be READ
  local pid="$1" n=0 row ppid args
  while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ] && [ "$n" -lt 40 ]; do
    row="$(bounded "$READ_CALL_TIMEOUT" "$PS_BIN" -p "$pid" -o ppid=,args= 2>/dev/null)"
    # ⛔ An empty/unreadable row is NOT "no human": the exclusion is a safety gate, so it must fail
    # closed (skip the lane) rather than proceed toward the kill path.
    [ -n "$row" ] || return 2
    read -r ppid args <<<"$row"
    case "$args" in
      *Terminal.app*|*iTerm*|*Warp.app*|*kitty.app*|*Alacritty.app*|*"/usr/bin/login"*|*" sshd"*|*sshd:*)
        return 0 ;;
    esac
    pid="$ppid"
    n=$((n + 1))
  done
  return 1
}

run_reap() {
  begin_pass
  # ${1:-}: NO mode means a LIVE pass (an empty string never equals `--dry-run`). An ABSENT or
  # empty `$1` MUST be survivable — a bare `"$1"` here is what killed the scheduler on its first
  # tick (#2424), and the loop still asks this role to run with an empty mode on every schedule;
  # see "POSITIONAL PARAMETERS: WHICH MAY BE ABSENT" before run_role_pass for the file-wide audit.
  local dry="${1:-}" s log m0 m1 c0 c1 age now pid clients ls0 ls1 started elapsed sp ha
  local seen=0 skipped=0 reaped=0 would=0 unverifiable=0 failed=0 result=""
  # ⛔ A POLICY-INERT PROCESS PASS IS A THIRD VERDICT, TRACKED APART (#2163 review r8, P1). It was a
  # `pass_rc=3`, which on a Linux cell is the STEADY STATE — so the cell's health verb was red for
  # ever and a REAL cannot-verify could not be told from a policy decision nobody can act on.
  local inert_pass=0
  note() { log "[reap] $*"; result="${result}${result:+; }$*"; }
  started="$(date +%s)"
  local names; names="$(harness_sessions)"
  case "$names" in
    *"$SESS_UNREADABLE_MARK"*)
      log "[reap] CANNOT-VERIFY: the harness session list could not be read (tmux absent or failing) — nothing was judged"
      state_write reap 3 "cannot-verify: session list unreadable (tmux $TMUX_BIN)"
      return 3 ;;
  esac

  for s in $names; do
    seen=$((seen + 1))
    # The budget is for the WHOLE read (§6.5.2). Checked at the top of each lane so a pass that has
    # spent it stops touching anything further and says so — the unreached lanes are NOT "quiet".
    elapsed=$(( $(date +%s) - started ))
    if [ "$elapsed" -gt "$REAP_TIMEOUT" ]; then
      log "[reap] CANNOT-VERIFY: the read budget (${REAP_TIMEOUT}s) was spent after $seen lane(s) — nothing further was judged"
      state_write reap 3 "cannot-verify: read budget ${REAP_TIMEOUT}s spent after $seen lane(s); ${seen} judged: $result"
      return 3
    fi
    log="$WORKER_LOG_DIR/$s.log"
    # ⛔ Two different facts, and they used to be one branch: NO LOG is the documented exclusion (a
    # lane that tees nothing cannot be judged), while a log that EXISTS but whose mtime cannot be read
    # (a missing or broken `stat`) is a FAILED READ — counted as an exclusion it produced a green reap
    # row on a box whose `stat` does not work.
    if [ ! -f "$log" ]; then
      skipped=$((skipped + 1)); note "$s SKIP no log (no progress signal)"
      continue
    fi
    m0="$(mtime_epoch "$log")"
    if [ -z "$m0" ]; then
      skipped=$((skipped + 1)); unverifiable=$((unverifiable + 1))
      note "$s SKIP cannot read the log mtime (cannot-verify)"
      continue
    fi
    age=$(( $(date +%s) - m0 ))
    if [ "$age" -le "$REAP_MIN_S" ]; then
      skipped=$((skipped + 1)); note "$s SKIP log advanced ${age}s ago (under ${REAP_MIN_S}s)"
      continue
    fi
    pid="$(pane_pid "$s")"
    if [ "${pid:-NA}" = "NA" ]; then
      # The pane pid is what the extra TERM/KILL is fenced to: without it the kill is not
      # attributable, so this lane was NOT judged. That is cannot-verify, never a clean skip — UNLESS
      # the session is GONE, which is an ANSWER (the lane ended between the two reads, the normal way
      # a lane ends) and not a failed read. `pane_pid` cannot arbitrate (it runs `… | head -1` under
      # `pipefail`, so it also reports SIGPIPE for a healthy multi-pane session); one classified
      # session read can, and it is the one this file already owns.
      sp=0; session_present "$s" || sp=$?
      skipped=$((skipped + 1))
      if [ "$sp" -eq 1 ]; then
        note "$s SKIP session is gone (no pane left)"
      else
        unverifiable=$((unverifiable + 1)); note "$s SKIP cannot read the pane pid (cannot-verify)"
      fi
      continue
    fi
    if [ "${pid:-0}" -le 1 ]; then
      skipped=$((skipped + 1)); note "$s SKIP no usable pane pid (${pid})"
      continue
    fi
    clients="$(attached_clients "$s")"
    if [ "${clients:-NA}" = "NA" ]; then
      # The attached-client gate is a SAFETY gate: an unreadable read must fail CLOSED (skip), never
      # read as "nobody is watching" — otherwise a hung `list-clients` would defeat it.
      skipped=$((skipped + 1)); unverifiable=$((unverifiable + 1)); note "$s SKIP cannot read the attached clients (cannot-verify)"
      continue
    fi
    if [ "${clients:-0}" -gt 0 ]; then
      skipped=$((skipped + 1)); note "$s SKIP a tmux client is attached (human watching)"
      continue
    fi
    human_above "$pid"; local hrc=$?
    if [ "$hrc" -eq 0 ]; then
      skipped=$((skipped + 1)); note "$s SKIP ancestry reaches a human terminal/login"
      continue
    fi
    if [ "$hrc" -ne 1 ]; then
      # ⛔ `ps -p <pid>` exits 1 for "no such process", which is an ANSWER, not a failed read — and it
      # is what the walk gets when the pane's process exited between the pid read and this one. The
      # session read says which: gone = the lane ended mid-pass (a benign skip; recording
      # cannot-verify for every normal lane exit is the row operators learn to ignore), still listed =
      # the walk's own answer is unreadable, which is cannot-verify.
      sp=0; session_present "$s" || sp=$?
      skipped=$((skipped + 1))
      if [ "$sp" -eq 1 ]; then
        note "$s SKIP session is gone (the pane process exited)"
      else
        unverifiable=$((unverifiable + 1)); note "$s SKIP cannot read the process ancestry (cannot-verify)"
      fi
      continue
    fi
    # ── observation 1 ──
    c0="$(subtree_cpu_secs "$pid")"
    if [ "${c0:-NA}" = "NA" ]; then
      skipped=$((skipped + 1)); unverifiable=$((unverifiable + 1)); note "$s SKIP cannot read the process table (cannot-verify)"
      continue
    fi
    ls0="$(pid_ident "$pid")"
    # ── observation 2, after a real window ──
    "$SLEEP_BIN" "$REAP_SAMPLE_S"
    m1="$(mtime_epoch "$log")"
    c1="$(subtree_cpu_secs "$pid")"
    if [ -z "$m1" ] || [ "${c1:-NA}" = "NA" ]; then
      skipped=$((skipped + 1)); unverifiable=$((unverifiable + 1)); note "$s SKIP second observation unreadable (cannot-verify)"
      continue
    fi
    if [ "$m1" -gt "$m0" ]; then
      skipped=$((skipped + 1)); note "$s SKIP child is still writing (log advanced during the sample)"
      continue
    fi
    if [ "${c1:-0}" -gt "${c0:-0}" ]; then
      skipped=$((skipped + 1)); note "$s SKIP child is still working (cpu ${c0}s -> ${c1}s)"
      continue
    fi
    # ⛔ A DECREASE is not "no progress" either — it is proof the two readings are not COMPARABLE.
    # Cumulative CPU cannot shrink for a fixed process set, so a lower second reading means the
    # subtree changed under us: a member exited during the sample (taking its seconds with it), or the
    # bounded read was TRUNCATED at a record boundary (the measured cause of long reads on a loaded
    # cell). Both are cannot-verify; reading the fall as "unchanged" keeps the exact false-wedge route
    # this pass exists to remove, one branch over from the parse check — the only comparable reading is
    # an EQUAL one.
    if [ "${c1:-0}" -lt "${c0:-0}" ]; then
      skipped=$((skipped + 1)); unverifiable=$((unverifiable + 1))
      note "$s SKIP cpu went ${c0}s -> ${c1}s (the readings are not comparable, cannot-verify)"
      continue
    fi
    # The sampling window is where a budget is actually spent, so it is re-checked HERE: a pass that
    # has run out of its overall budget must not act on the evidence it happened to reach (§6.5.2).
    elapsed=$(( $(date +%s) - started ))
    if [ "$elapsed" -gt "$REAP_TIMEOUT" ]; then
      log "[reap] CANNOT-VERIFY: the read budget (${REAP_TIMEOUT}s) was spent while sampling $s — no action taken; the pass is partial"
      state_write reap 3 "cannot-verify: read budget ${REAP_TIMEOUT}s spent sampling $s; no action taken: $result"
      return 3
    fi
    if [ "$dry" = "--dry-run" ]; then
      would=$((would + 1)); note "$s WOULD REAP (silent ${age}s, cpu ${c0}s unchanged, no human)"
      continue
    fi
    # ── act ──
    # ⛔ The kill is a destructive step too: a stop that arrived while this pass was sampling must not
    # have a lane killed afterwards (README's claim covers every destructive call, so this is one).
    if cell_stopped_midpass; then
      log "[reap] STOP arrived during this pass — $s NOT killed"
      note "$s NOT killed (stop mid-pass)"
      break
    fi
    log "[reap] $s silent ${age}s, cpu ${c0}s unchanged -> killing session (pane_pid=${pid})"
    "$TMUX_BIN" kill-session -t "=$s" 2>/dev/null || true
    # ⛔ The kill is VERIFIED before anything is recorded or signalled. Counting a failed
    # `kill-session` as a reap writes a fix into the state record and into `status` that did not
    # happen: the lane is still wedged and the next pass reads "reaped" as "handled". The extra
    # TERM/KILL is skipped on that path too — a tmux refusal is a reason to report, never to signal
    # harder.
    sp=0; session_present "$s" || sp=$?
    if [ "$sp" -eq 3 ]; then
      skipped=$((skipped + 1)); unverifiable=$((unverifiable + 1))
      note "$s SKIP kill unverified (the tmux read failed) — cannot-verify; no signal sent, not counted as reaped"
      continue
    fi
    if [ "$sp" -eq 0 ]; then
      skipped=$((skipped + 1)); failed=$((failed + 1))
      note "$s KILL FAILED (the session is still present after kill-session) — the action did not take, not counted as reaped"
      continue
    fi
    # The extra TERM/KILL is fenced: only signal the pid if it still holds the incarnation whose
    # lstart we recorded. An off-fence or absent pid is an ABSTENTION, never a kill (#1178).
    ls1="$(pid_ident "$pid")"
    if [ -n "$ls0" ] && [ "$ls0" = "$ls1" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      "$SLEEP_BIN" 1
      ls1="$(pid_ident "$pid")"
      [ -n "$ls1" ] && [ "$ls1" = "$ls0" ] && kill -KILL "$pid" 2>/dev/null || true
    fi
    reaped=$((reaped + 1))
    result="${result}${result:+; }reaped $s"
  done
  [ -n "$result" ] || result="no harness session to judge"
  # ⛔ A pass in which a SAFETY gate could not be READ is cannot-verify, not a clean pass: "I skipped
  # every lane because ps is broken" must not read the same as "every lane was judged and left alone"
  # — that is the "looks alive while doing nothing" class this role exists to remove. A GENUINE
  # exclusion (no log, a real attached client, real human ancestry, a lane that is still writing)
  # stays a clean rc=0 skip.
  local pass_rc=0
  [ "$unverifiable" -gt 0 ] && pass_rc=3
  # ⛔ An action that did not take is a THIRD fact, and it is not a clean pass either: a `kill-session`
  # tmux refused leaves the lane wedged. rc=3 as well (the header's "an action it took could not be
  # verified to have taken effect"), named separately in the record so an operator can tell an
  # unreadable read from a refused kill.
  [ "$failed" -gt 0 ] && pass_rc=3
  # ⛔ ONE `state_write` PER PASS, AND IT CARRIES THE CENSUS (#2163 review, P3). A pre-census write sat
  # here and was superseded by the one below, so `passes=` (which `state_write` INCREMENTS) advanced
  # twice per pass, and the FIRST `[reap]` line an operator reads omitted `lanes=`/`zombie=`/
  # `unidentifiable=` — the three readings this role exists to publish. The rehearsal rule
  # (`--dry-run` never records a verdict) is applied at that single write below.
  # ── the census: lanes by EVIDENCE, and the box's zombies (#2163) ────────────────────────────────
  # `lanes=<live>/<total>` is the reading a session count cannot produce: a leaked wrapper + pi whose
  # pane died is invisible to `tmux ls`, and the string count (`ps | grep -c 'pi --model'`) counted
  # wrappers (76 for 14 working lanes, measured 2026-10-19). `zombie=<n>` sits in the SAME pass line
  # because a box full of corpses otherwise reads as busy. An unreadable census is `?`, never 0.
  local census="lanes=?/? zombie=?" proc_result="" proc_out="" proc_refusal=""
  if [ -n "$LANE_REAP_BIN" ]; then
    # 60s, not the 15s per-read bound: `count` resolves each lane's log, which on a 76-lane box is a
    # per-process lsof sweep. A census killed at 15s would print `?/?` on every busy box — an
    # instrument that fails exactly when it matters.
    # The tool's OWN budget is set BELOW the external bound, so a slow census is an abstention it
    # reports (`lanes=?/?`, exit 3) rather than a SIGKILL that leaves the pass with no answer at all.
    census="$(LANE_REAP_PASS_TIMEOUT=50 bounded 60 bash "$LANE_REAP_BIN" count 2>/dev/null)"
    case "$census" in
      lanes=*' 'zombie=*) ;;
      # ⛔ A READ THE PASS COULD NOT TAKE IS NOT A PASS (#2163 review, P2). Recording `?` in the line
      # while leaving rc=0 is the "looks alive while doing nothing" class this role exists to remove:
      # the census is the only instrument that sees the population the session pass cannot.
      # ⛔ AND IT IS COUNTED ONCE, BY THE NEXT CASE (#2163 review cycle 8, P2). This arm REWRITES the
      # census into exactly the `?`-numerator shape the arm below escalates on, so incrementing
      # `unverifiable` here as well counted ONE failed read twice: the shipped pass line read
      # `unverifiable=2` for a single garbled `count`, and `unverifiable=` is the field an operator
      # reads to decide whether the instrument is trustworthy. Rewrite only; the arm below owns the
      # count and the rc — and reverting that one turns the suite red (185 PASS / 2 FAIL, measured), so
      # the escalation the classifier owns is pinned.
      *) census="lanes=?/? zombie=?" ;;
    esac
    # A `?` NUMERATOR with readable totals is the same abstention one lane at a time (`count` exits 3
    # when a liveness age could not be read); it must not read as a clean pass either.
    case "$census" in lanes='?'/*) unverifiable=$((unverifiable + 1)); pass_rc=3 ;; esac
    # ── the PROCESS pass: the population the session pass above cannot see ─────────────────────────
    # Armed with the SAME dry/apply posture as this pass: `--dry-run` reports, the armed role acts.
    # The reaper keeps its own gates and its own default (dry run); this call only decides whether
    # the armed role is allowed to apply them.
    # ⛔ Bounded by REAP_TIMEOUT, NOT READ_CALL_TIMEOUT: the reaper sleeps its own CPU SAMPLE WINDOW
    # (default 30s), so the 15s per-read bound would kill the pass before it judged anything — an
    # inert reaper that looks scheduled. REAP_TIMEOUT is the budget this role already gives its whole
    # session pass.
    # ⛔ THE REAPER'S OWN LINES ARE THE ONLY EVIDENCE OF *WHY* IT JUDGED NOTHING (#2163 review r3,
    # P2). Keeping `tail -1` alone discarded every per-tree `REFUSE`/`SKIP` reason, so `[reap]` — the
    # operator's log — showed a summary with no cause, and a refusal could not be told from an idle
    # box. The full output is kept, the summary is the LAST line (as before), and the FIRST refusal is
    # logged beside it.
    if [ "$dry" = "--dry-run" ]; then
      proc_out="$(LANE_REAP_LOG="$O/state/lane-reap.log" LANE_REAP_LOCK="$O/state/lane-reap" \
        bounded "$REAP_TIMEOUT" bash "$LANE_REAP_BIN" reap 2>&1)"
    else
      proc_out="$(LANE_REAP_LOG="$O/state/lane-reap.log" LANE_REAP_LOCK="$O/state/lane-reap" \
        bounded "$REAP_TIMEOUT" bash "$LANE_REAP_BIN" reap --apply 2>&1)"
    fi
    proc_result="$(printf '%s\n' "$proc_out" | tail -1)"
    proc_refusal="$(printf '%s\n' "$proc_out" | grep -E '^  (REFUSE|SKIP|FENCE-ABSTAIN|CANNOT-VERIFY)' | head -1)"
    case "$proc_result" in
      *"CANNOT-VERIFY"*) unverifiable=$((unverifiable + 1)); pass_rc=3 ;;
      # ⛔ AN ABSTAINING PASS IS NOT AN IDLE ONE (#2163 review, P2). lane-reap.sh counts every tree it
      # could not judge (a descriptor it could not read, an ancestry it could not classify, a CPU delta
      # that went backwards, a log age it could not stat) into `abstained=`, and exits 3. Only the
      # literal CANNOT-VERIFY token used to escalate here, so a pass reporting
      # `reaped=0 refused=0 abstained=4` was indistinguishable from a quiet, healthy reaper — the
      # "looks alive while doing nothing" class this role exists to remove.
      *abstained=[!0]*) unverifiable=$((unverifiable + 1)); pass_rc=3 ;;
      # ⛔ AN UNUSABLE PIPE IDENTITY IS AN ABSTENTION, BUT NOT A FAILED READ (#2163 review r5, P3).
      # `unidentifiable=` counts trees whose descriptors were READ and whose pipe simply has no
      # per-pipe name on this platform (`lsof 4.95` prints the literal `pipe`), so a `tee` beside the
      # tree cannot be shown to be its writer. The reaper exits 3 for it, and this arm reads the FIELD
      # too — but the point of the separate field is that the escalated cause must NAME IDENTITY. It
      # used to arrive as `abstained=`, whose per-tree line said "the descriptors could not be read";
      # the operator then chased an lsof/permissions fault that never happened on a box where every
      # read succeeded. The first refusal line logged below now carries `pipe-identity-unusable`.
      # ⛔ IT MUST PRECEDE THE `abstained=0` ARM BELOW: with an abstention-free line the catch-all
      # would record this pass as clean.
      *unidentifiable=[!0]*) unverifiable=$((unverifiable + 1)); pass_rc=3 ;;
      # ⛔ …AND NEITHER IS AN `inert` PASS (#2163 review r3, P2). `inert=` counts the LANES a POLICY
      # refused (a resolved lane log under a human or unclassifiable ancestry). On a cell EVERY lane is
      # `ancestry-unknown`, so the armed pass judged zero trees, printed `trees=0/0 … refused=1
      # abstained=0`, exited 0 and this role recorded a healthy reaper every pass. The reaper now
      # exits 3 for that shape too; this arm reads the FIELD as well, so the escalation does not depend
      # on a consumer ever checking the reaper's exit code (the `bounded | tail` shape loses it, and
      # `--json`/summary parsing is what this role actually has in hand).
      # ⛔ BUT ONLY THE PASS THAT JUDGED NOTHING (#2163 review r4, P2). `inert=` is a POLICY count, not
      # a failure: `lane-reap.sh` returns 3 for it only when `total == 0 && inert > 0`, and returns 0
      # for a pass that judged trees while refusing a human-owned one beside them (its own
      # `INERT-MIXED` leg pins that). Escalating every non-zero `inert=` therefore wrote
      # `reap FAILED rc=3` every pass over a pass the reaper calls clean — on any box with one
      # human-owned or `ancestry-unknown` lane. The arm is the INERT PASS's SHAPE (`trees=0/0`: the
      # same `total == 0` the reaper tests), never the field alone.
      *inert=[!0]*)
        case "$proc_result" in
          # ⛔ A POLICY VERDICT, NOT A FAILED READ (rc=4, #2163 review r8, P1). `3` means cannot-verify
          # — a read that FAILED, which a consumer must escalate — and this shape is the recorded cell
          # steady state (§11.4): the policy refused every lane because gate 2 requires positive fleet
          # evidence and a cell's ancestry carries none. Recording 3 here made the doctor role red for
          # ever (`role_row` → `status` rc=1) AND collapsed a genuine restart failure into the same
          # number. It is recorded as its own verdict below (`pass_rc=4`), so it is still never a clean
          # `reaped=0` while it says exactly what it is.
          *"trees=0/0"*|*'"trees":"0/0"'*) inert_pass=1 ;;
        esac ;;
      *abstained=0*) ;;
      *) unverifiable=$((unverifiable + 1)); pass_rc=3 ;;
    esac
    log "[reap] proc: ${proc_result:-<no output>}"
    [ -n "$proc_refusal" ] && log "[reap] proc-first: $proc_refusal"
  else
    log "[reap] WARN: lane-reap.sh NOT FOUND (looked in $O and beside this script) — the leaked lane processes were NOT judged; re-run 'start' to seed it"
  fi
  local proc_note=""
  [ -n "$proc_result" ] && proc_note="; proc: $proc_result"
  # ⛔ A POLICY-INERT PROCESS PASS IS ITS OWN VERDICT (rc=4), NEVER A FAILED ONE (#2163 review r8, P1).
  # It is promoted ONLY where nothing failed: a real abstention (3) still dominates, so this can never
  # hide a read that could not be taken — it only stops a WORKING policy from reading as a fault.
  [ "$inert_pass" = "1" ] && [ "$pass_rc" -eq 0 ] && pass_rc=4
  # The FIRST refusal travels with the state line too: the summary says how many, never why, and an
  # operator reading `state_write` is the operator who needs the why.
  [ -n "$proc_refusal" ] && proc_note="$proc_note; first: ${proc_refusal#  }"
  if [ "$dry" = "--dry-run" ]; then
    state_write_rehearsal reap "$pass_rc" "$census seen=$seen reaped=$reaped would=$would skipped=$skipped unverifiable=$unverifiable failed=$failed — $result$proc_note"
  else
    state_write reap "$pass_rc" "$census seen=$seen reaped=$reaped would=$would skipped=$skipped unverifiable=$unverifiable failed=$failed — $result$proc_note"
  fi
  log "[reap] $census seen=$seen reaped=$reaped would=$would skipped=$skipped unverifiable=$unverifiable failed=$failed${proc_result:+; proc: $proc_result}"
  return "$pass_rc"
}

# ── MERGE (the standard rail, never an override) ────────────────────────────────────────────────
# The rail is the ONLY thing that merges. This role decides WHEN it is worth calling:
#   * the PR is open, non-draft;
#   * a clean attestation exists for THIS head (the shipped record-review.sh artifact), so the rail
#     is not spent on a PR nobody reviewed;
#   * the same head has not just been refused (MERGE_RETRY_S). A refusal is recorded with its reason
#     and NOT retried blind; a push moves the head and re-arms it.
# ⛔ It does not read the check surface itself. The rail does that, with its own allow-list polarity
# and head/merge-ref binding; a second opinion here is the two-readers defect (#1872/#1714). The
# pre-filter is a COST gate, never an authorization — `admin-merge.sh` re-verifies everything.
rail_path() {
  local c
  # ⛔ `$SELF_DIR/../admin-merge.sh` is the SHIPPED location: the rail is `scripts/admin-merge.sh`, and
  # this file lives in `scripts/orchestrator-harness/` (or in `$O`, seeded from there) — exactly the
  # relationship the worktree reaper's search already handles. `$SELF_DIR/admin-merge.sh` alone was a
  # dead path, so a standalone `merge` verb with no DOCTOR_SUPERVISOR found no rail at all and recorded
  # cannot-verify while the rail sat one directory up.
  for c in "${DOCTOR_ADMIN_MERGE:-}" \
           "${SUPERVISOR:+$(dirname "$SUPERVISOR")/admin-merge.sh}" \
           "$SELF_DIR/../admin-merge.sh" \
           "$SELF_DIR/admin-merge.sh" \
           "$REPO/scripts/admin-merge.sh" \
           "$CELL_HOME/.pi/agent/scripts/admin-merge.sh"; do
    [ -n "$c" ] && [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# THREE-VALUED, like every other read in this doctor (agent-infra#1989):
#   0 — a clean attestation for <pr> at <head> exists in THIS cell's review store
#   1 — no clean attestation for this head (the ordinary skip: unreviewed, stale, or refused)
#   3 — CANNOT-VERIFY: the store itself is unreadable, or an attestation file is corrupt/unparseable.
#       ⛔ The distinction is the whole point: an unreadable store used to render exactly like "no
#       attestation", so every candidate was skipped and the pass recorded a clean `nothing to land`
#       while reviewed PRs silently never landed — the cannot-verify-as-empty class the open-PR read
#       already refuses to commit (rc=3, never an empty queue).
attestation_clean() {
  local pr="$1" head="$2" dir="$CELL_HOME/.pi/agent/reviews" slug f rc
  [ -d "$dir" ] || return 1            # no store yet = no attestations, not a fault
  # A directory we cannot read/search answers "nothing clean" for EVERY PR — refuse to believe it.
  [ -r "$dir" ] && [ -x "$dir" ] || return 3
  slug="$(printf '%s' "$OR" | tr '/' '-')"
  for f in "$dir/${slug}-${pr}.json" "$dir/${pr}.json"; do
    [ -e "$f" ] || continue
    # Present but unreadable (permissions) is not "no attestation" either.
    [ -f "$f" ] && [ -r "$f" ] || return 3
    # ⛔ The PARSER being unusable is cannot-verify too. `python3` missing or non-executable exits
    # 126/127, which matched no arm below and fell through to "no clean attestation" — a clean
    # `nothing to land` while every reviewed PR was skipped. The open-PR read already refuses this.
    command -v python3 >/dev/null 2>&1 || return 3
    python3 - "$f" "$head" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
except Exception:
    sys.exit(3)      # corrupt/unparseable — cannot verify, NOT "not clean"
if not isinstance(d, dict):
    sys.exit(3)
h = str(d.get("head_sha") or "")
v = str(d.get("verdict") or "").lower()
sys.exit(0 if h == sys.argv[2] and v in ("clean", "clean-micro", "clean-low") else 1)
PY
    rc=$?
    case "$rc" in
      0) return 0 ;;
      3) return 3 ;;   # one corrupt record for this PR: cannot verify this candidate
      # A parser that ran but could not be executed (permissions, a broken interpreter) is the same
      # class: the record was not read, so nothing was verified.
      126|127) return 3 ;;
    esac
  done
  return 1
}

attempt_epoch() { # <pr> <head> -> the last attempt epoch for this exact head, or empty
  awk -v p="$1" -v h="$2" '$1 == p && $2 == h { e = $3 } END { if (e != "") print e }' \
    "$ROLES_DIR/merge.attempts" 2>/dev/null
}
attempt_record() { # <pr> <head> [<rc>]
  mkdir -p "$ROLES_DIR" || return 0
  printf '%s %s %s %s\n' "$1" "$2" "$(date +%s)" "${3:-}" >> "$ROLES_DIR/merge.attempts" 2>/dev/null || true
  # Bounded history: the file only exists to suppress a blind retry, and an unbounded one becomes a
  # disk leak on exactly the verb that exists to stop them.
  tail -n 400 "$ROLES_DIR/merge.attempts" > "$ROLES_DIR/merge.attempts.tmp" 2>/dev/null \
    && mv -f "$ROLES_DIR/merge.attempts.tmp" "$ROLES_DIR/merge.attempts" 2>/dev/null || true
}

run_merge() {
  begin_pass
  # ${1:-}: NO mode means a LIVE pass (an empty string never equals `--dry-run`). An ABSENT or
  # empty `$1` MUST be survivable — a bare `"$1"` here is what killed the scheduler on its first
  # tick (#2424), and the loop still asks this role to run with an empty mode on every schedule;
  # see "POSITIONAL PARAMETERS: WHICH MAY BE ABSENT" before run_role_pass for the file-wide audit.
  local dry="${1:-}" rail err prs line pr head draft now ep aep arc cl opid merge_parse_failed=0 started ws_only
  local candidates=0 attempted=0 landed=0 skipped=0 unverifiable=0 result="" out rc
  if [ -z "$OR" ]; then
    log "[merge] CANNOT-VERIFY: \$OR is unset (the queue target is resolved by the supervisor)"
    state_write merge 3 "cannot-verify: OR unset"; return 3
  fi
  rail="$(rail_path)" || {
    log "[merge] CANNOT-VERIFY: admin-merge.sh not found (looked beside the supervisor, $SELF_DIR, $REPO/scripts, $CELL_HOME/.pi/agent/scripts)"
    state_write merge 3 "cannot-verify: admin-merge.sh not found"; return 3
  }
  if ! command -v "$GH_BIN" >/dev/null 2>&1; then
    log "[merge] CANNOT-VERIFY: gh is not on PATH"
    state_write merge 3 "cannot-verify: gh missing"; return 3
  fi
  mkdir -p "$ROLES_DIR" || true
  # ⛔ The clock starts BEFORE the read, and the read itself is bounded: otherwise a hung `gh api`
  # sits outside MERGE_BUDGET_S and blocks the whole loop — including the doctor's supervision and
  # the reap pass behind it on the one sequential loop.
  started="$(date +%s)"
  err="$ROLES_DIR/.merge-read.$$"
  prs="$(bounded "$MERGE_READ_TIMEOUT" "$GH_BIN" api "repos/$OR/pulls?state=open&per_page=$MERGE_MAX_PRS" 2>"$err")"
  rc=$?
  # ⛔ NEVER `[ -z "${prs//[[:space:]]/}" ]` HERE (the same hole `cleanup-stale-branches.sh:694`
  # documents). The pattern substitution is SUPERLINEAR, and a real open-PR answer is large. Measured
  # on THIS box, bash 5.2.21, one-builtin cost with nothing else running: 322 KiB (330,246 B) took
  # 14.5 s, 843 KiB (862,802 B — the suite's fixture) took 99.8 s — 2.6x the bytes for 6.9x the time,
  # i.e. quadratic, not linear. Both with the merge lock held and no syscalls, so `MERGE_BUDGET_S`
  # cannot bound it: a `timeout` cannot interrupt a builtin, so the whole sequential loop (doctor,
  # then reap, then hygiene) stalls behind it on the first tick of every cell. The `case` glob answers
  # "empty or whitespace-only" in 9 ms (322 KiB) / 26 ms (843 KiB) and matches exactly the same set
  # (POSIX `[:space:]`); a NUL cannot reach here (command substitution strips it).
  ws_only=0
  case "$prs" in *[![:space:]]*) ;; *) ws_only=1 ;; esac
  if [ "$rc" -ne 0 ] || [ "$ws_only" = 1 ]; then
    local why; why="$(head -3 "$err" 2>/dev/null | tr '\n' ' ')"
    rm -f "$err"
    log "[merge] CANNOT-VERIFY: the open-PR read failed (rc=$rc) ${why:+— $why}"
    state_write merge 3 "cannot-verify: open-PR read failed rc=$rc"
    return 3
  fi
  rm -f "$err"
  now="$(date +%s)"
  if [ $(( now - started )) -gt "$MERGE_BUDGET_S" ]; then
    log "[merge] CANNOT-VERIFY: the merge budget (${MERGE_BUDGET_S}s) was spent reading the queue — no candidate was tried"
    state_write merge 3 "cannot-verify: merge budget ${MERGE_BUDGET_S}s spent on the open-PR read"
    return 3
  fi
  # Tab-separated triples, parsed ONCE into a file: a parse failure is CANNOT-VERIFY (rc 3), never an
  # empty list ("nothing to land"). python3 is a cell runtime dependency (cmd_check refuses a cell
  # without it). One REST read, bounded by MERGE_MAX_PRS — no pagination, so the role's cost cannot
  # grow with the fleet (the #1988 class).
  local rawf="$ROLES_DIR/.merge-json.$$" parsed="$ROLES_DIR/.merge-parsed.$$"
  printf '%s' "$prs" > "$rawf" || { log "[merge] CANNOT-VERIFY: cannot stage the open-PR answer"; state_write merge 3 "cannot-verify: cannot stage read"; return 3; }
  if ! python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
except Exception:
    sys.exit(1)
if not isinstance(d, list):
    sys.exit(1)
for p in d:
    if not isinstance(p, dict):
        continue
    print("%s\t%s\t%s" % (p.get("number"), ((p.get("head") or {}).get("sha") or ""), "1" if p.get("draft") else "0"))
' "$rawf" > "$parsed"; then
    rm -f "$rawf" "$parsed"
    log "[merge] CANNOT-VERIFY: the open-PR answer was not a JSON list — nothing merged"
    state_write merge 3 "cannot-verify: open-PR answer unparseable"
    return 3
  fi
  rm -f "$rawf"
  while IFS="$(printf '\t')" read -r pr head draft; do
    [ -n "${pr:-}" ] || continue
    case "$pr" in ''|*[!0-9]*) continue ;; esac
    [ "$draft" = "1" ] && { skipped=$((skipped + 1)); continue; }
    candidates=$((candidates + 1))
    # Before each candidate, not once at the start: the budget exists to bound the PASS, whose cost
    # is per candidate. A spent budget ends the pass as rc=3 (partial), naming what was not tried.
    if [ $(( $(date +%s) - started )) -gt "$MERGE_BUDGET_S" ]; then
      log "[merge] CANNOT-VERIFY: the merge budget (${MERGE_BUDGET_S}s) was spent — #$pr and the rest of the queue were NOT tried"
      rm -f "$parsed"
      state_write merge 3 "cannot-verify: merge budget ${MERGE_BUDGET_S}s spent before #$pr; candidates=$candidates attempted=$attempted landed=$landed — $result"
      return 3
    fi
    attestation_clean "$pr" "$head"; arc=$?
    if [ "$arc" -eq 3 ]; then
      unverifiable=$((unverifiable + 1))
      log "[merge] CANNOT-VERIFY: the review store ($CELL_HOME/.pi/agent/reviews) is unreadable or its attestation for #$pr is corrupt — the PR was NOT considered"
      result="${result}${result:+; }cannot-verify #$pr"
      skipped=$((skipped + 1)); continue
    fi
    if [ "$arc" -ne 0 ]; then
      skipped=$((skipped + 1)); continue
    fi
    aep="$(attempt_epoch "$pr" "$head")"
    # ⛔ NOT num_ok: an epoch is TEN digits and num_ok deliberately bounds its operands at nine. A
    # digit shape test is all this needs — the value is our own `date +%s`, never operator input.
    case "${aep:-}" in
      ''|*[!0-9]*) ;;
      *) ep=$((now - aep))
         if [ "$ep" -lt "$MERGE_RETRY_S" ]; then
           skipped=$((skipped + 1)); continue
         fi ;;
    esac
    if [ "$dry" = "--dry-run" ]; then
      log "[merge] WOULD call the rail on #$pr at ${head:0:12} (clean attestation recorded)"
      result="${result}${result:+; }would-rail #$pr"; attempted=$((attempted + 1)); continue
    fi
    # ⛔ A stop that arrived while this pass was reading has to WIN: the rail is the destructive step,
    # and bash defers the loop's TERM trap while it waits on a foreground child, so a stop that lands
    # mid-rail cannot recall it. Refusing to START one is the part this pass controls — and it is the
    # difference between "stop returned 0 and no PR was landed afterwards" and "stop returned 0 and a
    # merge landed two minutes later".
    if cell_stopped_midpass; then
      log "[merge] STOP arrived during this pass — #$pr and the rest of the queue were NOT railed"
      result="${result}${result:+; }stopped mid-pass (no rail for #$pr or after)"
      break
    fi
    # ── the standard rail, executed as shipped ──
    out="$O/logs/doctor-merge-$pr.log"
    : > "$out" 2>/dev/null || true   # per-candidate: a stale log must not decide this pass's verdict
    # ⛔ FROM THE TARGET CHECKOUT. The loop's cwd is the HARNESS (start_doctor_loop's `-c`), and the
    # rail's flake-residual reproduction runs `git -C "$PWD" worktree add … <base>` — on a cell whose
    # queue target is not agent-infra that base is not in the harness checkout, so the reproduction
    # fails closed and the flake-clearing half of the rail is silently broken. `merge-one.sh` wraps
    # the same call in `( cd "$REPO" && … )` for exactly this reason.
    # ⛔ A MISSING checkout is not a rail refusal. `( cd "$REPO" && … )` fails rc=1 without ever running
    # the rail, and that used to fall into the generic REFUSED branch: the pass recorded a clean 0, the
    # failure was mislabelled as the rail's verdict, and the cooldown then suppressed the PR for
    # MERGE_RETRY_S — a vanished checkout reading green in `status` while nothing lands.
    # READABLE as well as present: a checkout whose execute/search bit is revoked still passes `-d`,
    # and `cd` into it then fails rc=1 without running the rail — the same false green by a narrower
    # door.
    if [ ! -d "$REPO" ] || [ ! -x "$REPO" ]; then
      log "[merge] CANNOT-VERIFY: the checkout $REPO is missing or not readable — the rail was NOT invoked for #$pr"
      result="${result}${result:+; }cannot-verify #$pr (no checkout)"
      unverifiable=$((unverifiable + 1))
      skipped=$((skipped + 1)); continue
    fi
    # ⛔ THE SAME PER-PR CLAIM THE CONTROLLER TAKES (`merge-one.sh`). The local noclobber lock is what
    # stops two reviewers on ONE box from racing the same head — duplicate evidence comments, duplicate
    # record-review writes, and one worker's needsfix marker landing after the other merged. The doctor
    # runs in its own loop with its own lock, so without this a PR with a clean attestation could be
    # railed by the doctor and by `merge-one.sh` at the same moment. (The CROSS-BOX claim stays
    # merge-one.sh's: it is a network push, it is fail-open by design, and every side effect on this
    # path is idempotent per head — so the doctor takes the local lock, and the rail re-verifies head
    # and checks itself.)
    mkdir -p "$O/state" 2>/dev/null
    cl="$O/state/mergeclaim-$pr.lock"
    claim_take() { ( set -o noclobber; printf '%s\n' "$$" > "$cl" ) 2>/dev/null; }
    if ! claim_take; then
      opid="$(cat "$cl" 2>/dev/null)"
      case "${opid:-}" in ''|*[!0-9]*) opid=0 ;; esac
      if [ "$opid" -gt 0 ] && kill -0 "$opid" 2>/dev/null; then
        log "[merge] #$pr is claimed by a live worker (pid $opid) — not railing it from this role"
        result="${result}${result:+; }skipped #$pr (claimed by pid $opid)"
        skipped=$((skipped + 1)); continue
      fi
      rm -f "$cl" 2>/dev/null
      if ! claim_take; then
        log "[merge] #$pr claim race — not railing it this pass"
        result="${result}${result:+; }skipped #$pr (claim race)"
        skipped=$((skipped + 1)); continue
      fi
    fi
    ( cd "$REPO" && run_bounded "$RAIL_TIMEOUT" bash "$rail" "$pr" --repo "$OR" ) >>"$out" 2>&1
    rc=$?
    # Release only what is still OURS: a rail that outlived us must not have its claim deleted.
    [ "$(cat "$cl" 2>/dev/null)" = "$$" ] && rm -f "$cl" 2>/dev/null
    attempted=$((attempted + 1))
    if [ "$rc" -eq 0 ]; then
      landed=$((landed + 1))
      # A LANDED PR CARRIES NO REFUSAL (review P3, 2026-10-21): the record is head-bound, and this
      # head is now merged. `merge-one.sh` clears the same pair on its merged arm; leaving it here
      # would leave a verdict on disk for a PR that no longer exists in the queue.
      command -v rail_refusal_clear >/dev/null 2>&1 && rail_refusal_clear "$O" "$pr" 2>/dev/null
      rm -f "$O/state/redfix-$pr" 2>/dev/null || true
      rm -f "$O/state/fixgate-$pr-"* 2>/dev/null || true
      log "[merge] #$pr LANDED through the rail at ${head:0:12}"
      result="${result}${result:+; }landed #$pr"
    elif grep -q 'merge_unreadable' "$out" 2>/dev/null; then
      # ⛔ The rail exits 1 for a REFUSAL *and* for `BLOCK [merge_unreadable]`, where it could not read
      # the post-merge state and says in its own words that this is NOT a claim the merge did not
      # happen. Recording that as a clean "REFUSED" both hides a read failure and suppresses the head
      # for MERGE_RETRY_S at a head that may well have merged.
      unverifiable=$((unverifiable + 1))
      log "[merge] CANNOT-VERIFY: the rail could not read the merge state for #$pr (BLOCK merge_unreadable) — not a refusal, and NOT cooled down on a guess"
      result="${result}${result:+; }cannot-verify #$pr (rail merge_unreadable)"
    else
      local why; why="$(tail -2 "$out" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
      # ⛔ THE CLASSIFICATION IS A PREDICATE, NOT AN ENUMERATION. A list can only ever name the rcs
      # somebody has SEEN, and every death it leaves out takes the `*)` arm below — which records the
      # rail's REFUSAL (`attempt_record`, suppressing that head for MERGE_RETRY_S) and returns a CLEAN
      # pass at a head that may have merged. That is the fail-open this whole branch exists to close,
      # reachable by any signal this list did not happen to name.
      #   * ANY rc >= 128 is a SIGNAL death (128+N, N = the signal number), and every one of them is
      #     the same unknown outcome:
      #       129 = SIGHUP — what a rail's foreground child gets when its tmux session dies;
      #       130 = SIGINT;  134 = SIGABRT;  139 = SIGSEGV;  141 = SIGPIPE (a `grep -q`/`head`
      #       reader that closed the pipe on it);
      #       137 = 128+9, the `-k` KILL that ended it. This is the COMMON bound case, not an exotic
      #         one: the comment two screens up says the KILL is what ends a rail blocked on a
      #         foreground `gh`/`git`, and `timeout` reports the KILL's status, not the TERM it tried;
      #       143 = 128+15, from the `bounded` fallback (no timeout(1) on the box), which returns
      #         `wait`'s status for a child it TERMed itself.
      #     The `bounded` fallback propagates the child's status VERBATIM, so all of these reach here.
      #   * 124 = the rail was KILLED at its own bound; 125 = timeout(1) itself failed, so it never ran
      #     the rail at all; 126/127 = it could not be executed. These are timeout(1)'s OWN codes and
      #     all sit BELOW 128, so they are named explicitly.
      # The merge may or may not have landed and the rail never gave a verdict, so this is NOT the
      # rail's refusal (which is DATA on a clean pass) but an action whose OUTCOME IS UNKNOWN.
      # The rail's own deliberate exits are 0/1/2 (`scripts/admin-merge.sh`; its only `4` is a comment
      # about pytest), so neither half of this predicate can swallow an intended refusal.
      local unanswered=0
      case "$rc" in
        124|125|126|127) unanswered=1 ;;                        # timeout(1)'s own codes
        *) [ "$rc" -ge 128 ] && unanswered=1 ;;                 # any signal death (128+N)
      esac
      if [ "$unanswered" -eq 1 ]; then
        unverifiable=$((unverifiable + 1))
        log "[merge] CANNOT-VERIFY: the rail for #$pr did not answer (rc=$rc) — ${why:-no output}; the merge may or may not have landed"
        result="${result}${result:+; }cannot-verify #$pr (the rail did not answer, rc=$rc)"
      else
        attempt_record "$pr" "$head" "$rc"
        # [railrefusal-doctor:begin] (extracted and DRIVEN by red-fixer.test.sh — keep the markers)
        # ⛔ THE REFUSAL IS RECORDED FOR THE CONTROLLER'S RED-FIXER ROLE (agent-infra#2223). `$out` is
        # TRUNCATED per candidate above, so it holds THIS PR's rail output and nothing else — no
        # byte-offset is needed here (unlike merge-one.sh's append-only log). The class decides
        # whether a fixer lane is spawned; `merge.attempts` above only cools this head down, which
        # suppresses the RETRY, not the repair — a cooled-down red tree still needs a lane.
        _rf_att="$(grep -c "^$pr $head " "$ROLES_DIR/merge.attempts" 2>/dev/null || true)"
        case "${_rf_att:-}" in ''|*[!0-9]*) _rf_att=0 ;; esac
        _rf_ovr=0; [ -n "${AGENT_ADMIN_MERGE_OVERRIDE:-}" ] && _rf_ovr=1
        _rf_cls=""
        if command -v rail_refusal_record >/dev/null 2>&1; then
          # The status is the WRITE's: a reader that logs "recorded" for a write that failed is how
          # the controller ends up with nothing to act on while the log says otherwise (review P2).
          _rf_cls="$(rail_refusal_record "$O" "$pr" "$head" "$_rf_att" "$out" "$_rf_ovr" 2>/dev/null)" || _rf_cls=""
        fi
        if [ -n "${_rf_cls:-}" ]; then
          log "[merge] #$pr REFUSED by the rail rc=$rc — ${why:-no output}; recorded (class=$_rf_cls override=$_rf_ovr), not retried for ${MERGE_RETRY_S}s at this head"
        else
          log "[merge] #$pr REFUSED by the rail rc=$rc — ${why:-no output}; ⚠️ NOT RECORDED (rail-refusal.sh missing/unusable, or \$O/state unwritable), so no red-fixer can be spawned from it"
        fi
        result="${result}${result:+; }REFUSED #$pr rc=$rc"
        # [railrefusal-doctor:end]
      fi
    fi
  done < "$parsed"
  rm -f "$parsed"
  # A pass that could not read the attestation store has NOT established "nothing to land": the
  # candidates it skipped for that reason were never considered. rc=3 makes `status` say so.
  if [ "$unverifiable" -gt 0 ]; then
    state_write merge 3 "cannot-verify: $unverifiable candidate(s) could not be verified (review store, checkout or rail state unreadable); candidates=$candidates attempted=$attempted landed=$landed skipped=$skipped — $result"
    log "[merge] CANNOT-VERIFY: $unverifiable candidate(s) could not be verified this pass"
    return 3
  fi
  [ -n "$result" ] || result="nothing to land"
  # ⛔ A REHEARSAL IS NOT A VERDICT: `--dry-run` calls no rail, so its rc=0 cannot clear a stored
  # "the rail did not answer" (or a failed read) — that is the state a human must look at.
  if [ "$dry" = "--dry-run" ]; then
    state_write_rehearsal merge 0 "candidates=$candidates attempted=$attempted landed=$landed skipped=$skipped — $result"
  else
    state_write merge 0 "candidates=$candidates attempted=$attempted landed=$landed skipped=$skipped — $result"
  fi
  log "[merge] candidates=$candidates attempted=$attempted landed=$landed skipped=$skipped"
  return 0
}

# ── HYGIENE (the disk the cell fills without noticing) ───────────────────────────────────────────
# MEASURED: a machine-global `uv` cache reached 7.1 GB and one cell went 258 MB → dispatch refused
# (#1987); before that, an abandoned 5.8 GB worktree. The sinks are pruned here, with the shipped
# tools and the shipped gates — this role adds the SCHEDULE, not another reaper.
#
# ⛔ WHAT #2573 ADDED, AND WHY IT MATTERED MORE THAN THE SCHEDULE. Three sinks were outside every
# pass, and the sweep that DID exist disabled itself exactly when the box was busiest:
#   * `/tmp/cloud-cell-<pid>.<rand>` — this family's own `mktemp -d` dirs, kept for the life of the
#     box because a run killed by ENOSPC never reaches its trap;
#   * docker images/volumes no container is using (cell-3 held 24.9 GB of images and 5.2 GB of
#     volumes while lanes died of ENOSPC);
#   * the worktree-root cache sweep, which ran only when NO worker session was live — i.e. it
#     declined to reclaim precisely when the box was busiest, and an unreadable session list had the
#     same effect.
# The rule those three share is the brief's, and it is not negotiable: RECLAIM ONLY ON PROOF OF
# IDLENESS, STATE THE PROOF IN THE LOG, AND REPORT ANYTHING UNCLEAR INSTEAD OF REAPING IT. Evidence
# beats tidiness — a candidate with diagnostic value stays.
#
# ⛔ EVERY SAVINGS CLAIM IS A `df` DELTA. A `du` sum is not space the filesystem got back: MEASURED
# the same night, `du -sm` read 4,115 MB on a directory whose contents summed to ~22 MB, and free
# space on these boxes OSCILLATES by GBs inside a minute (cell-3: 6570 → 3341 → 2411 MB in 30 s), so
# one sample is not a state either. The reapers keep their own no-`du` rule; this role reports the
# filesystem's own answer, signed, and never clamps a negative delta to zero.

# Each sub-sweep leaves its RESULT FRAGMENT in HYG_FRAG and its VERDICT in HYG_SUB_RC (0 = the step
# ran, or was deliberately not needed; 3 = cannot-verify) — the same split the role's record uses, so
# a step that could not run can never be folded into a clean pass. ⛔ NOT on stdout and NOT read back
# through `$( … )`: a command substitution runs in a SUBSHELL, so the verdict assigned inside it is
# lost and every failed sub-step would arrive at the caller as rc=0 (measured while building this).
# Every destructive call goes through the pass's STOP fence (`cell_stopped_midpass`) and is VERIFIED
# afterwards: the artifact, never the send.
HYG_SUB_RC=0
HYG_FRAG=""

# `df` in MiB, empty when unreadable — every caller reads empty as "no delta can be claimed".
hyg_df_mb() { free_mb "${1:-$CELL_HOME}"; }

# "<before>MB → <after>MB (±NMB)", or the abstention. Signed on purpose: a NEGATIVE delta is the
# truth on a box another lane is writing to, and printing "+0" there would be the same lie inverted.
hyg_df_delta() { # <before> <after>
  if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    printf 'df UNREADABLE (%s → %s) — no delta can be claimed' "${1:-?}" "${2:-?}"
    return 0
  fi
  printf '%sMB → %sMB (%+dMB)' "$1" "$2" "$(( $2 - $1 ))"
}

# ── (1) THE TEMP DIRS THIS FAMILY LEAVES BEHIND (agent-infra#2573) ───────────────────────────────
# PROOF REQUIRED, all three, and each is named in the log:
#   a. the pid its NAME carries is not alive (`kill -0` — exact, because the name carries it);
#   b. nothing has been written into it for HYGIENE_TMP_MIN_AGE_S (the name is not always a pid —
#      see the config block — so a recycled pid must not be the only evidence);
#   c. it is a real directory, not a symlink (we never follow one out of $TMPDIR).
# ANYTHING UNCLEAR IS REPORTED: no pid in the name, a pid we may not probe (EPERM), an unreadable
# mtime. A live pid is never touched.
hygiene_tmp_sweep() { # <dry>; fragment in HYG_FRAG, verdict in HYG_SUB_RC
  local dry="${1:-}" root d name tok mt age now kerr why walk=""
  local reaped=0 kept=0 failed=0 would=0 df_before df_after
  root="${HYGIENE_TMP_DIR:-${TMPDIR:-/tmp}}"
  HYG_SUB_RC=0
  HYG_FRAG=""
  if [ ! -d "$root" ]; then HYG_FRAG="temp: $root absent"; return 0; fi
  # ⛔ UNREADABLE IS NOT EMPTY. Without this, a root this pass may not list produces the same "0 reaped,
  # 0 left" as a clean one, and the role reports a sweep it never performed.
  if [ ! -r "$root" ] || [ ! -x "$root" ]; then
    log "[hygiene] CANNOT-VERIFY: the temp root $root cannot be listed — no candidate was judged"
    HYG_FRAG="CANNOT-VERIFY: temp root $root unreadable"
    HYG_SUB_RC=3
    return 0
  fi
  df_before="$(hyg_df_mb "$root")"
  now="$(date +%s)"
  for d in "$root"/cloud-cell-*; do
    # An unmatched glob stays literal, and a bare path is not ours to judge.
    [ -e "$d" ] || [ -L "$d" ] || continue
    name="$(basename "$d")"
    tok="${name#cloud-cell-}"; tok="${tok%%.*}"
    why=""
    if [ -L "$d" ]; then
      why="it is a SYMLINK, not a temp directory this family created (we never follow one)"
    elif [ ! -d "$d" ]; then
      why="it is not a directory"
    else
      case "$tok" in
        ''|*[!0-9]*)
          why="no pid in the name ('$tok') — this spelling has no liveness proof, so it is not reaped" ;;
        # ⛔ A NUMBER IS NOT A PID (review round 2, P2). `kill -0` answers two different questions and
        # this code read both as "dead": a token that CANNOT be a pid proves nothing about liveness.
        # `kill -0 0` SUCCEEDS (it signals the caller's own process GROUP), so `cloud-cell-0.*` would
        # otherwise never be reapable; a leading zero is octal to arithmetic; and a date-stamped
        # spelling like `cloud-cell-20260101.XXXX` is above the kernel pid ceiling yet fails with
        # "No such process" — i.e. it would be reaped on the age floor alone, which is exactly the
        # reap-without-proof the no-pid arm above refuses.
        0|0*) why="the token '$tok' cannot be a pid (0 is a process GROUP and a leading zero is not a decimal pid), so its liveness is UNKNOWN" ;;
        *)
          if [ "$tok" -gt 4194304 ]; then
            why="the token '$tok' is above the kernel pid ceiling (4194304), so it is not a pid and its liveness is UNKNOWN"
          elif kerr="$(kill -0 "$tok" 2>&1)"; then
            why="pid $tok from the name is ALIVE"
          else
            case "$kerr" in
              *ermitted*|*"not owner"*|*EPERM*)
                why="pid $tok from the name cannot be probed here (not permitted), so its liveness is UNKNOWN" ;;
              # The ONE answer that means "gone": bash says "(pid) - No such process", BSD says
              # "pid: no such process". Anything else is an answer we could not read.
              ''|*"No such process"*|*"no such process"*) ;;
              *)
                # Any OTHER complaint means `kill` could not answer the liveness question at all — and
                # an unanswerable probe is not a dead pid.
                why="the liveness of token '$tok' could not be probed ($(printf '%s' "$kerr" | head -1)), so it is UNKNOWN" ;;
            esac
          fi ;;
      esac
    fi
    if [ -z "$why" ]; then
      mt="$(mtime_epoch "$d")"
      case "${mt:-}" in
        ''|*[!0-9]*)
          why="its mtime cannot be read, so its idleness cannot be proven" ;;
        *)
          age=$(( now - mt ))
          [ "$age" -ge "$HYGIENE_TMP_MIN_AGE_S" ] || \
            why="it was written to ${age}s ago, under the ${HYGIENE_TMP_MIN_AGE_S}s idle floor (a pid can be recycled)" ;;
      esac
    fi
    if [ -z "$why" ]; then
      # ⛔ A DIRECTORY'S OWN MTIME DOES NOT MOVE WHEN SOMETHING IS WRITTEN INTO A SUBDIRECTORY
      # (review, P2). `$d`'s mtime changes only for an entry created/removed at ITS top level; a write
      # to `$d/sub/file` touches `$d/sub`, never `$d`. On the pid-less spellings the header itself
      # documents (`cloud-cell-test.XXXXXX`) the age gate was therefore the ONLY gate, blind to exactly
      # the activity it claimed to have measured — while the log reported "untouched ${age}s" as PROOF.
      # An entry newer than the directory itself means a descendant was written after the directory's
      # last change: its age does not cover it, so the candidate is REPORTED, not reaped.
      # ⛔ NO `-maxdepth` (review round 2, P2): a CREATED entry bumps its parent directory's mtime, but
      # an in-place APPEND (`echo >> $d/a/b/c/log`) bumps only the FILE's — so any depth bound leaves a
      # hole a live writer can sit in while the directory's own age stays ancient. The walk is one
      # linear pass over a candidate that already passed the cheap gates, and `sed -n 1p` reads to EOF
      # (no SIGPIPE, unlike `head`).
      # ⛔ THE WALK'S EXIT STATUS IS PART OF THE PROOF (review round 3, P2). `[ -n "$(find …)" ]` cannot
      # tell "nothing newer" from "the walk did not complete": a find that fails (EACCES below the root,
      # a resource limit) prints nothing and exits non-zero, and the candidate would then be reaped on
      # evidence the pass never obtained — with the log asserting "untouched Ns".
      if ! walk="$(find "$d" -newer "$d" -print 2>/dev/null)"; then
        why="the nested-write walk over it could not be completed, so its idleness cannot be proven"
      elif [ -n "$walk" ]; then
        why="an entry INSIDE it was written after its own mtime (a nested write), so its age does not prove it is idle"
      fi
    fi
    if [ -n "$why" ]; then
      kept=$((kept + 1))
      log "[hygiene] temp: LEFT $d — $why"
      continue
    fi
    if [ "$dry" = "--dry-run" ]; then
      would=$((would + 1))
      log "[hygiene] WOULD reap temp dir $d (proof: the name's token $tok is not a LIVE pid, it is untouched ${age}s — past the ${HYGIENE_TMP_MIN_AGE_S}s floor — and nothing inside it is newer)"
      continue
    fi
    if cell_stopped_midpass; then
      kept=$((kept + 1))
      log "[hygiene] temp: LEFT $d — STOP arrived mid-pass (nothing new is started after a stop)"
      continue
    fi
    # The ARTIFACT is the removal, not `rm`'s exit status.
    if rm -rf -- "$d" 2>/dev/null && [ ! -e "$d" ] && [ ! -L "$d" ]; then
      reaped=$((reaped + 1))
      # ⛔ Name what was MEASURED (review round 7, P2). The name's token is not always a pid — the header
      # documents `cloud-cell-1718.XXXXXX` (an ISSUE number) and `cloud-cell-test.XXXXXX` (no number) — so
      # "pid $tok is not alive" claims an evidence the code may not have had, and it omits the gate that
      # actually protects those spellings: the idle floor (plus the nested-write walk).
      log "[hygiene] temp: reaped $d (proof: the name's token $tok is not a LIVE pid, it is untouched ${age}s — past the ${HYGIENE_TMP_MIN_AGE_S}s floor — and nothing inside it is newer)"
    else
      failed=$((failed + 1))
      log "[hygiene] CANNOT-VERIFY: could not remove $d — it is STILL THERE"
    fi
  done
  df_after="$(hyg_df_mb "$root")"
  log "[hygiene] temp: df ($root): $(hyg_df_delta "$df_before" "$df_after") ($reaped reaped, $kept left)"
  if [ "$failed" -gt 0 ]; then
    HYG_FRAG="CANNOT-VERIFY: temp $reaped reaped, $failed FAILED to remove"
    HYG_SUB_RC=3
    return 0
  fi
  if [ "$dry" = "--dry-run" ]; then
    HYG_FRAG="temp: would reap $would, $kept left"
  else
    HYG_FRAG="temp $reaped reaped, $kept left"
  fi
}

# ── (2) DOCKER: the images and volumes NOTHING is using (agent-infra#2573) ───────────────────────
# ⛔ EXACTLY TWO VERBS. `docker image prune -af` removes only images no CONTAINER references and
# `docker volume prune -f` only volumes no container uses, so a live test container keeps its image
# and its volumes. `docker system prune -a --volumes` (which also removes STOPPED CONTAINERS — a
# test's evidence — and networks) is NOT run here, and must not be: it is a verb with a different
# blast radius, and no disk emergency justifies widening to it silently.
# A box with NO DAEMON holds zero bytes, which is a true "nothing to reclaim"; every other failure to
# answer (permission, a broken socket) is cannot-verify, because a clean row would say we had pruned.
hygiene_docker_sweep() { # <dry>; fragment in HYG_FRAG, verdict in HYG_SUB_RC
  local dry="${1:-}" derr root df_before df_after img_rc=0 vol_rc=0 last srv srv_major vol_note
  HYG_SUB_RC=0
  HYG_FRAG=""
  if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then HYG_FRAG='docker absent'; return 0; fi
  if ! derr="$("$DOCKER_BIN" info 2>&1 >/dev/null)"; then
    # ⛔ UNREACHABLE IS A CLASS, NOT TWO SPELLINGS (review, P2). Docker words the same condition at
    # least three ways — "Cannot connect to the Docker daemon … Is the docker daemon running?",
    # "permission denied while trying to connect to the Docker daemon socket … dial unix …", and a
    # missing socket ("connect: no such file or directory"). A box where the loop's user simply cannot
    # reach a healthy daemon has nothing to reclaim, so matching only the first spelling turned
    # `last_rc=3` permanent: a red hygiene row on every hourly pass on a HEALTHY machine, which is how
    # an operator learns to ignore the row (same reasoning as the 4/5/7 carve-out noted in
    # `reap_global_caches`, cloud-cell-supervisor.sh).
    case "$derr" in
      # ⛔ A DENIED SOCKET IS NOT AN ABSENT DAEMON (review round 3, P2 — and round 2 had narrowed this
      # the wrong way). "Cannot connect … Is the docker daemon running?" means the box holds NOTHING for
      # us to reclaim: a true, clean "nothing to do". A daemon that EXISTS and refuses this user means
      # the opposite — the reclaimable images and volumes are there and this pass cannot touch them.
      # Reporting that as "no daemon" put a green row and a false cause on the exact shape the issue
      # measured (24.9 GB of idle images on cell-3).
      *"permission denied"*|*"not permitted"*|*"operation not permitted"*)
        log "[hygiene] CANNOT-VERIFY: the docker daemon is unreachable from this user — $(printf '%s' "$derr" | head -1)"
        HYG_FRAG='CANNOT-VERIFY: docker daemon unreachable (permission) — reclaimable images/volumes exist but this pass cannot prune them'
        HYG_SUB_RC=3
        return 0 ;;
      *"docker daemon"*|*"Dial unix"*|*"dial unix"*|*"Is the docker daemon running"*)
        log "[hygiene] docker: no daemon ($(printf '%s' "$derr" | head -1)) — nothing to reclaim"
        HYG_FRAG='docker: no daemon'
        return 0 ;;
      *)
        log "[hygiene] CANNOT-VERIFY: docker info failed — $(printf '%s' "$derr" | head -1)"
        HYG_FRAG='CANNOT-VERIFY: docker info failed (cannot tell whether a prune is possible)'
        HYG_SUB_RC=3
        return 0 ;;
    esac
  fi
  if [ "$dry" = "--dry-run" ]; then
    log "[hygiene] WOULD run: docker image prune -af; docker volume prune -f"
    HYG_FRAG='would prune idle docker images/volumes'
    return 0
  fi
  if cell_stopped_midpass; then HYG_FRAG='STOP arrived mid-pass — docker prune skipped'; return 0; fi
  # ⛔ THE REDIRECT IS WHERE THE PRUNE IS DECIDED. Without the directory the SHELL fails before `docker`
  # runs at all, and both prunes then report rc=1 — recorded as "docker prune FAILED", a cannot-verify
  # naming the wrong cause while the reclaim silently did not happen (measured: a manual `hygiene` verb
  # on an $O whose logs/ the loop had not created yet — and the same on a full disk, which is exactly
  # the case this role exists for).
  mkdir -p "$O/logs" 2>/dev/null || true
  root="$("$DOCKER_BIN" info --format '{{.DockerRootDir}}' 2>/dev/null | head -1)"
  [ -n "$root" ] && [ -d "$root" ] || root="$CELL_HOME"
  df_before="$(hyg_df_mb "$root")"
  run_bounded "$HYGIENE_TIMEOUT" "$DOCKER_BIN" image prune -af >"$O/logs/docker-prune.log" 2>&1; img_rc=$?
  # ⛔ THE VOLUME VERB'S BLAST RADIUS IS DAEMON-VERSION DEPENDENT (review round 7, P2 — and it is the
  # data-loss-shaped one). `docker volume prune` has removed ANONYMOUS unused volumes only since 23.0;
  # `-a/--all` exists precisely because the default set CHANGED there. On an older daemon the same
  # command takes every UNUSED volume, NAMED ones included — the durable volume `docker compose down`
  # deliberately preserves — and this pass runs hourly, unattended, on boxes with free disk. So the verb
  # is gated on the SERVER major; an unreadable version skips it and says so (fail-closed), because the
  # safe direction here is "do not run a destructive verb whose set we could not establish".
  srv="$("$DOCKER_BIN" version --format '{{.Server.Version}}' 2>/dev/null | head -1)"
  srv_major="${srv%%.*}"
  vol_note=""
  case "$srv_major" in
    ''|*[!0-9]*)
      vol_note="volume prune SKIPPED (server version unreadable: '${srv:-none}')"
      vol_rc=0 ;;
    *)
      if [ "$srv_major" -ge 23 ]; then
        run_bounded "$HYGIENE_TIMEOUT" "$DOCKER_BIN" volume prune -f >>"$O/logs/docker-prune.log" 2>&1; vol_rc=$?
        vol_note="volume prune rc=$vol_rc"
      else
        vol_rc=0
        vol_note="volume prune SKIPPED (server $srv < 23.0 prunes NAMED unused volumes too — not a verb this role may run)"
      fi ;;
  esac
  df_after="$(hyg_df_mb "$root")"
  last="$(tail -2 "$O/logs/docker-prune.log" 2>/dev/null | tr '\n' ' ' | cut -c1-160)"
  log "[hygiene] docker: image prune rc=$img_rc $vol_note; df ($root): $(hyg_df_delta "$df_before" "$df_after"); docker's own report: ${last:-none}"
  if [ "$img_rc" -ne 0 ] || [ "$vol_rc" -ne 0 ]; then
    HYG_FRAG="CANNOT-VERIFY: docker prune FAILED (image rc=$img_rc volume rc=$vol_rc)"
    HYG_SUB_RC=3
    return 0
  fi
  case "$srv_major" in
    ''|*[!0-9]*)
      # The image prune ran; the volume verb did not, because its blast radius was not established.
      HYG_FRAG="docker: images pruned; VOLUME PRUNE SKIPPED (server version unreadable) — df $(hyg_df_delta "$df_before" "$df_after")"
      HYG_SUB_RC=3
      return 0 ;;
  esac
  HYG_FRAG="docker pruned (images+volumes); df $(hyg_df_delta "$df_before" "$df_after")"
}

# ── (3) THE WORKTREE-ROOT CACHE SWEEP, PER ROOT (agent-infra#2573) ───────────────────────────────
# The shipped sweep deletes `node_modules` / `.pytest_cache` / `__pycache__` at every worktree root (a
# per-worktree `.venv` is NOT its business any more — #1932 gave that delete to `reap-lane-venvs.sh`,
# which proves per-LANE liveness). This role used to gate the WHOLE sweep on "no worker session is
# live", i.e. it declined to reclaim exactly when the box was busiest, and an unreadable session list
# had the same effect. A live worker is NOT a reason to skip a worktree that provably belongs to
# nobody, so the decision is now PER ROOT and the evidence is the shipped cwd census
# (`live-ownership.sh` — ONE implementation of "who is in this checkout"):
#   * a root with a live process's cwd inside it is EXCLUDED and NAMED;
#   * every other root is swept, however many workers are live elsewhere on the box;
#   * an UNREADABLE census proves nothing about ANY root, so the sweep is skipped and the pass is
#     cannot-verify — the same fail-closed direction as the unreadable session list above.
# The exclusion is passed as `--exclude-root=` (an EXCLUSION, never an inclusion list) so the roots
# this file does not enumerate — `$HARNESS_REPO`'s, which it does not even know — keep their coverage.
hygiene_cache_sweep() { # <dry>; fragment in HYG_FRAG, verdict in HYG_SUB_RC
  # ⛔ `excl` IS LOCAL, AND THAT IS THE WHOLE FIX FOR ONE P1 (review round 2). A global array is never
  # reset, and `run_loop` calls this function over and over IN ONE PROCESS: `hr` restarts at 0 each
  # pass, so a pass that held fewer roots overwrote only the low indices and left the rest behind. The
  # exclusion set then grew monotonically to the historical maximum of held roots — after one busy
  # period the sweep excluded roots nothing holds, printed "a LIVE process holds it" about them, and
  # still recorded "swept N idle root(s)". Same failure as the clamp this role exists to remove, with
  # a slower fuse. `cloud-cell-doctor.hygiene.test.sh` calls the function TWICE in one shell to pin it.
  local dry="${1:-}" names rc sup roots r lo lg held="" hr=0 idle_n=0 live_n=0 census_clone="" wl=""
  local -a excl=()
  HYG_SUB_RC=0; HYG_FRAG=""
  names="$(harness_sessions)"
  case "$names" in
    *"$SESS_UNREADABLE_MARK"*)
      log "[hygiene] cannot verify the worker sessions — skipping the worktree-root cache sweep (fail-closed)"
      # ⛔ rc=3, like every other cannot-verify sub-step in this role: the sweep was NOT evaluated, so a
      # clean pass would tell a monitor that a destructive step it never ran was fine.
      HYG_FRAG='CANNOT-VERIFY: caches-sweep skipped (session list unreadable)'
      HYG_SUB_RC=3; return 0 ;;
  esac
  sup="${SUPERVISOR:-}"
  if [ -z "$sup" ] || [ ! -f "$sup" ]; then
    # The sweep is ONE of the role's stated jobs; a missing executor must not make it vanish into a
    # clean pass (same rule as the worktree reaper below).
    HYG_FRAG='CANNOT-VERIFY: worktree cache sweep skipped (supervisor not found)'
    HYG_SUB_RC=3; return 0
  fi
  # ⛔ THE CENSUS IS TAKEN WHETHER OR NOT A SESSION IS LIVE (review, P2). A tmux session is a
  # DECLARATION about the past; a process's cwd is a LIVE FACT. "No session on this box" is not "no
  # live process on this box" — a lane whose workspace is gone keeps its pid (the fleet's documented
  # case, and why the pre-dispatch gate reads the pid rather than the workspace) — so the session
  # count changes the WORDING below, never whether the evidence is gathered. Gating the census on the
  # session list was the same self-disable shape this role exists to remove: it swept with NO exclusion
  # on exactly the boxes where a headless process was holding a root.
  live_n="$(printf '%s' "$names" | awk 'NF{n++} END{printf "%d\n", n+0}')"
  [ "$live_n" -gt 0 ] && wl="; workers live"
  # BOTH repos the sweep executor prunes: `$REPO` and `$HARNESS_REPO` (the harness checkout is
  # handed to the doctor loop by the supervisor). A root outside them this file cannot see — so it
  # cannot exclude it either — which is why the exclusion is passed as an EXCLUSION and why the
  # census is given the harness repo as a second CLONE rather than as an unknown.
  roots="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')"
  if [ -n "${HARNESS_REPO:-}" ] && [ "$HARNESS_REPO" != "$REPO" ] \
     && git -C "$HARNESS_REPO" rev-parse --git-dir >/dev/null 2>&1; then
    roots="$roots
$(git -C "$HARNESS_REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')"
    census_clone="$HARNESS_REPO"
  fi
  # A duplicate root (the same repo named twice) must not produce two exclusion args.
  roots="$(printf '%s\n' "$roots" | awk 'NF && !seen[$0]++')"
  if [ -z "$roots" ]; then
    # ⛔ AN EMPTY ENUMERATION IS A FAILED READ, not an answer: `git -C "$REPO" worktree list` exits
    # 128 with its complaint discarded by `2>/dev/null`, so "no roots" means the question could not be
    # put to git at all ($REPO unset or not a checkout). Reading it as "nothing is provably idle, carry
    # on" was the same fail-open as every other unreadable read in this role — and it left `status`
    # showing hygiene green on a box whose cache sweep had never once run.
    log "[hygiene] CANNOT-VERIFY: no worktree root of ${REPO:-<REPO unset>} could be enumerated (git worktree list returned nothing) — the cache sweep was not evaluated"
    HYG_FRAG='CANNOT-VERIFY: caches-sweep skipped (no worktree root enumerated)'
    HYG_SUB_RC=3
    return 0
  fi
  lo="$SELF_DIR/live-ownership.sh"
  if [ ! -f "$lo" ]; then
    log "[hygiene] CANNOT-VERIFY: $lo is missing — no cwd census, so no worktree root can be proven idle; sweep skipped"
    HYG_FRAG='CANNOT-VERIFY: caches-sweep skipped (no cwd census available)'
    HYG_SUB_RC=3; return 0
  fi
  lg="$(mktemp "${TMPDIR:-/tmp}/hyg-live-cwd.XXXXXX" 2>/dev/null)" || {
    HYG_FRAG='CANNOT-VERIFY: caches-sweep skipped (cannot create the census scratch file)'
    HYG_SUB_RC=3; return 0; }
  # The census is a READ this pass ACTS on, so it is bounded like every other read here — and it is
  # run in a CHILD shell because `bounded`/`timeout(1)` can only execute a COMMAND: handing it this
  # file's own function name fails `127` under `timeout -k`, i.e. the bound would turn every census
  # into cannot-verify on any box where timeout(1) exists. The child sources the SAME library, so
  # there is still exactly ONE implementation of "who is in this checkout".
  bounded "$READ_CALL_TIMEOUT" bash -c '. "$1"/live-ownership.sh && lo_scan "$2" "$3" "$4"' \
    _ "$SELF_DIR" "$lg" "$REPO" "$census_clone"; rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$lg"
    log "[hygiene] CANNOT-VERIFY: the live-cwd census could not be taken (lo_scan rc=$rc) — no worktree root can be proven idle, so the cache sweep is skipped (fail-closed)"
    HYG_FRAG="CANNOT-VERIFY: caches-sweep skipped (live-cwd census unreadable rc=$rc)"
    HYG_SUB_RC=3; return 0
  fi
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if awk -F'\t' -v p="$r" '$4 == p || index($4, p "/") == 1 { f = 1; exit } END { exit !f }' "$lg" 2>/dev/null; then
      printf -v held '%s\n%s' "$held" "$r"
      # The EXCLUSION argv: `--exclude-root=<HELD path>`, one array element per root so a path with a
      # space in it survives (`set --`/word-splitting would not). ⛔ HELD is excluded; an IDLE root is
      # exactly what this sweep came for and must never be excluded.
      excl[$hr]="--exclude-root=$r"
      hr=$((hr + 1))
      log "[hygiene] caches: LEFT $r — a LIVE process has a cwd inside it (proof: the cwd census, which is a floor on VISIBLE processes)"
    else
      idle_n=$((idle_n + 1))
    fi
  done <<< "$roots"
  rm -f "$lg"
  if [ "$idle_n" -eq 0 ]; then
    log "[hygiene] caches: every worktree root is held by a live process — nothing swept$wl"
    HYG_FRAG="caches-sweep skipped (every root held$wl)"
    return 0
  fi
  if [ "$dry" = "--dry-run" ]; then
    log "[hygiene] WOULD sweep worktree caches at $idle_n idle root(s)$wl, excluding $(printf '%s' "$held" | tr '\n' ' ')"
    HYG_FRAG="would sweep worktree caches ($idle_n idle root(s)$wl)"
    return 0
  fi
  if cell_stopped_midpass; then HYG_FRAG='STOP arrived mid-pass — worktree cache sweep skipped'; return 0; fi
  # EXCLUSION argv, never an inclusion list: every root this file does not enumerate keeps its
  # coverage (`$HARNESS_REPO`'s worktrees are swept by the same verb and are never named here).
  # ⛔ `${excl[@]+...}`: this file still states `/bin/bash 3.2` compatibility, where expanding an
  # EMPTY array under `set -u` is an unbound-variable ABORT — and "no root is held" is the normal
  # case on a quiet box, so the plain form would fail the sweep exactly when it has most to do.
  run_bounded "$HYGIENE_TIMEOUT" bash "$sup" prune --caches ${excl[@]+"${excl[@]}"} >>"$O/logs/doctor.log" 2>&1
  rc=$?
  # ⛔ "no VISIBLE holder" — not "idle" (review round 2, P2). The census cannot see another user's or a
  # hardened process (live-ownership.sh states this), so the record says what was MEASURED instead of
  # presenting a floor as proof.
  log "[hygiene] caches: swept $idle_n root(s) with no VISIBLE holder$wl; excluded $(printf '%s' "$held" | tr '\n' ' ')"
  if [ "$rc" -eq 0 ]; then
    HYG_FRAG="worktree caches swept ($idle_n idle root(s)$wl)"
  else
    HYG_FRAG="CANNOT-VERIFY: worktree cache sweep FAILED rc=$rc"
    HYG_SUB_RC=3
  fi
}
# ── and the CROSS-BOX REVIEW-RECORD REGISTRY (agent-infra#2577) ──────────────────────────────────
# The fourth sub-step is not disk hygiene; it is the other thing that rots silently while every piece
# of the machinery reports itself healthy — a registry that never converges. It lives HERE because
# this is the role that already runs hourly, and it is deliberately NOT a fifth role (a role is a
# lock, a state record and a `status` row for one recurring job; a 300 s sub-step does not need three).
# The three helpers below are its whole surface.
registry_sync_path() { # → the shipped converging verb, or nothing
  local c
  for c in "$REGISTRY_SYNC_SCRIPT" \
           "${SUPERVISOR:+$(dirname "$SUPERVISOR")/registry-sync.sh}" \
           "$SELF_DIR/../registry-sync.sh" \
           "${HARNESS_REPO:+$HARNESS_REPO/scripts/registry-sync.sh}" \
           "${HARNESS_PIN_DIR:+$HARNESS_PIN_DIR/scripts/registry-sync.sh}" \
           "$REPO/scripts/registry-sync.sh" \
           "$CELL_HOME/.pi/agent/scripts/registry-sync.sh"; do
    [ -n "$c" ] && [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

is_work_tree() { [ -n "${1:-}" ] && [ -d "$1" ] && git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }

# ⛔ THE DIRECTORY ITSELF MUST BE THE ROOT git reports — `is_work_tree` alone does NOT answer that:
# `git -C <dir>` walks UPWARD, so any plain leftover directory inside a checkout reports a git dir and
# a toplevel of the ENCLOSING checkout. Measured: a stray `<hub>/.worktrees/registry-sync` (a leftover
# from a provisioning killed at its bound, or from an out-of-band delete) made `is_work_tree` true, and
# the store resolved to that path — i.e. the verb ran against the HUB, and the convergence line named a
# path `git worktree list` does not know as "the worktree". `pwd -P` because git reports a PHYSICAL
# toplevel, and a symlinked worktree path would otherwise never compare equal.
is_worktree_root() { # <path>
  [ -n "${1:-}" ] && [ -d "$1" ] || return 1
  [ "$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$1" 2>/dev/null && pwd -P)" ]
}

is_same_repo() { # <a> <b> — same git COMMON dir, i.e. linked worktrees of ONE repository
  local a b
  a="$(cd "$1" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || return 1
  b="$(cd "$2" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || return 1
  a="$(cd "$1" 2>/dev/null && cd "$a" 2>/dev/null && pwd -P)" || return 1
  b="$(cd "$2" 2>/dev/null && cd "$b" 2>/dev/null && pwd -P)" || return 1
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" = "$b" ]
}

# A WORKTREE (a linked one) rather than the PRIMARY checkout — the hub. `--git-common-dir` may come
# back RELATIVE to the worktree (`.git`), so it is resolved before the comparison: an unresolved
# relative path never equals an absolute one, which would call every checkout "linked".
is_linked_worktree() { # <path>
  local gd common
  is_work_tree "${1:-}" || return 1
  gd="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  common="$(cd "$1" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$gd" ] && [ -n "$common" ] || return 1
  common="$(cd "$1" 2>/dev/null && cd "$common" 2>/dev/null && pwd)" || return 1
  [ -n "$common" ] && [ "$gd" != "$common" ]
}

# WHERE THE SYNC RUNS FROM. The verb performs git REF operations against the store, and it is run here
# from a WORKTREE of the agent-infra checkout — never from the hub checkout itself:
#   * a hub-rooted invocation is refused for an agent session (`unverifiable-verb` — the checkout
#     guard cannot statically bound the verbs the script's dynamic-argv wrapper may emit, measured in
#     #2520). A scheduled path that only works when a NON-agent happens to run it is a path nobody
#     can reproduce by hand, which is the wrong half of the surface to depend on;
#   * the local `refs/reviews/*` cache it maintains belongs on a disposable checkout, not on the one
#     every lane and the controller share.
# Provisioning follows `refresh-candidates.sh`'s pre-flight scout: a dedicated throwaway worktree,
# created on first use and reused afterwards. `--no-checkout` because this consumer needs the OBJECT
# DATABASE and the ref namespace, not a working tree — so the cost is one gitdir entry, not a second
# copy of the repo (and `hygiene`, of all roles, must not pay a checkout-sized disk cost every hour).
# ⛔ When it cannot be provisioned this returns NOTHING and the caller logs a skip. It never falls
# back to the hub: silently syncing from the checkout the guard refuses is how the scheduled path
# would "work" on a machine and be un-reproducible on the next one.
# Resolve the agent-infra checkout the registry lives on — with NO side effects, so the rehearsal can
# ask the same question the live pass asks without provisioning anything.
registry_store_hub() { # → the checkout to sync FROM, or empty
  local hub="" c
  if [ -n "$REGISTRY_SYNC_STORE" ]; then
    # An explicit store is honoured (an operator may name a worktree, or a checkout outright), but it
    # gets the SAME two normalisations as a discovered candidate — an override is a pointer, not an
    # exemption. Measured before this check existed: `DOCTOR_REGISTRY_STORE` naming a checkout whose
    # `origin` was a tortoise remote pushed a review record into that repository's `refs/reviews/*`
    # (a silent cross-repo write — the one thing this resolution must never do), and an override
    # naming a SUBDIRECTORY would have put `--repo` inside the store instead of at it.
    if ! is_work_tree "$REGISTRY_SYNC_STORE"; then
      log "[hygiene] registry: DOCTOR_REGISTRY_STORE=$REGISTRY_SYNC_STORE is not a git work tree — not syncing from it" >&2
      return 1
    fi
    hub="$(git -C "$REGISTRY_SYNC_STORE" rev-parse --show-toplevel 2>/dev/null)" || {
      log "[hygiene] registry: DOCTOR_REGISTRY_STORE=$REGISTRY_SYNC_STORE is not inside a readable git work tree — not syncing from it" >&2
      return 1; }
    case "$(git -C "$hub" remote get-url origin 2>/dev/null)" in
      *agent-infra*) printf '%s\n' "$hub"; return 0 ;;
      *) log "[hygiene] registry: DOCTOR_REGISTRY_STORE=$REGISTRY_SYNC_STORE does not look like an agent-infra checkout (its origin is not an agent-infra remote) — refusing to push review records to it" >&2
         return 1 ;;
    esac
  fi
  # The store is an AGENT-INFRA checkout, in the resolution order the deployed harness already uses:
  # `$HARNESS_REPO` is the checkout the harness was applied FROM (the supervisor refuses to apply one
  # otherwise), then `$AGENT_INFRA_PATH`, then the pin dir, then the checkout this harness was copied
  # FROM (`$SELF_DIR` is `<checkout>/scripts/orchestrator-harness`, so its grandparent holds the
  # checkout). Every candidate is NAMED, never discovered by walking the filesystem.
  #
  # ⛔ TWO normalisations, both load-bearing:
  #   * the candidate is reduced to its CHECKOUT ROOT (`--show-toplevel`). `$SELF_DIR/..` names
  #     `<checkout>/scripts`, and `is_work_tree` happily accepts it because it is *inside* a repo —
  #     so the throwaway worktree would be provisioned at `<checkout>/scripts/.worktrees/…`, inside
  #     the tracked source tree, and `--repo` would name a subdirectory of the store instead of the
  #     store. (Measured before this line existed: `converged … via /tmp/rev-regtest/hub/scripts/\
  #     .worktrees/registry-sync`.)
  #   * the candidate's `origin` must LOOK like agent-infra. "a remote named origin exists" is not
  #     enough: a harness copy that happens to live inside some other repo would resolve THAT repo as
  #     the store and `registry-sync.sh` would faithfully push `refs/reviews/*` to its remote — a
  #     silent cross-repo write, which is the one thing the store resolution must never do. A
  #     mistaken store is now a LOGGED skip (best-effort by design), not a wrong push.
  for c in "${HARNESS_REPO:-}" "${AGENT_INFRA_PATH:-}" "${HARNESS_PIN_DIR:-}" "$SELF_DIR/../.."; do
    [ -n "$c" ] || continue
    is_work_tree "$c" || continue
    hub="$(git -C "$c" rev-parse --show-toplevel 2>/dev/null)" || continue
    [ -n "$hub" ] && [ -d "$hub" ] || continue
    case "$(git -C "$hub" remote get-url origin 2>/dev/null)" in
      *agent-infra*) ;;
      *) hub=""; continue ;;
    esac
    break
  done
  [ -n "$hub" ] && printf '%s\n' "$hub"
  return 0
}

registry_store() { # → the worktree to sync from (may provision one), or empty
  local hub wt
  hub="$(registry_store_hub)" || return 1
  [ -n "$hub" ] || return 1
  # An explicit store is used AS GIVEN: the "never the hub" rule below governs what this role CHOOSES
  # on its own, and an operator naming a checkout explicitly has made that choice.
  if [ -n "$REGISTRY_SYNC_STORE" ]; then printf '%s\n' "$hub"; return 0; fi
  # A harness materialised INTO a worktree (a cell's layout) already IS the worktree this role has.
  if is_linked_worktree "$hub"; then printf '%s\n' "$hub"; return 0; fi
  wt="$hub/.worktrees/registry-sync"
  if is_worktree_root "$wt"; then
    # ⛔ AND IT MUST BE A WORKTREE OF *THIS* REPOSITORY. Every other store path is identity-checked
    # against the fleet's store (the candidates and the override by their `origin`); a REUSED worktree
    # inherits the config of whichever repo registered it — so a leftover worktree of some OTHER
    # repository sitting at this path would have the verb push this box's `refs/reviews/*` to that
    # repo's remote (permanent: rule 2 has no delete path), and report `converged with the fleet` while
    # the fleet store received nothing.
    if is_same_repo "$wt" "$hub"; then printf '%s\n' "$wt"; return 0; fi
    log "[hygiene] registry: $wt is a worktree of a DIFFERENT repository — refusing to push review records to its remote (remove it, or set DOCTOR_REGISTRY_STORE)" >&2
    return 1
  fi
  if [ -e "$wt" ]; then
    # ⛔ No `rm -rf` here. A directory that is not a worktree is NOT this role's to delete — that is
    # the destructive-verb class this file's reap gates exist to prevent — so it is named and skipped.
    # ⛔ And this branch is REACHABLE now: with a plain `is_work_tree` test it could never fire, so the
    # hub was used as "the worktree" in silence (see `is_worktree_root`).
    log "[hygiene] registry: $wt exists but is not the root of a git worktree — not syncing from it (remove it, or set DOCTOR_REGISTRY_STORE)" >&2
    return 1
  fi
  mkdir -p "$hub/.worktrees" 2>/dev/null || true
  # ⛔ BOUNDED, like every other subprocess in this file. `worktree add` is a WRITE on the hub's gitdir
  # and the only step here that can block on a slow/locked/shared filesystem; a hang there would hold
  # the one loop that supervises everything else — past `REGISTRY_STEP_TIMEOUT` and past `WORST_PASS_S`,
  # both of which bound the VERB and would therefore report a healthy cell while the loop is stuck.
  local prc=0 stale=0 l regs
  # ⛔ A STALE REGISTRATION IS A PERMANENT DEADLOCK, and it is reachable WITHOUT hand-editing: the
  # worktree is a THROWAWAY, so `rm -rf`-ing it (what any disk cleanup does, and what its own name
  # invites) leaves the registration in `<hub>/.git/worktrees/` with no directory — and then a plain
  # `worktree add` refuses FOR EVER with rc=128 ("is a missing but already registered worktree; use
  # 'add -f' to override, or 'prune'"). Measured: every hourly pass logged `could not provision … rc=128`
  # and skipped, i.e. the sub-step was dead on that box while the rehearsal still said `would sync`.
  # The targeted repair is `-f` on OUR OWN path: `git worktree prune` would also drop other (possibly
  # merely-unmounted) registrations, which is not this role's to remove. Read the registration list
  # itself — the directory's absence was already established by the caller.
  regs="$(git -C "$hub" worktree list --porcelain 2>/dev/null)"
  while IFS= read -r l; do
    [ "$l" = "worktree $wt" ] && stale=1
  done <<< "$regs"
  # The STEP bound, not the network one: this is a LOCAL gitdir write, and using the network knob here
  # let an operator who raised it for a slow store also widen an unrelated local bound.
  if [ "$stale" = 1 ]; then
    log "[hygiene] registry: $wt is REGISTERED as a worktree but its directory is gone — re-creating it (a throwaway removed out of band leaves this state, which plain \`worktree add\` refuses for ever)" >&2
    run_bounded "$REGISTRY_STEP_TIMEOUT" git -C "$hub" worktree add -f --detach --no-checkout "$wt" \
      >/dev/null 2>&1 || prc=$?
  else
    run_bounded "$REGISTRY_STEP_TIMEOUT" git -C "$hub" worktree add --detach --no-checkout "$wt" \
      >/dev/null 2>&1 || prc=$?
  fi
  if [ "$prc" -ne 0 ]; then
    log "[hygiene] registry: could not provision the sync worktree at $wt from $hub (rc=$prc, stale_registration=$stale) — skipped (the hub checkout is deliberately not used; #2520). If a registration is stale: git -C $hub worktree prune" >&2
    return 1
  fi
  printf '%s\n' "$wt"
}

# ⛔ BEST-EFFORT, AND DELIBERATELY THE ONE SUB-STEP OF THIS ROLE THAT CANNOT FAIL THE PASS.
# Every other sub-step here is `cannot-verify` (rc=3) when it fails, because each of them is a step
# the role was asked to perform and skipping it would report a clean pass for work never done. The
# registry sync is the opposite shape: its failure leaves the box EXACTLY as blind as it already was,
# and an offline cell, a rate-limited box or a repo whose objects are not fetchable would then make a
# permanently red `hygiene` row — an over-block that hides the real failures (the disk ones) behind a
# network condition nobody can fix, and that would tempt an operator to stop reading the row. So a
# failure is LOGGED with the box, the store, the exit code and the verb's own first complaint, it is
# written into the role's `last_result`, and the pass continues with its own verdict.
# WHY CAN THIS BOX NOT SYNC? — answered WITHOUT side effects, so the REHEARSAL can tell the truth.
# `--dry-run` is the verb an operator is told to run first, and step 4 used to log `WOULD run: …`
# unconditionally: on a box where the live pass reports `registry SKIPPED (registry-sync.sh not
# found)` (or the seam is off), the rehearsal claimed an action that cannot happen — hiding a
# permanently LOCAL-ONLY (blind) box behind a positive statement, which is the misinformation this
# role's "a rehearsal is not a verdict" doctrine exists to prevent. The STORE is deliberately not
# part of this: resolving it provisions a worktree, and a rehearsal performs no action.
registry_precheck() { # → the reason this box cannot sync (nothing = it can be attempted)
  case "$REGISTRY_SYNC_SCRIPT" in
    off|none|0) printf 'by request (DOCTOR_REGISTRY_SYNC=%s)' "$REGISTRY_SYNC_SCRIPT"; return 0 ;;
  esac
  if ! registry_sync_path >/dev/null 2>&1; then printf 'registry-sync.sh not found'; return 0; fi
  # The STORE is part of the answer, and it is checked WITHOUT provisioning (`registry_store_hub` has
  # no side effects). Leaving it out made the two arms disagree on the documented farmed shape (script
  # present, no agent-infra checkout above it): the live pass recorded `SKIPPED (no worktree to sync
  # from)` while the rehearsal claimed `would sync`, and because `state_write_rehearsal` keeps the
  # worse rc but REPLACES `last_result`, the operator's first verb ERASED the skip from the role row —
  # a blind box reading clean, the class this sub-step exists to remove.
  local hub
  hub="$(registry_store_hub)" || { printf 'no worktree to sync from'; return 0; }
  [ -n "$hub" ] || { printf 'no worktree to sync from'; return 0; }
  # An explicit store is used as given, and a harness living in a linked worktree IS the store — both
  # are answered by `registry_store` without touching anything.
  [ -n "$REGISTRY_SYNC_STORE" ] && return 0
  is_linked_worktree "$hub" && return 0
  # The OCCUPANCY of the worktree path is knowable with no side effects, and it is the third reason the
  # live pass skips. Leaving it out meant a box that will skip EVERY hourly pass still got a rehearsal
  # claiming `would sync` — and `state_write_rehearsal` keeps the worse rc but REPLACES `last_result`,
  # so the operator's first verb erased the recorded skip.
  if is_worktree_root "$hub/.worktrees/registry-sync"; then
    is_same_repo "$hub/.worktrees/registry-sync" "$hub" || printf 'no worktree to sync from'
  else
    [ -e "$hub/.worktrees/registry-sync" ] && printf 'no worktree to sync from'
  fi
  return 0
}

REGISTRY_RESULT=""
sync_registry() {
  local sync store out rc summary host why
  REGISTRY_RESULT=""
  host="$(hostname 2>/dev/null || uname -n 2>/dev/null || printf 'this box')"
  case "$REGISTRY_SYNC_SCRIPT" in
    off|none|0)
      log "[hygiene] registry: sync SKIPPED by request (DOCTOR_REGISTRY_SYNC=$REGISTRY_SYNC_SCRIPT) — the review-record registry on $host stays LOCAL-ONLY"
      REGISTRY_RESULT="registry skipped (by request)"
      return 0 ;;
  esac
  if ! sync="$(registry_sync_path)"; then
    log "[hygiene] registry: registry-sync.sh NOT FOUND (looked beside the supervisor, $SELF_DIR/.., \$HARNESS_REPO, \$HARNESS_PIN_DIR, $REPO/scripts, $CELL_HOME/.pi/agent/scripts) — the registry on $host stays LOCAL-ONLY, so a PR reviewed on another box still reads as unreviewed (#2374/#2577)"
    REGISTRY_RESULT="registry SKIPPED (registry-sync.sh not found)"
    return 0
  fi
  if ! store="$(registry_store)"; then
    log "[hygiene] registry: no usable WORKTREE of an agent-infra checkout on $host — the registry sync was skipped (the hub checkout is deliberately not used; #2520), so a PR reviewed on another box may still read as unreviewed"
    REGISTRY_RESULT="registry SKIPPED (no worktree to sync from)"
    return 0
  fi
  # `--dir` is passed EXPLICITLY: it is the SAME directory the merge role reads (`attestation_clean`
  # resolves `$CELL_HOME/.pi/agent/reviews`), and `$HOME` is not that directory on every path — a
  # doctor whose HOME is not the cell home would otherwise converge a registry no lane ever reads.
  # `--quiet` keeps the per-record chatter out of a bounded capture; the `union:` SUMMARY line is
  # printed unconditionally, so the counts survive.
  # ⛔ THE CAPTURE GOES THROUGH A FILE, and this is the ONLY call site in this file that has to. Every
  # other `run_bounded` here redirects the child straight to a log; this one needs the OUTPUT. Handing
  # the child a command-substitution PIPE is exactly the defect `bounded`'s own comment records
  # (:440-444): `timeout` cannot reach a DESCENDANT that inherited the pipe, so anything the verb
  # leaves behind (a credential/ssh helper, a wrapper installed through the seam) holds the read end
  # open and the pass blocks for that descendant's full lifetime — measured: a verb backgrounding one
  # child ran 6 s under a 2 s bound, with NO log line, because the log is emitted after the capture
  # returns. That would starve the other roles and defeat both this bound and WORST_PASS_S. The file
  # capture is the sibling call sites' shape, and it also leaves the run's own output on disk.
  mkdir -p "$WORKER_LOG_DIR" 2>/dev/null || true
  local cap="$WORKER_LOG_DIR/registry-sync.log"
  : > "$cap" 2>/dev/null || true
  run_bounded "$REGISTRY_STEP_TIMEOUT" bash "$sync" union --repo "$store" \
    --dir "$CELL_HOME/.pi/agent/reviews" --timeout "$REGISTRY_SYNC_NET_TIMEOUT" --quiet \
    >"$cap" 2>&1
  rc=$?
  out="$(cat "$cap" 2>/dev/null)"
  summary="$(printf '%s\n' "$out" | grep -E '^union:' | tail -1)"
  case "$rc" in
    0)
      # ⛔ rc=0 IS NOT THE EVIDENCE — the verb's own convergence line is. A silent exit 0 (a truncated
      # capture on a full disk — the condition this very role exists for — or an older copy of the verb
      # whose summary prefix differs) used to be recorded as `converged`, i.e. a blind box reading
      # synced: the false-PASS direction that matters most here. Absent the line, convergence is
      # UNPROVEN and is reported as such.
      if [ -z "$summary" ]; then
        log "[hygiene] registry: SYNC FAILED on $host rc=0 — registry-sync.sh exited 0 WITHOUT its 'union:' summary line, so convergence is UNPROVEN (nothing about this box's registry was established); store=$store. ⛔ NOT fatal: the pass continues. No retry until the next pass."
        REGISTRY_RESULT="registry UNPROVEN (rc=0 without a union summary)"
        return 0
      fi
      log "[hygiene] registry: converged with the fleet via $store — $summary"
      REGISTRY_RESULT="registry synced" ;;
    3)
      # rule 4: two records share a `reviewed_at` and disagree. NOTHING was overwritten, and this is
      # not a failure of the pass — it is a state a human reconciles (or two boxes recording one revision).
      log "[hygiene] registry: DIVERGENCE on $host rc=$rc — ${summary:-union: (no summary line)}; store=$store. Two records share a reviewed_at and disagree, so neither side was overwritten (rule 4). Not fatal; reconcile by hand if this is not two boxes recording one revision."
      REGISTRY_RESULT="registry DIVERGES (rule 4, nothing overwritten)" ;;
    4)
      log "[hygiene] registry: SYNC INCOMPLETE on $host rc=$rc — ${summary:-union: (no summary line)}; store=$store. Records the store holds were SKIPPED and nothing was overwritten, but this is NOT a converged state. Not fatal."
      REGISTRY_RESULT="registry INCOMPLETE (rc=4, records skipped)" ;;
    *)
      # ONE attempt, once per hourly pass: the verb itself never retries, so a dark or rate-limited
      # store cannot become a retry storm from here — the next attempt is the next pass.
      why="$(printf '%s\n' "$out" | grep -vE '^union:' | grep -v '^$' | head -1)"
      log "[hygiene] registry: SYNC FAILED on $host rc=$rc${summary:+ ($summary)} — ${why:-no output from registry-sync.sh}; store=$store. ⛔ NOT fatal: this pass continues, this box's records are untouched, and the registry is exactly as blind as it was before. No retry until the next pass."
      REGISTRY_RESULT="registry SYNC FAILED rc=$rc (logged, not fatal)" ;;
  esac
  return 0
}

run_hygiene() {
  begin_pass
  # ${1:-}: NO mode means a LIVE pass (an empty string never equals `--dry-run`). An ABSENT or
  # empty `$1` MUST be survivable — a bare `"$1"` here is what killed the scheduler on its first
  # tick (#2424), and the loop still asks this role to run with an empty mode on every schedule;
  # see "POSITIONAL PARAMETERS: WHICH MAY BE ABSENT" before run_role_pass for the file-wide audit.
  local dry="${1:-}" before after mb rc wt mode out result="" h_rc=0 prev frag df_before df_after stop_reaper=0
  local dry="${1:-}" before after mb rc wt mode out result="" h_rc=0 prev frag df_before df_after stop_reaper=0 reason
  # ⛔ THE PASS-LEVEL `df` READ COMES FIRST, and the delta printed at the END is the ONLY savings this
  # role may claim. Not a `du` sum (see the section header), and not docker's own "Total reclaimed"
  # line — that is a different instrument reporting on a different question.
  df_before="$(hyg_df_mb "$CELL_HOME")"
  # 1) the package cache. `uv cache prune` removes UNUSED entries (safe while lanes resolve); it is
  #    NOT `uv cache clean` — emptying a cache a live lane is reading is the class #1987 forbids.
  if command -v uv >/dev/null 2>&1; then
    before="$(du -sm "$CELL_HOME/.cache/uv" 2>/dev/null | awk '{print $1}')"
    if cell_stopped_midpass; then
      result="${result}${result:+; }STOP arrived mid-pass — uv cache prune skipped"
    elif [ "$dry" = "--dry-run" ]; then
      log "[hygiene] WOULD run: uv cache prune (cache ${before:-?}MB)"
      result="would prune uv (${before:-?}MB)"
    else
      run_bounded "$HYGIENE_TIMEOUT" uv cache prune >>"$O/logs/doctor.log" 2>&1
      rc=$?
      after="$(du -sm "$CELL_HOME/.cache/uv" 2>/dev/null | awk '{print $1}')"
      # ⛔ The `du` pair is INFORMATIONAL and labelled as such: the cache's own bookkeeping is the
      # right way to say "the prune ran over this directory", and it is never the savings figure.
      log "[hygiene] uv cache prune rc=$rc (du ${before:-?}MB -> ${after:-?}MB on the cache dir — informational; the df delta below is the claim)"
      # ⛔ A prune that FAILED (or was cut at HYGIENE_TIMEOUT, rc=124/137) did not happen: recording a
      # clean pass would read green in `status` while the disk keeps filling — the silent-no-op class
      # this role exists to remove. Every other failed sub-step in this role is rc=3; so is this one.
      if [ "$rc" -eq 0 ]; then
        result="uv pruned"
      else
        result="${result}${result:+; }CANNOT-VERIFY: uv cache prune FAILED rc=$rc"
        h_rc=3
      fi
    fi
  else
    result="uv absent"
  fi
  # 2) the `cloud-cell-<pid>.<rand>` temp dirs this family leaves behind (#2573). Proof, per dir, and
  #    the reason it is either reaped or LEFT is in the log — see `hygiene_tmp_sweep`.
  hygiene_tmp_sweep "$dry"
  [ "$HYG_SUB_RC" -ne 0 ] && [ "$h_rc" -eq 0 ] && h_rc="$HYG_SUB_RC"
  result="${result}${result:+; }${HYG_FRAG}"
  # 3) docker images/volumes nothing is using (#2573). Two verbs only, both "not in use by ANY
  #    container" by docker's own semantics — never `system prune`.
  hygiene_docker_sweep "$dry"
  [ "$HYG_SUB_RC" -ne 0 ] && [ "$h_rc" -eq 0 ] && h_rc="$HYG_SUB_RC"
  result="${result}${result:+; }${HYG_FRAG}"
  # 4) worktree-root caches, decided PER ROOT on the live-cwd census (#2573). A live worker elsewhere
  #    on the box is not a reason to leave a worktree nobody holds full of regenerable caches.
  hygiene_cache_sweep "$dry"
  [ "$HYG_SUB_RC" -ne 0 ] && [ "$h_rc" -eq 0 ] && h_rc="$HYG_SUB_RC"
  result="${result}${result:+; }${HYG_FRAG}"
  # 5) stale worktrees — the shipped reaper, whose own gates preserve anything dirty, unreferenced or
  #    unreachable. `auto` arms it only under disk pressure: the failure being prevented is a FULL
  #    disk, and a tidy box does not need a destructive verb run for tidiness.
  wt="${DOCTOR_WORKTREE_REAPER:-}"
  if [ -z "$wt" ]; then
    # ⛔ `$(dirname "$SUPERVISOR")` FIRST: the shipped reaper is `scripts/pi-reap-worktrees.sh`, one
    # level ABOVE the harness dir this file lives in — the same layout `rail_path` already handles for
    # `admin-merge.sh`. Without it, a cell that runs a pinned harness has the reaper on disk and the
    # role never finds it (measured in review round 1), which made the reaper a silent no-op while
    # the pass reported itself clean.
    for wt in "${SUPERVISOR:+$(dirname "$SUPERVISOR")/pi-reap-worktrees.sh}" \
              "$SELF_DIR/../pi-reap-worktrees.sh" \
              "$REPO/scripts/pi-reap-worktrees.sh" \
              "$CELL_HOME/.pi/agent/scripts/pi-reap-worktrees.sh"; do
      [ -n "$wt" ] && [ -f "$wt" ] && break
    done
    [ -n "$wt" ] && [ -f "$wt" ] || wt=""
  fi
  if [ -f "${wt:-}" ]; then
    mode="$HYGIENE_WORKTREES"
    if [ "$mode" = "auto" ]; then
      mb="$(free_mb "$CELL_HOME")"
      if [ -z "$mb" ]; then
        # ⛔ `free_mb`'s own comment says an empty answer is "cannot answer — never enough", and this
        # branch used to make it mean exactly "enough": the reaper stayed in dry-run and the pass
        # reported itself clean for ever on a box whose disk it cannot measure. The SAFE direction is
        # kept (dry-run, never an armed sweep); the PASS is cannot-verify.
        mode=dry-run
        result="${result}${result:+; }CANNOT-VERIFY: cannot read the free space (the sweep stays dry-run)"
        h_rc=3
      elif [ "$mb" -lt "$((MIN_FREE_MB * 2))" ]; then mode=apply; else mode=dry-run; fi
    fi
    if [ "$dry" = "--dry-run" ]; then mode=dry-run; fi
    out="$O/logs/doctor-worktrees.log"
    if cell_stopped_midpass; then
      # The reaper deletes worktrees: a stop that arrived while this pass was running must not have it
      # start deleting afterwards (see `cell_stopped_midpass`).
      result="${result}${result:+; }STOP arrived mid-pass — worktree reaper skipped"
      # ⛔ `$h_rc`, NEVER a hardcoded 0: a stop arriving after a FAILED uv prune (or a failed cache
      # sweep) must not erase that cannot-verify and turn the pass green — the exact false green the
      # sibling sub-steps above exist to prevent. This used to `return` here, which ALSO skipped the
      # df delta every pass must print; the single exit below keeps both properties.
      stop_reaper=1
    else
      run_bounded "$HYGIENE_TIMEOUT" bash "$wt" "--$mode" --repo "$REPO" --aged-days "$STALE_WORKTREE_DAYS" >>"$out" 2>&1
      rc=$?
      if [ "$rc" -eq 0 ]; then
        result="${result}${result:+; }worktrees $mode"
      else
        # A reaper that failed or was killed at HYGIENE_TIMEOUT is not a completed hygiene step: on a
        # full disk its own git operations fail, and "worktrees apply" would claim a reap that did not
        # happen — the silent no-op this role exists to remove.
        result="${result}${result:+; }CANNOT-VERIFY: worktrees $mode FAILED rc=$rc"
        h_rc=3
      fi
    fi
  else
    # The role's stated jobs include the disk sink that broke a cell twice. "I could not find the
    # reaper" is not a completed hygiene pass — it is cannot-verify, and it must not read as green.
    result="${result}${result:+; }CANNOT-VERIFY: worktree reaper (pi-reap-worktrees.sh) not found"
    h_rc=3
  fi
  # 6) the CROSS-BOX REVIEW-RECORD REGISTRY (#2577). ⛔ This sub-step is BEST-EFFORT: it never touches
  #    `$h_rc`, so no sync outcome — a dark store, a rate limit, a divergence, a missing script — can
  #    fail the pass or reach a merge decision. Its failure is a LOGGED line naming the box + the
  #    store + the verb's own first complaint, and a short entry in `last_result` so `status` shows it.
  #    The reasoning is in `sync_registry`'s header, next to the code it governs.
  if cell_stopped_midpass; then
    # Same rule as the reaper above: once the cell has been stopped, nothing NEW starts. The sync
    # writes to this box's registry, so a stop that landed mid-pass must not have it start writing.
    result="${result}${result:+; }STOP arrived mid-pass — registry sync skipped"
  elif [ "$dry" = "--dry-run" ]; then
    # A rehearsal performs NO action, and this one writes into the registry the merge role reads — so
    # it is logged as WOULD and not run. It therefore cannot know whether the last sync failure is
    # fixed, which is exactly why the rehearsal record is the worse of (stored, own).
    # ⛔ But it must not claim an action this box CANNOT take: the cheap, side-effect-free pre-check
    # decides between WOULD and the same SKIP the live pass would record. (`registry_precheck` never
    # resolves the store — that provisions a worktree.)
    if reason="$(registry_precheck)" && [ -z "$reason" ]; then
      log "[hygiene] WOULD run: registry-sync.sh union (the cross-box review-record registry)"
      result="${result}${result:+; }would sync the review registry"
    else
      log "[hygiene] registry: sync SKIPPED — ${reason:-could not be resolved}; a rehearsal takes no action, and the live pass would record the same skip (this box's registry stays LOCAL-ONLY)"
      result="${result}${result:+; }registry SKIPPED ($reason)"
    fi
  else
    sync_registry
    result="${result}${result:+; }${REGISTRY_RESULT}"
  fi
  # 7) THE `df` DELTA — before → after, signed, on the filesystem this pass reclaims from.
  df_after="$(hyg_df_mb "$CELL_HOME")"
  if [ -n "$df_before" ] && [ -n "$df_after" ]; then
    log "[hygiene] df ($CELL_HOME): $(hyg_df_delta "$df_before" "$df_after")"
    result="${result}${result:+; }df $(hyg_df_delta "$df_before" "$df_after")"
  else
    # An unreadable instrument cannot be reported as a delta — and must not read as a clean pass.
    log "[hygiene] CANNOT-VERIFY: free space at $CELL_HOME could not be read ($(hyg_df_delta "$df_before" "$df_after"))"
    result="${result}${result:+; }CANNOT-VERIFY: df unreadable at $CELL_HOME (no delta)"
    h_rc=3
  fi
  # ⛔ A REHEARSAL IS NOT A VERDICT. `--dry-run` is the verb an operator is told to run FIRST, and it
  # performs no action at all (the prune and both sweeps are logged as WOULD), so it cannot know
  # whether the previous failure is fixed. The rule and its two directions live in ONE place,
  # `state_write_rehearsal`, so `reap`, `merge` and `doctor` cannot drift from `hygiene` again.
  if [ "$dry" = "--dry-run" ]; then
    state_write_rehearsal hygiene "$h_rc" "$result"
    log "[hygiene] dry-run: $result"
    return "$h_rc"
  fi
  state_write hygiene "$h_rc" "$result"
  if [ "$stop_reaper" = 1 ]; then
    log "[hygiene] STOP arrived during this pass — worktree reaper NOT run"
  fi
  log "[hygiene] $result"
  return "$h_rc"
}

# ── DOCTOR (reap + keep the ONE dispatcher running) ─────────────────────────────────────────────
# ⛔ The doctor does NOT dispatch PR repair itself. The shipped `orch-loop.sh` sweep already does —
# `fix-one.sh` for red/conflicting PRs, `merge-one.sh` for review→record→rail — and #1872 measured
# what a second classifier costs (two answers to one question on 36-41% of live PRs). So the action
# here is to guarantee THAT loop runs. Two directions, deliberately different:
#   * session GONE and the cell is supposed to be running  -> `start` (the shipped, idempotent path;
#     it re-applies the harness, re-checks the cell and launches). Workers live in their own
#     sessions, so restarting the controller does not disturb them.
#   * session UP but the heartbeat is STALE                 -> REPORT, never kill. A controller that
#     is alive-but-slow may be mid-merge/mid-spawn; stopping it is a P0-consequence action
#     (destroying live work) and stays human (README §6.5.5, AGENTS.md P0 rule).
# ⛔ THE HEARTBEAT VERDICT IS ONE IMPLEMENTATION, TWO SUPERVISORS (review P1, #2402). A service-managed
# controller has NO tmux session by design, so the session branch below can never evaluate it — and the
# doctor's ABSENT branch would log `controller RESTARTED` every pass (the supervisor answers "already
# running") while `CONTROLLER STALE` became unreachable on exactly the box shape #2402 creates. `$who`
# names what is up so the log stays true in both modes. Sets the caller's `result` (bash dynamic scope).
controller_heartbeat_verdict() { # <who>
  local who="$1" hb t now age
  hb=0
  t="$(cat "$O/heartbeat" 2>/dev/null)"
  # ⛔ A DIGIT RUN IS NOT NECESSARILY AN INSTANT (review P2, #2402) — the four guards
  # install-controller-service.sh:253-264 documents, carried here because this helper is now the ONLY
  # staleness signal on the service-managed path: `$(( ))` parses a LEADING-ZERO run as OCTAL while
  # `[ ]` parses it as DECIMAL (a fabricated multi-year age), a FUTURE heartbeat makes the age NEGATIVE
  # and `[ -N -le bound ]` is true for every negative (a DEAD controller reads FRESH forever), and a
  # long run overflows. Anything unparseable is 0 — reported as "no heartbeat recorded yet", never fresh.
  case "${t:-}" in
    ''|*[!0-9]*) : ;;
    *) if [ "${#t}" -le 12 ]; then
         hb=$(( 10#$t ))
         now="$(date +%s)"
         if [ "$hb" -lt 1000000000 ] || [ "$hb" -gt "$(( now + 60 ))" ]; then hb=0; fi
       fi ;;
  esac
  if [ "$hb" -gt 0 ]; then
    age=$(( $(date +%s) - hb ))
    [ "$age" -ge 0 ] || age=0
    if [ "$age" -gt "$CONTROLLER_STALE_S" ]; then
      log "[doctor] ⛔ CONTROLLER STALE: $who is up but its heartbeat is ${age}s old (> ${CONTROLLER_STALE_S}s). NOT killing it (a live controller may be mid-merge); reap and the independent merge role continue. Fix by hand if this persists."
      result="$result; CONTROLLER STALE ${age}s (not killed)"
    else
      result="$result; controller RUNNING (heartbeat ${age}s)"
    fi
  else
    result="$result; controller RUNNING (no heartbeat recorded yet)"
  fi
}

# Is a controller OF THIS STATE DIR running with no session? The harness's own single-instance lock
# ($O/.orch.lock, taken by orch-loop.sh) is the ONLY authority: liveness plus the #1178 identity rule.
# FALSE is safe here: a false negative falls through to the pre-existing ABSENT→restart arm, which is
# what the doctor did before services existed.
# ⛔ FALSE IS SAFE; A FALLBACK WITNESS THAT CANNOT BE FALSE IS A FALSE PASS (review P0, #2402). This used
# to end in `loop_alive`, which reads $ROLES_DIR/loop.pid — and run_loop() writes that file with its OWN
# pid. Inside `doctor loop` (the only mode a cell runs: start_doctor_loop launches `doctor loop`) the
# fallback was therefore a TAUTOLOGY: service_controller_present returned 0 for a cell whose controller had
# died, the ABSENT→restart arm below became UNREACHABLE, and the doctor logged `controller RUNNING (no
# heartbeat recorded yet)` over exactly the "dispatches nothing, reads as idle" defect #2402 exists to
# remove — and over a start-limited `failed` unit that StartLimitBurst is designed to produce. A witness
# must be able to say no; the controller's own lock owner is the only one that can.
# ⛔ AND THE MATCH IS THE SHAPE `lock_controller_pid` USES (`<shell> <…/orch-loop.sh>`), NOT AN `$O/`
# PREFIX: HARNESS_PIN_DIR is normally $CELL_HOME/harness, so the prefix form missed a live controller.
# ⛔ AND THE SHAPE ALONE IS NOT OWNERSHIP EITHER — THE AGE IS (review P2, #2402). `lock_controller_pid`
# (scripts/cloud-cell-supervisor.sh) carries the shape AND the age, and states why both are load-bearing:
# the lock is data on disk and outlives a `kill -9`, so the OS can RECYCLE that pid onto a peer repo's
# controller — which on this box is the same basename from the same shared harness path, so the shape
# matches. That is the exact vector for which `lock_controller_pid` refuses a false positive, and this
# function copied only half of it: with a recycled pid the ABSENT→restart arm became UNREACHABLE on a
# service-managed cell and the doctor logged `controller RUNNING` over a dead controller — the same
# "witness that cannot say no" this file fixed at P0 by another route (the loop.pid tautology).
# A controller writes $O/.orch.lock AFTER it starts, so a process that BEGAN after the lock was written
# cannot be its owner. Unprovable age returns 1 (NOT ours): a false negative falls through to the
# ABSENT→restart arm, and that arm's `supervisor start` refuses over a controller that is really alive —
# so the failing direction here is the safe one, unlike the supervisor's `stop`, which must not signal.
service_controller_present() {
  local pid c lt se r d h m s started
  [ -f "$O/.orch.lock" ] || return 1
  pid="$(tr -dc '0-9' < "$O/.orch.lock" 2>/dev/null || true)"
  num_ok "${pid:-}" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  c="$("$PS_BIN" -p "$pid" -o command= 2>/dev/null)" || return 1
  # shellcheck disable=SC2086
  set -- $c
  [ "$#" -ge 2 ] || return 1
  case "${1##*/}" in bash|sh|dash|zsh) ;; *) return 1 ;; esac
  case "${2##*/}" in orch-loop.sh) ;; *) return 1 ;; esac
  # ── the age rule (pinned to `_proc_began_after`, scripts/cloud-cell-supervisor.sh) ──────────
  # ⛔ NOT `num_ok`: an epoch is TEN digits and num_ok rejects >=10, so routing `lt` through it would
  # make every lock "unprovable" and turn this witness into a permanent false negative.
  lt="$(date -r "$O/.orch.lock" +%s 2>/dev/null)" || return 1
  case "${lt:-}" in ''|*[!0-9]*) return 1 ;; esac
  se="$("$PS_BIN" -p "$pid" -o etime= 2>/dev/null | tr -d '[:space:]')" || return 1
  [ -n "$se" ] || return 1
  d=0
  case "$se" in *-*) d="${se%%-*}"; r="${se#*-}" ;; *) r="$se" ;; esac
  case "$d" in ''|*[!0-9]*) return 1 ;; esac
  case "$r" in
    *:*:*) h="${r%%:*}"; r="${r#*:}"; m="${r%%:*}"; s="${r##*:}" ;;
    *:*)   h=0;                m="${r%%:*}"; s="${r##*:}" ;;
    *) return 1 ;;
  esac
  case "$h$m$s" in ''|*[!0-9]*) return 1 ;; esac
  # `10#` because etime ZERO-PADS and bash reads a leading zero as OCTAL (`08` is an error) — the
  # same trap `_proc_start_epoch` documents after it was reproduced with an `08:31` stub.
  d=$((10#${d:-0})); h=$((10#${h:-0})); m=$((10#${m:-0})); s=$((10#${s:-0}))
  started=$(( $(date +%s) - (d * 86400 + h * 3600 + m * 60 + s) ))
  [ "$started" -le "$(( lt + 5 ))" ] || return 1
  return 0
}

run_doctor() {
  begin_pass
  # ${1:-}: NO mode means a LIVE pass (an empty string never equals `--dry-run`). An ABSENT or
  # empty `$1` MUST be survivable — a bare `"$1"` here is what killed the scheduler on its first
  # tick (#2424), and the loop still asks this role to run with an empty mode on every schedule;
  # see "POSITIONAL PARAMETERS: WHICH MAY BE ABSENT" before run_role_pass for the file-wide audit.
  local dry="${1:-}" rc hb age result="" tmp rpid
  # Through the ROLED PASS, not run_reap directly: a nested reap must take the reap role lock like
  # any other pass, or an operator's concurrent `reap` and this one would sample each other's lanes
  # and could both decide the same session is wedged (two kills, one corpse — the double-act the
  # lock exists to prevent). A lock held elsewhere makes this a logged SKIP, and the reap state is
  # then the sibling pass's record, which is the truth either way.
  local rrc=0 src_rc=0
  run_role_pass reap "$dry" >/dev/null || rrc=$?
  # ⛔ A POLICY VERDICT FROM THE NESTED REAP IS NOT A FAILURE OF THIS PASS (#2163 review r8, P1).
  # `rrc=4` says the reaper judged nothing because its ancestry policy refuses every lane on this
  # surface (§11.4) — that fact is recorded in the REAP row, and this pass's own work (supervision)
  # is unaffected. Carrying 4 into the doctor's record would make the row read `INERT` for a doctor
  # that restarted the controller correctly. It collapses to 0 HERE, not into a failure.
  [ "$rrc" -eq 4 ] && rrc=0
  result="reap: $(state_get reap last_result | cut -c1-160)"
  if [ ! -f "$DESIRED" ]; then
    log "[doctor] cell is not started (no $DESIRED) — supervising nothing; reap still ran"
    # The nested reap's rc travels with the record: "not started" is not a licence to pair rc=0 with
    # a cannot-verify result (the invariant this function states four lines below).
    # ⛔ …and a REHEARSAL still may not overwrite the stored verdict: in `--dry-run` the nested reap is
    # a rehearsal too, so its 0 is not evidence about a controller restart that previously failed.
    if [ "$dry" = "--dry-run" ]; then
      state_write_rehearsal doctor "$rrc" "not-started; $result"; return "$rrc"
    fi
    state_write doctor "$rrc" "not-started; $result"; return "$rrc"
  fi
  # ⛔ `session_present`, not `has-session`: the ABSENT branch below RESTARTS the controller, so a
  # failed tmux read must never become evidence of absence. `has-session` answers rc=1 both for "no
  # such session" and for every client/server error, so a blind read restarted a live cell's
  # controller and reported `controller RESTARTED` from a read that proved nothing.
  local csp=0
  session_present "$SESSION" || csp=$?
  if [ "$csp" -eq 3 ]; then
    log "[doctor] CANNOT-VERIFY: the controller session '$SESSION' could not be read — NOT restarting (a restart decided from a failed read answers a question nobody asked); the reap above and the independent merge role continue"
    result="$result; controller cannot-verify (the tmux read failed)"
    state_write doctor 3 "$result"
    log "[doctor] $result"
    return 3
  fi
  if [ "$csp" -eq 0 ]; then
    controller_heartbeat_verdict "tmux '$SESSION'"
  elif service_controller_present; then
    # ⛔ SERVICE-MANAGED, AND THE SESSION ARM CANNOT SEE IT (review P1, #2402). No session exists by
    # design (`exec`s the loop before the tmux launch), so without this branch every pass logged
    # "controller restarted" from a start that answered "already running", and a WEDGED controller —
    # alive, heartbeat stale — was never reported: the one signal that tells "dispatches nothing" from
    # "idle" was dead on exactly the box shape this PR creates.
    # ⛔ THE LABEL MUST NOT CLAIM MORE THAN THE READ (review P2 round 19, #2402 / C). `service_controller_present`
    # proves a LIVE, lock-owning controller with no session — not that a unit supervises it. This file reads no
    # unit here, so an orphaned controller that outlived its session (the shape `cmd_stop` documents), or a box
    # after `--uninstall`, was logged as "service-managed": supervision asserted from a lock, the
    # "claim nobody measured" shape this PR removes elsewhere. The substance (evaluate the heartbeat, do not
    # restart a live controller) is unchanged; the authoritative supervision read is `cmd_status`'s
    # `supervision:` row, which is not consulted on this path.
    log "[doctor] controller is up WITHOUT a tmux session — evaluating its heartbeat instead of restarting it (this read proves the CONTROLLER; whether a unit supervises it is decided by the rc-4/rc-5 arms, not here)"
    controller_heartbeat_verdict "the controller (no session)"
  elif [ "$dry" = "--dry-run" ]; then
    log "[doctor] WOULD restart the controller (tmux '$SESSION' absent, cell is started)"
    result="$result; would restart controller"
  else
    log "[doctor] controller session '$SESSION' is ABSENT on a started cell — restarting via the supervisor"
    if cell_stopped_midpass; then
      # A stop arrived while this pass was sampling: restarting the controller now would undo it.
      log "[doctor] STOP arrived during this pass — controller restart NOT launched"
      result="$result; STOP arrived mid-pass (restart not launched)"
      state_write doctor "$rrc" "$result"
      return "$rrc"
    fi
    if [ -n "${SUPERVISOR:-}" ] && [ -f "$SUPERVISOR" ]; then
      # ⛔ BACKGROUNDED and RECORDED: `start` can take up to CONTROLLER_START_TIMEOUT, and a `stop`
      # issued inside that window must be able to end it — an orphaned restart would complete, rewrite
      # `.desired`, and re-create the controller + doctor session, silently undoing the stop. The
      # record is identity-fenced like every other signal target here.
      # ⛔ AND the generation this pass observed is HANDED to the restart: `start` snapshots its own
      # baseline on entry, so a stop landing between this launch and that snapshot (bash startup, the
      # whole source) would otherwise be invisible and the restart would complete after the stop.
      STOP_GENERATION_AT_LAUNCH="$PASS_STOP_GEN" \
      ORCH_AUTOMATED_RESTART=1 \
      run_bounded "$CONTROLLER_START_TIMEOUT" bash "$SUPERVISOR" start >>"$O/logs/doctor.log" 2>&1 &
      local rpid=$!
      tmp="$ROLES_DIR/.restart.ident.tmp.$$"
      printf '%s|%s\n' "$rpid" "$(pid_ident "$rpid")" > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$ROLES_DIR/restart.ident" 2>/dev/null || rm -f "$tmp" 2>/dev/null
      wait "$rpid"; rc=$?
      rm -f "$ROLES_DIR/restart.ident"
      if [ "$rc" -eq 0 ]; then
        log "[doctor] controller restarted (supervisor start rc=0)"
        result="$result; controller RESTARTED"
      elif [ "$rc" -eq 5 ]; then
        # ⛔ A UNIT THAT CONVERGED TO `failed` IS NOT A CLEAN PASS (review P1 round 11, #2402). The supervisor
        # now answers rc 5 for a unit the manager has given up on (start limit hit), and keeps rc 4 for the
        # states a deliberate `systemctl stop` leaves. Scoring both as "not launched, not a failure" let a
        # STARTED cell (`.desired` present) with NO dispatcher be recorded as a clean pass, with `doctor
        # status` exiting 0 over it — the false green this whole change exists to remove, one layer in. A
        # failed unit is exactly what `--status` prints as unsupervised, so this pass must not certify it.
        log "[doctor] controller restart NOT launched — ${CONTROLLER_UNIT:-the controller unit} has CONVERGED TO FAILED (start limit): this cell has NO dispatcher and only a human re-arm brings it back"
        result="$result; controller restart not launched (unit FAILED — no dispatcher)"
        # ⛔ ITS OWN SLOT, like the `else` arm below (#2163 review r8, P1): `[ "$rrc" -eq 0 ] && rrc=1`
        # only RAISES a zero, so a nested reap that recorded cannot-verify (3) would swallow this
        # failure and the pass would say "cannot verify" over a cell whose unit has converged to failed.
        src_rc=1
      elif [ "$rc" -eq 4 ]; then
        # ⛔ THE SERVICE MANAGER OWNS A CONTROLLER IT HAS STOPPED (review P1, #2402). `start` answers rc 4
        # when an AUTOMATED restart would have to re-arm a unit the manager reports not active — a
        # deliberate `systemctl stop` (`.desired` survives it, so this pass would otherwise undo the
        # operator's stop within one pass) or a start limit that converged to `failed` (clearing it here
        # is what made a keyless cell retry forever with every surface reading supervised). Honouring it is
        # NOT a failed pass: the stop is the decision, and a failed unit is handled by the rc-5 arm above —
        # which is why this message no longer claims "a start limit that converged to failed" as well.
        log "[doctor] controller restart NOT launched — the service manager owns ${CONTROLLER_UNIT:-the controller unit} and reports it not active (a deliberate stop); a human 'cloud-cell-supervisor.sh start' re-arms it"
        result="$result; controller restart not launched (service-managed, unit not active)"
      else
        log "[doctor] controller restart FAILED (supervisor start rc=$rc) — see $O/logs/doctor.log"
        result="$result; controller restart FAILED rc=$rc"
        # ⛔ The supervision OUTCOME is part of the pass's rc. A started cell whose dispatcher is
        # absent and could not be restarted is not a clean pass, however well the reap half went.
        # ⛔ AND IT HAS ITS OWN SLOT (`src_rc`) SO IT STAYS EXPRESSIBLE (#2163 review r8, P1):
        # `[ "$rrc" -eq 0 ] && rrc=1` only ever RAISED a zero, so when the nested reap recorded
        # cannot-verify (3) a controller that was DOWN and could not be restarted recorded 3 as well —
        # "controller is down" was no longer sayable in the rc at all.
        src_rc=1
      fi
    else
      log "[doctor] CANNOT-VERIFY: controller absent and DOCTOR_SUPERVISOR is not a file — cannot restart"
      result="$result; controller restart cannot-verify (no supervisor)"
      src_rc=3
    fi
  fi
  # ── ONE place where the two halves' verdicts combine. The supervision FAILURE is dominant (a cell
  # with a dead controller is the more urgent fact and must survive in the rc, whatever the reap
  # recorded); a supervision that could not be VERIFIED raises a clean/ policy-inert pass to
  # cannot-verify — it never lowers a 3 it found already there.
  if [ "$src_rc" -eq 1 ]; then
    rrc=1
  elif [ "$src_rc" -eq 3 ] && [ "$rrc" -eq 0 ]; then
    rrc=3
  fi
  # A nested reap that could not be taken makes THIS pass partial too: the supervision half ran, but
  # the pass as a whole must not be recorded as a clean one (cannot-verify is never a pass).
  # ⛔ A REHEARSAL IS NOT A VERDICT: `doctor --dry-run` restarts nothing, so its "would restart" (or
  # a clean nested reap) says nothing about a controller restart a previous pass recorded `FAILED rc=1`.
  if [ "$dry" = "--dry-run" ]; then
    state_write_rehearsal doctor "$rrc" "$result"
  else
    state_write doctor "$rrc" "$result"
  fi
  log "[doctor] $result"
  return "$rrc"
}

# The RECORDED loop's liveness — THREE-VALUED, with the reason it decided named:
#
#     alive | dead:<reason> | unknown:<reason> | absent:<reason>
#
# ⛔ WHY THREE-VALUED (agent-infra#2306). `loop_alive` answered yes/no, so `return 1` folded TWO
# different facts into one no: "the recorded incarnation is GONE" and "I could not read the record".
# `role_row` then read neither — it derived `WAITING` from the loop's start record alone — and printed
# `loop: NOT RUNNING` beside four `WAITING ... 274s ago` rows on pi-cell-4. The reader concludes "the
# first pass is slow"; the truth is that the scheduler was killed with the invoking session and no
# pass would ever complete. Rows are what a reader and a supervisor act on, so the rows were the lie
# (the same family as #2249/#2221).
#
# The states are `docs/ops/fleet-liveness.md`'s doctrine applied to this surface, not a second
# vocabulary: IDENTITY is decided first and is the ONLY source of `dead`; an unreadable read is a
# NAMED abstention (`unknown`), never a death witness (a `kill -0` that fails proves absence, but an
# unparseable pid proves nothing). `absent` is kept apart from both: with no loop record at all there
# is no incarnation to witness the death of — but nothing was unreadable either, so calling it
# `unknown` would abstain over a fact that IS known ("no loop was ever recorded here").
#
# A bare `kill -0` says a pid exists, not that it is OUR loop: after a tmux server restart, an OOM
# kill or a crash the pid survives in the file and the OS may recycle it, so a dead loop would read as
# RUNNING (the fleet's one identity rule, #1178 — applied to the loop's own record, not only to the
# lanes it reaps).
loop_state() {
  local f="$ROLES_DIR/loop.pid" pid ls rec
  [ -f "$f" ] || { printf 'absent:no-loop-record\n'; return 0; }
  pid="$(cat "$f" 2>/dev/null)" || { printf 'unknown:loop-record-unreadable\n'; return 0; }
  num_ok "${pid:-}" || { printf 'unknown:pid-unparseable\n'; return 0; }
  # ⛔ A FAILED `kill -0` IS NOT ALWAYS ABSENCE: it also fails with EPERM for another uid's process,
  # which is an UNREADABLE read and must abstain (the doctrine this function's own comment states —
  # only a positive witness may produce `dead`). `2>/dev/null` was throwing that distinction away.
  local kerr
  if ! kerr="$(kill -0 "$pid" 2>&1)"; then
    case "$kerr" in
      *ermitted*|*"not owner"*|*EPERM*) printf 'unknown:not-permitted\n' ;;
      *) printf 'dead:pid-gone\n' ;;
    esac
    return 0
  fi
  ls="$(pid_ident "$pid")"
  [ -n "$ls" ] || { printf 'unknown:identity-unreadable\n'; return 0; }
  rec="$(cat "$ROLES_DIR/loop.ident" 2>/dev/null)"
  [ -n "$rec" ] || { printf 'unknown:no-identity-record\n'; return 0; }
  [ "$rec" = "$pid|$ls" ] || { printf 'dead:identity-mismatch\n'; return 0; }
  printf 'alive\n'
}

# `alive` in one test, for every caller that only needs "is it up" (role locking, stop, the loop's
# own quiesce). An ABSTENTION is NOT liveness evidence, so it answers no here — but the rows, which
# have to distinguish "dead" from "could not tell", read `loop_state` itself.
loop_alive() { [ "$(loop_state)" = alive ]; }

# Is the loop's TRANSCRIPT advancing inside the worst-case pass window? A live pid is a process, not
# a scheduler: a hung or SIGSTOPped loop keeps its pid and writes nothing, and `WAITING ... 274s ago`
# is exactly what that looks like. The transcript is `logs/cell-doctor.log` — the file `start`'s own
# `tee -a` creates and ONLY the loop's stdout reaches — falling back to `logs/doctor.log`, which every
# pass appends its summary line to (`reap seen=…`, `merge candidates=…`, `hygiene …`, `doctor …`).
# The fallback is weaker on purpose and stated: a MANUAL role verb also writes doctor.log, so on a box
# where the tee file is missing, a hand-run `reap` can refresh the "the loop moved" evidence.
loop_progress_age() { # → seconds since the newest transcript write; empty when there is none
  local newest=0 m f
  for f in "$WORKER_LOG_DIR/cell-doctor.log" "$WORKER_LOG_DIR/doctor.log"; do
    [ -f "$f" ] || continue
    m="$(mtime_epoch "$f")"
    case "${m:-}" in ''|*[!0-9]*) continue ;; esac
    [ "$m" -gt "$newest" ] && newest="$m"
    # The loop's OWN transcript wins outright: a manual verb can only touch the fallback.
    case "$f" in *cell-doctor.log) break ;; esac
  done
  [ "$newest" -gt 0 ] || return 0
  printf '%s' "$(( $(date +%s) - newest ))"
}

# ── STATUS (configured vs actually ran) ─────────────────────────────────────────────────────────
# The supervisor's `status` delegates here. "RUNNING" is a LIVE LOOP PID plus a PASS RECENT ENOUGH;
# the two are separate facts and both are reported, because a live loop that has stopped passing and
# a dead loop are different repairs. A role that never ran is named as NEVER RAN — never as idle.
#
# ⛔ NOTHING HERE MAY PRINT `WAITING`/`RUNNING` WITHOUT A PROVEN-ALIVE LOOP (#2306). `WAITING` is a
# PROMISE that something is in progress; it used to be derived from `loop.started` (and from a stale
# `.running` marker a SIGKILL left behind) with no liveness check at all. Rows per loop state:
#
#   alive          → WAITING (no record yet, inside the grace + a moving transcript) / RUNNING
#   dead:<reason>  → DEAD      the loop is not running (<reason>) — and the verb fails
#   unknown:<rsn>  → UNKNOWN   cannot be verified (<reason>) — and the verb fails (rc=3)
#   absent:…       → NEVER RAN for a role with no record (a fact about the role, not the loop)
role_row() { # <role> <stale-bound-seconds>
  local role="$1" bound="$2" f rc ep age st paged
  f="$ROLES_DIR/$role.state"
  st="${LOOP_STATE:-$(loop_state)}"
  if [ ! -f "$f" ]; then
    # ⛔ `absent` MUST NOT REACH THE WAITING BRANCHES BELOW (#2306 review): with no loop record there is
    # nothing to promise, and `run_loop`'s TERM/HUP trap removes `loop.pid`/`loop.ident` but NOT
    # `loop.started` or `.$role.running` — so `start` then `stop` mid-first-pass would have printed
    # `loop: STOPPED` beside `WAITING its first pass is still running`, the very #2306 shape in a
    # different state. It is the one state where "no pass recorded" is a plain fact.
    case "$st" in
      dead:*)
        printf '%-8s DEAD      the loop is not running (%s); no pass recorded, and none will come\n' \
          "$role" "${st#dead:}"
        return 1 ;;
      unknown:*)
        printf '%-8s UNKNOWN   the loop has no verifiable liveness (%s); no pass recorded\n' \
          "$role" "${st#*:}"
        return 3 ;;
      absent:*)
        if [ "${desired_for_rows:-0}" = 1 ]; then
          printf '%-8s NEVER RAN (no pass recorded, and no loop record)\n' "$role"
        else
          printf '%-8s NEVER RAN (no pass recorded; the cell is not started)\n' "$role"
        fi
        return 1 ;;
    esac    # A first pass can legitimately outlast the flat grace: the loop's first tick runs doctor,
    # merge and hygiene IN SEQUENCE, and a first merge pass may take MERGE_BUDGET_S + a rail call.
    # `run_role_pass` records an in-progress marker, so a pass that is STILL RUNNING reads WAITING —
    # bounded by ALL_PASSES_S, so a marker left by a killed loop cannot hide a NEVER RAN for ever.
    local rn; rn="$ROLES_DIR/.$role.running"
    if [ -f "$rn" ]; then
      local rn_age; rn_age=$(( $(date +%s) - $(mtime_epoch "$rn" || printf 0) ))
      if [ "${rn_age:-0}" -ge 0 ] && [ "${rn_age:-0}" -lt "$ALL_PASSES_S" ]; then
        printf '%-8s WAITING   its first pass is still running (%ss)\n' "$role" "$rn_age"
        return 0
      fi
    fi
    if [ "${NEVER_OK:-0}" = 1 ]; then
      # ⛔ A LIVE PID AND A FRESH START RECORD ARE NOT PROGRESS. The loop must also have WRITTEN
      # something inside its own worst-case pass window, or "it is working on it" is a guess.
      paged="$(loop_progress_age)"
      if [ -n "${paged:-}" ] && [ "$paged" -le "$ALL_PASSES_S" ]; then
        printf '%-8s WAITING   loop started %ss ago; no pass recorded yet (transcript %ss ago)\n' \
          "$role" "${LOOP_UP_S:-0}" "$paged"
        return 0
      fi
      # ⛔ "NO TRANSCRIPT" IS NOT "WROTE NOTHING" (#2306 review): an empty age means neither file could
      # be aged at all (never created, or rotated away), which is an unreadable read — name it as one
      # instead of asserting a hang with a `?` for the number.
      if [ -z "${paged:-}" ]; then
        printf '%-8s UNKNOWN   the loop is alive but has NO transcript in %s to prove progress (no pass recorded)\n' \
          "$role" "$WORKER_LOG_DIR"
      else
        printf '%-8s UNKNOWN   the loop is alive but its transcript has not moved for %ss (bound %ss); no pass recorded\n' \
          "$role" "$paged" "$ALL_PASSES_S"
      fi
      return 3
    fi
    printf '%-8s NEVER RAN (no pass recorded)%s\n' "$role" ""
    return 1
  fi
  rc="$(state_get "$role" last_rc)"; ep="$(state_get "$role" last_pass_epoch)"
  case "${ep:-}" in ''|*[!0-9]*) ep=0 ;; esac
  age=$(( $(date +%s) - ep ))
  case "$st" in
    dead:*)
      # The LAST PASS is still reported — it is the only record of what the role did — but the row's
      # verdict is the loop's: a dead scheduler means no further pass, whatever the last one said.
      printf '%-8s DEAD      the loop is not running (%s); last pass %ss ago rc=%s — %s\n' \
        "$role" "${st#dead:}" "$age" "${rc:-?}" "$(state_get "$role" last_result | cut -c1-150)"
      return 1 ;;
    unknown:*)
      printf '%-8s UNKNOWN   the loop has no verifiable liveness (%s); last pass %ss ago rc=%s — %s\n' \
        "$role" "${st#*:}" "$age" "${rc:-?}" "$(state_get "$role" last_result | cut -c1-150)"
      return 3 ;;
    alive)
      printf '%-8s RUNNING   last pass %ss ago rc=%s — %s\n' "$role" "$age" "${rc:-?}" "$(state_get "$role" last_result | cut -c1-150)" ;;
    *)
      printf '%-8s NO LOOP   last pass %ss ago rc=%s — %s\n' "$role" "$age" "${rc:-?}" "$(state_get "$role" last_result | cut -c1-150)" ;;
  esac
  # ⛔ A pass that did NOT complete is not healthy, however recent it is: "the controller is down and
  # the restart failed" (doctor rc=1) or "I could not read the lanes" (reap rc=3) used to print here
  # and still exit 0, which is the false green this verb exists to remove. The next CLEAN pass clears
  # it, so a transient failure reads as one failing pass, not as a dead cell.
  # ⛔ An UNREADABLE verdict is not a clean one. `${rc:-0}` made a record whose `last_rc` is missing or
  # non-numeric (a truncated write, a hand-edited state file) read as a CLEAN pass — the row printed
  # `rc=?` and the verb exited 0, so a probe saw health where nothing was known. Fail closed instead:
  # the same "cannot-verify is never a pass" direction every other read in this file takes.
  case "${rc:-}" in
    ''|*[!0-9]*) printf '%-8s FAILED    the record holds no readable rc (cannot-verify)\n' "$role"; return 1 ;;
  esac
  case "${rc:-0}" in
    0) ;;
    # ⛔ rc=4 IS A POLICY VERDICT, NOT A FAILURE (#2163 review r8, P1). The reaper COMPLETED and judged
    # nothing because its ancestry policy refuses every lane this surface has (§11.4) — the Linux-cell
    # steady state, not an incident. Printing FAILED here made the operator's health verb permanently
    # red on a healthy cell (and an alarm that can never clear is trained-to-be-ignored). It is NAMED
    # (never a silent green), and the staleness bound below still applies: a reaper that stopped
    # passing reads STALE.
    4) printf '%-8s INERT     last pass rc=4 — judged no tree and refused every lane it found BY POLICY (this surface has no fleet ancestry marker; §11.4) — reported, not failed\n' "$role" ;;
    *) printf '%-8s FAILED    last pass rc=%s (the pass did not complete)\n' "$role" "${rc:-?}"; return 1 ;;
  esac
  if [ "$age" -gt "$bound" ]; then
    printf '%-8s STALE     no pass in %ss (bound %ss)\n' "$role" "$age" "$bound"
    return 1
  fi
  return 0
}

# Keep the STRONGEST non-zero verdict across the four rows: a DEAD loop (1) outranks an ABSTENTION
# (3) — a proven absence is a stronger answer than "could not tell" — and neither is masked by a clean
# row printed after it.
ROW_RC=0
desired_for_rows=0
row_rc_merge() { # <the rc role_row returned>
  case "${1:-0}" in
    0) ;;
    3) [ "${ROW_RC:-0}" -eq 1 ] || ROW_RC=3 ;;
    *) ROW_RC=1 ;;
  esac
}

run_status() {
  local rc=0 desired=0 started r
  ROW_RC=0
  [ -f "$DESIRED" ] && desired=1
  # The grace window is derived from the LOOP's own start record, never from a role's, so it cannot
  # be refreshed by a pass and cannot outlive the loop that wrote it.
  # NOT `_AGE`-named on purpose: the name is an age-SHAPED identifier, and the declared-surface scan
  # rightly treats any `*_AGE` assignment as a candidate liveness bound. This is a display age for a
  # status row, not a bound — it is compared against DOCTOR_GRACE_S below, and against nothing else.
  # (The stale bounds derived from ALL_PASSES_S are applied to a ROLE's last-pass age in `role_row`, and
  # the transcript freshness that gates `WAITING` is read by `loop_progress_age`.)
  NEVER_OK=0; LOOP_UP_S=""
  # Whether the cell is SUPPOSED to be up — read once, so a row's prose ("the cell is started") is
  # decided by the same marker the loop line used, not by a second read of the marker file.
  desired_for_rows="$desired"
  # ⛔ THE LOOP'S LIVENESS IS DECIDED ONCE, HERE, and every row below is derived from it (#2306).
  # Deciding it per row was where the false `WAITING` came from. `LOOP_STATE` is exported into the
  # rows' scope (they read it, they do not re-derive it) so one read produces one verdict.
  LOOP_STATE="$(loop_state)"
  started="$(cat "$ROLES_DIR/loop.started" 2>/dev/null)"
  case "${started:-}" in
    ''|*[!0-9]*) : ;;   # no/unknown age -> no grace (fail-closed)
    *) LOOP_UP_S=$(( $(date +%s) - started ))
       [ "$LOOP_UP_S" -ge 0 ] && [ "$LOOP_UP_S" -le "$DOCTOR_GRACE_S" ] && NEVER_OK=1 ;;
  esac
  case "$LOOP_STATE" in
    alive)
      printf 'loop:    RUNNING (pid %s)\n' "$(cat "$ROLES_DIR/loop.pid" 2>/dev/null)" ;;
    dead:*)
      # The cell's DESIRED state qualifies the prose, exactly as the `absent:*` arm below does: a stop
      # that could not remove the record of a SIGKILLed loop must not be reported as "the cell is
      # started" (rc is already forced to 0 for an undesired cell at the end of this function).
      if [ "$desired" = 1 ]; then
        printf 'loop:    NOT RUNNING (dead:%s — cell is started, the doctor loop is expected)\n' "${LOOP_STATE#dead:}"
        rc=1
      else
        printf 'loop:    STOPPED (cell not started; the loop record is stale — dead:%s)\n' "${LOOP_STATE#dead:}"
      fi ;;
    absent:*)
      if [ "$desired" = 1 ]; then
        printf 'loop:    NOT RUNNING (absent:%s — cell is started, the doctor loop is expected)\n' "${LOOP_STATE#absent:}"
        rc=1
      else
        printf 'loop:    STOPPED (cell not started; roles are not expected to pass)\n'
      fi ;;
    *)
      # A read that could not be made is not a verdict: name it, and never print the optimistic rows
      # under it. Exit 3 is the abstention code every other surface here uses.
      printf 'loop:    UNKNOWN — its liveness cannot be verified (%s)\n' "${LOOP_STATE#*:}"
      rc=3 ;;
  esac
  # reap runs INSIDE the doctor pass, so it inherits the same worst-case gap.
  for r in reap doctor; do
    role_row "$r" "$DOCTOR_STALE_S"; row_rc_merge $?
  done
  # A merge pass may last MERGE_BUDGET_S plus one overrunning rail call, and everything else in the
  # tick may run before the NEXT one starts (see ALL_PASSES_S).
  role_row merge $((ALL_PASSES_S + MERGE_INTERVAL)); row_rc_merge $?
  # …and a hygiene pass waits behind doctor+merge, plus its own bounded run.
  role_row hygiene $((ALL_PASSES_S + HYGIENE_INTERVAL)); row_rc_merge $?
  case "${ROW_RC:-0}" in
    1) rc=1 ;;
    3) [ "$rc" -eq 1 ] || rc=3 ;;
  esac
  if [ "$desired" = 1 ]; then
    # A started cell whose loop is gone is not healthy even if every role's last pass is recent.
    [ "$rc" -ne 0 ] || loop_alive || rc=1
  else
    # Not started: report, never fail. `stop` must stay a successful verb.
    rc=0
  fi
  return "$rc"
}

# ── LOOP ────────────────────────────────────────────────────────────────────────────────────────
# One timer, three intervals, run IN SEQUENCE in this process — deliberately, so the loop can never
# accumulate overlapping children. The cost is that a slow pass (a rail call up to RAIL_TIMEOUT, a
# worktree sweep) delays the roles after it in that tick, so the intervals are bounds on "at least
# this often", not deadlines. Each role also takes its own lock (role_lock), so an operator verb and
# this loop can meet without a second pass starting.
# ⛔ AN ABSENT MODE IS A LIVE PASS — the invariant every role carries itself (agent-infra#2135/#2424).
# `run_loop` USED TO dispatch `doctor`, `merge` and `hygiene` with NO second argument, so `"$@"`
# expanded to nothing and each of those roles' `local dry="$1"` read an UNBOUND `$1`: under `set -u`
# the loop died on its first tick, every time a cell started it (`cloud-cell-doctor.sh: line 1385: $1: unbound
# variable` — three recorded instances on cell-4). `doctor` is first in the tick, so it was the one
# that crashed; `merge` and `hygiene` carried the identical latent crash and would have died on the
# tick after it. `status` kept printing a live loop off the stale pid file, so the outage read as a
# slow first pass — the inert-enforcer shape the whole role set exists to prevent. (The `start`
# message that blamed a file that was present is a separate fix, shipped by #2306.)
#
# The default therefore lives in EACH ROLE (`local dry="${1:-}"`), not only in this dispatcher: the
# invariant is "no mode means a live pass", not "this caller happens to pass one". That redundancy is
# deliberate — #2424 shipped twice (#2555 had ALREADY made the loop bind it explicitly,
# `run_role_pass doctor ""`, before this branch was rebased onto it) — so a FUTURE bare dispatch
# cannot reintroduce the crash, and the
# invariant is testable at the role boundary rather than through the loop's timing. `reap` is not
# bare-dispatched today (`run_doctor`'s nested `run_role_pass reap "$dry"` and the CLI's `${dry}` both
# bind it) and gets the same default anyway, for that same future-proofing.
# ⛔ The `[ "$dry" = "--dry-run" ]` branches are safe with an empty mode BY CONSTRUCTION: an empty
# string equals `--dry-run` nowhere, so every rehearsal arm falls through to the live path.
#
# ── POSITIONAL PARAMETERS: WHICH MAY BE ABSENT, AND WHICH STAY FATAL ─────────────────────────────
# The audit behind those four defaults, so the next `local x="$1"` in this file is a DECISION
# rather than an imitation of whichever shape happens to be nearby. Same rule `rail-refusal.sh`
# already follows (`"${1:-}"` on its readers): a default is right only when the EMPTY value is
# already meaningful AND is the safe direction. Otherwise the read stays fatal and names the caller
# as the buggy party — a default there would ARM the dangerous path with an empty identity.
#
#   MODE FLAGS — defaulted "${1:-}"; absent/empty = a LIVE pass (not a rehearsal):
#     run_reap, run_merge, run_hygiene, run_doctor.
#     ⛔ WHY empty means LIVE, not dry: `parse_dry` prints NOTHING for a live run and `--dry-run`
#     for a rehearsal, so "" is ALREADY the live value at every bound caller (the CLI's `${dry}`, the
#     loop's explicit `""`, `run_doctor`'s nested `run_role_pass reap "$dry"`). Flipping "" to mean
#     rehearsal would turn every live verb — including the loop's own scheduled pass — into a silent
#     no-op: an inert enforcer, strictly worse than the crash it would fix. Rehearsal stays OPT-IN
#     (`--dry-run`), and the suite pins BOTH directions so the distinction cannot drift.
#
#   REQUIRED — deliberately bare `"$1"`/`"$2"`, NO default; absent stays fatal:
#     state_write(role, rc), state_write_rehearsal(role, own), lock_claim(d, tmp), reclaim_lock(d),
#     role_lock(role), role_unlock(role), bounded(s), run_bounded(s), pid_ident(pid),
#     human_above(pid), attestation_clean(pr, head), role_row(role, bound), run_role_pass(role),
#     controller_heartbeat_verdict(who).
#     * who (controller_heartbeat_verdict) — it NAMES what is up (`tmux '<session>'`, `the
#       controller (service-managed)`) in the line the operator reads. An empty default would print a
#       diagnosis that names nobody — `⛔ CONTROLLER STALE:  is up but …` — so the read stays fatal
#       and the caller that omitted it is the bug. The BARE read arrived with #2402, after this audit
#       was written, and the suite's exhaustive walk is what caught it — the audit working.
#     * role/rc/own/bound — an empty ROLE records a pass nowhere, and an empty BOUND makes
#       `[ "" -ge N ]` an arithmetic error: the caller is wrong and saying so beats a silent write
#       to nowhere.
#     * d, s — an empty lock dir takes a lock nowhere; an empty timeout bounds nothing.
#     * pid (pid_ident, human_above) — an empty pid matches no process, and `human_above` would then
#       answer "no human is above" about NOTHING: exactly the false negative the reaper must not be
#       able to produce before a kill.
#     * pr/head (attestation_clean) — an empty HEAD would be graded as an attestation "for this
#       head", i.e. a false PASS onto the rail. That is the false-green class the rail exists for,
#       so this read must never acquire a default.
#     * run_role_pass's role — "" would fall to the `*)` arm's `unknown role ""`; not bare-dispatched
#       anywhere, so it stays fatal.
#   EMBEDDING — an ANNOTATION, never an exemption (review P2): a value that embeds the positional —
#   `tmp="$1/.own.tmp.$$"`, `d="$ROLES_DIR/.$1.lock"` — is GRADED on the read (`bare` above, hence
#   `lock_claim`'s `tmp` and `role_unlock`'s `d` are on the REQUIRED list) and merely ANNOTATED as
#   embedding.
#   It used to be a separate ungraded bucket, and that bucket swallowed `local dry="$1 "` and
#   `local x="$1$2"` — both read an absent argument exactly like `local x="$1"` and both died the
#   #2424 death — while printing a ✅ "reported, not graded". A bucket that reports instead of grading
#   is how a fail-open classifier looks.
# ⛔ SCOPE — WHAT THIS AUDIT DOES NOT COVER (review P2). It walks `local` BINDINGS, i.e. lines matching
#   `^[[:space:]]*local `. A positional read that is not bound by `local` is NOT graded by it. The
#   instances today, all in functions whose every caller binds: `free_mb` (`${1:-.}`), `hyg_df_mb`
#   (`${1:-$CELL_HOME}`), `hyg_df_delta` (`${1:-?}`, `${2:-?}`), `num_ok` (`${1:-}`), `row_rc_merge`
#   (`${1:-0}`), `state_get` (`$1`, `$2`), `mtime_epoch`, `pane_pid`, `session_present`,
#   `attached_clients`, `subtree_cpu_secs`, `attempt_epoch`, `attempt_record`,
#   `service_controller_present` (`${1##*/}`, `${2##*/}` — self-bound via `set -- $c`, so the
#   caller's argv never reaches them), and the CLI dispatch's own `case "${1:-status}"`,
#   `role="$1"` and `$1`. Two of those — `free_mb` and `hyg_df_mb` — are the NON-EMPTY-DEFAULT
#   shape this audit rejects for a binding, so the exemption is deliberate here and would not be
#   there: they are pure helpers whose default is the harmless current directory / cell home. Named
#   so the omission is a recorded decision, not an implication of coverage: extending the walk to
#   function bodies is the fix if a positional read outside a `local` ever carries a real hazard.
#   Read this as "every `local` binding of a positional", never "every positional read in the file".
#   A positional is counted in ANY spelling this audit recognises: `$N`, `${N}`, `${N:-…}`,
#   `${N##*/}`, and the operators `${#N}` (length) and `${!N}` (indirect) — the last two were blind
#   spots until review found that `local n="${#1}"` died on an absent argument while the scan saw no
#   read at all and the fail-closed counter had nothing to compare against.
# ⛔ AND `local` MUST BE THE LINE'S FIRST TOKEN. The walk greps `^[[:space:]]*local[[:space:]]` (any
#   whitespace, so `local<TAB>` is found), so a binding
#   written inside a ONE-LINE function body (`f() { local x="$1"; }`) is not scanned either, and
#   neither is the continuation half of a binding split over lines (`local s="$1" \` + `tmp="$2"`)
#   — only the first line is seen (review P2). Neither exists in this file today (one binding per
#   line, no continuations), and the style here is what keeps the walk complete: stated because a
#   future one-liner or continuation would be invisible rather than graded.
# ⛔ The suite (final pass 3) walks this MECHANICALLY, by VALUE, keyed by (FUNCTION, NAME) and over a
#   DERIVED role list: `"${N:-}"` passes at any index, `"${N:-<anything>}"` FAILS (a non-empty default
#   would let an absent argument arm a mode by itself), a bare `$N` must be a `function:name` pair on
#   the list above — the NAME ALONE is not enough, because `s`/`rc`/`d`/`role` are reused across
#   helpers and a name-keyed list grandfathers the next `local s="$1"` anywhere in the file — and a
#   role added to `run_role_pass` tomorrow is graded on the day it is added, not only the four that
#   exist today.
# ⛔ THE KEY IS (FUNCTION, NAME) AND DELIBERATELY NOT THE INDEX (declared residual, review P2). One
#   listed pair therefore covers every read of that name inside that function: `local pid="$1$2"` in
#   `human_above` (whose only caller passes one argument) inherits `human_above:pid`'s REQUIRED verdict
#   and its `$2` read is not separately decided. It is caught BEHAVIOURALLY — the suite's reap arm runs
#   the function and the unbound `$2` fails it — so it is not a silent pass, but the static audit alone
#   would allow it. Keying by index was rejected for now because it multiplies the list by every
#   read position and the index is not what makes a read safe (the FUNCTION's contract is); if this
#   ever needs closing, key the list by `function:name:index` and re-derive it mechanically.
run_role_pass() { # <role> [--dry-run]
  local role="$1" rc; shift
  if ! role_lock "$role"; then
    log "[$role] SKIP another $role pass is running"
    return 0
  fi
  # The in-progress marker is what lets `status` tell "its first pass is still running" from "it never
  # ran" without guessing from a flat grace window (see role_row).
  : > "$ROLES_DIR/.$role.running" 2>/dev/null || true
  case "$role" in
    reap)    run_reap "$@";    rc=$? ;;
    doctor)  run_doctor "$@";  rc=$? ;;
    merge)   run_merge "$@";   rc=$? ;;
    hygiene) run_hygiene "$@"; rc=$? ;;
    *) rm -f "$ROLES_DIR/.$role.running"; role_unlock "$role"; printf 'FATAL: unknown role "%s"\n' "$role" >&2; return 2 ;;
  esac
  rm -f "$ROLES_DIR/.$role.running" 2>/dev/null || true
  role_unlock "$role"
  return "$rc"
}

run_loop() {
  local now last_d=0 last_m=0 last_h=0 tmp
  mkdir -p "$ROLES_DIR" "$WORKER_LOG_DIR" || { printf 'FATAL: cannot create %s\n' "$ROLES_DIR" >&2; exit 3; }
  # The loop's own pid is what makes "configured" vs "ran" decidable. Written atomically so a reader
  # never sees a truncated pid (a truncated pid is either unparseable — treated as no loop — or a
  # DIFFERENT live pid, which would make a dead loop read as running).
  tmp="$ROLES_DIR/loop.pid.tmp.$$"
  printf '%s\n' "$$" > "$tmp" && mv -f "$tmp" "$ROLES_DIR/loop.pid" || { printf 'FATAL: cannot write %s\n' "$ROLES_DIR/loop.pid" >&2; exit 3; }
  tmp="$ROLES_DIR/loop.ident.tmp.$$"
  printf '%s|%s\n' "$$" "$(pid_ident "$$")" > "$tmp" && mv -f "$tmp" "$ROLES_DIR/loop.ident" \
    || { printf 'FATAL: cannot write %s\n' "$ROLES_DIR/loop.ident" >&2; exit 3; }
  tmp="$ROLES_DIR/loop.started.tmp.$$"
  printf '%s\n' "$(date +%s)" > "$tmp" && mv -f "$tmp" "$ROLES_DIR/loop.started" \
    || { printf 'FATAL: cannot write %s\n' "$ROLES_DIR/loop.started" >&2; exit 3; }
  # HUP too: a tmux server restart / `kill-session` delivers HUP, and without it the identity record
  # would outlive the loop (the fence above would then see a recycled pid as a different incarnation
  # and correctly say NO LOOP — this is the cheap half of the same repair).
  trap 'rm -f "$ROLES_DIR/loop.pid" "$ROLES_DIR/loop.ident"; exit 0' TERM INT HUP
  log "loop started pid=$$ doctor=${DOCTOR_INTERVAL}s merge=${MERGE_INTERVAL}s hygiene=${HYGIENE_INTERVAL}s"
  while :; do
    # ⛔ THE LOOP QUENCHES ON `.desired` ITSELF, before dispatching anything. `cell_stopped_midpass`
    # compares against what a pass SNAPSHOTTED, so a pass that begins AFTER the stop (an orphan loop, or
    # one whose stop landed between ticks) sees no movement and would keep landing PRs and pruning. A
    # live read of the marker cannot be outrun: once the operator's stop has removed it, the loop exits
    # rather than acting on a cell that is no longer supposed to be up. Manual verbs are untouched —
    # they are not the loop, and an operator may legitimately run one pass on a stopped cell.
    if [ ! -f "$DESIRED" ]; then
      log "cell not started (no $DESIRED) — the loop is exiting without dispatching a role"
      rm -f "$ROLES_DIR/loop.pid" "$ROLES_DIR/loop.ident" 2>/dev/null || true
      return 0
    fi
    now="$(date +%s)"
    if [ $(( now - last_d )) -ge "$DOCTOR_INTERVAL" ]; then run_role_pass doctor ""; last_d=$now; fi
    if [ $(( now - last_m )) -ge "$MERGE_INTERVAL" ]; then run_role_pass merge ""; last_m=$now; fi
    if [ $(( now - last_h )) -ge "$HYGIENE_INTERVAL" ]; then run_role_pass hygiene ""; last_h=$now; fi
    # `sleep & wait`: bash runs a trap only after the foreground command returns, and a foreground
    # `sleep 600` would defer `stop` for its whole duration (orch-loop.sh's measured note).
    "$SLEEP_BIN" "$LOOP_TICK" & wait $! || true
  done
}

# `--dry-run` is the only accepted flag, and an unknown argument is REFUSED (a typo'd `--dryrun`
# that was silently ignored would arm the destructive verb an operator meant to rehearse).
parse_dry() {
  local a seen=""
  for a in "$@"; do
    case "$a" in
      --dry-run)
        # ⛔ A SECOND flag is refused, and the value is newline-terminated: `printf '%s'` twice
        # concatenated to `--dry-run--dry-run`, which no `[ = "--dry-run" ]` matches — so the
        # destructive verb would RUN instead of the rehearsal the operator asked for.
        [ -z "$seen" ] || { printf 'FATAL: %s: --dry-run given more than once\n' "$0" >&2; return 2; }
        seen=1 ;;
      *) printf 'FATAL: %s: unknown argument "%s" (only --dry-run is accepted)\n' "$0" "$a" >&2; return 2 ;;
    esac
  done
  [ -n "$seen" ] && printf '%s\n' '--dry-run'
  return 0
}

# ⛔ SOURCING DEFINES FUNCTIONS; IT DOES NOT RUN A PASS. Without this guard a suite cannot exercise a
# per-PASS invariant (the exclusion set is reset each pass — see `hygiene_cache_sweep`), because the
# only way to reach that function twice in one shell is to source this file, and the dispatch below
# would then execute a role as a side effect of the import.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi

case "${1:-status}" in
  reap|doctor|merge|hygiene)
    role="$1"; shift
    dry="$(parse_dry "$@")" || exit $?
    run_role_pass "$role" "${dry}" ;;
  loop)
    shift
    # An argument here is a typo (`loop --dryrun`), and silently accepting it would leave an operator
    # believing a rehearsal was armed while the real roles ran — refuse it like every role verb does.
    [ $# -eq 0 ] || { printf 'FATAL: %s: loop takes no arguments (got "%s")\n' "$0" "$1" >&2; exit 2; }
    run_loop ;;
  status)  shift; run_status ;;
  *) printf 'usage: %s reap|doctor|merge|hygiene|status [--dry-run] | loop\n' "$0" >&2; exit 2 ;;
esac
