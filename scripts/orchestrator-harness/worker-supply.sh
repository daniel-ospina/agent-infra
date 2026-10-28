#!/usr/bin/env bash
# worker-supply.sh — the SUPPLY half of the PR-repair pool: it keeps the configured number of repair
# workers alive by RE-OFFERING the orders whose worker died, and it refuses to run twice.
#
# ⛔ WHY THIS FILE EXISTS, AND WHAT IT IS *NOT* (measured 2026-10-27T03:30Z-03:45Z).
# `pr-doctor.py` ran every 5 minutes and printed, three passes in a row:
#
#     pass: 22 open PRs :: rerun-checks=6 resolve-conflict=10 skipped-running=6
#           (capacity fix=16 review=12, inflight=0 (alive=0 unknown=0), budget fix=16 review=12 total=28)
#     REFUSING: 16 order(s) no worker accepted and nothing was dispatched -- not a clean pass
#     EXIT rc=3
#
# while the same daemon had logged `dispatched 3 of 4 queued — ok` five hours earlier. NOTHING in the
# fleet was refilling the pool: the doctor's own dispatch is the ONLY thing that had ever created a
# repair worker, so supply existed exactly as often as a pass found actionable PRs *and* could place
# them. Two independent failures came through that hole on the same night, and both are visible in
# `~/.pi/agent/state/pr-doctor.log`:
#
#   * `contract_note()` refused the whole repo (`the required-check set and human-gated surface paths
#     daniel-ospina/agent-infra is judged by are NOT supplied` — agent-infra#2518). Sixteen orders were
#     graded and none was placed. A HUMAN must supply that declaration; no worker can be supplied for
#     an order the dispatcher refuses to hand out, and this script says so rather than inventing work.
#   * a checkout that could not be read (`REPO=…/tortoise has no readable 'origin' remote`) so no
#     worktree could be materialised — five orders, nothing placed.
#
# ⛔ AND THE SECOND DEFECT IT CLOSES IS THE ONE NO PASS CAN SEE: a worker that DIES MID-ORDER.
# `nonblocking-dispatch.sh` records the order in `$O/bg/<name>.started` and its verdict in `.rc`; when
# the process is killed (a machine sleep, a cap kill, an OOM) the record stays, the worker is gone, and
# the PR sits with an order nobody is executing until the doctor's own 45-minute cooldown expires and
# some later pass re-dispatches it — if the pass is still able to place orders at all. This script
# closes that window to one interval by re-offering the DEAD order.
#
# ⛔ IT IS NOT A SECOND DISPATCH PATH. It spawns `pi` never; it calls the ONE dispatcher
# (`$O/nonblocking-dispatch.sh`) with the arguments the dispatcher ITSELF recorded for that order
# (worktree, brief, cap, kind). A supervisor that grew its own spawn logic would diverge from
# `spawn-gate.sh`'s load/disk/brief gates and stop being a supply path at all — the same reason
# `pr-doctor.dispatch()` routes through it. `worker-supply.test.sh` asserts the invoker set.
#
# ⛔ IT IS NOT A MERGE AUTHORITY. It never calls `gh`, never calls `admin-merge.sh`, never records a
# review, never reaps or kills a worker. Its only actions are: READ the records, WRITE an offer through
# the dispatcher, WRITE its own ledger. A supervisor that could land a PR would be a second merge path
# with no attestation — the gate is a human's, and this file has one verb that can push: none.
#
# ── THE ORDER, THE WORKER AND THE VERDICT (the three files it reads) ────────────────────────────
#   order    `$O/bg/<name>.started` — `name/worktree/branch/kind/prompt/started/cap`, written by
#            `nonblocking-dispatch.sh` at ACCEPT time and rewritten on every spawn. This is the
#            acceptance record: `pr-doctor` adopting a worker is a FILE, not a claim, not a socket.
#   verdict  `$O/bg/<name>.rc` + `$O/bg/<name>.pid` — the harness's own exit status and pid.
#   answer   `<dispatcher> --status <name>` — `running|done|failed|lost`, THE reader the doctor uses
#            (`worker_live()`), so the two cannot disagree about whether a worker exists.
#
# ── THE POLARITY RULE, STATED ONCE ─────────────────────────────────────────────────────────────
#   running                 → LIVE       (holds a slot, never re-offered)
#   done                    → COMPLETE   (the order RAN TO COMPLETION. The doctor's next pass re-grades
#                                          that PR against its head, its checks and its cooldown; a
#                                          re-offer here would re-execute a FINISHED brief on the same
#                                          worktree and bypass that re-grade — so supply replaces
#                                          workers that DIED, and never replays ones that finished.
#                                          Found by review: the first version folded `done` into DEAD.)
#   failed | lost           → DEAD       (an offer may be re-issued)
#   unreadable / no answer   → UNKNOWN    → DO NOT SPAWN. A second worker into one deterministic
#                                          worktree destroys the first one's log/.rc/.pid
#                                          (pr-doctor's own measurement), so "I could not tell" is
#                                          never read as "the slot is free".
#   running, but the order's own wall-clock cap has expired → UNKNOWN, NOT dead. A `.pid` file nothing
#                                          prunes plus a recycled pid reads `running` for ever; the
#                                          doctor concludes DEAD there because it then re-dispatches
#                                          through its own worktree guard. Here the same datum is only
#                                          ever a REPORT (`stale-claim`), because this script's action
#                                          is a SPAWN and the asymmetry of the two mistakes is not
#                                          equal: a late refill costs an interval, a double spawn
#                                          destroys a running worker.
#
# ── CAPACITY COMES FROM ONE PLACE ──────────────────────────────────────────────────────────────
# `fix + review` is the machine's own budget: `MAX_FIX` + `MAX_REVIEW` from the environment, else from
# the SAME launchd plist `pr-doctor.capacity()` reads (`com.eldato.orchestrator-loop.plist`), else the
# same shipped defaults. The numeric rule is `orch-loop.sh`'s `is_num`/`is_limit` (and pr-doctor's
# `_limit`): `0`, or a non-zero-leading run of at most nine digits — bare `int()` would accept `010`
# and `1_000` that the loop rejects, and that divergence is a fail-open budget. `worker-supply.test.sh`
# PINS this reader against `pr-doctor.capacity()` itself rather than against a second literal.
#
# Usage:
#   worker-supply.sh              one pass (default; same as `refill`)
#   worker-supply.sh refill       one pass, explicit
#   worker-supply.sh heal         one pass, explicit — the operator's word for `refill` (one alias, not a
#                                 second code path): it is the verb you reach for when `status` shows dead
#                                 orders, so it must exist rather than be discovered as a usage error
#   worker-supply.sh --loop       the service's main process: pass, sleep INTERVAL, repeat
#   worker-supply.sh --dry-run    decide and print; spawn nothing, write no ledger row AND no pass
#                                 record — the record is the LAST REAL PASS's evidence, and a rehearsal
#                                 that overwrote it would destroy the only durable answer to "what did
#                                 the supervisor actually do?"
#   worker-supply.sh status       the last pass record + a FRESH live count, exit 0
#   worker-supply.sh --help
#
# Exit codes (the fleet vocabulary, kept identical on purpose):
#   0  a pass completed — it refilled, or there was genuinely nothing to refill
#   2  REFUSING — a read a pass needs could not be taken (no dispatcher, an unwritable state dir), or
#      the pool itself could not be read: nothing was supplied and `unknown > 0` with nothing dead
#   3  UNDELIVERED — a refill was ATTEMPTED and no worker took it (the dispatcher refused)
#   4  ALREADY-RUNNING — the single-instance guard holds; nothing was touched
#   6  DEFERRED — dead orders are still dead after the pass: the budget is full, the order has spent
#      its refills, or its record is un-replayable. A pass that re-offered SOME and then hit a bound is
#      DEFERRED too (a verdict about what is left, not a pass) — `refilled>0` alone is not a clean
#      pass, which is the doctor's `dispatched 0 of M` law. The record names which bound held it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# ── knobs (env only; the unit/plist renders them so an operator can read them where they run) ──
O="${O:-$HOME/orchestrator}"
STATE_DIR="${WORKER_SUPPLY_STATE_DIR:-$O/state}"
BG_DIR="${WORKER_SUPPLY_BG_DIR:-$O/bg}"
DISPATCH="${WORKER_SUPPLY_DISPATCH:-$O/nonblocking-dispatch.sh}"
PREFIX="${WORKER_SUPPLY_PREFIX:-prd-}"                 # the worker NAMESPACE it supplies
INTERVAL_S="${WORKER_SUPPLY_INTERVAL_S:-60}"           # --loop cadence
MAX_REFILLS="${WORKER_SUPPLY_MAX_REFILLS:-2}"          # re-offers per ORDER (a crash loop bound)
SPAWN_CALL_TIMEOUT="${WORKER_SUPPLY_SPAWN_TIMEOUT_S:-120}"   # bounds the DISPATCHER, not the worker
PROBE_TIMEOUT="${WORKER_SUPPLY_PROBE_TIMEOUT_S:-60}"   # bounds one `--status` probe
STALE_SLACK_S="${WORKER_SUPPLY_STALE_SLACK_S:-300}"    # a `running` past cap+slack is only REPORTED
LOCK_MAX_S="${WORKER_SUPPLY_LOCK_MAX_S:-900}"          # an unverifiable lock is taken over after this
LOG_MAX_BYTES="${WORKER_SUPPLY_LOG_MAX_BYTES:-262144}"
ORCH_PLIST="${WORKER_SUPPLY_ORCH_PLIST:-$HOME/Library/LaunchAgents/com.eldato.orchestrator-loop.plist}"
DEFAULT_MAX_FIX=3
DEFAULT_MAX_REVIEW=4

