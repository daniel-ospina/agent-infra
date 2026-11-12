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
# ⛔ AND THE BRIEF IT REPLAYS IS REVALIDATED FIRST (agent-infra#3958). Replaying a recorded argv replays
# the recorded brief PATH, so an order whose cached brief the gate refuses would be refused `rc=80` on
# every pass for ever. The invariant — a refused brief never reaches the dispatcher again — is stated
# and implemented above `brief_verdict()`; it does NOT relax the gate, and this file never composes a
# brief.
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
# ── AN ORDER THE PASS CAN NEVER ACT ON AGAIN IS RETIRED, NOT DEFERRED FOR EVER (#4007) ────────
# ⛔ THE DEFECT, MEASURED (2026-12-04). The order population only ever GROWS: `pr-doctor` writes a
# `$O/bg/<name>.started` per spawn and nothing removes one, so a box held orders for PRs that had long
# since MERGED -- 105 distinct order PR numbers, **105 not open**, and **0 orders for the 18 live PRs**.
# Every pass then walked those fossils: the brief gate refused 72 of them (`rc=80`) on every pass, the
# rest had spent their `MAX_REFILLS`, and the pass ended `deferred` (rc=6) for ever -- so the pool
# could not say anything, a `live=` count could not become non-zero, and the log read as "quiet".
# An order the pass can NEVER act on again is not a dead order waiting for supply; it is a record about
# work that ended. It is RETIRED: written to `worker-supply-retired.tsv` (name, reason, and the mtime of
# the record instance that was retired), excluded from both walks, and counted as `retired=` -- never
# deleted, and never re-offered.
# ⛔ RETIREMENT IS TTL-BOUNDED, SO IT CANNOT LOSE LIVE WORK. Only an order whose record is older than
# `WORKER_SUPPLY_ORDER_TTL_S` (7 days) is eligible, and only in a state this path has already decided it
# cannot supply: its refills are SPENT, the WORKTREE it names is gone, the BRIEF it names is gone, or its
# brief the gate REFUSES. A fresh order -- including one whose worker simply died -- is never retired, so
# the refill path is untouched. (The worktree/brief arms are the DOMINANT measured case: 80 orders, 0
# worktrees present -- the deterministic `prd-<n>` repair trees had been reaped, which every pass logged
# as "the worktree recorded for the order is gone" and could never act on.)
# ⛔ AND IT IS REVERSIBLE WITHOUT A HUMAN. `retired_row()` matches the SAME `started` record instance
# (mtime), and `pr-doctor.py` rewrites that file UNCONDITIONALLY on every spawn -- so if the PR is still
# open, the composer's next order writes a NEW record, the row stops matching, and the order is supplied
# again by itself. Retirement records a fact about an instance; it never shadows a live order.
# ⛔ IT IS NOT A PR-STATE READER. This file still never calls `gh`: "the PR is closed" is not observable
# here, and inferring it from the network on a 60 s clock would be a new failure mode (and a second
# opinion about a queue the doctor owns). The pass instead retires what IT cannot act on and says so;
# the PR-state half belongs to the composer that classified the PR.
#
# ── A SUPERVISOR THAT WROTE NOTHING IS NOT A QUIET ONE: `status` REPORTS STALE (#4007) ────────
# The measured shape was a supervisor alive 16 days whose log had stopped 2 days ago -- and nothing
# anywhere said so, because the process was up and `ActiveState` was `active`. `status` therefore
# grades the AGE of the last completed pass record against `WORKER_SUPPLY_STALE_AFTER_S` and prints
# `beat:  ok` / `beat:  STALE`, exiting **5** on STALE so a monitor reads a verdict and not a silence.
# The bound defaults to `5 x INTERVAL_S`, floored at 300 s (five missed passes at the shipped 60 s
# cadence is not a slow pass, it is a dead one); it is a knob because a cell's pass over a large pool
# is slower than the Mac's.
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
#   worker-supply.sh status       the last pass record + a FRESH live count + the HEARTBEAT verdict.
#                                 Exit 0 when the last completed pass is inside the staleness bound, 5
#                                 when it is STALE (or no pass has ever written a record here) — a
#                                 monitor gets a verdict instead of reading a stopped log as "quiet"
#   worker-supply.sh --help
#
# Exit codes (the fleet vocabulary, kept identical on purpose):
#   0  a pass completed — it refilled, or there was genuinely nothing to refill
#   2  REFUSING — a read a pass needs could not be taken (no dispatcher, an unwritable state dir), or
#      the pool itself could not be read: nothing was supplied and `unknown > 0` with nothing dead
#   3  UNDELIVERED — a refill was ATTEMPTED and no worker took it (the dispatcher refused)
#   4  ALREADY-RUNNING — the single-instance guard holds; nothing was touched
#   5  STALE — `status` only: the last completed pass is older than the staleness bound (or no pass has
#      ever run here), which is what a DEAD or WEDGED supervisor looks like from outside
#   6  DEFERRED — dead orders are still dead after the pass: the budget is full, the order has spent
#      its refills, or its record is un-replayable. A pass that re-offered SOME and then hit a bound is
#      DEFERRED too (a verdict about what is left, not a pass) — `refilled>0` alone is not a clean
#      pass, which is the doctor's `dispatched 0 of M` law. The record names which bound held it.
#      "UN-REPLAYABLE" INCLUDES A REFUSED BRIEF (agent-infra#3958): an order whose cached brief the gate
#      refuses is not re-offered at all — it is reported as needing REGENERATION by its composer, and
#      the record's `stale_briefs=` counts it. It is NOT `3` (nothing was attempted) and it is NOT `0`
#      (the order is still dead).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# ── knobs (env only; the unit/plist renders them so an operator can read them where they run) ──
O="${O:-$HOME/orchestrator}"
STATE_DIR="${WORKER_SUPPLY_STATE_DIR:-$O/state}"
BG_DIR="${WORKER_SUPPLY_BG_DIR:-$O/bg}"
DISPATCH="${WORKER_SUPPLY_DISPATCH:-$O/nonblocking-dispatch.sh}"
# The brief validator. EMPTY means "resolve the copy the dispatcher will judge with" (`brief_gate_path`,
# the same ladder `spawn-gate.sh::brief_gate_lib` walks); the knob exists so a test can grade the
# revalidation without a second copy of the gate. An override that is not a FILE is skipped, not obeyed.
BRIEF_GATE="${WORKER_SUPPLY_BRIEF_GATE:-}"
BRIEF_GATE_TIMEOUT="${WORKER_SUPPLY_BRIEF_GATE_TIMEOUT_S:-30}"  # bounds ONE gate call, not the pass
PREFIX="${WORKER_SUPPLY_PREFIX:-prd-}"                 # the worker NAMESPACE it supplies
INTERVAL_S="${WORKER_SUPPLY_INTERVAL_S:-60}"           # --loop cadence
MAX_REFILLS="${WORKER_SUPPLY_MAX_REFILLS:-2}"          # re-offers per ORDER (a crash loop bound)
SPAWN_CALL_TIMEOUT="${WORKER_SUPPLY_SPAWN_TIMEOUT_S:-120}"   # bounds the DISPATCHER, not the worker
PROBE_TIMEOUT="${WORKER_SUPPLY_PROBE_TIMEOUT_S:-60}"   # bounds one `--status` probe
STALE_SLACK_S="${WORKER_SUPPLY_STALE_SLACK_S:-300}"    # a `running` past cap+slack is only REPORTED
RETIRE_TTL_S="${WORKER_SUPPLY_ORDER_TTL_S:-604800}"   # 7 d: an un-actionable order older than this is RETIRED
STALE_AFTER_S="${WORKER_SUPPLY_STALE_AFTER_S:-0}"      # 0 = derive (5 x INTERVAL_S, floored at 300)
LOCK_MAX_S="${WORKER_SUPPLY_LOCK_MAX_S:-900}"          # an unverifiable lock is taken over after this
LOG_MAX_BYTES="${WORKER_SUPPLY_LOG_MAX_BYTES:-262144}"
ORCH_PLIST="${WORKER_SUPPLY_ORCH_PLIST:-$HOME/Library/LaunchAgents/com.eldato.orchestrator-loop.plist}"
DEFAULT_MAX_FIX=3
# ⛔ 10, NOT 4 (#3441) — `MAX_REVIEW` is the reviewer-concurrency cap AND the per-PR review-ROUND
# ceiling, and this is the third reader of the one number (with `orch-loop.sh` and `pr-doctor.py`).
# Divergence here is not cosmetic: `limit_of` reads the plist first, so this fallback only binds on a
# box with no plist (a cell, a manual run) — exactly where a value of 4 would throttle the drain
# against a documented 10.
DEFAULT_MAX_REVIEW=10

