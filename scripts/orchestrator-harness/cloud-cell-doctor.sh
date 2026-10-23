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
#   hygiene   package cache + worktree-root caches + stale worktrees
#   loop      the timer the supervisor starts: doctor / merge / hygiene on their own intervals
#   status    print the per-role liveness table; exit 1 when a role never ran / went stale
#
# Usage:
#   bash cloud-cell-doctor.sh reap|doctor|merge|hygiene|status [--dry-run]
#   bash cloud-cell-doctor.sh loop
#
# Exit codes: 0 = pass completed (including "nothing to do"); 2 = usage; 3 = the read a pass needs
# could not be taken (cannot-verify is never a pass).

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
          READ_CALL_TIMEOUT MERGE_BUDGET_S MERGE_READ_TIMEOUT; do
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
          REAP_SAMPLE_S REAP_MIN_S; do
  [ "${!_v}" -gt 0 ] || { printf 'FATAL: %s must be > 0 (0 makes the bound vacuous: `timeout 0` runs with no timeout at all, a zero REAP_SAMPLE_S makes the two CPU observations simultaneous, a zero REAP_MIN_S removes the age floor) — got "%s"\n' "$_v" "${!_v}" >&2; exit 2; }
done
# The roles run IN SEQUENCE in ONE loop, so the legitimate gap between two passes of the same role is
# not that role's own duration — it is the sum of everything that can run in between. Building each
# stale bound from only its own role's cost made a healthy-but-busy cell read STALE (and `status`
# exit 1): merge N could be followed by a 600 s hygiene pass, a tick, then a 300 s reap plus a 600 s
# controller restart inside the next doctor pass, BEFORE merge N+1 even started.
WORST_PASS_S=$(( MERGE_BUDGET_S + RAIL_TIMEOUT + HYGIENE_TIMEOUT ))
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
say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
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
  local role="$1" own="$2" prev; shift 2
  if [ -f "$ROLES_DIR/$role.state" ]; then
    prev="$(state_get "$role" last_rc)"
    case "${prev:-}" in ''|*[!0-9]*) prev=3 ;; esac
  else
    prev="$own"
  fi
  num_ok "${own:-}" && [ "$own" -gt "$prev" ] && prev="$own"
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
  local p w rc tmp
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
  local dry="$1" s log m0 m1 c0 c1 age now pid clients ls0 ls1 started elapsed sp ha
  local seen=0 skipped=0 reaped=0 would=0 unverifiable=0 failed=0 result=""
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
  # ⛔ A REHEARSAL IS NOT A VERDICT: in `--dry-run` this pass did not kill anything, so its rc=0 says
  # nothing about the lane a previous real pass recorded `KILL FAILED` (or an unreadable read) for.
  if [ "$dry" = "--dry-run" ]; then
    state_write_rehearsal reap "$pass_rc" "seen=$seen reaped=$reaped would=$would skipped=$skipped unverifiable=$unverifiable failed=$failed — $result"
  else
    state_write reap "$pass_rc" "seen=$seen reaped=$reaped would=$would skipped=$skipped unverifiable=$unverifiable failed=$failed — $result"
  fi
  log "[reap] seen=$seen reaped=$reaped would=$would skipped=$skipped unverifiable=$unverifiable failed=$failed"
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
  local dry="$1" rail err prs line pr head draft now ep aep arc cl opid merge_parse_failed=0 started
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
  if [ "$rc" -ne 0 ] || [ -z "${prs//[[:space:]]/}" ]; then
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
# (#1987); before that, an abandoned 5.8 GB worktree. The two sinks are pruned here, with the
# shipped tools and the shipped gates — this role adds the SCHEDULE, not another reaper.
run_hygiene() {
  begin_pass
  local dry="$1" before after mb rc wt mode out result="" h_rc=0 prev
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
      log "[hygiene] uv cache prune rc=$rc ${before:-?}MB -> ${after:-?}MB"
      # ⛔ A prune that FAILED (or was cut at HYGIENE_TIMEOUT, rc=124/137) did not happen: recording a
      # clean pass would read green in `status` while the disk keeps filling — the silent-no-op class
      # this role exists to remove. Every other failed sub-step in this role is rc=3; so is this one.
      if [ "$rc" -eq 0 ]; then
        result="uv ${before:-?}MB->${after:-?}MB"
      else
        result="${result}${result:+; }CANNOT-VERIFY: uv cache prune FAILED rc=$rc"
        h_rc=3
      fi
    fi
  else
    result="uv absent"
  fi
  # 2) worktree-root caches (`.venv`, `node_modules`, `__pycache__`) via the supervisor's own sweep.
  #    ⛔ Never while a worker session is live: the sweep deletes `.venv`, and a lane using it would
  #    re-resolve mid-run (the reason `cmd_start` guards the same delete). The supervisor's `prune`
  #    WARNS about a running controller but does not guard it, so the guard lives here.
  #    ⛔ An UNREADABLE session list is not "no workers": the guard fails CLOSED (skip the sweep and
  #    say so), never open.
  local names; names="$(harness_sessions)"
  case "$names" in
    *"$SESS_UNREADABLE_MARK"*)
      log "[hygiene] cannot verify the worker sessions — skipping the worktree-root cache sweep (fail-closed)"
      # ⛔ rc=3, like every other cannot-verify sub-step in this role: the sweep was NOT evaluated, so a
      # clean pass would tell a monitor that a destructive step it never ran was fine.
      result="${result}${result:+; }CANNOT-VERIFY: caches-sweep skipped (session list unreadable)"
      h_rc=3 ;;
    *)
      if [ "$(printf '%s' "$names" | awk 'NF{n++} END{printf "%d\n", n+0}')" -gt 0 ]; then
        log "[hygiene] worker sessions are live — skipping the worktree-root cache sweep"
        result="${result}${result:+; }caches-sweep skipped (workers live)"
          elif [ -n "${SUPERVISOR:-}" ] && [ -f "$SUPERVISOR" ]; then
        if cell_stopped_midpass; then
          result="${result}${result:+; }STOP arrived mid-pass — worktree cache sweep skipped"
        elif [ "$dry" = "--dry-run" ]; then
          result="${result}${result:+; }would sweep worktree caches"
        else
          run_bounded "$HYGIENE_TIMEOUT" bash "$SUPERVISOR" prune --caches >>"$O/logs/doctor.log" 2>&1
          rc=$?
          if [ "$rc" -eq 0 ]; then
            result="${result}${result:+; }worktree caches swept"
          else
            result="${result}${result:+; }CANNOT-VERIFY: worktree cache sweep FAILED rc=$rc"
            h_rc=3
          fi
        fi
      else
        # The sweep is ONE of the role's three stated jobs; a missing supervisor must not make it
        # vanish into a clean pass (same rule as the worktree reaper below).
        result="${result}${result:+; }CANNOT-VERIFY: worktree cache sweep skipped (supervisor not found)"
        h_rc=3
      fi ;;
  esac
  # 3) stale worktrees — the shipped reaper, whose own gates preserve anything dirty, unreferenced or
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
      # sibling sub-steps above exist to prevent.
      # ⛔ AND A REHEARSAL KEEPS THE WORSE VERDICT HERE TOO. This branch writes the record and returns
      # BEFORE the dry-run merge below, so a rehearsal interrupted by a stop recorded its OWN rc — 0
      # by construction, because a rehearsal performs no action and nothing it did can fail — over a
      # stored cannot-verify. The rehearsal is the verb an operator is told to run FIRST, so that path
      # cleared a failure it had never probed. The same merge as the main path applies: the worse of
      # the stored verdict and this pass's own, with an unreadable stored verdict fail-closed at rc=3.
      if [ "$dry" = "--dry-run" ]; then
        state_write_rehearsal hygiene "$h_rc" "$result"
        log "[hygiene] STOP arrived during this pass — dry-run: $result"
        return "$h_rc"
      fi
      state_write hygiene "$h_rc" "$result"
      log "[hygiene] STOP arrived during this pass — worktree reaper NOT run"
      return "$h_rc"
    fi
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
  else
    # The role's stated jobs include the disk sink that broke a cell twice. "I could not find the
    # reaper" is not a completed hygiene pass — it is cannot-verify, and it must not read as green.
    result="${result}${result:+; }CANNOT-VERIFY: worktree reaper (pi-reap-worktrees.sh) not found"
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
service_controller_present() {
  local pid c
  [ -f "$O/.orch.lock" ] || return 1
  pid="$(tr -dc '0-9' < "$O/.orch.lock" 2>/dev/null || true)"
  num_ok "${pid:-}" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  c="$(ps -o command= -p "$pid" 2>/dev/null)" || return 1
  # shellcheck disable=SC2086
  set -- $c
  [ "$#" -ge 2 ] || return 1
  case "${1##*/}" in bash|sh|dash|zsh) ;; *) return 1 ;; esac
  case "${2##*/}" in orch-loop.sh) return 0 ;; *) return 1 ;; esac
}