LOCK_DIR="$STATE_DIR/worker-supply.lock"
LEDGER="$STATE_DIR/worker-supply-offers.tsv"
RECORD="$STATE_DIR/worker-supply.state"
LOG="$STATE_DIR/worker-supply.log"

# ── bounded probes: perl's alarm survives `exec`, which is why it is the bound ──────────────────
# `timeout` is absent on macOS (measured, the hard way: `timeout 60 python3 …` → command not found),
# so it is the SECOND choice and a plain run is the last resort. A bound that FIRES is a normal
# non-zero answer: every caller treats it as UNKNOWN, never as a pass. Copied in shape (not sourced)
# from `worker-terminal.sh`'s `wt_bounded`, which carries the same rule for the same platform reason.
bounded() { # <secs> <cmd...>
  local s="${1:-10}"; shift || true
  case "$s" in ''|*[!0-9]*) s=10 ;; esac
  [ "$s" -gt 0 ] 2>/dev/null || s=10
  if command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$s" "$@"; return $?; fi
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; return $?; fi
  "$@"
}

# File mtime, portable: `stat -c` (GNU/Linux) first, `stat -f` (BSD/macOS) second — the same two
# shapes the harness's own portable helpers use. An unreadable mtime answers empty, never 0.
mtime_of() {
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || true
}

# ── the log: bounded, because a supervisor on a 60 s clock writes for ever ─────────────────────
log_line() {
  local msg line
  msg="$(date '+%Y-%m-%dT%H:%M:%SZ') worker-supply: $*"
  printf '%s\n' "$msg"
  if [ -d "$STATE_DIR" ]; then
    local sz=0
    [ -f "$LOG" ] && sz="$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')" && [ -n "$sz" ] || sz=0
    case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
    if [ "$sz" -ge "$LOG_MAX_BYTES" ]; then mv -f "$LOG" "$LOG.1" 2>/dev/null || true; fi
    printf '%s\n' "$msg" >> "$LOG" 2>/dev/null || true
  fi
  return 0
}

# ── the capacity rule, bit-for-bit the loop's ────────────────────────────────────────────────
# `0` or a non-zero-leading run of at most nine digits, exactly `orch-loop.sh`'s is_num/is_limit and
# `pr-doctor._limit`. A bare numeric test would read `010` as 10 where the loop coerces to its default.
valid_num() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 9 ] || return 1
  [ "$1" = "0" ] && return 0
  case "$1" in 0*) return 1 ;; esac
  return 0
}