LOCK_DIR="$STATE_DIR/worker-supply.lock"
LEDGER="$STATE_DIR/worker-supply-offers.tsv"
RETIRED="$STATE_DIR/worker-supply-retired.tsv"
RECORD="$STATE_DIR/worker-supply.state"
# ⛔ A PASS THAT IS STILL WORKING MUST NOT READ AS DEAD (review P2, round 2 on #4017). `$RECORD` only
# advances at pass END, so a legitimately long pass (up to `cap x SPAWN_CALL_TIMEOUT` on the re-offer
# walk, plus one PROBE_TIMEOUT per order on the census walk) left the previous pass's mtime on disk for
# its whole duration and `status` called it STALE. The START of a real pass is therefore its own marker:
# `status` reads the newest of the two, and a start marker that is ITSELF older than the bound is a
# WEDGED pass, not a working one. Written by real passes only — `--dry-run` still writes NOTHING.
PASS_BEAT="$STATE_DIR/worker-supply.pass-start"
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
knob_num WORKER_SUPPLY_BRIEF_GATE_TIMEOUT_S "$BRIEF_GATE_TIMEOUT" 30    pos || BRIEF_GATE_TIMEOUT=30
knob_num WORKER_SUPPLY_ORDER_TTL_S        "$RETIRE_TTL_S"      604800  any || RETIRE_TTL_S=604800
knob_num WORKER_SUPPLY_STALE_AFTER_S      "$STALE_AFTER_S"     0       any || STALE_AFTER_S=0
# 0 means DERIVE, so the derived value can never be the thing an operator set to 0 by accident: five
# missed passes at the shipped 60 s cadence is a dead supervisor, not a slow pass -- and a floor of 300 s
# keeps a 1 s interval from turning every normal pass into a STALE verdict.
if [ "$STALE_AFTER_S" -eq 0 ]; then
  STALE_AFTER_S=$(( 5 * INTERVAL_S ))
  [ "$STALE_AFTER_S" -lt 300 ] && STALE_AFTER_S=300