run_doctor() {
  begin_pass
  local dry="$1" rc hb age result="" tmp rpid
  # Through the ROLED PASS, not run_reap directly: a nested reap must take the reap role lock like
  # any other pass, or an operator's concurrent `reap` and this one would sample each other's lanes
  # and could both decide the same session is wedged (two kills, one corpse — the double-act the
  # lock exists to prevent). A lock held elsewhere makes this a logged SKIP, and the reap state is
  # then the sibling pass's record, which is the truth either way.
  local rrc=0
  run_role_pass reap "$dry" >/dev/null || rrc=$?
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
    log "[doctor] controller is up WITHOUT a tmux session (service-managed) — evaluating its heartbeat instead of restarting it"
    controller_heartbeat_verdict "the controller (service-managed)"
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
      else
        log "[doctor] controller restart FAILED (supervisor start rc=$rc) — see $O/logs/doctor.log"
        result="$result; controller restart FAILED rc=$rc"
        # ⛔ The supervision OUTCOME is part of the pass's rc. A started cell whose dispatcher is
        # absent and could not be restarted is not a clean pass, however well the reap half went.
        [ "$rrc" -eq 0 ] && rrc=1
      fi
    else
      log "[doctor] CANNOT-VERIFY: controller absent and DOCTOR_SUPERVISOR is not a file — cannot restart"
      result="$result; controller restart cannot-verify (no supervisor)"
      [ "$rrc" -eq 0 ] && rrc=3
    fi
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

# Is the RECORDED loop an ALIVE, SAME-INCARNATION process? A bare `kill -0` says a pid exists, not
# that it is OUR loop: after a tmux server restart, an OOM kill or a crash the pid survives in the
# file and the OS may recycle it, so a dead loop would read as RUNNING (the fleet's one identity
# rule, #1178 — applied to the loop's own record, not only to the lanes it reaps).
loop_alive() {
  local pid ls rec
  pid="$(cat "$ROLES_DIR/loop.pid" 2>/dev/null)"
  num_ok "${pid:-}" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ls="$(pid_ident "$pid")"
  rec="$(cat "$ROLES_DIR/loop.ident" 2>/dev/null)"
  [ -n "$ls" ] && [ "$rec" = "$pid|$ls" ] || return 1
  return 0
}

# ── STATUS (configured vs actually ran) ─────────────────────────────────────────────────────────
# The supervisor's `status` delegates here. "RUNNING" is a LIVE LOOP PID plus a PASS RECENT ENOUGH;
# the two are separate facts and both are reported, because a live loop that has stopped passing and
# a dead loop are different repairs. A role that never ran is named as NEVER RAN — never as idle.
role_row() { # <role> <stale-bound-seconds>
  local role="$1" bound="$2" f rc ep age
  f="$ROLES_DIR/$role.state"
  if [ ! -f "$f" ]; then
    # ⛔ A first pass can legitimately outlast the flat grace: the loop's first tick runs doctor,
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
      printf '%-8s WAITING   loop started %ss ago; no pass recorded yet\n' "$role" "${LOOP_UP_S:-0}"
      return 0
    fi
    printf '%-8s NEVER RAN (no pass recorded)%s\n' "$role" ""
    return 1
  fi
  rc="$(state_get "$role" last_rc)"; ep="$(state_get "$role" last_pass_epoch)"
  case "${ep:-}" in ''|*[!0-9]*) ep=0 ;; esac
  age=$(( $(date +%s) - ep ))
  if loop_alive; then
    printf '%-8s RUNNING   last pass %ss ago rc=%s — %s\n' "$role" "$age" "${rc:-?}" "$(state_get "$role" last_result | cut -c1-150)"
  else
    printf '%-8s NO LOOP   last pass %ss ago rc=%s — %s\n' "$role" "$age" "${rc:-?}" "$(state_get "$role" last_result | cut -c1-150)"
  fi
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
    *) printf '%-8s FAILED    last pass rc=%s (the pass did not complete)\n' "$role" "${rc:-?}"; return 1 ;;
  esac
  if [ "$age" -gt "$bound" ]; then
    printf '%-8s STALE     no pass in %ss (bound %ss)\n' "$role" "$age" "$bound"
    return 1
  fi
  return 0
}

