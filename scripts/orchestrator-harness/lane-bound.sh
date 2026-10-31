#!/bin/sh
# lane-bound.sh — THE lifetime bound for a lane, and the verdict that says which bound fired.
#
# WHY THIS EXISTS (measured 2026-10-27)
# ─────────────────────────────────────
# Nine lanes were launched across two cloud cells. EVERY one of them parked with 0 bytes of output
# and `00:00:00` CPU — the oldest for **3 h 32 m**. The `pi` child sat in `ep_poll` (an event-loop
# wait) with no bound of any kind. The same defect then ate two dispatch attempts at a real PR: the
# second and third lanes stayed at 0 bytes for 5–15 minutes and were killed BY HAND. The trigger was
# transient (a `dial tcp … i/o timeout` against api.github.com, healthy again 0.26 s later), and a
# transient becomes a multi-hour corpse only because NOTHING bounds a lane's lifetime or its silence.
#
# ⛔ THE ASYMMETRY THIS FILE CLOSES — STATED PRECISELY, BECAUSE IT IS THE WHOLE BUG.
#   `extensions/builtin-tools`' `task` tool bounds a CHILD on three axes with a named verdict each:
#   `TASK_STREAM_STALL_MS` (20 min of idle stream), `TASK_CPU_STALL_MS` (30 min flat AFTER
#   demonstrated CPU work) and `TASK_TOOL_STALL_MS` (a 6 h age backstop). A LANE — a strictly more
#   expensive process, holding a worktree, a claim, a concurrency slot and a PR's worth of work — had
#   ONE axis: `run_agent`'s wall clock. And a wall clock cannot tell SLOW from STALLED, so it is
#   either too short (a kill mid-merge on a lane that has done nothing wrong) or too long (a cell
#   that holds 10 lanes aged 17–29 h and produces nothing, §6.5.1's measurement). The fleet's own
#   words for the missing reading are in `mac-lane.sh --status`: "bytes is NOT progress for a `-p`
#   lane … Reading either — or both — made ten healthy lanes look dead".
#
# ⛔ TWO INDEPENDENT SIGNALS, AND BOTH MUST BE QUIET — THAT IS THE DISTINCTION.
#   A lane is killed only when it has shown NO OUTPUT GROWTH **and** NO CPU DELTA for the idle window.
#   Either signal advancing keeps it alive however long it runs, which is what makes a legitimately
#   slow lane safe: a single 11 h test against a 26 m slowest shard is SLOW (its subtree burns CPU)
#   and is never touched; a `pi` parked in `ep_poll` is STALLED (both signals flat) and dies at the
#   idle bound. CPU alone is not enough in the other direction either — an I/O-bound tool child can be
#   silent AND CPU-flat at the start, which is why the two are CONJUNCTIVE and not a vote.
#
# ⛔ THE PROGRESS BOUND IS THE PRIMARY BOUND; THE WALL CLOCK IS A BACKSTOP (agent-infra#2888).
#   The two axes are NOT peers, and landing them as peers is what censored ≥50% of repair lanes at
#   their median: `prfix` rows in `walltime.tsv` read median = p90 = 2400 s, i.e. the bound, not the
#   work. Measured 2026-10-27/28, FIVE of five lanes in one batch ended at `elapsed == cap` with zero
#   commits and 144 KB of finished, uncommitted work between them.
#   * `--idle` (progress) is what decides whether a lane is WEDGED. It is set to the fleet's ALREADY
#     DECLARED no-progress allowance — 45 min — not to a number invented here: `DEFAULT_PROGRESS_AGE_MS`
#     (`extensions/shared/heartbeat-progress-edges.ts`, the builtin-tools `no-progress` clause #5195,
#     documented in `docs/ops/load-policy.md` §3 as `TASK_PROGRESS_AGE_MS = 2_700_000`). A second
#     threshold for the same concept — 20 min of BOTH signals flat — had shipped here, and having two
#     numbers for "how long may a lane show no progress" is how the wall clock came to kill a lane 5
#     minutes before either could be consulted. The two signals are CONJUNCTIVE here where the task
#     clause reads output alone, so this bound can only ever fire LATER than the doctrine's own
#     allowance — never earlier.
#   * `--wall` is an ABSOLUTE BACKSTOP for the case the progress rule cannot bound at all (a lane whose
#     %CPU and log both creep forward for ever). It must sit ABOVE the progress allowance, otherwise it
#     pre-empts it and the progress rule can never reach its verdict — which is exactly the shape that
#     was shipped (wall 2400 < allowance 2700). The pre-emption is now WARNED about at arm time.
#   * The DEFAULT backstop value is PROVISIONAL and is a SEAM, not a conclusion: today's `prfix`
#     distribution is censored by the very value being replaced (every row reports the cap), so the
#     ceiling cannot be sized from it. `agent-infra#2888` states the re-measurement that has to follow;
#     until then the value must make the REAL distribution observable, not trim it. See
#     `LANE_BACKSTOP_S` in `spawn-gate.sh` for the one default the shipped callers use.
#
# ⛔ KEEPING THE WEDGE KILL — WHAT THE EVIDENCE IS, STATED SO IT CAN BE FALSIFIED.
#   “Working slowly” = at least one of the two signals advanced inside the allowance.
#   “Wedged” = NEITHER did, for the whole allowance, on TWO CONSECUTIVE confirming samples (below).
#   A wedged lane is therefore still killed, and it is killed by the PROGRESS bound — never by the
#   backstop — because the backstop is required to sit above the allowance. That is the whole of the
#   no-regression claim: nothing was removed, the progress rule was given the doctrine's own window and
#   precedence. The latency of a wedge kill moves with that window (20 min → 45 min), which is a cost
#   `agent-infra#2888` accepts explicitly and states in its targets ("a wedged lane is still gone within
#   `cap`").
#
# ⛔ REPORTED, NOT JUST KILLED. A silent kill is the same blindness one level up: an operator who
#   finds a dead lane with no verdict has to re-derive everything. So every exit writes ONE line —
#   `verdict=stalled` / `verdict=exceeded-wallclock` / `verdict=finished` — carrying the last output
#   size, the CPU total and delta, the elapsed time, both bounds and the kill signal, to THREE
#   surfaces: the lane log (what an operator greps), stdout (the single status line), and
#   `--verdict-file` (what a caller reads programmatically).
#
# ⛔ PORTABLE BY CONSTRUCTION. POSIX `sh`, GNU **and** BSD userland. `timeout` is ABSENT on macOS, so
#   nothing here calls it: the bound is a poll loop over `ps`/`wc`. The only external commands used
#   are `ps`, `awk`, `wc`, `tr`, `date`, `sleep`, `kill` and `printf`, all POSIX. The test suite
#   proves it by running this file under `sh` with a PATH that has no `timeout` in it.
#
# USAGE
#   lane-bound.sh run   --log <file> [--wall S] [--idle S] -- <command> [args…]
#   lane-bound.sh watch --pid <pid> --log <file> [--wall S] [--idle S]
#
#     --log <file>        the lane's output. REQUIRED: it is one of the two progress signals, and a
#                         bound that cannot read its own signal is not a bound (refused, exit 2).
#     --wall <secs>       ABSOLUTE BACKSTOP. Not the primary bound (see the header): it fires whether
#                         or not the lane was working, so it must sit above --idle. `0` disables this
#                         axis (loudly). Default 7200 (2 h) — PROVISIONAL, an `agent-infra#2888` seam.
#     --idle <secs>       PROGRESS bound: no output growth AND no CPU delta for this long. This is the
#                         bound that decides wedged-vs-slow. Default 2700 (45 min) — the fleet's own
#                         declared no-progress allowance, reused rather than re-derived (#2888).
#     --tol-cs <cs>       CPU tolerance in centiseconds: a delta at or below this is NOT progress.
#                         Default 10 (0.10 s).
#     --poll <secs>       sampling interval. Default min(60, max(1, idle/4)).
#     --grace <secs>      TERM → KILL grace. Default 15 (unchanged from `run_agent`).
#     --tag <label>       named in every line. Default `lane`.
#     --verdict-file <f>  where the one-line verdict is also written. It is TRUNCATED at arm time and
#                         APPENDED to per line, so on a TERM→KILL escalation it holds the verdict line
#                         FOLLOWED by the kill outcome: a reader takes the first `verdict=` match.
#
#   `watch` supervises an EXISTING pid and kills it LEADER-ONLY, so the caller's own post-`wait`
#   group reap (spawn-gate.sh) keeps working exactly as before. `run` spawns the command, supervises
#   it, and kills its whole subtree (children first); it exits with the CHILD's status, so it is a
#   transparent wrapper.
#
# ENV KNOBS — the same contract as the `task` tool's own (`getCpuStallMs`): an explicit `0` disables
#   that axis, and a BLANK or MALFORMED value falls back to the DEFAULT, never to "disabled by a
#   typo" (a launcher doing `LANE_BOUND_IDLE_S="${UNSET}"` exports an empty string).
#     LANE_BOUND_IDLE_S · LANE_BOUND_WALL_S · LANE_BOUND_CPU_TOL_CS · LANE_BOUND_POLL_S ·
#     LANE_BOUND_GRACE_S
#
# EXIT  0..255 the child's own status (`run`) · 0 (`watch`) · 2 usage / refused
set -u