fi
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

# ── RETIREMENT: A RECORD ABOUT ONE ORDER INSTANCE, NEVER A DELETE (agent-infra#4007) ────────────
# The declared invariant is above the CAPACITY section; these are its three verbs. The ledger row is
# `<epoch>\t<name>\t<reason>\t<record-mtime>` -- the FOURTH field is load-bearing: it names WHICH
# instance of the order was retired, so a composer that re-orders the PR (rewriting the record, which
# moves its mtime) un-retires the order with no human and no second bookkeeping surface.
retired_row() { # <name> -> prints "<epoch>\t<reason>\t<record-mtime>" for the LAST row naming <name>, rc=1 if none
  [ -f "$RETIRED" ] || return 1
  awk -F'\t' -v n="$1" '$2==n { e=$1; r=$3; m=$4 } END { if (e=="") exit 1; printf "%s\t%s\t%s\n", e, r, m }' \
    "$RETIRED" 2>/dev/null
}

# RETIRE_WHY is set when the order IS retired (the reason of its last row); RET_ROW the raw row.
order_retired() { # <name> <started-file> -> 0 retired, 1 not retired
  local name="$1" f="$2" row rm m
  RETIRE_WHY=""; RET_ROW=""
  row="$(retired_row "$name")" || return 1
  [ -n "$row" ] || return 1
  RET_ROW="$row"
  rm="${row##*$'\t'}"
  m="$(mtime_of "$f")"
  case "${rm:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "${m:-}" ] && [ "$m" = "$rm" ] || return 1
  RETIRE_WHY="$(printf '%s' "$row" | awk -F'\t' '{ print $2 }')"
  return 0
}

retire_order() { # <name> <started-file> <reason> -> 0 written, 1 unwritable
  local m
  m="$(mtime_of "$2")"
  case "${m:-}" in ''|*[!0-9]*) return 1 ;; esac   # an unrecordable instance is not retired: it would re-appear
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$3" "$m" >> "$RETIRED" 2>/dev/null || return 1
  return 0
}

# ── THE BRIEF IS REVALIDATED BEFORE IT IS OFFERED AGAIN (agent-infra#3958) ──────────────────
# ⛔ THE DEFECT, MEASURED. A re-offer replays the argv `nonblocking-dispatch.sh` recorded at ACCEPT
# time, and one of those arguments is the brief PATH. So the SAME brief file is handed to the SAME
# gate on every pass: the gate refuses it `rc=80`, the pass reports `72 re-offer(s) refused by the
# dispatcher`, and it does that for ever — measured on this box 2026-11-11, pass after pass
# (`orders=100 live=0/18 dead=83 … 72 re-offer(s) refused`, 537 such lines accumulated).
# The GENERATOR is healthy: `pr-doctor.py:4338-4340` rewrites the brief UNCONDITIONALLY on every
# spawn, so the fossils survive only because this path never reaches that code — 100 of the 100
# orders recorded in `$O/bg` point at a brief the current gate refuses, while the briefs pr-doctor
# has composed recently are admitted (`research contract rendered … admitted by 1 validator(s)`).
#
# THE INVARIANT: a brief the gate has REFUSED is never handed to the dispatcher again. A cache whose
# validity is never checked is not a cache, it is a fossil — the "stale flag that records a past
# state and is never revalidated" class, here on a dispatch path.
#
# ⛔ IT IS NOT FIXED BY RELAXING THE GATE. The `RESEARCH FIRST`/`PREVIOUS WORK` contract exists because
# two lanes in one day acted on a false premise (#2258, #3484); a bypass here would restore exactly
# that failure, so the refusal STANDS and this path stops offering the fossil instead.
# ⛔ AND IT IS NOT FIXED BY COMPOSING A BRIEF HERE. A brief is an ORDER ("re-run the checks on this
# head", "resolve this conflict") that `pr-doctor` derives from a classification of the PR AS IT
# STANDS NOW; splicing a fresh contract block onto an 18-day-old order would hand a worker a
# current-LOOKING brief for work the PR may no longer need. That is inventing work, which this file
# refuses to do (`contract_note()`'s argument one layer over) — so the brief is skipped and REPORTED
# as needing regeneration, and the one composer (`pr-doctor`) is named as the only thing that writes it.
# ⛔ NO LEDGER ROW IS WRITTEN FOR A SKIP, deliberately: `refills_of()` counts rows per order, so a row
# would spend one of the order's `MAX_REFILLS` — and a regeneration is not a failed worker. (Pinned by
# the test: an order stays re-offerable after any number of skipped passes.)