run_status() {
  local rc=0 desired=0 started
  [ -f "$DESIRED" ] && desired=1
  # The grace window is derived from the LOOP's own start record, never from a role's, so it cannot
  # be refreshed by a pass and cannot outlive the loop that wrote it.
  # NOT `_AGE`-named on purpose: the name is an age-SHAPED identifier, and the declared-surface scan
  # rightly treats any `*_AGE` assignment as a candidate liveness bound. This is a display age for a
  # status row, not a bound — it is compared against DOCTOR_GRACE_S below, and against nothing else.
  # (The stale bounds derived from ALL_PASSES_S are applied to a ROLE's last-pass age in `role_row`.)
  NEVER_OK=0; LOOP_UP_S=""
  started="$(cat "$ROLES_DIR/loop.started" 2>/dev/null)"
  case "${started:-}" in
    ''|*[!0-9]*) : ;;   # no/unknown age -> no grace (fail-closed)
    *) LOOP_UP_S=$(( $(date +%s) - started ))
       [ "$LOOP_UP_S" -ge 0 ] && [ "$LOOP_UP_S" -le "$DOCTOR_GRACE_S" ] && NEVER_OK=1 ;;
  esac
  if loop_alive; then
    printf 'loop:    RUNNING (pid %s)\n' "$(cat "$ROLES_DIR/loop.pid" 2>/dev/null)"
  elif [ "$desired" = 1 ]; then
    printf 'loop:    NOT RUNNING (cell is started — the doctor loop is expected)\n'
    rc=1
  else
    printf 'loop:    STOPPED (cell not started; roles are not expected to pass)\n'
  fi
  # reap runs INSIDE the doctor pass, so it inherits the same worst-case gap.
  role_row reap "$DOCTOR_STALE_S" || rc=1
  role_row doctor "$DOCTOR_STALE_S" || rc=1
  # A merge pass may last MERGE_BUDGET_S plus one overrunning rail call, and everything else in the
  # tick may run before the NEXT one starts (see ALL_PASSES_S).
  role_row merge $((ALL_PASSES_S + MERGE_INTERVAL)) || rc=1
  # …and a hygiene pass waits behind doctor+merge, plus its own bounded run.
  role_row hygiene $((ALL_PASSES_S + HYGIENE_INTERVAL)) || rc=1
  if [ "$desired" = 1 ]; then
    # A started cell whose loop is gone is not healthy even if every role's last pass is recent.
    loop_alive || rc=1
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
    if [ $(( now - last_d )) -ge "$DOCTOR_INTERVAL" ]; then run_role_pass doctor; last_d=$now; fi
    if [ $(( now - last_m )) -ge "$MERGE_INTERVAL" ]; then run_role_pass merge; last_m=$now; fi
    if [ $(( now - last_h )) -ge "$HYGIENE_INTERVAL" ]; then run_role_pass hygiene; last_h=$now; fi
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