PROG=lane-bound

usage() {
  sed -n '/^# USAGE$/,/^# EXIT /p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' >&2
  exit "${1:-2}"
}

# ⛔ num_or <value> <default> — digits only, and an explicit 0 SURVIVES (it is the documented off
# switch). Everything else — blank, negative, "10m", "1.5" — is a TYPO and takes the default, because
# `0`-means-off conventions must never turn a typo into a silently unbounded lane.
num_or() {
  case "${1:-}" in
    '') printf '%s' "$2" ;;
    *[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

MODE=""; WALL_S=""; IDLE_S=""; TOL_CS=""; GRACE_S=""; POLL_S=""
LOGF=""; TAG=lane; VFILE=""; PID=""

[ $# -ge 1 ] || usage
case "$1" in
  run|watch) MODE="$1"; shift ;;
  -h|--help) usage 0 ;;
  *) echo "$PROG: refusing: first argument must be 'run' or 'watch', got '$1'" >&2; exit 2 ;;
esac

# ⛔ A VALUE IS VALIDATED WHERE IT IS READ, NOT IN A `$( )` (which is a SUBSHELL: its `exit 2` ends
# the substitution, not this script — measured here, the refusal printed, the parse carried on, and the
# lane was armed with the DEFAULT exactly as if nobody had asked for `10m`). An explicit, unreadable
# flag is an operator error and must REFUSE; only an ENV knob is defaulted, because a launcher doing
# `LANE_BOUND_IDLE_S="${UNSET}"` exports an empty string and must not thereby disarm the bound.
require_num() { # require_num <flag-name> <value>
  case "$2" in
    ''|*[!0-9]*) echo "$PROG: refusing: $1 '$2' is not a whole number (use 0 to disable that axis)" >&2; exit 2 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --wall)         [ $# -ge 2 ] || { echo "$PROG: refusing: --wall needs a value" >&2; exit 2; }; require_num --wall "$2"; WALL_S="$2"; shift 2 ;;
    --idle)         [ $# -ge 2 ] || { echo "$PROG: refusing: --idle needs a value" >&2; exit 2; }; require_num --idle "$2"; IDLE_S="$2"; shift 2 ;;
    --tol-cs)       [ $# -ge 2 ] || { echo "$PROG: refusing: --tol-cs needs a value" >&2; exit 2; }; require_num --tol-cs "$2"; TOL_CS="$2"; shift 2 ;;
    --poll)         [ $# -ge 2 ] || { echo "$PROG: refusing: --poll needs a value" >&2; exit 2; }; require_num --poll "$2"; POLL_S="$2"; shift 2 ;;
    --grace)        [ $# -ge 2 ] || { echo "$PROG: refusing: --grace needs a value" >&2; exit 2; }; require_num --grace "$2"; GRACE_S="$2"; shift 2 ;;
    --log)          [ $# -ge 2 ] || { echo "$PROG: refusing: --log needs a value" >&2; exit 2; }; LOGF="$2"; shift 2 ;;
    --tag)          [ $# -ge 2 ] || { echo "$PROG: refusing: --tag needs a value" >&2; exit 2; }; TAG="$2"; shift 2 ;;
    --pid)          [ $# -ge 2 ] || { echo "$PROG: refusing: --pid needs a value" >&2; exit 2; }; PID="$2"; shift 2 ;;
    --verdict-file) [ $# -ge 2 ] || { echo "$PROG: refusing: --verdict-file needs a value" >&2; exit 2; }; VFILE="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "$PROG: refusing unknown option: $1" >&2; exit 2 ;;
    *)  echo "$PROG: refusing unexpected argument: $1 (options after the mode, command after --)" >&2; exit 2 ;;
  esac