# ── THE KNOBS ARE VALIDATED WHERE THEY ARE ENFORCED, NOT ONLY WHERE THEY ARE RENDERED ───────────
# `valid_num()` is this file's rule for every number it COMPARES, so EVERY numeric knob goes through it
# here, at startup. Found by review (#2896 rounds 2 and 3) — every one of these failed OPEN, and none is
# render-only: an operator, a shell profile or a hand-edited unit can set the environment directly, so
# the fallback has to live at the point of use.
#   WORKER_SUPPLY_MAX_REFILLS=two   → `[ <n> -ge two ]` does not PARSE (rc 2), the `if` reads FALSE and
#                                     the per-order crash-loop bound is INERT: a worker that dies for
#                                     ever is re-offered for ever, and the record cannot say so.
#   WORKER_SUPPLY_INTERVAL_S=abc|0  → `sleep` returns at once and so does `wait`, so `--loop` re-passes
#                                     with NO cadence — a hot loop against the dispatcher.
#   WORKER_SUPPLY_LOCK_MAX_S=abc    → the ARITHMETIC test fails, falls to the takeover arm, and a
#                                     pid-less lock is taken over while the holder is alive: the exact
#                                     double-supervisor this file's lock exists to refuse. (Round 2
#                                     guarded the render-time knobs only; the lock bound is the same
#                                     class and the worst of them.)
#   WORKER_SUPPLY_STALE_SLACK_S=abc → `$(( cap + STALE_SLACK_S ))` names a variable under `set -u`: the
#                                     supervisor dies on the probe instead of reporting a stale claim.
#   WORKER_SUPPLY_SPAWN_TIMEOUT_S / _PROBE_TIMEOUT_S / _LOG_MAX_BYTES → the bound silently disappears
#                                     (`alarm`/`timeout` refuse the argument) and log rotation stops.
# The installer REFUSES these values at render time (install-worker-supply.sh) — refusing is right for
# an install question, and wrong for an already-running supervisor, which must keep supplying.
knob_num() { # <VARNAME> <value> <default> <pos|any> — the fallback says what it did, never silently
  local name="$1" v="$2" d="$3" mode="$4" kind="non-negative integer"
  [ "$mode" = pos ] && kind="positive integer"
  if ! valid_num "$v" || { [ "$mode" = pos ] && [ "$v" -eq 0 ]; }; then
    log_line "knob: $name='$v' is not a $kind — using $d (an unreadable bound is an inert one)"
    return 1
  fi
  return 0
}
knob_num WORKER_SUPPLY_MAX_REFILLS       "$MAX_REFILLS"        2       any || MAX_REFILLS=2
knob_num WORKER_SUPPLY_INTERVAL_S        "$INTERVAL_S"         60      pos || INTERVAL_S=60
knob_num WORKER_SUPPLY_SPAWN_TIMEOUT_S   "$SPAWN_CALL_TIMEOUT" 120     pos || SPAWN_CALL_TIMEOUT=120
knob_num WORKER_SUPPLY_PROBE_TIMEOUT_S   "$PROBE_TIMEOUT"      60      pos || PROBE_TIMEOUT=60
knob_num WORKER_SUPPLY_STALE_SLACK_S     "$STALE_SLACK_S"      300     any || STALE_SLACK_S=300
knob_num WORKER_SUPPLY_LOCK_MAX_S        "$LOCK_MAX_S"         900     pos || LOCK_MAX_S=900
knob_num WORKER_SUPPLY_LOG_MAX_BYTES     "$LOG_MAX_BYTES"      262144  pos || LOG_MAX_BYTES=262144
case "$PREFIX" in
  ''|*[[:space:]]*)
    log_line "knob: WORKER_SUPPLY_PREFIX='$PREFIX' is empty or contains whitespace — using 'prd-' (the order glob would match nothing, and an empty queue reads as a clean pass)"
    PREFIX="prd-" ;;
esac

