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
# A role that has not passed inside this window is STALE in `status`. Two intervals, so one skipped
# tick (a slow rail call, a role lock held by an operator verb) is not reported as a dead loop.
DOCTOR_STALE_S="${DOCTOR_STALE_S:-}"
# A loop that has JUST started has not passed yet — its first doctor pass includes a real sampling
# window per lane, so `start && status` must not report a healthy cell as dead in the first seconds.
# NEVER RAN fails `status` only once the loop is older than this grace; a cell with NO loop-age
# record (an older tree, a hand-made fixture) is judged immediately, i.e. the fail-closed direction.
DOCTOR_GRACE_S="${DOCTOR_GRACE_S:-300}"
for _v in DOCTOR_INTERVAL MERGE_INTERVAL HYGIENE_INTERVAL LOOP_TICK REAP_MIN_S REAP_SAMPLE_S \
          CONTROLLER_STALE_S CONTROLLER_START_TIMEOUT RAIL_TIMEOUT MERGE_MAX_PRS MERGE_RETRY_S \
          HYGIENE_TIMEOUT STALE_WORKTREE_DAYS MIN_FREE_MB DOCTOR_GRACE_S REAP_TIMEOUT \
          READ_CALL_TIMEOUT; do
  num_ok "${!_v}" || { printf 'FATAL: %s must be a whole number 0..999999999 (got "%s")\n' "$_v" "${!_v}" >&2; exit 2; }
done
case "$HYGIENE_WORKTREES" in auto|dry-run|apply) ;; *) printf 'FATAL: HYGIENE_WORKTREES must be auto|dry-run|apply (got "%s")\n' "$HYGIENE_WORKTREES" >&2; exit 2 ;; esac
[ -n "$DOCTOR_STALE_S" ] || DOCTOR_STALE_S=$((DOCTOR_INTERVAL * 2))
num_ok "$DOCTOR_STALE_S" || { printf 'FATAL: DOCTOR_STALE_S must be a whole number 0..999999999 (got "%s")\n' "$DOCTOR_STALE_S" >&2; exit 2; }

ROLES_DIR="$O/state/roles"
WORKER_LOG_DIR="$O/logs"
DESIRED="$ROLES_DIR/.desired"

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

# One pass at a time per role. The loop and an operator verb can meet; the loser SKIPS (and says so)
# rather than running a second pass — two reaps sampling each other, or two rails on one PR, are the
# double-dispatch the harness's claim layer exists to prevent. A lock whose owner is gone is
# reclaimed (the same fail-closed direction orch-loop's `acq()` uses for a dead pid).
role_lock() {
  local role="$1" d="$ROLES_DIR/.$role.lock" pid
  mkdir -p "$ROLES_DIR" || return 1
  if mkdir "$d" 2>/dev/null; then printf '%s\n' "$$" > "$d/pid"; return 0; fi
  pid="$(cat "$d/pid" 2>/dev/null)"
  if num_ok "${pid:-}" && kill -0 "$pid" 2>/dev/null; then return 1; fi
  rm -rf "$d" 2>/dev/null
  if mkdir "$d" 2>/dev/null; then printf '%s\n' "$$" > "$d/pid"; return 0; fi
  return 1
}
role_unlock() { rm -rf "$ROLES_DIR/.$1.lock" 2>/dev/null || true; }

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

# Bound ONE external read (tmux/ps). `timeout` is a cell runtime dependency in practice, but its
# absence must not turn a bounded read into an unbounded one silently — the caller is told.
if ! command -v timeout >/dev/null 2>&1; then
  printf 'warn: timeout(1) not on PATH — reads are bounded only by REAP_TIMEOUT/%ss per pass\n' \
         "${REAP_TIMEOUT}" >&2
fi
bounded() { local s="$1"; shift; if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else "$@"; fi; }