done

# ⛔ RESOLUTION ORDER IS FLAG → ENV → DEFAULT, AND THE FLAG WINS BY BEING PRESENT (see the parse loop
# above, which validated and refused a non-numeric flag already).
[ -n "$WALL_S" ]  || WALL_S="$(num_or "${LANE_BOUND_WALL_S:-}" 7200)"
[ -n "$IDLE_S" ]  || IDLE_S="$(num_or "${LANE_BOUND_IDLE_S:-}" 2700)"
[ -n "$TOL_CS" ]  || TOL_CS="$(num_or "${LANE_BOUND_CPU_TOL_CS:-}" 10)"
[ -n "$GRACE_S" ] || GRACE_S="$(num_or "${LANE_BOUND_GRACE_S:-}" 15)"
[ -n "$POLL_S" ]  || POLL_S="$(num_or "${LANE_BOUND_POLL_S:-}" 0)"
# A poll interval of 0 (or an idle window shorter than a second) means "derive one": a quarter of the
# idle window, capped at 60 s so the census cost stays ~3 `ps` calls a minute per lane on a box whose
# load IS the fleet, and floored at 1 s so a short window cannot spin.
if [ "$POLL_S" -eq 0 ]; then
  POLL_S=$(( IDLE_S / 4 ))
  [ "$POLL_S" -gt 60 ] && POLL_S=60
  [ "$POLL_S" -lt 1 ] && POLL_S=1