# The plist's EnvironmentVariables, as `KEY=VALUE` lines. Read with python3's plistlib (both platforms
# have it; `plutil` is macOS-only) and printed only — a malformed or absent plist is EMPTY, never an
# error: the environment and then the shipped defaults still apply, and every read is total.
plist_env_dump() { # <plist> <outfile>
  local pl="$1" out="$2"
  # ⛔ THE REDIRECTION FAILS *BEFORE* `2>/dev/null` IN THE SAME COMMAND TAKES EFFECT, so the shell's own
  # "No such file or directory" leaked to stderr — `install-worker-supply.sh` folds this into the report
  # it shows an operator, contradicting the rule stated directly above (an absent plist is EMPTY, never
  # an error). A compound command applies the redirections to the GROUP, so the failure is silent.
  { : > "$out"; } 2>/dev/null || return 0
  [ -f "$pl" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  bounded 20 python3 - "$pl" > "$out" 2>/dev/null <<'PY' || : > "$out"
import plistlib, sys
try:
    pl = plistlib.load(open(sys.argv[1], "rb"))
except Exception:
    sys.exit(0)
env = pl.get("EnvironmentVariables") if isinstance(pl, dict) else None
if isinstance(env, dict):
    for k, v in env.items():
        print("%s=%s" % (k, v))
PY
  return 0
}

# `<key> <default> [<plistenv>]` -> the limit, validated. Environment WINS, exactly as in pr-doctor —
# and SET-BUT-EMPTY IS NOT UNSET. `pr-doctor.capacity()` does `cfg.update(os.environ)` and then applies
# its regex, so an empty `MAX_FIX=` reaches the regex, FAILS it, and yields the DEFAULT (3) rather than
# the plist's value. A reader that treated "" as "unset" would fall through to the plist and run 16
# fix slots where the loop runs 3 — a fail-open budget on the documented override path. `printenv`'s
# exit status is what distinguishes the two, so it is read, not discarded.
limit_of() {
  local key="$1" def="$2" envfile="${3:-}" raw="" have=0
  if raw="$(printenv "$key" 2>/dev/null)"; then have=1; fi
  if [ "$have" = 0 ] && [ -n "$envfile" ] && [ -f "$envfile" ]; then
    raw="$(awk -F= -v k="$key" '$1==k { sub("^" k "=", ""); print; exit }' "$envfile" 2>/dev/null || true)"
  fi
  if valid_num "$raw"; then printf '%s\n' "$raw"; else printf '%s\n' "$def"; fi
}

# ── the single-instance guard: an atomic mkdir, a pid inside it, and a CAS takeover ──────────────
# ⛔ `mkdir` IS THE CAS. macOS has no `flock`, and `ln`-based locking has its own recovery hole; a
# directory create is atomic on every filesystem this fleet runs on and needs no tool.
# ⛔ THE TAKEOVER IS A RENAME, NOT A `rm -rf` + `mkdir`: two supervisors waking in the same second must
# not both decide a stale lock is stale. `mv` of a given directory succeeds for exactly one of them.
lock_take() {
  mkdir -p "$STATE_DIR" 2>/dev/null || { log_line "REFUSING: state dir $STATE_DIR is not writable"; return 2; }
  if mkdir "$LOCK_DIR" 2>/dev/null; then printf '%s\n' "$$" > "$LOCK_DIR/pid"; return 0; fi
  local holder age now holder_cmd
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null | tr -d ' \n' || true)"
  if valid_num "$holder" && kill -0 "$holder" 2>/dev/null; then
    # A LIVE PID IS A HOLDER ONLY IF IT IS THIS SCRIPT. A recycled pid would otherwise wedge the
    # supervisor for ever (an inert guard is the failure this file exists to remove); a pid that IS
    # another worker-supply is positive evidence, and is respected.
    # ⛔ NO PIPE INTO `grep -q` (found by review, #2896 round 2 — the shape the repo's own SIGPIPE guard
    # exists for): under `set -o pipefail` a `grep -q` that exits at the match can make the WRITER die of
    # SIGPIPE, the pipeline then reports 141, this `if` reads FALSE, and a LIVE holder is classified as a
    # recycled pid — the one outcome this guard exists to prevent (two supervisors, one worktree).
    # Capture, then test the string.
    holder_cmd="$(ps -o command= -p "$holder" 2>/dev/null || true)"
    if grep -q 'worker-supply\.sh' <<<"$holder_cmd"; then
      log_line "ALREADY-RUNNING: holder pid=$holder holds $LOCK_DIR — nothing touched"
      return 1
    fi
    log_line "stale lock: pid $holder is alive but is NOT worker-supply.sh (recycled pid) — taking over"
  else
    now="$(date +%s)"; age="$(mtime_of "$LOCK_DIR")"
    case "${age:-}" in ''|*[!0-9]*) age=0 ;; esac
    if [ "$age" -gt 0 ] && [ $((now - age)) -lt "$LOCK_MAX_S" ] && [ -z "$holder" ]; then
      # No pid AND young: the holder may be between `mkdir` and its pid write. Wait for the interval.
      log_line "ALREADY-RUNNING: lock $LOCK_DIR is held with no pid and is only $((now - age))s old"
      return 1
    fi
    log_line "stale lock: holder '${holder:-<none>}' is gone — taking over"
  fi
  local grave="$LOCK_DIR.stale.$$"
  if ! mv "$LOCK_DIR" "$grave" 2>/dev/null; then
    log_line "ALREADY-RUNNING: another instance took over $LOCK_DIR first — nothing touched"
    return 1
  fi
  rm -rf "$grave" 2>/dev/null || true
  if mkdir "$LOCK_DIR" 2>/dev/null; then printf '%s\n' "$$" > "$LOCK_DIR/pid"; return 0; fi
  log_line "ALREADY-RUNNING: lost the race for $LOCK_DIR after the takeover"
  return 1
}

lock_release() {
  [ -f "$LOCK_DIR/pid" ] || return 0
  [ "$(cat "$LOCK_DIR/pid" 2>/dev/null | tr -d ' \n')" = "$$" ] || return 0
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  return 0
}

# ⛔ A SUPERVISOR THAT IGNORES SIGTERM IS PINNED, NOT SUPERVISED. The obvious
# `trap 'lock_release' EXIT INT TERM` RELEASES THE LOCK AND KEEPS GOING, so the worst case is not a
# slow stop: `systemctl stop` (or a launchd unload) releases the single-instance guard and leaves the
# `--loop` running WITHOUT it — the exact double-supervisor the guard exists to refuse, reached by
# stopping one. bash also defers a trapped signal until the foreground command returns, which is why
# the interval below is `wait`ed on rather than `sleep`t through: otherwise every stop is one whole
# interval late. Measured by `worker-supply.test.sh` case (b), which asserts the stop is bounded.
on_signal() { lock_release; exit "${1:-143}"; }

# ── reading ONE order ────────────────────────────────────────────────────────────────────────
# `field <started-file> <key>` — the stamp is `key=value`, one per line, written by the dispatcher.
field() {
  awk -F= -v k="$2" '$1==k { sub("^" k "=", ""); print; exit }' "$1" 2>/dev/null || true
}

# cap in seconds from the stamp's `cap=2400s`
cap_seconds() {
  local c; c="$(field "$1" cap)"; c="${c%s}"
  valid_num "$c" && [ "$c" -gt 0 ] 2>/dev/null && printf '%s\n' "$c" || printf '%s\n' ""
}