# Free MiB. `df -Pk`'s 4th column is 1KiB blocks; `printf %d` (never awk's OFMT, which prints
# scientific notation for large values on mawk, i.e. on the cell). Empty when it cannot answer —
# every caller reads that as cannot-verify, never as "enough".
free_mb() { df -Pk "${1:-.}" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%d\n", $4 / 1024}'; }

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

# Names of the sessions in this harness's namespace. A `tmux ls` that fails with NO server is an
# empty list (nothing to reap); a tmux binary that is absent is CANNOT-VERIFY and is reported as such
# by the caller before this runs.
harness_sessions() {
  local s
  for s in $(bounded "$READ_CALL_TIMEOUT" "$TMUX_BIN" ls -F '#{session_name}' 2>/dev/null); do
    case "$s" in
      lane-*|fix-*|merge-*|chain-*) ;;
      *) continue ;;
    esac
    # Defensive: an API value must never reach a tmux target unvalidated.
    case "$s" in *[!A-Za-z0-9_-]*) continue ;; esac
    printf '%s\n' "$s"
  done
}

pane_pid() { bounded "$READ_CALL_TIMEOUT" "$TMUX_BIN" list-panes -t "=$1" -F '#{pane_pid}' 2>/dev/null | head -1; }
attached_clients() { bounded "$READ_CALL_TIMEOUT" "$TMUX_BIN" list-clients -t "=$1" 2>/dev/null | awk 'NF{n++} END{printf "%d\n", n+0}'; }
pid_lstart() { bounded "$READ_CALL_TIMEOUT" "$PS_BIN" -p "$1" -o lstart= 2>/dev/null; }