fi

# ⛔ AN ARM-TIME WARNING MUST REACH THE LANE LOG, NOT ONLY STDOUT (agent-infra#2888 review, P2 —
# verified). `run_agent` launches this helper as `sh lane-bound.sh watch … >/dev/null 2>&1`
# (spawn-gate.sh), so every bare `printf` here was DISCARDED on the one path that matters: the shipped
# claim "the pre-emption is warned about at arm time" was true of the tty and false of every real lane,
# and an operator who never reads the source could not learn that a lane was being wall-killed. So the
# arm-time warnings go to BOTH surfaces. NOT to `--verdict-file`: its reader takes the FIRST `verdict=`
# line (`sed … | head -1`), and an arm-time warning there would push the verdict out of first place.
warn_line() { # warn_line <line>
  printf '%s\n' "$1"
  [ -n "$LOGF" ] && printf '%s\n' "$1" >> "$LOGF" 2>/dev/null
  return 0
}

# ⛔ A BOUND THAT IS OFF MUST SAY SO. `LANE_BOUND_IDLE_S=0 LANE_BOUND_WALL_S=0` is a supported
# combination (an operator debugging a lane by hand) and it is also exactly what a fleet-wide typo
# would look like, so the single line below is the only thing that separates the two.
if [ "$WALL_S" -eq 0 ] && [ "$IDLE_S" -eq 0 ]; then
  warn_line "$(printf '[lane-bound] WARN tag=%s BOTH bounds are disabled (wall=0 idle=0) — this lane is UNBOUNDED by construction' "$TAG")"
fi
# ⛔ THE BACKSTOP MUST SIT ABOVE THE PROGRESS ALLOWANCE, AND A VIOLATION IS LOUD (#2888). The shipped
# pair was wall 2400 < allowance 2700, i.e. the backstop pre-empted the bound it is supposed to back
# up — so the progress rule could never reach its verdict and a lane was killed by elapsed time before
# anything could ask whether it was working. This is a WARN, never a refusal: a caller (and every test
# here) may arm a deliberately short wall to exercise the ceiling itself, and killing timing is an
# operator decision (#1070). ⚠️ IT GOES TO THE LANE LOG AS WELL (see `warn_line`) — an operator is told
# this on every lane that is armed this way, not only on a tty.
if [ "$WALL_S" -gt 0 ] && [ "$IDLE_S" -gt 0 ] && [ "$WALL_S" -le "$IDLE_S" ]; then
  warn_line "$(printf '[lane-bound] WARN tag=%s the BACKSTOP (wall=%ss) is NOT above the PROGRESS allowance (idle=%ss): the wall clock will pre-empt the progress bound, so a lane that is still working is killed by elapsed time (agent-infra#2888). Set --wall above --idle unless you are deliberately exercising the ceiling.' "$TAG" "$WALL_S" "$IDLE_S")"
fi