# ── liveness, asked of the HARNESS (never re-derived here) ───────────────────────────────────
# Sets STATUS_KIND (LIVE|COMPLETE|DEAD|UNKNOWN) and STATUS_WHY. No subshell, so the caller keeps the
# values. COMPLETE is its own state, NOT a DEAD one: see the polarity rule at the top of this file.
ask_status() { # <name> <started-file>
  local name="$1" stamp="$2" out rc
  STATUS_KIND=UNKNOWN; STATUS_WHY="no answer"
  [ -f "$DISPATCH" ] || { STATUS_WHY="no dispatcher at $DISPATCH"; return 0; }
  out="$(bounded "$PROBE_TIMEOUT" bash "$DISPATCH" --status "$name" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then STATUS_WHY="--status exited rc=$rc"; return 0; fi
  case "$out" in
    "$name running"*) STATUS_KIND=LIVE; STATUS_WHY="running" ;;
    "$name done"*)    STATUS_KIND=COMPLETE; STATUS_WHY="${out#"$name "}" ;;
    "$name failed"*|"$name lost"*) STATUS_KIND=DEAD; STATUS_WHY="${out#"$name "}" ;;
    *) STATUS_WHY="unparseable answer: ${out%%$'\n'*}" ;;
  esac
  # ⛔ A `running` NO WORKER CAN STILL BE TRUE OF IS REPORTED, NEVER ACTED ON (see the polarity rule).
  if [ "$STATUS_KIND" = LIVE ]; then
    local cap m age
    cap="$(cap_seconds "$stamp")"; m="$(mtime_of "$stamp")"
    case "${m:-}" in ''|*[!0-9]*) m="" ;; esac
    if [ -n "$cap" ] && [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      if [ "$age" -gt $(( cap + STALE_SLACK_S )) ]; then
        STATUS_KIND=UNKNOWN
        STATUS_WHY="stale-claim: pid answers running but the order is ${age}s old (cap=${cap}s + ${STALE_SLACK_S}s)"
      fi
    fi
  fi
  return 0
}

# ⛔ ONE WORKTREE, TWO NAMES (#2280, #2725). `pr-doctor.worker_name()` is REPO-QUALIFIED
# (`prd-<repo-tag>-42`, in every mode since #2725) while the WORKTREE is `prd-42`, so two orders can
# name one directory -- and this script is the ONLY liveness guard `nonblocking-dispatch.sh` has (it
# performs none itself). Asking only the order's OWN name is the exact defect `worker_live_for`
# (pr-doctor.py:3637) was written to remove: the pass reads the other order's LIVE worker as absent,
# re-offers, and a second agent is spawned into one git index, one branch and one log/.rc/.pid —
# destroying the live worker's evidence.
#
# So the question asked here is the DOCTOR's question — is ANY worker alive on this WORKTREE? —
# answered from the order population (every `$O/bg/<name>.started` recording that worktree) PLUS the
# UNQUALIFIED `prd-<n>` alias when it differs from ours. Since #2725 that alias is the PRE-RENAME
# worker's name (a worker started before the identity was repo-scoped), so it is a BACK-COMPAT arm:
# the doctor itself no longer writes it. ⚠️ Like this script, the doctor does NOT attribute that name
# to a checkout either (#2980 review cycle 6, P1: `$O/bg/<name>.started` is ONE box-global slot keyed
# by NAME, and the pre-rename collision OVERWRITES it, so `worktree=` names whichever repo dispatched
# last — it cannot prove which repos hold the name). So another repo's pre-rename worker can hold
# this order as `live`, on BOTH paths, and that agreement is deliberate: the safe direction is a
# deferred re-offer, and it clears itself as those artifacts age out. An UNANSWERABLE read wins over
# a later negative: the safe direction is not to spawn.
# Prints `live:<name>` | `unknown:<name>` | nothing. Runs in its own subshell at the call site, so
# `ask_status`'s globals (STATUS_KIND/STATUS_WHY) do not leak into the caller's walk.
worktree_holder() { # <own-name> <worktree>
  local own="$1" wt="$2" f gname gwt alias nn unk=""
  [ -n "$wt" ] || return 0
  for f in "$BG_DIR/$PREFIX"*.started; do
    [ -f "$f" ] || continue
    gname="$(field "$f" name)"; [ -n "$gname" ] || gname="$(basename "$f" .started)"
    [ "$gname" = "$own" ] && continue
    gwt="$(field "$f" worktree)"; [ -n "$gwt" ] || continue
    [ "${gwt%/}" = "${wt%/}" ] || continue
    ask_status "$gname" "$f"
    case "$STATUS_KIND" in
      LIVE)    printf 'live:%s\n' "$gname"; return 0 ;;
      UNKNOWN) unk="$gname" ;;
    esac
  done
  # The alias arm: `prd-<n>` may be live with no `.started` of its own (the earlier single-repo
  # order's record was superseded). Its stamp is passed as the path it would have, so a MISSING
  # stamp cannot manufacture a stale-claim downgrade — an absent stamp leaves `running` as LIVE.
  case "$own" in
    *-*) nn="${own##*-}" ;;
    *)   nn="" ;;
  esac
  if [ -n "$nn" ] && [ "$nn" != "$own" ]; then
    alias="prd-$nn"
    if [ "$alias" != "$own" ]; then
      ask_status "$alias" "$BG_DIR/$alias.started"
      case "$STATUS_KIND" in
        LIVE)    printf 'live:%s\n' "$alias"; return 0 ;;
        UNKNOWN) unk="$alias" ;;
      esac
    fi
  fi
  [ -n "$unk" ] && printf 'unknown:%s\n' "$unk"
  return 0
}

refills_of() { # <name>
  [ -f "$LEDGER" ] || { printf '0\n'; return 0; }
  awk -F'\t' -v n="$1" '$2==n { c++ } END { printf "%d\n", c+0 }' "$LEDGER" 2>/dev/null || printf '0\n'
}

offer_recorded() { # <name> <sig>
  [ -f "$LEDGER" ] || return 1
  awk -F'\t' -v n="$1" -v s="$2" '$2==n && $3==s { found=1 } END { exit(found?0:1) }' "$LEDGER" 2>/dev/null
}

offer_append() { # <name> <sig> <verdict>
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" >> "$LEDGER" 2>/dev/null || return 1
  return 0
}