brief_gate_path() { # -> the copy the DISPATCHER will judge with, or rc=1 (nothing resolved)
  local c
  [ -n "$BRIEF_GATE" ] && [ -f "$BRIEF_GATE" ] && { printf '%s\n' "$BRIEF_GATE"; return 0; }
  # The ladder is `spawn-gate.sh::brief_gate_lib`'s, in ITS order (`$O` first), because the verdict this
  # path acts on has to come from the copy that will actually judge the re-offer. A copy that merely
  # EXISTS somewhere else is not that copy — the 6h32m stall #2708 measured.
  for c in "${O:-}/brief-gate.sh" "$HERE/brief-gate.sh" \
           "${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/brief-gate.sh" \
           "${HOME:-}/.pi/agent/scripts/brief-gate.sh"; do
    [ -n "$c" ] && [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# The gate's OWN WORDS, reduced to its `missing:` list: the teaching block is ~3.5 KB and this runs on
# a 60 s clock, once per refused order. Nothing is paraphrased — the bullets are the gate's own text.
brief_gate_missing() { # <gate output>
  printf '%s\n' "$1" | awk '
    /^\[brief-gate\][[:space:]]*missing:/ { f=1; next }
    f && /^\[brief-gate\]/ { exit }
    f && NF { sub(/^[[:space:]]+/, ""); s = (s == "" ? $0 : s "; " $0) }
    END { print s }'
}

# 0 = ADMITTED · 80 = REFUSED (never re-offer unchanged) · anything else = NO VERDICT.
# ⛔ A NO VERDICT FALLS THROUGH TO THE DISPATCHER, UNCHANGED. `brief-gate.sh` exits 78 when the
# VALIDATOR is missing and this file's own bound answers 142; neither says anything about the BRIEF.
# The dispatcher owns that refusal (it exits 78 itself, loudly), and converting an install fault into
# "this order needs a new brief" would name the wrong fault — the `$O`-skew lesson (#2708, #2986).
brief_verdict() { # <brief>
  local g out rc
  BRIEF_GATE_WHY=""; BRIEF_GATE_USED=""
  if ! g="$(brief_gate_path)"; then
    BRIEF_GATE_WHY="no brief-gate.sh on any resolved root (\$O, this directory, \$AGENT_INFRA_PATH, ~/.pi/agent/scripts)"
    return 78
  fi
  BRIEF_GATE_USED="$g"
  out="$(bounded "$BRIEF_GATE_TIMEOUT" bash "$g" --check "$1" worker 2>&1)"; rc=$?
  case "$rc" in
    0)  return 0 ;;
    80) BRIEF_GATE_WHY="$(brief_gate_missing "$out")"
        [ -n "$BRIEF_GATE_WHY" ] || BRIEF_GATE_WHY="refused, and the gate printed no missing list"
        return 80 ;;
    *)  BRIEF_GATE_WHY="rc=$rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
        return "$rc" ;;
  esac
}

# ⛔ THE LOG IS AN EVENT STREAM, NOT A CLOCK — this file's own rule, one layer out. Emitting the same
# regeneration line for every refused order on every 60 s pass is ~100k lines a day against a 256 KB
# rotation, so the log would be rewritten about every 18 minutes and the pass that mattered would be
# gone. The COUNT is the durable signal (it is in `$RECORD` and in the pass line, both re-read by
# `status`); the per-order detail is emitted once per process. A restart re-emits it — which is the
# right amount of repetition for a condition an operator has to fix.
STALE_LOGGED=" "
log_once() { # <key> <message>
  case "$STALE_LOGGED" in *" $1 "*) return 0 ;; esac
  STALE_LOGGED="$STALE_LOGGED$1 "
  log_line "$2"
  return 0
}

write_record() { # <decision> <orders> <live> <dead> <unknown> <cap> <fix> <review> <refilled> <why> [<complete>] [<stale_briefs>] [<retired>]
  local tmp="$RECORD.tmp"
  {
    printf 'ts=%s\n' "$(date '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'decision=%s\n' "$1"
    printf 'orders=%s\nlive=%s\ndead=%s\nunknown=%s\ncomplete=%s\nretired=%s\n' "$2" "$3" "$4" "$5" "${11:-0}" "${13:-0}"
    printf 'capacity=%s\nmax_fix=%s\nmax_review=%s\n' "$6" "$7" "$8"
    printf 'refilled=%s\nmax_refills=%s\ninterval_s=%s\nprefix=%s\n' "$9" "$MAX_REFILLS" "$INTERVAL_S" "$PREFIX"
    printf 'stale_briefs=%s\norder_ttl_s=%s\nstale_after_s=%s\n' "${12:-0}" "$RETIRE_TTL_S" "$STALE_AFTER_S"
    printf 'reason=%s\n' "${10}"
  } > "$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$RECORD" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  return 0
}