# ── the two signals ───────────────────────────────────────────────────────────────────────────────
# size_of <file> — the OUTPUT signal. `wc -c` rather than `stat`, because GNU and BSD `stat` disagree
# on the flag for "size in bytes" (`-c%s` vs `-f%z`) and a wrong-flag stat prints nothing, which would
# read as "no growth" forever and turn this bound into a lane-killer.
size_of() {
  [ -n "${1:-}" ] && [ -f "$1" ] || { printf '0'; return 0; }
  _lb_sz="$(wc -c < "$1" 2>/dev/null | tr -d ' \t')"
  printf '%s' "$(num_or "${_lb_sz:-}" 0)"
}

# pid_alive <pid> — a ZOMBIE is not alive (it has exited and is waiting to be reaped; `kill -0` still
# answers 0 for it, which would make `run` mode wait for its own corpse until the wall clock fired).
# ⛔ AND AN UNPROVABLE DEATH IS NEVER DEATH. If `ps` cannot be read — a fork-exhausted box, a truncated
# process table — an empty answer is NOT evidence that the lane exited: concluding `finished` there
# would retire BOTH bounds (the loop returns) and leave the lane unbounded, which is the exact defect
# this file exists to remove. `kill -0` separates the cases (it answers for any pid this process may
# signal), and the unreadable-and-unsignalable pair falls through to `dead` only when both agree.
pid_alive() {
  [ -n "${1:-}" ] || return 1
  case "${1:-}" in *[!0-9]*) return 1 ;; esac
  [ "$1" -gt 1 ] || return 1
  _lb_st="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' \t')"
  if [ -n "$_lb_st" ]; then
    case "$_lb_st" in Z*) return 1 ;; esac
    return 0
  fi
  kill -0 "$1" 2>/dev/null && return 0
  return 1
}

# The awk that both the CPU sum and the subtree walk are built from. It converts `ps -o time=` into
# CENTISECONDS (so a 0.1 s tolerance is representable) and walks the ppid graph from the root to a
# fixpoint, because BSD `ps` has no portable `--ppid` and `pgrep -P` is not POSIX.
LB_AWK='
  function csec(t,   d, a, n, s) {
    d = 0
    if (match(t, /^[0-9]+-/)) { d = substr(t, 1, RLENGTH - 1) + 0; t = substr(t, RLENGTH + 1) }
    n = split(t, a, ":")
    if (n >= 3)      s = a[n-2] * 3600 + a[n-1] * 60 + a[n]
    else if (n == 2) s = a[n-1] * 60 + a[n]
    else             s = a[n] + 0
    return int(d * 8640000 + s * 100 + 0.5)
  }
  { pid[NR] = $1; par[NR] = $2; cs[NR] = csec($3); n = NR }
  END {
    # ⛔ AN EMPTY OR ROOT-LESS SNAPSHOT IS AN UNREADABLE SAMPLE, NEVER A FLAT LANE. `ps -A` can return a
    # truncated table on a loaded box, and a lane sampled as "0 CPU" would then look stalled and be
    # killed while it is working — the exact fail-open this bound must not have. The caller reads an
    # empty result as `unknown` and stands the idle clause down; the wall clock still applies.
    if (n == 0) exit
    found = 0
    for (i = 1; i <= n; i++) if (pid[i] + 0 == root + 0) { found = 1; break }
    if (!found) exit
    inc[root] = 1
    for (pass = 1; pass <= n; pass++) {
      changed = 0
      for (i = 1; i <= n; i++) if (!(pid[i] in inc) && (par[i] in inc)) { inc[pid[i]] = 1; changed = 1 }
      if (!changed) break
    }
    total = 0
    for (i = 1; i <= n; i++) if (pid[i] in inc) total += cs[i]
    print total + 0
  }'

cpu_cs_of() {
  _lb_ps="$(ps -Ao pid=,ppid=,time= 2>/dev/null)" || return 0
  [ -n "$_lb_ps" ] || return 0
  printf '%s\n' "$_lb_ps" | awk -v root="${1:-0}" "$LB_AWK"
}

# The subtree, DEEPEST FIRST, so a child is signalled before the parent that owns it. A best-effort
# walk: if `ps` cannot be read the pid itself is still printed, because refusing to kill anything is
# not a safe failure mode for a bound that has already decided.
subtree_pids() {
  ps -Ao pid=,ppid= 2>/dev/null | awk -v root="${1:-0}" '
    { pid[NR] = $1; par[NR] = $2; n = NR }
    END {
      if (n == 0) { if (root > 1) print root; exit }
      inc[root] = 1
      for (pass = 1; pass <= n; pass++) {
        changed = 0
        for (i = 1; i <= n; i++) if (!(pid[i] in inc) && (par[i] in inc)) { inc[pid[i]] = 1; changed = 1 }
        if (!changed) break
      }
      for (i = n; i >= 1; i--) if ((pid[i] in inc) && pid[i] != root) print pid[i]
      if (root > 1) print root
    }'
}