write_record() { # <decision> <orders> <live> <dead> <unknown> <cap> <fix> <review> <refilled> <why> [<complete>]
  local tmp="$RECORD.tmp"
  {
    printf 'ts=%s\n' "$(date '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'decision=%s\n' "$1"
    printf 'orders=%s\nlive=%s\ndead=%s\nunknown=%s\ncomplete=%s\n' "$2" "$3" "$4" "$5" "${11:-0}"
    printf 'capacity=%s\nmax_fix=%s\nmax_review=%s\n' "$6" "$7" "$8"
    printf 'refilled=%s\nmax_refills=%s\ninterval_s=%s\nprefix=%s\n' "$9" "$MAX_REFILLS" "$INTERVAL_S" "$PREFIX"
    printf 'reason=%s\n' "${10}"
  } > "$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$RECORD" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  return 0
}

# ── ONE PASS ──────────────────────────────────────────────────────────────────────────────────
DRY=0
pass() {
  local plenv orders=0 live=0 dead=0 unknown=0 cap fix review refilled=0 why="" decision=clean prev=""
  local complete=0
  local n_offered=0 n_dead_total=0 refused=0 budget_full=0 exhausted=0 no_record=0
  local f name wt prompt kind stamp wt_branch rec_branch capr sig hold

  mkdir -p "$STATE_DIR" 2>/dev/null || { log_line "REFUSING: state dir $STATE_DIR is not writable"; return 2; }
  plenv="$STATE_DIR/.worker-supply.plistenv"
  plist_env_dump "$ORCH_PLIST" "$plenv"
  fix="$(limit_of MAX_FIX "$DEFAULT_MAX_FIX" "$plenv")"
  review="$(limit_of MAX_REVIEW "$DEFAULT_MAX_REVIEW" "$plenv")"
  cap=$(( fix + review ))

  if [ ! -f "$DISPATCH" ]; then
    log_line "REFUSING: no dispatcher at $DISPATCH — the pool cannot be supplied (this is an INSTALL fault, not a worker fault)"
    write_record refusing 0 0 0 0 "$cap" "$fix" "$review" 0 "no dispatcher at $DISPATCH"
    return 2
  fi

  # One ordered walk: count the pool, then act on the dead ones. The glob is the ORDER POPULATION —
  # an order that has no `.started` record was never accepted and is nobody's to refill.
  for f in "$BG_DIR/$PREFIX"*.started; do
    [ -f "$f" ] || continue
    orders=$(( orders + 1 ))
    name="$(field "$f" name)"; [ -n "$name" ] || name="$(basename "$f" .started)"
    ask_status "$name" "$f"
    case "$STATUS_KIND" in
      LIVE)     live=$(( live + 1 )) ;;
      COMPLETE) complete=$(( complete + 1 )) ;;
      DEAD)     dead=$(( dead + 1 )); n_dead_total=$(( n_dead_total + 1 )) ;;
      *)        unknown=$(( unknown + 1 )) ;;
    esac
  done

  # Second walk: re-offer, bounded by the machine's budget and by the per-order refill cap.
  for f in "$BG_DIR/$PREFIX"*.started; do
    [ -f "$f" ] || continue
    name="$(field "$f" name)"; [ -n "$name" ] || name="$(basename "$f" .started)"
    ask_status "$name" "$f"
    [ "$STATUS_KIND" = DEAD ] || continue
    if [ "$live" -ge "$cap" ]; then budget_full=$(( budget_full + 1 )); continue; fi
    if [ "$(refills_of "$name")" -ge "$MAX_REFILLS" ]; then
      exhausted=$(( exhausted + 1 ))
      log_line "$name: DEFERRED — this order has spent its $MAX_REFILLS refill(s); a worker that keeps dying is a diagnosis, not a supply problem"
      continue
    fi
    wt="$(field "$f" worktree)"; prompt="$(field "$f" prompt)"
    kind="$(field "$f" kind)"; kind="${kind:-prfix}"
    stamp="$(field "$f" started)"; sig="${stamp:-unknown}"
    capr="$(cap_seconds "$f")"; capr="${capr:-2400}"
    # ⛔ THE ORDER MUST STILL BE THE ORDER. The worktree is deterministic (`prd-<n>`) and is reused by
    # later heads; a re-offer into a tree that now belongs to another branch would hand a worker the
    # wrong PR. Refuse (and SAY so) rather than spawn into a tree the record does not describe.
    if [ -z "$wt" ] || [ ! -d "$wt" ]; then
      no_record=$(( no_record + 1 )); log_line "$name: not re-offered — the worktree recorded for the order is gone (${wt:-<unrecorded>})"; continue
    fi
    if [ -z "$prompt" ] || [ ! -f "$prompt" ]; then
      no_record=$(( no_record + 1 )); log_line "$name: not re-offered — the brief recorded for the order is gone (${prompt:-<unrecorded>})"; continue
    fi
    rec_branch="$(field "$f" branch)"
    wt_branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ -n "$rec_branch" ] && [ -n "$wt_branch" ] && [ "$wt_branch" != "$rec_branch" ]; then
      no_record=$(( no_record + 1 ))
      log_line "$name: not re-offered — worktree $wt is on '$wt_branch' but the order was for '$rec_branch' (the tree was reused; the PR must be re-classified, not replayed)"
      continue
    fi
    # ⛔ ANOTHER ORDER MAY HOLD THIS WORKTREE UNDER A DIFFERENT NAME (see worktree_holder). Refuse,
    # and move the pool census with it: a worktree with a live worker on it IS a held slot, and an
    # unanswerable read is UNKNOWN — never a licence to spawn blind.
    hold="$(worktree_holder "$name" "$wt")"
    if [ -n "$hold" ]; then
      case "${hold%%:*}" in
        live)    dead=$(( dead - 1 ))
                 live=$(( live + 1 ))
                 log_line "$name: not re-offered — another order holds its worktree $wt and is RUNNING (${hold#*:}); a second worker there would destroy the live one's log/.rc/.pid" ;;
        # ⛔ A HOLDER WE COULD NOT READ IS *NOT* A HELD SLOT (review #2896 round 3). The old arm
        # decremented `dead` here too, so the one order the pass could not decide about VANISHED from
        # the census — `live=0 dead=0 unknown=2` then reached the verdict's `else`, printed `clean` and
        # returned rc=0 over a pool with a dead order in it. The order stays dead (nothing was
        # established about it) and the unknown is counted beside it; the pass is then DEFERRED, which
        # is what "there is still a dead order" means.
        *)       unknown=$(( unknown + 1 ))
                 log_line "$name: not re-offered — another order holds its worktree $wt and its liveness could not be read (${hold#*:}); spawning blind would risk a live worker" ;;
      esac
      continue
    fi
    if offer_recorded "$name" "$sig"; then
      log_line "$name: not re-offered — this exact spawn instance (started=$sig) was already re-offered once"
      continue
    fi
    if [ "$DRY" = 1 ]; then
      log_line "DRY-RUN would re-offer $name in $wt (kind=$kind cap=${capr}s) — the order's worker is dead"
      n_offered=$(( n_offered + 1 )); refilled=$(( refilled + 1 ))
      continue
    fi
    local out rc
    out="$(bounded "$SPAWN_CALL_TIMEOUT" bash "$DISPATCH" "$name" "$wt" "$prompt" "$capr" "$kind" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
      refused=$(( refused + 1 ))
      log_line "$name: REFUSED by the dispatcher (rc=$rc): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
      continue
    fi
    # ACCEPTED IS A RECORD, NOT A RETURN CODE (pr-doctor's own rule): ask the harness again.
    ask_status "$name" "$f"
    if [ "$STATUS_KIND" = LIVE ]; then
      offer_append "$name" "$sig" accepted
      refilled=$(( refilled + 1 )); n_offered=$(( n_offered + 1 )); live=$(( live + 1 )); dead=$(( dead - 1 ))
      log_line "$name: RE-OFFERED in $wt (kind=$kind cap=${capr}s) — the order's dead worker was replaced ($live/$cap live)"
    elif [ -f "$BG_DIR/$name.rc" ]; then
      # ⛔ ACCEPTED, AND ALREADY OVER. The dispatcher took the order and the worker has ENDED (a
      # fast failure: bad credentials, a missing interpreter). The ledger row is still written --
      # the same spawn instance must never be re-offered twice (`offer_recorded`) -- but this is
      # NOT a live slot and the order is NOT un-dead: counting it live is the "bookkeeping is not
      # the worker" class one layer down (pr-doctor #2700 C5), and it holds the budget against
      # workers that do not exist, so the pass under-supplies and reports a `live=` that is false.
      offer_append "$name" "$sig" accepted
      refilled=$(( refilled + 1 )); n_offered=$(( n_offered + 1 ))
      log_line "$name: RE-OFFERED but the worker ENDED at once ($STATUS_WHY) — no slot is held, the order is still dead"
    else
      refused=$(( refused + 1 ))
      log_line "$name: re-offer UNCONFIRMED ($STATUS_WHY) — no ledger row; liveness is re-read next pass"
    fi
  done

  # The verdict, and it must not be a green tick over an empty pool (the doctor's own law).
  # ⛔ `refilled > 0` USED TO BE ENOUGH TO RETURN A CLEAN PASS, AND IT IS NOT. A pass that re-offered
  # two orders and then hit the machine's budget with two more still dead printed rc=0 and a `why` that
  # named only the two it refilled — the remainder was visible NOWHERE. That is the doctor's own
  # `dispatched 0 of M` defect one layer down: a bounded pass reported as a complete one. So ANY order
  # still dead after both walks is DEFERRED (rc=6) and the reason names the bound that held it; only a
  # pass with nothing left dead may call itself refilled.
  if [ "$orders" -eq 0 ]; then
    decision=idle; why="no $PREFIX orders in $BG_DIR — nothing to supply (a pass that never placed an order leaves no record to refill)"
  elif [ "$refused" -gt 0 ]; then
    decision=refused; why="$refused re-offer(s) refused by the dispatcher ($refilled accepted first)"
  elif [ "$dead" -gt 0 ]; then
    decision=deferred
    local held=""
    [ "$budget_full" -gt 0 ] && held="$held, budget full ($live/$cap live) held $budget_full"
    [ "$exhausted" -gt 0 ] && held="$held, $exhausted spent their $MAX_REFILLS refill(s)"
    [ "$no_record" -gt 0 ] && held="$held, $no_record had no replayable record"
    why="$refilled of $n_dead_total re-offered; $dead still dead${held}"
  elif [ "$refilled" -gt 0 ]; then
    decision=refilled; why="$refilled of $n_dead_total dead order(s) re-offered"
  elif [ "$live" -eq 0 ] && [ "$unknown" -gt 0 ]; then
    # ⛔ A PASS THAT SUPPLIED NOTHING BECAUSE IT COULD NOT READ THE POOL IS NOT A CLEAN PASS (review
    # #2896 round 3). Every UNKNOWN path used to fall through to the `clean` arm below, so a pass whose
    # every `--status` was unreadable printed `pass: clean — live=0/7 unknown=2` and exited 0 — the
    # doctor's own `capacity … inflight=0` health theatre, and a direct contradiction of this file's
    # exit code 2 ("a read a pass needs could not be taken"). `dead > 0` already wins above (a dead
    # order is a fact even when another read failed); this arm is the remaining case: nothing supplied,
    # nothing established dead, and at least one read we could not take.
    decision=unreadable; why="no order could be supplied and $unknown read(s) could not be taken ($live/$cap live, $complete complete)"
  else
    decision=clean; why="no dead order to refill ($live/$cap live, $complete complete, $unknown unknown)"
  fi
  # ⛔ A DRY RUN WRITES NO RECORD AND EXITS 0 (found by review). `$RECORD` is the LAST REAL PASS's
  # evidence — the durable answer to "what did the supervisor actually do?" — and a rehearsal that
  # overwrote it (its `refilled=` counting would-is, its `ts=` claiming a pass that never happened)
  # destroys exactly that. The dry run's verdict goes to stdout and nowhere else.
  if [ "$DRY" = 1 ]; then
    log_line "DRY-RUN pass: decision=$decision orders=$orders live=$live/$cap dead=$dead complete=$complete unknown=$unknown would-refill=$refilled — $why (no record, no ledger row, nothing spawned)"
    return 0
  fi
  prev="$(awk -F= '$1=="decision"{ print $2; exit }' "$RECORD" 2>/dev/null || true)"
  write_record "$decision" "$orders" "$live" "$dead" "$unknown" "$cap" "$fix" "$review" "$refilled" "$why" "$complete"
  # ⛔ THE LOG IS AN EVENT STREAM, NOT A CLOCK. An unchanged `idle`/`clean` pass writes NOTHING: a
  # 60 s service logging `nothing to do` 1,440 times a day is noise that hides the pass that mattered,
  # and the last-pass record (`$RECORD`, with its own `ts=`) is the heartbeat a reader checks instead.
  # A refill and every refusal always log.
  if [ "$decision" != "$prev" ] || [ "$refilled" -gt 0 ] || [ "$refused" -gt 0 ]; then
    log_line "pass: $decision — orders=$orders live=$live/$cap dead=$dead complete=$complete unknown=$unknown refilled=$refilled — $why"
  fi

  case "$decision" in
    refused) return 3 ;;
    # ⛔ REFUSING IS NOT RESERVED FOR AN INSTALL FAULT: a pass that could not READ the pool supplied
    # nothing and knows it (see the verdict block). rc=2 already means exactly that in this file's
    # vocabulary, so the /loop retries on the next interval and `systemctl status` is not silent.
    unreadable) return 2 ;;
    # ⛔ DEFERRED IS NOT A CLEAN EXIT EVEN WHEN SOMETHING WAS REFILLED (see the verdict block): dead
    # orders remain, so the pass reports 6 and its record names the bound. `[ "$refilled" = 0 ] && 6 ||
    # 0` turned a bounded pass into rc=0 — the same defect class the verdict block was fixed for, one
    # line further down, where the test could only see it through the exit code.
    deferred) return 6 ;;
    *) return 0 ;;
  esac
}