# ── ONE PASS ──────────────────────────────────────────────────────────────────────────────────
DRY=0
pass() {
  local plenv orders=0 live=0 dead=0 unknown=0 cap fix review refilled=0 why="" decision=clean prev=""
  local complete=0 retired=0 retired_new=0 ret_note="" age=0 m_age=""
  local n_offered=0 n_dead_total=0 refused=0 budget_full=0 exhausted=0 no_record=0 stale_brief=0
  local f name wt prompt kind stamp wt_branch rec_branch capr sig hold bgrc stale_note prev_stale
  local wt_now prompt_now ret_reason

  mkdir -p "$STATE_DIR" 2>/dev/null || { log_line "REFUSING: state dir $STATE_DIR is not writable"; return 2; }
  # see PASS_BEAT: stamped BEFORE the walks, so a long pass is visibly working rather than silent
  if [ "$DRY" = 0 ]; then
    { date +%s > "$PASS_BEAT.tmp"; } 2>/dev/null && mv -f "$PASS_BEAT.tmp" "$PASS_BEAT" 2>/dev/null || true
  fi
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
    # ⛔ A RETIRED ORDER IS OUT OF THE POPULATION, NOT A MISSING ONE (agent-infra#4007). It is counted
    # (`retired=`) and it is NOT probed: there is nothing to learn from a record about work that ended,
    # and asking the dispatcher about it on every 60 s pass is what made a live count impossible to
    # read. `order_retired` matches the RECORD INSTANCE, so a re-ordered PR is back in the population on
    # the very next pass with no human action.
    if order_retired "$name" "$f"; then retired=$(( retired + 1 )); continue; fi
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
    if order_retired "$name" "$f"; then continue; fi   # already counted retired in the census walk
    ask_status "$name" "$f"
    [ "$STATUS_KIND" = DEAD ] || continue
    # ⛔ AN ORDER THIS PASS CAN NEVER SUPPLY IS RETIRED, NOT DEFERRED FOR EVER (agent-infra#4007).
    # The eligibility is deliberately NARROW: this path has already decided it cannot act on the order,
    # AND the record is older than the TTL -- so a transient crash burst can never retire an order a
    # later pass would have supplied. THREE un-actionable states qualify, named by the reason recorded:
    #   refills-spent   its `MAX_REFILLS` are gone -- the branch below logs this one for ever
    #   worktree-gone   the repair tree it names is not there -- the DOMINANT measured case (80 orders,
    #                   0 worktrees present, 2026-12-04): every pass logged "the worktree recorded for the
    #                   order is gone" and could not act. Before this arm that line was permanent.
    #   brief-gone      the brief file it names is not there (same shape, one field over)
    # `brief-refused` is the fourth, and it is decided where the gate is asked (below). The retired order
    # leaves `dead` (nothing remains to wait for) and enters `retired`; no spawn, no gate call, no ledger
    # row, and no log line per pass -- the count is the durable signal.
    age=0
    if m_age="$(mtime_of "$f")" && [ -n "$m_age" ]; then age=$(( $(date +%s) - m_age )); fi
    ret_reason=""
    if [ "$age" -gt "$RETIRE_TTL_S" ]; then
      wt_now="$(field "$f" worktree)"; prompt_now="$(field "$f" prompt)"
      if [ "$(refills_of "$name")" -ge "$MAX_REFILLS" ]; then ret_reason=refills-spent
      elif [ -z "$wt_now" ] || [ ! -d "$wt_now" ]; then ret_reason=worktree-gone
      elif [ -z "$prompt_now" ] || [ ! -f "$prompt_now" ]; then ret_reason=brief-gone
      fi
    fi
    if [ -n "$ret_reason" ]; then
      if [ "$DRY" = 1 ]; then
        log_line "DRY-RUN would RETIRE $name (reason=$ret_reason) — its record is ${age}s old (TTL ${RETIRE_TTL_S}s) and no pass can act on it again"
        retired_new=$(( retired_new + 1 )); retired=$(( retired + 1 )); dead=$(( dead - 1 ))
      elif retire_order "$name" "$f" "$ret_reason"; then
        retired_new=$(( retired_new + 1 )); retired=$(( retired + 1 )); dead=$(( dead - 1 ))
        log_line "$name: RETIRED (reason=$ret_reason) — its record is ${age}s old (TTL ${RETIRE_TTL_S}s) and no pass can act on it again. It leaves the pool. The composer (pr-doctor.py) re-orders the PR with a fresh record and a fresh worktree/brief if it is still open, which un-retires it (agent-infra#4007)"
      else
        # ⛔ AN UNWRITABLE RETIREMENT IS SAID OUT LOUD (review P2 on #4017): the order stays `dead` from the
        # census walk, so the pass stays `deferred` -- conservative, but the REASON the fossil is still
        # there was invisible, which is the "state nobody can act on" class this file keeps re-learning.
        log_once "$name:retire-failed" "$name: RETIREMENT FAILED (reason=$ret_reason) — $RETIRED could not be written; the order stays dead and the pass stays DEFERRED until the state dir is writable"
      fi
      continue
    fi
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
    # ⛔ THE BRIEF MUST STILL SATISFY THE GATE THAT WILL JUDGE IT (#3958) — the invariant is declared
    # above `brief_verdict`. It runs AFTER the cheap skips (an exhausted, held or already-offered order
    # never costs a subprocess) and BEFORE the dry-run branch, so a rehearsal tells the truth about the
    # same orders a real pass would refuse.
    brief_verdict "$prompt"; bgrc=$?
    if [ "$bgrc" = 80 ]; then
      # ⛔ A REFUSED BRIEF OLDER THAN THE TTL IS A FOSSIL, AND IT IS RETIRED RATHER THAN REPORTED FOR EVER
      # (agent-infra#4007). #3958 made this pass STOP replaying the refused brief -- correct, and it left
      # the order in the pool for ever: measured 2026-12-04, 72 orders were refused on EVERY pass and the
      # pass could never be clean. Past the TTL the composer has had a week of passes to rewrite the brief
      # and has not, so the record describes work that is no longer being ordered. Retirement is still
      # reversible by construction: a new record from the composer un-retires it on the next pass.
      if [ "$age" -gt "$RETIRE_TTL_S" ]; then
        if [ "$DRY" = 1 ]; then
          log_line "DRY-RUN would RETIRE $name — the brief recorded for the order is REFUSED by the brief gate (rc=80) and its record is ${age}s old (TTL ${RETIRE_TTL_S}s)"
          retired_new=$(( retired_new + 1 )); retired=$(( retired + 1 )); dead=$(( dead - 1 ))
        elif retire_order "$name" "$f" brief-refused; then
          retired_new=$(( retired_new + 1 )); retired=$(( retired + 1 )); dead=$(( dead - 1 ))
          log_line "$name: RETIRED — the brief recorded for the order is REFUSED by the brief gate (rc=80) and the record is ${age}s old (TTL ${RETIRE_TTL_S}s), so this supervisor has been unable to re-offer it for longer than the TTL. It leaves the pool. The composer (pr-doctor.py) writes a fresh brief and a fresh record if the PR is still open, which un-retires it (agent-infra#3958, #4007): $BRIEF_GATE_USED says: $(printf '%s' "$BRIEF_GATE_WHY" | cut -c1-300)"
        else
          # ⛔ AN UNWRITABLE RETIREMENT IS SAID OUT LOUD HERE TOO (review P3, round 2 on #4017): without
          # this arm the order was skipped SILENTLY -- no log line, and the `continue` also skipped the
          # `stale_brief` count, so the record's durable `stale_briefs=` lost a fossil the previous
          # release reported as `REGENERATION REQUIRED`. A failed retirement is still a REFUSED BRIEF.
          stale_brief=$(( stale_brief + 1 ))
          log_once "$name:retire-failed" "$name: RETIREMENT FAILED (reason=brief-refused) — $RETIRED could not be written, so this fossil stays in the pool; it is counted in stale_briefs= and still needs REGENERATION by pr-doctor: $(printf '%s' "$BRIEF_GATE_WHY" | cut -c1-200)"
        fi
        continue
      fi
      # NOT A DISPATCH ATTEMPT, so it is not `refused`, nothing is written to the ledger, and the order
      # keeps its refills. What it is: a brief that must be REGENERATED by its composer.
      stale_brief=$(( stale_brief + 1 ))
      if [ "$DRY" = 1 ]; then
        log_line "DRY-RUN would NOT re-offer $name — the brief recorded for the order is REFUSED by the brief gate (rc=80) and re-offering it would replay it unchanged; REGENERATION REQUIRED ($BRIEF_GATE_USED says: $(printf '%s' "$BRIEF_GATE_WHY" | cut -c1-300))"
      else
        log_once "$name:stale" "$name: NOT re-offered — the brief recorded for the order is REFUSED by the brief gate (rc=80), and re-offering it would replay the same file the gate keeps refusing. REGENERATION REQUIRED: $BRIEF_GATE_USED says: $(printf '%s' "$BRIEF_GATE_WHY" | cut -c1-300). The composer is pr-doctor.py, which rewrites $prompt on its next spawn for this PR; this supervisor neither composes nor edits a brief (agent-infra#3958)"
      fi
      continue
    fi
    if [ "$bgrc" != 0 ]; then
      # NO VERDICT: say so, and let the DISPATCHER own the refusal (see `brief_verdict`).
      log_once "$name:unvalidated" "$name: the brief could not be revalidated before this offer ($BRIEF_GATE_WHY) — handing the offer to the dispatcher, which owns this refusal"
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
  # ⛔ A SKIPPED FOSSIL IS A REASON THE PASS DID NOT SUPPLY, SO IT MUST APPEAR IN EVERY ARM THAT SAYS
  # WHY (#3958). It rides in the `why` string and in the record's `stale_briefs=` so `status` — the
  # durable answer — names it without the log.
  [ "$stale_brief" -gt 0 ] && stale_note="$stale_brief order(s) had a brief the gate REFUSES — REGENERATION REQUIRED by pr-doctor (never re-offered unchanged, and no refill spent)"
  [ "$retired_new" -gt 0 ] && ret_note="$retired_new order(s) RETIRED this pass — un-actionable (spent refills / worktree gone / brief gone or refused, record older than the ${RETIRE_TTL_S}s TTL); $retired retired in the population, out of the refill walk"
  if [ "$orders" -eq 0 ]; then
    decision=idle; why="no $PREFIX orders in $BG_DIR — nothing to supply (a pass that never placed an order leaves no record to refill)"
  elif [ "$refused" -gt 0 ]; then
    decision=refused; why="$refused re-offer(s) refused by the dispatcher ($refilled accepted first)${stale_note:+; $stale_note}"
  elif [ "$dead" -gt 0 ]; then
    decision=deferred
    local held=""
    [ "$budget_full" -gt 0 ] && held="$held, budget full ($live/$cap live) held $budget_full"
    [ "$exhausted" -gt 0 ] && held="$held, $exhausted spent their $MAX_REFILLS refill(s)"
    [ "$no_record" -gt 0 ] && held="$held, $no_record had no replayable record"
    [ "$stale_brief" -gt 0 ] && held="$held, $stale_note"
    why="$refilled of $n_dead_total re-offered; $dead still dead${held}"
  elif [ "$retired_new" -gt 0 ] && [ "$refilled" -eq 0 ] && [ "$unknown" -eq 0 ]; then
    # ⛔ RETIRING IS A SUPPLY OUTCOME, NOT A NO-OP: the pool it walked is now action-free, so the pass is
    # clean (rc=0) and SAYS what it did. Before #4007 this same pass was `deferred` (rc=6) for ever and
    # `live=` could never become non-zero, which is the "quiet" a stopped log also produces.
    # ⛔ AND A RETIREMENT MAY NOT BUY A CLEAN PASS OVER READS THAT FAILED (review P1 on #4017, reproduced):
    # this arm sat ABOVE the `unreadable` arm, so a pool of two unanswerable probes plus ONE retirable
    # fossil printed `decision=retired` and exited 0 — "nothing supplied, two reads not taken" reported as
    # healthy, which is exactly the #2896 round-3 defect the `unreadable` arm exists to refuse. Retirement
    # is a fact about orders we COULD read, so it only decides the verdict when every read was taken.
    decision=retired; why="$retired_new un-actionable order(s) retired; nothing left to supply ($live/$cap live, $retired retired${stale_note:+; $stale_note})"
  elif [ "$refilled" -gt 0 ]; then
    decision=refilled; why="$refilled of $n_dead_total dead order(s) re-offered${stale_note:+; $stale_note}"
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
    decision=clean; why="no dead order to refill ($live/$cap live, $complete complete, $unknown unknown, $retired retired)"
  fi
  [ -n "$ret_note" ] && why="$why; $ret_note"
  # ⛔ A DRY RUN WRITES NO RECORD AND EXITS 0 (found by review). `$RECORD` is the LAST REAL PASS's
  # evidence — the durable answer to "what did the supervisor actually do?" — and a rehearsal that
  # overwrote it (its `refilled=` counting would-is, its `ts=` claiming a pass that never happened)
  # destroys exactly that. The dry run's verdict goes to stdout and nowhere else.
  if [ "$DRY" = 1 ]; then
    log_line "DRY-RUN pass: decision=$decision orders=$orders live=$live/$cap dead=$dead complete=$complete unknown=$unknown retired=$retired would-retire=$retired_new would-refill=$refilled stale_briefs=$stale_brief — $why (no record, no ledger row, nothing spawned)"
    return 0
  fi
  prev="$(awk -F= '$1=="decision"{ print $2; exit }' "$RECORD" 2>/dev/null || true)"
  prev_stale="$(awk -F= '$1=="stale_briefs"{ print $2; exit }' "$RECORD" 2>/dev/null || true)"
  write_record "$decision" "$orders" "$live" "$dead" "$unknown" "$cap" "$fix" "$review" "$refilled" "$why" "$complete" "$stale_brief" "$retired"
  # ⛔ THE LOG IS AN EVENT STREAM, NOT A CLOCK. An unchanged `idle`/`clean` pass writes NOTHING: a
  # 60 s service logging `nothing to do` 1,440 times a day is noise that hides the pass that mattered,
  # and the last-pass record (`$RECORD`, with its own `ts=`) is the heartbeat a reader checks instead.
  # A refill and every refusal always log; so does a CHANGE in the fossil count (the per-order lines are
  # emitted once per process — see `log_once`), because a supply outage whose size moves is news.
  if [ "$decision" != "$prev" ] || [ "$refilled" -gt 0 ] || [ "$refused" -gt 0 ] || [ "$stale_brief" != "${prev_stale:-0}" ] || [ "$retired_new" -gt 0 ]; then
    log_line "pass: $decision — orders=$orders live=$live/$cap dead=$dead complete=$complete unknown=$unknown retired=$retired refilled=$refilled — $why"
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
  local orders=0 live=0 dead=0 unknown=0 complete=0 retired=0 f name
  local rc=0 m_age age beat=""
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
    if order_retired "$name" "$f"; then retired=$(( retired + 1 )); continue; fi
    ask_status "$name" "$f"
    case "$STATUS_KIND" in LIVE) live=$(( live + 1 ));; COMPLETE) complete=$(( complete + 1 ));; DEAD) dead=$(( dead + 1 ));; *) unknown=$(( unknown + 1 ));; esac
  done
  local cap fix review plenv="$STATE_DIR/.worker-supply.plistenv"
  plist_env_dump "$ORCH_PLIST" "$plenv"
  fix="$(limit_of MAX_FIX "$DEFAULT_MAX_FIX" "$plenv")"
  review="$(limit_of MAX_REVIEW "$DEFAULT_MAX_REVIEW" "$plenv")"
  cap=$(( fix + review ))
  echo "now:   orders=$orders live=$live/$cap dead=$dead complete=$complete unknown=$unknown retired=$retired (fix=$fix review=$review)"
  # ⛔ THE HEARTBEAT IS THE ONE READING THIS VERB EXISTS TO GIVE (agent-infra#4007). The measured shape
  # was a supervisor alive for 16 days whose log had stopped two days earlier: every derived number read
  # "quiet" and nothing reported the ABSENCE. A record that has not been rewritten within the staleness
  # bound is what a DEAD or WEDGED supervisor looks like from outside, so it is named `STALE` and it
  # EXITS 5 -- a monitor that reads the code (a lane, `set -e`, an activation grid) gets a verdict rather
  # than an `ActiveState=active` over a loop that stopped passing.
  local rec_m pass_m newest
  rec_m="$(mtime_of "$RECORD")"; pass_m="$(mtime_of "$PASS_BEAT")"
  case "${rec_m:-}" in ''|*[!0-9]*) rec_m="" ;; esac
  case "${pass_m:-}" in ''|*[!0-9]*) pass_m="" ;; esac
  newest="${rec_m:-}"
  if [ -n "$pass_m" ] && { [ -z "$newest" ] || [ "$pass_m" -gt "$newest" ]; }; then newest="$pass_m"; fi
  if [ -n "$newest" ]; then
    age=$(( $(date +%s) - newest ))
    if [ "$age" -gt "$STALE_AFTER_S" ]; then
      if [ -n "$pass_m" ] && [ "$pass_m" = "$newest" ]; then
        beat="STALE — a pass STARTED ${age}s ago and has not finished, over the ${STALE_AFTER_S}s bound: the process is WEDGED (or died mid-pass), not working"
      else
        beat="STALE — the last completed pass was ${age}s ago, over the ${STALE_AFTER_S}s bound: the process that should be passing is DEAD or WEDGED, not idle"
      fi
      rc=5
    elif [ -n "$pass_m" ] && [ "$pass_m" = "$newest" ]; then
      beat="ok — a pass is IN PROGRESS (started ${age}s ago; the completed-pass record updates when it ends, bound ${STALE_AFTER_S}s)"
    else
      beat="ok — last completed pass ${age}s ago (bound ${STALE_AFTER_S}s)"
    fi
  else
    beat="STALE — no pass has EVER written $RECORD or $PASS_BEAT here (bound ${STALE_AFTER_S}s); a supervisor whose record is absent has supplied nothing, and this box cannot tell a first boot from a death"
    rc=5
  fi
  echo "beat:  $beat"
  # …and the knobs the process ACTUALLY resolved (post-validation): the unit renders what was asked for,
  # this line is what is enforced — the two are different facts when an override was rejected.
  echo "knobs: interval_s=$INTERVAL_S max_refills=$MAX_REFILLS prefix=$PREFIX order_ttl_s=$RETIRE_TTL_S stale_after_s=$STALE_AFTER_S"
  echo "paths: dispatcher=$DISPATCH bg=$BG_DIR ledger=$LEDGER retired=$RETIRED log=$LOG"
  if [ -d "$LOCK_DIR" ]; then
    echo "lock:  HELD by pid $(cat "$LOCK_DIR/pid" 2>/dev/null || echo '<unknown>') ($LOCK_DIR)"
  else
    echo "lock:  free"
  fi
  return "$rc"
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
  status) show_status; exit $? ;;
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