# ── the verdict ──────────────────────────────────────────────────────────────────────────────────
# ONE line, to all three surfaces. Every number that decided it is IN the line, because the question an
# operator actually asks a frozen lane is "was it silent, or was it slow?" and that answer cannot be
# reconstructed afterwards: the log is truncated on rerun and the CPU counter is gone with the process.
V_VERDICT=""; V_SIGNAL=""; V_RC=""; V_AT=0; V_BYTES=0; V_DBYTES=0; V_CPU=0; V_DCPU=0; V_SILENT=0
V_START=0; V_UNREADABLE=0; V_EMITTED=0

emit_line() { # emit_line <line>
  printf '%s\n' "$1"
  [ -n "$LOGF" ] && printf '%s\n' "$1" >> "$LOGF" 2>/dev/null
  # ⛔ APPEND, NEVER `>` (agent-infra#2888 review, NEW finding — MEASURED on a real killed lane). With
  # `>` each emitted line REPLACED the previous one, so on a TERM→KILL escalation the file ended up
  # holding ONLY `[lane-bound] KILL … still alive 15s after TERM`; `spawn-gate.sh` reads it back with
  # `sed -n 's/.*verdict=\([a-z-]*\).*/\1/p' | head -1` and got NOTHING, so `AGENT_BOUND_VERDICT` was
  # blank for exactly the lane the bound killed (the human surface — the log — was intact, the
  # machine-readable one was not). The verdict line is emitted BEFORE the kill by design (`enforce`),
  # so appending keeps it FIRST in the file and `head -1` stays the right reader; the caller truncates
  # the file at arm time (`rm -f`, both modes below), so nothing accumulates across runs.
  [ -n "$VFILE" ] && printf '%s\n' "$1" >> "$VFILE" 2>/dev/null
  return 0
}

verdict_line() {
  printf '[lane-bound] VERDICT verdict=%s tag=%s pid=%s rc=%s elapsed=%ss wall_bound=%ss idle_bound=%ss silent=%ss bytes=%s bytes_delta=%s cpu_cs=%s cpu_delta_cs=%s tol_cs=%s cpu_unreadable=%s signal=%s log=%s' \
    "${V_VERDICT:-unknown}" "$TAG" "${PID:-0}" "${V_RC:-na}" "$(( V_AT - V_START ))" "$WALL_S" "$IDLE_S" \
    "$V_SILENT" "$V_BYTES" "$V_DBYTES" "${V_CPU:-na}" "${V_DCPU:-na}" "$TOL_CS" "$V_UNREADABLE" "${V_SIGNAL:-none}" "${LOGF:-none}"
}