# ── status ───────────────────────────────────────────────────────────────────────────────────
show_status() {
  local orders=0 live=0 dead=0 unknown=0 complete=0 f name
  if [ -f "$RECORD" ]; then
    echo "record: $RECORD"
    awk '{ printf "  %s\n", $0 }' "$RECORD"
  else
    echo "record: $RECORD (absent — no pass has run here)"
  fi
  # A FRESH count, not the record's: "recorded live=N" and "N are alive now" are different facts.
  for f in "$BG_DIR/$PREFIX"*.started; do
    [ -f "$f" ] || continue
    orders=$(( orders + 1 ))
    name="$(field "$f" name)"; [ -n "$name" ] || name="$(basename "$f" .started)"
    ask_status "$name" "$f"
    case "$STATUS_KIND" in LIVE) live=$(( live + 1 ));; COMPLETE) complete=$(( complete + 1 ));; DEAD) dead=$(( dead + 1 ));; *) unknown=$(( unknown + 1 ));; esac
  done
  local cap fix review plenv="$STATE_DIR/.worker-supply.plistenv"
  plist_env_dump "$ORCH_PLIST" "$plenv"
  fix="$(limit_of MAX_FIX "$DEFAULT_MAX_FIX" "$plenv")"
  review="$(limit_of MAX_REVIEW "$DEFAULT_MAX_REVIEW" "$plenv")"
  cap=$(( fix + review ))
  echo "now:   orders=$orders live=$live/$cap dead=$dead complete=$complete unknown=$unknown (fix=$fix review=$review)"
  # …and the knobs the process ACTUALLY resolved (post-validation): the unit renders what was asked for,
  # this line is what is enforced — the two are different facts when an override was rejected.
  echo "knobs: interval_s=$INTERVAL_S max_refills=$MAX_REFILLS prefix=$PREFIX"
  echo "paths: dispatcher=$DISPATCH bg=$BG_DIR ledger=$LEDGER log=$LOG"
  if [ -d "$LOCK_DIR" ]; then
    echo "lock:  HELD by pid $(cat "$LOCK_DIR/pid" 2>/dev/null || echo '<unknown>') ($LOCK_DIR)"
  else
    echo "lock:  free"
  fi
  return 0
}