# Seconds of cumulative CPU time for <pid> and every descendant. Prints "NA" when the root is not in
# the table (an unreadable/empty `ps`: cannot-verify, never "0 seconds of progress").
subtree_cpu_secs() {
  bounded "$READ_CALL_TIMEOUT" "$PS_BIN" -A -o pid=,ppid=,time= 2>/dev/null | awk -v root="$1" '
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
    { ppid[$1] = $2; cpu[$1] = secs($3) }
    END {
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
human_above() {
  local pid="$1" n=0 row ppid args
  while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ] && [ "$n" -lt 40 ]; do
    row="$(bounded "$READ_CALL_TIMEOUT" "$PS_BIN" -p "$pid" -o ppid=,args= 2>/dev/null)"
    [ -n "$row" ] || return 1
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
  local dry="$1" s log m0 m1 c0 c1 age now pid clients ls0 ls1 started elapsed
  local seen=0 skipped=0 reaped=0 would=0 result=""
  note() { log "[reap] $*"; result="${result}${result:+; }$*"; }
  started="$(date +%s)"

  for s in $(harness_sessions); do
    seen=$((seen + 1))
    # The budget is for the WHOLE read (§6.5.2). Checked at the top of each lane so a pass that has
    # spent it stops touching anything further and says so — the unreached lanes are NOT "quiet".
    elapsed=$(( $(date +%s) - started ))
    if [ "$elapsed" -gt "$REAP_TIMEOUT" ]; then
      log "[reap] CANNOT-VERIFY: the read budget (${REAP_TIMEOUT}s) was spent after $seen of $(harness_sessions | wc -l | tr -d ' ') lane(s) — nothing further was judged"
      state_write reap 3 "cannot-verify: read budget ${REAP_TIMEOUT}s spent after $seen lane(s); ${seen} judged: $result"
      return 3
    fi
    log="$WORKER_LOG_DIR/$s.log"
    m0="$(mtime_epoch "$log")"
    if [ ! -f "$log" ] || [ -z "$m0" ]; then
      skipped=$((skipped + 1)); note "$s SKIP no readable log (no progress signal)"
      continue
    fi
    age=$(( $(date +%s) - m0 ))
    if [ "$age" -le "$REAP_MIN_S" ]; then
      skipped=$((skipped + 1)); note "$s SKIP log advanced ${age}s ago (under ${REAP_MIN_S}s)"
      continue
    fi
    pid="$(pane_pid "$s")"
    if ! num_ok "${pid:-}" || [ "${pid:-0}" -le 1 ]; then
      skipped=$((skipped + 1)); note "$s SKIP no usable pane pid"
      continue
    fi
    clients="$(attached_clients "$s")"
    if [ "${clients:-0}" -gt 0 ]; then
      skipped=$((skipped + 1)); note "$s SKIP a tmux client is attached (human watching)"
      continue
    fi
    if human_above "$pid"; then
      skipped=$((skipped + 1)); note "$s SKIP ancestry reaches a human terminal/login"
      continue
    fi
    # ── observation 1 ──
    c0="$(subtree_cpu_secs "$pid")"
    if [ "${c0:-NA}" = "NA" ]; then
      skipped=$((skipped + 1)); note "$s SKIP cannot read the process table (cannot-verify)"
      continue
    fi
    ls0="$(pid_lstart "$pid")"
    # ── observation 2, after a real window ──
    "$SLEEP_BIN" "$REAP_SAMPLE_S"
    m1="$(mtime_epoch "$log")"
    c1="$(subtree_cpu_secs "$pid")"
    if [ -z "$m1" ] || [ "${c1:-NA}" = "NA" ]; then
      skipped=$((skipped + 1)); note "$s SKIP second observation unreadable (cannot-verify)"
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
    log "[reap] $s silent ${age}s, cpu ${c0}s unchanged -> killing session (pane_pid=${pid})"
    "$TMUX_BIN" kill-session -t "=$s" 2>/dev/null || true
    # The extra TERM/KILL is fenced: only signal the pid if it still holds the incarnation whose
    # lstart we recorded. An off-fence or absent pid is an ABSTENTION, never a kill (#1178).
    ls1="$(pid_lstart "$pid")"
    if [ -n "$ls0" ] && [ "$ls0" = "$ls1" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      "$SLEEP_BIN" 1
      ls1="$(pid_lstart "$pid")"
      [ -n "$ls1" ] && [ "$ls1" = "$ls0" ] && kill -KILL "$pid" 2>/dev/null || true
    fi
    reaped=$((reaped + 1))
    result="${result}${result:+; }reaped $s"
  done
  [ -n "$result" ] || result="no harness session to judge"
  state_write reap 0 "seen=$seen reaped=$reaped would=$would skipped=$skipped — $result"
  log "[reap] seen=$seen reaped=$reaped would=$would skipped=$skipped"
  return 0
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
  for c in "${DOCTOR_ADMIN_MERGE:-}" \
           "${SUPERVISOR:+$(dirname "$SUPERVISOR")/admin-merge.sh}" \
           "$SELF_DIR/admin-merge.sh" \
           "$REPO/scripts/admin-merge.sh" \
           "$CELL_HOME/.pi/agent/scripts/admin-merge.sh"; do
    [ -n "$c" ] && [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# 0 = a clean attestation for <pr> at <head> exists in THIS cell's review store.
attestation_clean() {
  local pr="$1" head="$2" dir="$CELL_HOME/.pi/agent/reviews" slug f rc
  slug="$(printf '%s' "$OR" | tr '/' '-')"
  for f in "$dir/${slug}-${pr}.json" "$dir/${pr}.json"; do
    [ -f "$f" ] || continue
    python3 - "$f" "$head" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
except Exception:
    sys.exit(1)
h = str(d.get("head_sha") or "")
v = str(d.get("verdict") or "").lower()
sys.exit(0 if h == sys.argv[2] and v in ("clean", "clean-micro", "clean-low") else 1)
PY
    rc=$?
    [ "$rc" -eq 0 ] && return 0
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
  local dry="$1" rail err prs line pr head draft now ep aep merge_parse_failed=0
  local candidates=0 attempted=0 landed=0 skipped=0 result="" out rc
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
  err="$ROLES_DIR/.merge-read.$$"
  prs="$("$GH_BIN" api "repos/$OR/pulls?state=open&per_page=$MERGE_MAX_PRS" 2>"$err")"
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
    if ! attestation_clean "$pr" "$head"; then
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
    # ── the standard rail, executed as shipped ──
    out="$O/logs/doctor-merge-$pr.log"
    if command -v timeout >/dev/null 2>&1; then
      timeout "$RAIL_TIMEOUT" bash "$rail" "$pr" --repo "$OR" >>"$out" 2>&1
    else
      bash "$rail" "$pr" --repo "$OR" >>"$out" 2>&1
    fi
    rc=$?
    attempted=$((attempted + 1))
    attempt_record "$pr" "$head" "$rc"
    if [ "$rc" -eq 0 ]; then
      landed=$((landed + 1))
      log "[merge] #$pr LANDED through the rail at ${head:0:12}"
      result="${result}${result:+; }landed #$pr"
    else
      local why; why="$(tail -2 "$out" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
      log "[merge] #$pr REFUSED by the rail rc=$rc — ${why:-no output}; recorded, not retried for ${MERGE_RETRY_S}s at this head"
      result="${result}${result:+; }REFUSED #$pr rc=$rc"
    fi
  done < "$parsed"
  rm -f "$parsed"
  [ -n "$result" ] || result="nothing to land"
  state_write merge 0 "candidates=$candidates attempted=$attempted landed=$landed skipped=$skipped — $result"
  log "[merge] candidates=$candidates attempted=$attempted landed=$landed skipped=$skipped"
  return 0
}

# ── HYGIENE (the disk the cell fills without noticing) ───────────────────────────────────────────
# MEASURED: a machine-global `uv` cache reached 7.1 GB and one cell went 258 MB → dispatch refused
# (#1987); before that, an abandoned 5.8 GB worktree. The two sinks are pruned here, with the
# shipped tools and the shipped gates — this role adds the SCHEDULE, not another reaper.
run_hygiene() {
  local dry="$1" before after mb rc wt mode out result=""
  # 1) the package cache. `uv cache prune` removes UNUSED entries (safe while lanes resolve); it is
  #    NOT `uv cache clean` — emptying a cache a live lane is reading is the class #1987 forbids.
  if command -v uv >/dev/null 2>&1; then
    before="$(du -sm "$CELL_HOME/.cache/uv" 2>/dev/null | awk '{print $1}')"
    if [ "$dry" = "--dry-run" ]; then
      log "[hygiene] WOULD run: uv cache prune (cache ${before:-?}MB)"
      result="would prune uv (${before:-?}MB)"
    else
      if command -v timeout >/dev/null 2>&1; then
        timeout "$HYGIENE_TIMEOUT" uv cache prune >>"$O/logs/doctor.log" 2>&1
      else
        uv cache prune >>"$O/logs/doctor.log" 2>&1
      fi
      rc=$?
      after="$(du -sm "$CELL_HOME/.cache/uv" 2>/dev/null | awk '{print $1}')"
      log "[hygiene] uv cache prune rc=$rc ${before:-?}MB -> ${after:-?}MB"
      result="uv ${before:-?}MB->${after:-?}MB"
    fi
  else
    result="uv absent"
  fi
  # 2) worktree-root caches (`.venv`, `node_modules`, `__pycache__`) via the supervisor's own sweep.
  #    ⛔ Never while a worker session is live: the sweep deletes `.venv`, and a lane using it would
  #    re-resolve mid-run (the reason `cmd_start` guards the same delete). The supervisor's `prune`
  #    WARNS about a running controller but does not guard it, so the guard lives here.
  if [ "$(harness_sessions | awk 'END {printf "%d\n", NR}')" -gt 0 ]; then
    log "[hygiene] worker sessions are live — skipping the worktree-root cache sweep"
    result="${result}${result:+; }caches-sweep skipped (workers live)"
  elif [ -n "${SUPERVISOR:-}" ] && [ -f "$SUPERVISOR" ]; then
    if [ "$dry" = "--dry-run" ]; then
      result="${result}${result:+; }would sweep worktree caches"
    else
      bash "$SUPERVISOR" prune --caches >>"$O/logs/doctor.log" 2>&1 || true
      result="${result}${result:+; }worktree caches swept"
    fi
  fi
  # 3) stale worktrees — the shipped reaper, whose own gates preserve anything dirty, unreferenced or
  #    unreachable. `auto` arms it only under disk pressure: the failure being prevented is a FULL
  #    disk, and a tidy box does not need a destructive verb run for tidiness.
  wt="${DOCTOR_WORKTREE_REAPER:-}"
  if [ -z "$wt" ]; then
    for wt in "$SELF_DIR/pi-reap-worktrees.sh" "$REPO/scripts/pi-reap-worktrees.sh" "$CELL_HOME/.pi/agent/scripts/pi-reap-worktrees.sh"; do
      [ -f "$wt" ] && break
    done
  fi
  if [ -f "${wt:-}" ]; then
    mode="$HYGIENE_WORKTREES"
    if [ "$mode" = "auto" ]; then
      mb="$(free_mb "$CELL_HOME")"
      if [ -n "$mb" ] && [ "$mb" -lt "$((MIN_FREE_MB * 2))" ]; then mode=apply; else mode=dry-run; fi
    fi
    if [ "$dry" = "--dry-run" ]; then mode=dry-run; fi
    out="$O/logs/doctor-worktrees.log"
    if command -v timeout >/dev/null 2>&1; then
      timeout "$HYGIENE_TIMEOUT" bash "$wt" "--$mode" --repo "$REPO" --aged-days "$STALE_WORKTREE_DAYS" >>"$out" 2>&1 || true
    else
      bash "$wt" "--$mode" --repo "$REPO" --aged-days "$STALE_WORKTREE_DAYS" >>"$out" 2>&1 || true
    fi
    result="${result}${result:+; }worktrees $mode"
  else
    result="${result}${result:+; }worktree reaper not found"
  fi
  state_write hygiene 0 "$result"
  log "[hygiene] $result"
  return 0
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
run_doctor() {
  local dry="$1" rc hb age result=""
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
    state_write doctor 0 "not-started; $result"; return 0
  fi
  if "$TMUX_BIN" has-session -t "=$SESSION" 2>/dev/null; then
    hb="$(cat "$O/heartbeat" 2>/dev/null)"
    case "${hb:-}" in ''|*[!0-9]*) hb=0 ;; esac
    if [ "$hb" -gt 0 ]; then
      age=$(( $(date +%s) - hb ))
      if [ "$age" -gt "$CONTROLLER_STALE_S" ]; then
        log "[doctor] ⛔ CONTROLLER STALE: tmux '$SESSION' is up but its heartbeat is ${age}s old (> ${CONTROLLER_STALE_S}s). NOT killing it (a live controller may be mid-merge); reap and the independent merge role continue. Fix by hand if this persists."
        result="$result; CONTROLLER STALE ${age}s (not killed)"
      else
        result="$result; controller RUNNING (heartbeat ${age}s)"
      fi
    else
      result="$result; controller RUNNING (no heartbeat recorded yet)"
    fi
  elif [ "$dry" = "--dry-run" ]; then
    log "[doctor] WOULD restart the controller (tmux '$SESSION' absent, cell is started)"
    result="$result; would restart controller"
  else
    log "[doctor] controller session '$SESSION' is ABSENT on a started cell — restarting via the supervisor"
    if [ -n "${SUPERVISOR:-}" ] && [ -f "$SUPERVISOR" ]; then
      if command -v timeout >/dev/null 2>&1; then
        timeout "$CONTROLLER_START_TIMEOUT" bash "$SUPERVISOR" start >>"$O/logs/doctor.log" 2>&1
      else
        bash "$SUPERVISOR" start >>"$O/logs/doctor.log" 2>&1
      fi
      rc=$?
      if [ "$rc" -eq 0 ]; then
        log "[doctor] controller restarted (supervisor start rc=0)"
        result="$result; controller RESTARTED"
      else
        log "[doctor] controller restart FAILED (supervisor start rc=$rc) — see $O/logs/doctor.log"
        result="$result; controller restart FAILED rc=$rc"
      fi
    else
      log "[doctor] CANNOT-VERIFY: controller absent and DOCTOR_SUPERVISOR is not a file — cannot restart"
      result="$result; controller restart cannot-verify (no supervisor)"
    fi
  fi
  # A nested reap that could not be taken makes THIS pass partial too: the supervision half ran, but
  # the pass as a whole must not be recorded as a clean one (cannot-verify is never a pass).
  state_write doctor "$rrc" "$result"
  log "[doctor] $result"
  return "$rrc"
}

# ── STATUS (configured vs actually ran) ─────────────────────────────────────────────────────────
# The supervisor's `status` delegates here. "RUNNING" is a LIVE LOOP PID plus a PASS RECENT ENOUGH;
# the two are separate facts and both are reported, because a live loop that has stopped passing and
# a dead loop are different repairs. A role that never ran is named as NEVER RAN — never as idle.
role_row() { # <role> <stale-bound-seconds>
  local role="$1" bound="$2" f rc ep age loop_pid
  f="$ROLES_DIR/$role.state"
  if [ ! -f "$f" ]; then
    if [ "${NEVER_OK:-0}" = 1 ]; then
      printf '%-8s WAITING   loop started %ss ago; no pass recorded yet\n' "$role" "${LOOP_AGE:-0}"
      return 0
    fi
    printf '%-8s NEVER RAN (no pass recorded)%s\n' "$role" ""
    return 1
  fi
  rc="$(state_get "$role" last_rc)"; ep="$(state_get "$role" last_pass_epoch)"
  case "${ep:-}" in ''|*[!0-9]*) ep=0 ;; esac
  age=$(( $(date +%s) - ep ))
  loop_pid="$(cat "$ROLES_DIR/loop.pid" 2>/dev/null)"
  if num_ok "${loop_pid:-}" && kill -0 "$loop_pid" 2>/dev/null; then
    printf '%-8s RUNNING   last pass %ss ago rc=%s — %s\n' "$role" "$age" "${rc:-?}" "$(state_get "$role" last_result | cut -c1-150)"
  else
    printf '%-8s NO LOOP   last pass %ss ago rc=%s — %s\n' "$role" "$age" "${rc:-?}" "$(state_get "$role" last_result | cut -c1-150)"
  fi
  if [ "$age" -gt "$bound" ]; then
    printf '%-8s STALE     no pass in %ss (bound %ss)\n' "$role" "$age" "$bound"
    return 1
  fi
  return 0
}

run_status() {
  local rc=0 desired=0 loop_pid started
  [ -f "$DESIRED" ] && desired=1
  loop_pid="$(cat "$ROLES_DIR/loop.pid" 2>/dev/null)"
  # The grace window is derived from the LOOP's own start record, never from a role's, so it cannot
  # be refreshed by a pass and cannot outlive the loop that wrote it.
  NEVER_OK=0; LOOP_AGE=""
  started="$(cat "$ROLES_DIR/loop.started" 2>/dev/null)"
  case "${started:-}" in
    ''|*[!0-9]*) : ;;   # no/unknown age -> no grace (fail-closed)
    *) LOOP_AGE=$(( $(date +%s) - started ))
       [ "$LOOP_AGE" -ge 0 ] && [ "$LOOP_AGE" -le "$DOCTOR_GRACE_S" ] && NEVER_OK=1 ;;
  esac
  if num_ok "${loop_pid:-}" && kill -0 "$loop_pid" 2>/dev/null; then
    printf 'loop:    RUNNING (pid %s)\n' "$loop_pid"
  elif [ "$desired" = 1 ]; then
    printf 'loop:    NOT RUNNING (cell is started — the doctor loop is expected)\n'
    rc=1
  else
    printf 'loop:    STOPPED (cell not started; roles are not expected to pass)\n'
  fi
  role_row reap $((REAP_MIN_S + DOCTOR_INTERVAL * 2)) || rc=1
  role_row doctor "$DOCTOR_STALE_S" || rc=1
  role_row merge $((MERGE_INTERVAL * 2)) || rc=1
  role_row hygiene $((HYGIENE_INTERVAL * 2)) || rc=1
  if [ "$desired" = 1 ]; then
    # A started cell whose loop is gone is not healthy even if every role's last pass is recent.
    num_ok "${loop_pid:-}" && kill -0 "$loop_pid" 2>/dev/null || rc=1
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
  case "$role" in
    reap)    run_reap "$@";    rc=$? ;;
    doctor)  run_doctor "$@";  rc=$? ;;
    merge)   run_merge "$@";   rc=$? ;;
    hygiene) run_hygiene "$@"; rc=$? ;;
    *) role_unlock "$role"; printf 'FATAL: unknown role "%s"\n' "$role" >&2; return 2 ;;
  esac
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
  tmp="$ROLES_DIR/loop.started.tmp.$$"
  printf '%s\n' "$(date +%s)" > "$tmp" && mv -f "$tmp" "$ROLES_DIR/loop.started" \
    || { printf 'FATAL: cannot write %s\n' "$ROLES_DIR/loop.started" >&2; exit 3; }
  trap 'rm -f "$ROLES_DIR/loop.pid"; exit 0' TERM INT
  log "loop started pid=$$ doctor=${DOCTOR_INTERVAL}s merge=${MERGE_INTERVAL}s hygiene=${HYGIENE_INTERVAL}s"
  while :; do
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
  local a
  for a in "$@"; do
    case "$a" in
      --dry-run) printf '%s' '--dry-run' ;;
      *) printf 'FATAL: %s: unknown argument "%s" (only --dry-run is accepted)\n' "$0" "$a" >&2; return 2 ;;
    esac
  done
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