# enforce <verdict> <reason sentence> — decide, KILL, and be loud about both.
#
# ⛔ THE VERDICT IS WRITTEN **BEFORE** THE KILL, AND THAT ORDER IS LOAD-BEARING (measured on the
# integration run, not reasoned about). The caller that owns the lane (`run_agent`) reaps the
# watchdog's whole process group the instant its own `wait` on `pi` returns — which is milliseconds
# after the TERM lands — so a verdict written AFTER the grace loop was **never written at all**: the
# lane log showed `[lane-bound] STALLED …` with NO `VERDICT` line, and the caller read `bound=none`
# for a lane the bound had just killed. A kill with no verdict is the blindness this file exists to
# remove, one level up, so everything that decides the verdict is emitted first; the grace/KILL
# outcome is a SEPARATE line (a verdict line is the single status line, and it stays single).
enforce() {
  V_VERDICT="$1"
  # `signal=` is the signal THIS BOUND sends (TERM). Whether a KILL was needed after the grace period
  # is a separate fact and gets its own line below — the verdict is written before the kill, so it may
  # not claim an outcome it has not reached yet.
  V_SIGNAL=TERM
  emit_line "[lane-bound] $(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_') — $2: sending TERM to pid $PID, KILL after ${GRACE_S}s"
  emit_line "$(verdict_line)"
  V_EMITTED=1
  # ⛔ `watch` mode kills the LEADER ONLY. The caller owns the process group and reaps it after its
  # own `wait` (spawn-gate.sh's `kill -TERM -- -$pid`), exactly as the pre-existing wall-clock
  # watchdog did; signalising the group from here as well would be a behaviour change with no
  # measurement behind it. `run` mode owns the tree, so it kills the tree, children first.
  if [ "$MODE" = "run" ]; then
    for _lb_q in $(subtree_pids "$PID"); do kill -TERM "$_lb_q" 2>/dev/null || true; done
  else
    kill -TERM "$PID" 2>/dev/null || true
  fi
  _lb_i=0
  while [ "$_lb_i" -lt "$GRACE_S" ]; do
    pid_alive "$PID" || return 0
    sleep 1
    _lb_i=$(( _lb_i + 1 ))
  done
  if pid_alive "$PID"; then
    if [ "$MODE" = "run" ]; then
      for _lb_q in $(subtree_pids "$PID"); do kill -KILL "$_lb_q" 2>/dev/null || true; done
    else
      kill -KILL "$PID" 2>/dev/null || true
    fi
    V_SIGNAL=TERM+KILL
    emit_line "[lane-bound] KILL tag=$TAG pid=$PID — still alive ${GRACE_S}s after TERM"
  fi
  return 0
}

# ── the loop ─────────────────────────────────────────────────────────────────────────────────────
# One implementation, both modes: the only difference is who owns the child's exit status.
supervise() {
  V_START="$(date +%s)"
  _lb_last_progress="$V_START"
  _lb_prev_bytes="$(size_of "$LOGF")"
  _lb_prev_cpu="$(cpu_cs_of "$PID")"
  V_AT="$V_START"; V_BYTES="$_lb_prev_bytes"; V_CPU="$_lb_prev_cpu"
  _lb_idle_hits=0

  while :; do
    if ! pid_alive "$PID"; then
      V_AT="$(date +%s)"
      return 0
    fi
    _lb_now="$(date +%s)"
    _lb_bytes="$(size_of "$LOGF")"
    _lb_cpu="$(cpu_cs_of "$PID")"
    # ⛔ AN UNREADABLE CPU SAMPLE IS `unknown`, AND UNKNOWN MUST NOT ARM A KILL (the rule
    # `tools/fleet/liveness.py` and `extensions/task-heartbeat.ts` both state: "absence of evidence must
    # never arm a kill"). The sample is discarded for this tick, the previous baseline is kept, and the
    # idle clause stands down — the WALL clock still applies, so this is a latency cost on a fail-safe
    # path, never an unbounded wait. The count reaches the verdict line so the degradation is visible
    # after the fact instead of only in a stdout nobody kept.
    case "${_lb_cpu:-}" in
      ''|*[!0-9]*)
        V_UNREADABLE=$(( V_UNREADABLE + 1 ))
        _lb_cpu="$_lb_prev_cpu"
        _lb_cpu_known=0 ;;
      *) _lb_cpu_known=1 ;;
    esac
    _lb_dbytes=$(( _lb_bytes - _lb_prev_bytes ))
    _lb_dcpu=$(( _lb_cpu - _lb_prev_cpu ))
    # ⛔ NEITHER SIGNAL MAY PRODUCE NEGATIVE EVIDENCE. A truncated/rotated log and a pid-reuse CPU
    # counter both read as a DECREASE; treating that as "progress" would let a lane defeat its own
    # bound by rotating a file, and treating it as a stall would kill one for being rotated.
    [ "$_lb_dcpu" -lt 0 ] && _lb_dcpu=0
    V_AT="$_lb_now"; V_BYTES="$_lb_bytes"; V_CPU="$_lb_cpu"
    V_DBYTES="$_lb_dbytes"; V_DCPU="$_lb_dcpu"
    V_SILENT=$(( _lb_now - _lb_last_progress ))

    # Progress = EITHER signal advanced. The CPU comparison is strictly-greater-than the tolerance, so
    # a sub-tolerance twitch (a timer wake, a parked fork child, a prompt redraw) is not progress.
    if [ "$_lb_dbytes" -gt 0 ] || [ "$_lb_dcpu" -gt "$TOL_CS" ]; then
      _lb_last_progress="$_lb_now"
      V_SILENT=0
    fi

    if [ "$IDLE_S" -gt 0 ] && [ "$_lb_cpu_known" = 1 ] && [ $(( _lb_now - _lb_last_progress )) -ge "$IDLE_S" ]; then
      # ⛔ TWO CONSECUTIVE CONFIRMING SAMPLES, NEVER ONE — the rule README §6.5.1 states for the outside
      # reapers ("the decision takes two consecutive observations … never one reading"), applied to the
      # inside bound for the same reason and one measured one of its own: with a single sample, ONE
      # anomalous `ps` snapshot (a lane sampled as 0 CPU) ended a healthy lane, because a single reading
      # cannot tell a freeze from a missed measurement. The cost is one extra poll of latency, and the
      # bound is therefore detected between `IDLE_S` and `IDLE_S + 2 x poll` — stated, not hidden.
      _lb_idle_hits=$(( _lb_idle_hits + 1 ))
    else
      _lb_idle_hits=0
    fi
    if [ "$IDLE_S" -gt 0 ] && [ "${_lb_idle_hits:-0}" -ge 2 ]; then
      V_SILENT=$(( _lb_now - _lb_last_progress ))
      enforce stalled "no output growth and no CPU delta for ${V_SILENT}s (idle bound ${IDLE_S}s, tolerance $(( TOL_CS / 100 )).$(printf '%02d' $(( TOL_CS % 100 )))s CPU)"
      return 0
    fi
    if [ "$WALL_S" -gt 0 ] && [ $(( _lb_now - V_START )) -ge "$WALL_S" ]; then
      enforce exceeded-wallclock "wall-clock ceiling ${WALL_S}s reached (silent=${V_SILENT}s, bytes_delta=${_lb_dbytes}, cpu_delta_cs=${_lb_dcpu} at the last sample — the ceiling fires whether or not the lane was still advancing)"
      return 0
    fi

    # Never sleep past the wall clock: a 60 s poll on a 5 s ceiling would overshoot the bound by a
    # minute, and the wall ceiling is the one axis an operator expects to be exact.
    _lb_tick="$POLL_S"
    if [ "$WALL_S" -gt 0 ]; then
      _lb_rem=$(( WALL_S - ( _lb_now - V_START ) ))
      [ "$_lb_rem" -lt "$_lb_tick" ] && _lb_tick="$_lb_rem"
    fi
    [ "$_lb_tick" -lt 1 ] && _lb_tick=1
    sleep "$_lb_tick"
    _lb_prev_bytes="$_lb_bytes"
    _lb_prev_cpu="$_lb_cpu"
  done
}