# ── main ─────────────────────────────────────────────────────────────────────────────────────
MODE=pass
while [ $# -gt 0 ]; do
  case "$1" in
    ''|--once|refill|heal) MODE=pass ;;
    --loop) MODE=loop ;;
    --dry-run) MODE=pass; DRY=1 ;;
    status|--status) MODE=status ;;
    -h|--help)
      awk 'NR>1 && /^set -uo pipefail/ { exit } NR>1 { sub(/^# ?/, ""); print }' "$0"
      exit 0 ;;
    *) echo "usage: worker-supply.sh [refill|heal|--once|--loop|--dry-run|status]" >&2; exit 2 ;;
  esac
  shift
done

case "$MODE" in
  status) show_status; exit 0 ;;
  pass)
    lock_take || { rc=$?; [ "$rc" = 2 ] && exit 2; exit 4; }
    trap 'lock_release' EXIT
    trap 'on_signal 143' INT TERM
    pass; rc=$?
    lock_release
    trap - EXIT INT TERM
    exit "$rc"
    ;;
  loop)
    # ⛔ THE LOOP TAKES THE LOCK ONCE, FOR ITS LIFETIME. Taking it per pass would let a second loop
    # drain the queue in the gaps — the double-supervisor the guard exists to refuse — and a loop that
    # exits on a single rc=3 is a supply path that stops about the first refusal it meets.
    lock_take || { rc=$?; [ "$rc" = 2 ] && exit 2; exit 4; }
    trap 'lock_release' EXIT
    trap 'on_signal 143' INT TERM
    while :; do
      pass; rc=$?
      [ "$rc" = 2 ] && log_line "loop: REFUSING (install fault) — retrying in ${INTERVAL_S}s"
      # An INTERRUPTIBLE interval: `wait` returns the moment a trapped signal arrives, so a stop is
      # immediate and the EXIT/INT/TERM traps above run. A bare `sleep "$INTERVAL_S"` defers the
      # signal for the whole interval (measured by the test's own bounded-stop assertion).
      sleep "$INTERVAL_S" &
      wait "$!" 2>/dev/null || true
    done
    ;;
esac