# ── modes ────────────────────────────────────────────────────────────────────────────────────────
case "$MODE" in
  watch)
    [ -n "$LOGF" ] || { echo "$PROG: refusing: --log is required (it is one of the two progress signals; a bound that cannot read its signal is not a bound)" >&2; exit 2; }
    pid_alive "$PID" || { echo "$PROG: refusing: --pid '$PID' is not a live process — nothing to bound" >&2; exit 2; }
    [ -n "$VFILE" ] && rm -f "$VFILE" 2>/dev/null
    supervise
    V_RC=na
    ;;
  run)
    [ -n "$LOGF" ] || { echo "$PROG: refusing: --log is required (it is one of the two progress signals; a bound that cannot read its signal is not a bound)" >&2; exit 2; }
    [ $# -ge 1 ] || { echo "$PROG: refusing: no command after --" >&2; exit 2; }
    [ -n "$VFILE" ] && rm -f "$VFILE" 2>/dev/null
    "$@" &
    PID=$!
    supervise
    wait "$PID" 2>/dev/null; V_RC=$?
    ;;
esac

# ⛔ THE FINISHED PATH EMITS HERE; A BOUND-KILLED LANE ALREADY DID, BEFORE THE KILL (see `enforce`).
# Emitting twice would break the "one status line" contract an operator reads with `tail -1`.
if [ "${V_EMITTED:-0}" = "1" ]; then
  : # already written, and written early on purpose
else
  V_VERDICT="${V_VERDICT:-finished}"
  V_SIGNAL="${V_SIGNAL:-none}"
  emit_line "$(verdict_line)"
fi
# ⛔ AN EXPLICIT BRANCH, never `[ … ] && exit`: on the `watch` arm that test is FALSE, so its status
# would become the script's exit status and a successful bound would report 1 to whoever read it.
if [ "$MODE" = "run" ]; then exit "$V_RC"; fi
exit 0
