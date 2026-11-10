#!/usr/bin/env bash
# ai-drainer.test.sh — the guard and TOP-UP regressions for scripts/orchestrator-harness/ai-drainer.sh.
#
# WHAT THIS SUITE IS FOR. The drainer is a SCHEDULED DISPATCHER, and every one of its properties fails
# in the expensive direction if it breaks:
#   * no top-up            → one lane per tick while a 34-PR backlog waits (the #2639 shape);
#   * top-up with no bound → an unbounded tick forks a box into swap (the #1985 shape);
#   * no lock              → two ticks each dispatch the full remainder, and every tick exits 0;
#   * a lane outliving the tick counted as a blocker → the box drains one lane per 20 min for ever;
#   * a refusal counted as a completed lane → every tick reports DONE while no agent ever ran;
#   * no memory/swap guard → a lane starts on a box already at its floor (or, on a cell with NO swap,
#                            the drainer skips every tick and is inert);
#   * a slice cursor that advances per TICK → N lanes in one tick all work the same six PRs.
# Each arm drives the REAL script (no reimplementation), with a fake dispatcher and injected probe
# values, so the arm tests the shipped code path rather than a copy of it.
#
# ⛔ THE TWO ARMS THAT MATTER MOST:
#   * NON-VACUITY — the top-up loop is REMOVED (`n=1`, injected at the `topup-loop` marker) and arm (a)
#     MUST fail there. A top-up test that still passes with the top-up deleted tests nothing.
#   * ARM (b) — a lane outliving its tick must NOT block the next tick's top-up, and must still be
#     COUNTED. That pair is the whole correction of #2639's lock scope: blocking = starvation,
#     not-counting = over-dispatch.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAINER="${DRAINER:-$HERE/ai-drainer.sh}"
LAUNCHER="$HERE/multi-repo-controller.sh"
[ -f "$DRAINER" ] || { echo "ai-drainer.test: no drainer at $DRAINER" >&2; exit 2; }
# ⛔ THE PLATFORM IS PINNED, NOT INHERITED. The swap arm is a DIFFERENT GATE per platform (a `SwapFree`
# floor on Linux, a kernel pressure level on Darwin), so an arm that let `uname -s` decide would test a
# different gate on the operator's Mac than on a cell — and would read the LIVE box's pressure on the
# way. Linux is the default because that is the branch every cell runs and the one the swap-floor arms
# are about; the Darwin arms set `DRAINER_OS=Darwin` explicitly. An explicit value in the caller's env
# still wins.
DRAINER_OS="${DRAINER_OS:-Linux}"; export DRAINER_OS

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1${3:+ — $3}"; fi; }

ROOT="$(mktemp -d)" || exit 1
cleanup() {
  # Bounded: kill only pids THIS test recorded, never a pattern-matched population.
  [ -f "$ROOT/pids" ] && while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null; done <"$ROOT/pids"
  rm -rf "$ROOT"
}
trap cleanup EXIT

# ── a fixture seed repo: the drainer branches each lane's worktree from SEED_REF ───────────────
SEED="$ROOT/seed"
mkdir -p "$SEED"
git -C "$SEED" init -q >/dev/null 2>&1
git -C "$SEED" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed >/dev/null 2>&1
SEED_REF="$(git -C "$SEED" rev-parse HEAD)"

# ── the fake lane, and the fake dispatcher ────────────────────────────────────────────────────
# ⛔ THE FAKE LANE IS CALLED `nonblocking-dispatch.sh`, DELIBERATELY. The census counts a lane by ARGV
# SHAPE (`_counts_as_lane`), because both shipped dispatchers record the pid of a backgrounded subshell
# whose command line is `bash …/nonblocking-dispatch.sh …` (`pi` is its CHILD). A fixture named
# `sleep` would be invisible to the very census the arms are about — and a lane nobody counts is the
# defect the arms exist for, not a test convenience.
cat >"$ROOT/nonblocking-dispatch.sh" <<'LANE_EOF'
#!/usr/bin/env bash
# <secs> <rc|none> <rc-file>
sleep "${1:-0}"
[ "${2:-0}" = "none" ] || printf '%s\n' "${2:-0}" > "$3"
LANE_EOF
chmod +x "$ROOT/nonblocking-dispatch.sh"

# The dispatcher contract: write `$O/bg/<name>.pid` (a live lane) and, unless told otherwise,
# `$O/bg/<name>.rc` when the lane ends. Those are the two files the census and the verdict depend on.
#   FAKE_LANE_SECS      how long the lane lives (0 = a lane that is already gone)
#   FAKE_RC             the exit status the lane records (default 0; "none" = write no status file)
#   FAKE_NO_PIDFILE     write no pidfile at all (the "dispatcher returned, lane untrackable" shape)
#   FAKE_DISPATCH_SLEEP seconds the DISPATCHER itself blocks (widens the window for the signal arm)
DISPATCH="$ROOT/dispatch.sh"
cat >"$DISPATCH" <<'DISPATCH_EOF'
#!/usr/bin/env bash
set -u
NAME="$1"; WT="$2"; BRIEF="$3"
O="${O:?}"; D="$O/bg"; mkdir -p "$D"
printf '%s\n' "$(cd "$WT" && pwd)" > "$D/$NAME.wt"
[ "${FAKE_DISPATCH_SLEEP:-0}" = "0" ] || sleep "${FAKE_DISPATCH_SLEEP:-0}"
if [ "${FAKE_NO_PIDFILE:-0}" = "1" ]; then exit 0; fi
bash "$(dirname "$0")/nonblocking-dispatch.sh" "${FAKE_LANE_SECS:-0}" "${FAKE_RC:-0}" "$D/$NAME.rc" &
echo "$!" > "$D/$NAME.pid"
exit 0
DISPATCH_EOF
chmod +x "$DISPATCH"

# One drainer invocation's environment, hermetically scoped. Every path is inside $ROOT, so nothing
# here can touch the live fleet's state dirs even when this runs on the operator's box — and every
# PROBE is injected, because a suite that reads the host's memory/load reports the host's health.
#   RUN_TARGET      pin the target (TARGET_LANES) — arms that assert exact counts use this
#   RUN_NCPU        cores the formula sees                       default 4
#   RUN_MEM         available memory (MB) the formula sees        default 8192
#   RUN_LOAD        1-min load ×100 the formula sees              default 100 (= 1.00)
#   RUN_SWAP        free swap MB   ·  RUN_SWAP_TOTAL  total swap MB (0 = this box has NO swap)
#   RUN_DRAINER_OS  the platform arm to exercise          default: Linux (the CELLS' arm, and the one
#                   this suite's swap-floor arms are about). Set `Darwin` for the Darwin arm — the
#                   seam exists so NO arm depends on the box it runs on, in either direction.
#   RUN_PRESSURE    the Darwin `kern.memorystatus_vm_pressure_level` to assume (1|2|4|unreadable)
#   RUN_MAX_PRESSURE  MAX_MEM_PRESSURE_LEVEL (the Darwin refuse-at threshold)
#   RUN_WT_MOD      worker-terminal.sh for the launcher census     default: a path that does not exist
#   RUN_CWD         the CWD one arm runs the drainer from          default: this suite's own CWD
#                   (for the #3882 glob arm: the token split must not pathname-expand, and that can
#                   only be OBSERVED from a CWD that holds lane-shaped filenames)
_drainer_env() { # <tag> → echoes the env assignments, one per line (callers use `env`)
  local o="$ROOT/o-$1" ai="$ROOT/ai-$1"
  # The channel: the fixture seed by default, `RUN_FLEET_REPO` to name one, and `RUN_NO_FLEET_REPO=1` for
  # "nothing configured" — a state the drainer must REFUSE by name rather than resolve to a lane checkout.
  local _fleet_v="${RUN_FLEET_REPO:-$SEED}"
  [ "${RUN_NO_FLEET_REPO:-0}" = 1 ] && _fleet_v=""
  mkdir -p "$o/bg" "$ai"
  printf '%s\n' \
    "O=$o" "AI=$ai" "DISPATCH=$DISPATCH" "SEED_REPO=${RUN_SEED_REPO:-$SEED}" "SEED_REF=$SEED_REF" \
    "TARGET_LANES=${RUN_TARGET:-}" "MAX_LANES=${RUN_MAX_LANES:-}" \
    "NCPU=${RUN_NCPU:-4}" "MEM_AVAIL_MB=${RUN_MEM:-8192}" "LOAD1_100=${RUN_LOAD:-100}" \
    "SWAP_TOTAL_MB=${RUN_SWAP_TOTAL:-9999}" "SWAP_FREE_MB=${RUN_SWAP:-9999}" \
    "DRAINER_OS=${RUN_DRAINER_OS:-Linux}" "MEM_PRESSURE_LEVEL=${RUN_PRESSURE:-}" \
    "MAX_MEM_PRESSURE_LEVEL=${RUN_MAX_PRESSURE:-}" \
    "WT_MOD=${RUN_WT_MOD:-$ROOT/no-such-worker-terminal.sh}" \
    "LANE_TIMEOUT=${RUN_LANE_TIMEOUT:-60}" "PS=${RUN_PS:-ps}" \
    "SLICE_WIDTH=${RUN_SLICE_WIDTH:-10}" "SLICE_TOTAL=${RUN_SLICE_TOTAL:-70}" \
    "FAKE_LANE_SECS=${FAKE_LANE_SECS:-0}" "FAKE_RC=${FAKE_RC:-0}" "FAKE_NO_PIDFILE=${FAKE_NO_PIDFILE:-0}" \
    "FLEET_REPO=${_fleet_v}" "CAPACITY_MOD=${RUN_CAPACITY_MOD:-}" "CAP_EXPECTED_BOXES=${RUN_EXPECTED:-}" \
    "FAKE_DISPATCH_SLEEP=${FAKE_DISPATCH_SLEEP:-0}" \
    "RC_GRACE_S=${RUN_RC_GRACE:-2}"
  return 0
}
run_drainer_bg() { # <tag>
  local tag="$1" line
  local -a envs
  envs=()
  while IFS= read -r line; do envs+=("$line"); done < <(_drainer_env "$tag")
  env -u SWAP_FREE_MB -u SWAP_TOTAL_MB "${envs[@]}" bash "$DRAINER" >/dev/null 2>&1 &
  echo "$!" >>"$ROOT/pids"
  LAST_O="$ROOT/o-$tag"; LAST_AI="$ROOT/ai-$tag"
}
run_drainer_fg() { # <tag> [drainer-path] → sets LAST_RC
  local tag="$1" script="${2:-$DRAINER}" line
  local -a envs
  envs=()
  while IFS= read -r line; do envs+=("$line"); done < <(_drainer_env "$tag")
  # ⛔ THE OPERATOR'S `REPO` MUST NOT DECIDE THIS SUITE'S CHANNEL (fresh review round 7). The drainer's own
  # default chain is `FLEET_REPO -> REPO -> (refuse)`, and a lane shell routinely exports `REPO` for its
  # own work; inheriting it made (f3) read a REAL fleet channel instead of the fixture's originless seed.
  ( cd "${RUN_CWD:-.}" && env -u REPO -u SWAP_FREE_MB -u SWAP_TOTAL_MB "${envs[@]}" bash "$script" ) >/dev/null 2>&1
  LAST_RC=$?
  LAST_O="$ROOT/o-$tag"; LAST_AI="$ROOT/ai-$tag"
  return 0
}
wait_for_path() { # <path> <tenths>
  local i=0
  while [ "$i" -lt "$2" ]; do [ -e "$1" ] && return 0; sleep 0.2; i=$((i + 1)); done
  return 1
}
dispatched() { # <log> → the number of DISPATCHED lines (0 when the log does not exist)
  local n
  n="$(grep -c 'DISPATCHED:' "$1" 2>/dev/null)"
  printf '%s' "${n:-0}"
}
# Every probe/default seam this suite can set, cleared between arms: an arm that inherited the
# previous arm's `RUN_SWAP=unreadable` would fail for a reason that has nothing to do with what it
# asserts (measured during development: nine arms went red off one leaked seam).
reset_run() {
  RUN_TARGET=; RUN_MAX_LANES=; RUN_NCPU=; RUN_MEM=; RUN_LOAD=; RUN_SWAP=; RUN_SWAP_TOTAL=
  RUN_LANE_TIMEOUT=; RUN_SLICE_WIDTH=; RUN_SLICE_TOTAL=; RUN_RC_GRACE=; RUN_WT_MOD=; RUN_PS=; RUN_CWD=
  RUN_DRAINER_OS=; RUN_PRESSURE=; RUN_MAX_PRESSURE=
  RUN_FLEET_REPO=; RUN_NO_FLEET_REPO=0; RUN_SEED_REPO=; RUN_CAPACITY_MOD=; RUN_EXPECTED=
  FAKE_LANE_SECS=0; FAKE_RC=0; FAKE_NO_PIDFILE=0; FAKE_DISPATCH_SLEEP=0
}
# A lane-shaped live process in $O/bg, so the CENSUS sees it. A pidfile alone is not enough (the
# census checks the command line, and it is right to).
plant_lane() { # <tag> <slot> → echoes the pid
  local o="$ROOT/o-$1"
  bash "$ROOT/nonblocking-dispatch.sh" 60 0 /dev/null &
  local p=$!
  echo "$p" >>"$ROOT/pids"
  printf '%s' "$p" >"$o/bg/seed-lane-$2.pid"
  printf '%s' "$p"
}
# A `ps` for the CENSUS-CLAMP arms (agent-infra#3882). The clamp reads the box's live lane processes,
# so it is a PROBE like memory or load and must be INJECTED — a suite that read the host's process table
# would report the host's fleet (39 lane-shaped processes on the operator's Mac) and the arms would
# assert different things on a Mac than on a quiet cell.
#   `-A`        → a FIXED population: <n> lane-shaped rows, plus one shell whose argv NAMES a
#                 lane script without being one (inside a `case` pattern, so the token is
#                 `*nonblocking-dispatch.sh*)` — the exact shape a substring predicate counts and this
#                 one must not), plus one plain shell that is not a lane at all. Every row is `<pid>
#                 <ppid> <command>` because the probe counts lane ROOTS (a lane's `pi` child is the same
#                 lane); `pair` makes each lane TWO rows — the `bash …/lane.sh` wrapper and its `pi`
#                 child — which is what the box actually runs;
#   `-p <pid>`  → delegates to the REAL ps, because `_census_dispatcher` reads a live lane's argv that
#                 way and every other arm in this suite depends on it answering.
# <n> may also be `empty` (a `ps` that "succeeds" and prints nothing — the UNREADABLE case) or `fail`.
fake_ps() { # <path> <n|empty|fail> [pair]
  local p="$1" n="$2" shape="${3:-flat}"
  cat >"$p" <<PS_EOF
#!/usr/bin/env bash
case "\$*" in *"-p "*) exec ps "\$@" ;; esac
case "$n" in
  fail)  exit 1 ;;
  empty) exit 0 ;;
esac
i=0
while [ "\$i" -lt $n ]; do
  if [ "$shape" = "pair" ]; then
    printf '%s 1 /bin/bash /opt/orch/lane.sh %s\n' "\$((100000 + 2*i))" "\$i"
    printf '%s %s /usr/local/bin/pi -p --provider deepseek brief-%s\n' "\$((100001 + 2*i))" "\$((100000 + 2*i))" "\$i"
  else
    printf '%s 1 /usr/local/bin/pi -p --provider deepseek --model deepseek-flash brief-%s\n' "\$((100000 + i))" "\$i"
  fi
  i=\$((i + 1))
done
printf '%s\n' "100998 1 /bin/zsh -c 'case x in *nonblocking-dispatch.sh*) : ;; esac'"
printf '%s\n' "100999 1 /bin/zsh -l"
PS_EOF
  chmod +x "$p"
}

echo "== ai-drainer top-up =="

reset_run
# ── ARM (a): 0 ALIVE + TARGET 3 → 3 LANES, on three DIFFERENT slices ─────────────────────────
# This is the arm the non-vacuity mutation must break. The three offsets are the other half: a top-up
# that starts three lanes on ONE slice triples the work on the same six PRs.
RUN_TARGET=3 FAKE_LANE_SECS=10
run_drainer_fg a
n_a="$(dispatched "$LAST_AI/logs/ai-drainer.log")"
check "(a) 0 alive + target 3 → 3 lanes dispatched" '[ "${n_a:-0}" -eq 3 ]' "dispatched=$n_a — $(grep -c START: "$LAST_AI/logs/ai-drainer.log" 2>/dev/null) tick(s)"
check "(a) the tick exits 0" '[ "$LAST_RC" -eq 0 ]' "rc=$LAST_RC"
check "(a) the three lanes took THREE distinct slice offsets" \
  '[ "$(sed -n "s/.*slice-offset=\([0-9]*\).*/\1/p" "$LAST_AI/logs/ai-drainer.log" | sort -u | wc -l | tr -d " ")" -eq 3 ]' \
  "$(sed -n 's/.*slice-offset=\([0-9]*\).*/\1/p' "$LAST_AI/logs/ai-drainer.log" | tr '\n' ' ')"
check "(a) the START line states the reasoning (target=… alive=… dispatching N)" \
  'grep -q "START: target=3 (PINNED by TARGET_LANES) alive=0 .* dispatching 3 " "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep "START:" "$LAST_AI/logs/ai-drainer.log" 2>/dev/null | head -1)"
check "(a) the cursor advanced PER LANE (3, not 1)" \
  '[ "$(cat "$LAST_AI/state/drainer-slice" 2>/dev/null)" = "3" ]' \
  "cursor=$(cat "$LAST_AI/state/drainer-slice" 2>/dev/null)"
check "(a) each lane has its OWN brief file, and drainer-brief.md is the latest" \
  '[ "$(ls "$LAST_AI"/state/drainer-brief-ai-drain-*.md 2>/dev/null | wc -l | tr -d " ")" -eq 3 ] && [ -f "$LAST_AI/state/drainer-brief.md" ]'

reset_run
# ── ARM (a2): 2 ALIVE + TARGET 3 → exactly 1 MORE ────────────────────────────────────────────
RUN_TARGET=3 FAKE_LANE_SECS=0
o="$ROOT/o-a2b"; ai="$ROOT/ai-a2b"; mkdir -p "$o/bg" "$ai"
plant_lane a2b 1 >/dev/null; plant_lane a2b 2 >/dev/null
run_drainer_fg a2b
n_a2b="$(dispatched "$LAST_AI/logs/ai-drainer.log")"
check "(b) 2 alive + target 3 → exactly 1 lane dispatched" '[ "${n_a2b:-0}" -eq 1 ]' "dispatched=$n_a2b"
check "(b) …and the START line reports alive=2" \
  'grep -q "alive=2 (" "$LAST_AI/logs/ai-drainer.log"' "$(grep START: "$LAST_AI/logs/ai-drainer.log" | head -1)"

reset_run
# ── ARM (a3): AT TARGET → ZERO DISPATCHED, AND THAT IS NOT AN ERROR ───────────────────────────
o="$ROOT/o-a3"; ai="$ROOT/ai-a3"; mkdir -p "$o/bg" "$ai"
RUN_TARGET=3
plant_lane a3 1 >/dev/null; plant_lane a3 2 >/dev/null; plant_lane a3 3 >/dev/null
run_drainer_fg a3
check "(c) 3 alive + target 3 → 0 lanes dispatched" '[ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 0 ]'
check "(c) …and the tick exits 0 (a full box is not a failure)" '[ "$LAST_RC" -eq 0 ]' "rc=$LAST_RC"
check "(c) …and it says WHY, with the same arithmetic a dispatch would print" \
  'grep -q "SKIP: nothing to add — target=3 .* alive=3 " "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep "SKIP: nothing to add" "$LAST_AI/logs/ai-drainer.log" | head -1)"
check "(c) a skipping tick still refreshes the beat (idle ≠ dead)" '[ -f "$LAST_AI/state/ai-drainer.beat" ]'

reset_run
# ── ARM (b): A LANE OUTLIVING ITS TICK NEITHER BLOCKS NOR HIDES FROM THE NEXT TICK ───────────
# ⛔ TWO ASSERTIONS, AND BOTH ARE THE POINT:
#   * the FIRST tick releases its lock while its lanes are STILL RUNNING (the #2639 lock scope is
#     gone — holding it for a lane's lifetime is what made a 20-min tick dispatch once an hour);
#   * the SECOND tick COUNTS them (alive=3) and dispatches the remainder (0 here), and a THIRD tick
#     after one dies dispatches exactly 1. Blocking would give "SKIP: drainer already running" for
#     ever; not counting would give 3 more lanes on a box that already has 3.
o="$ROOT/o-b"; ai="$ROOT/ai-b"; mkdir -p "$o/bg" "$ai"
RUN_TARGET=3 FAKE_LANE_SECS=40 RUN_SLICE_TOTAL=70
run_drainer_fg b
check "(d) the first tick dispatched 3 lanes that are STILL ALIVE" \
  '[ "$(dispatched "$ai/logs/ai-drainer.log")" -eq 3 ] && [ "$(ls "$o"/bg/*.pid 2>/dev/null | wc -l | tr -d " ")" -ge 3 ]' \
  "dispatched=$(dispatched "$ai/logs/ai-drainer.log")"
live_pids="$(cat "$o"/bg/ai-drain-*.pid 2>/dev/null | tr -d '\n')"
check "(d) the lock is RELEASED while the lanes still work (the tick does not wait)" \
  '[ ! -d "$ai/state/ai-drainer.lock" ]' "lock still held"
check "(d) …and its worktrees were LEFT, not destroyed" \
  '[ "$(ls -d "$ai"/wt-drainer-ai-drain-* 2>/dev/null | grep -vc "\.lane-pid$")" -eq 3 ]' \
  "$(ls -d "$ai"/wt-drainer-ai-drain-* 2>/dev/null | grep -v '\.lane-pid$' | wc -l | tr -d " ")"
run_drainer_fg b                     # SAME state dir + same $O: the lanes are the box's, not the tick's
check "(d) the next tick is NOT blocked by them, and counts them (alive=3)" \
  'grep -q "SKIP: nothing to add .* alive=3 " "$ai/logs/ai-drainer.log" && ! grep -q "SKIP: drainer already running" "$ai/logs/ai-drainer.log"' \
  "$(grep -E "SKIP:" "$ai/logs/ai-drainer.log" | tail -2 | tr '\n' ' ')"
check "(d) …and dispatched nothing more (no over-dispatch on a full box)" \
  '[ "$(dispatched "$ai/logs/ai-drainer.log")" -eq 3 ]' "dispatched=$(dispatched "$ai/logs/ai-drainer.log")"
first_lane="$(cat "$o"/bg/ai-drain-*.pid 2>/dev/null | head -1 | tr -dc '0-9')"
# The fixture stands in for a lane that FINISHED: it records its status, then its pid goes. (A lane
# KILLED with no status is a different arm — (g)/(h) — and it must not make this one fail.)
for _rf in "$o"/bg/ai-drain-*.pid; do
  [ "$(tr -dc '0-9' <"$_rf")" = "$first_lane" ] && printf '0\n' >"${_rf%.pid}.rc"
done
kill "$first_lane" 2>/dev/null; wait "$first_lane" 2>/dev/null; sleep 0.6
run_drainer_fg b                     # one lane gone → the box has room for exactly one
check "(d) after ONE lane dies the next tick tops up by exactly 1" \
  '[ "$(dispatched "$ai/logs/ai-drainer.log")" -eq 4 ]' "dispatched=$(dispatched "$ai/logs/ai-drainer.log")"
check "(d) …and it settled the dead lane's status (rc=0 → DONE)" \
  'grep -q "DONE: lane ai-drain-.* finished rc=0" "$ai/logs/ai-drainer.log"' \
  "$(grep -E "DONE|FAIL" "$ai/logs/ai-drainer.log" | tail -2 | tr '\n' ' ')"
FAKE_LANE_SECS=0

# ── THE CAPACITY FORMULA: cpu ceiling, memory ceiling, load arm, and NO SWAP ────────────────
# (Every value below is INJECTED — the formula is arithmetic on its inputs, so the arms are exact.)
reset_run
# ── (e1) NO SWAP ON THE BOX IS NOT ZERO CAPACITY ──────────────────────────────────────────────
# The defect: a cell ships with NO swap, `SwapFree` reads 0, and `0 < 700` skipped EVERY tick on
# EVERY cell — an installed job that never dispatched and exited 0, so nothing was red.
RUN_TARGET= FAKE_LANE_SECS=0 RUN_SWAP_TOTAL=0 RUN_SWAP=0 RUN_NCPU=4 RUN_MEM=8192 RUN_LOAD=100
run_drainer_fg e1
check "(e) a box with NO swap still dispatches (absent ≠ exhausted)" \
  '[ "$LAST_RC" -eq 0 ] && [ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -ge 1 ]' \
  "rc=$LAST_RC dispatched=$(dispatched "$LAST_AI/logs/ai-drainer.log")"
check "(e) …and the log NAMES the reading (swap=none, floor not applicable)" \
  'grep -q "swap=none (this box has no swap — the floor does not apply)" "$LAST_AI/logs/ai-drainer.log"'

reset_run
# ── (e2) SWAP THAT EXISTS AND IS BELOW THE FLOOR STILL REFUSES — **THE LINUX ARM** ──────────
# This is the arm the floor is FOR, and it must survive: a Linux box has a fixed swap partition, where
# `SwapFree` IS headroom. ⛔ IT RUNS THE **MEASURED** DARWIN NUMBERS ON PURPOSE (412MB of 3072MB, the
# 2026-10-29 reading) so that it and (e2b) are a CONTROLLED PAIR: same fixtures, same target, and the
# ONLY difference between the two runs is `DRAINER_OS`. A pair with different fixtures would not be
# evidence that the PLATFORM is what moved the verdict — only that two unrelated arms disagree.
RUN_DRAINER_OS=Linux RUN_TARGET=2 RUN_SWAP_TOTAL=3072 RUN_SWAP=412
run_drainer_fg e2
check "(e2) LINUX: the measured 412MB of 3072MB < the 700MB floor → SKIP, exit 0, nothing dispatched" \
  '[ "$LAST_RC" -eq 0 ] && [ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 0 ] && grep -q "SKIP: swap 412MB < 700MB floor (of 3072MB)" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep -E "SKIP|DISPATCHED" "$LAST_AI/logs/ai-drainer.log" | head -1)"

reset_run
# ── (e2b) THE DARWIN ARM: A LOW FREE-SWAP FIGURE DOES NOT REFUSE (the measured false refusal) ─
# MEASURED 2026-10-29 on the operator's Mac: `sysctl vm.swapusage` read
# `total = 3072.00M used = 2659.94M free = 412.06M` while `kern.memorystatus_vm_pressure_level` read
# **1 = normal** and `memory_pressure -Q` read **52%** free — and the OLD floor skipped every tick on
# that reading. Darwin's `total` is the SUM of the swap FILES the kernel has grown so far (three 1 GiB
# files, created 26 Oct 13:55, 26 Oct 14:28 and 28 Oct 19:29), so `free = total − used` is low because
# the kernel GREW the file, not because the box cannot take a lane. (e2) and (e2b) run THESE SAME
# NUMBERS at the same target, and the ONLY difference is `DRAINER_OS`.
RUN_DRAINER_OS=Darwin RUN_PRESSURE=1 RUN_TARGET=2 RUN_SWAP_TOTAL=3072 RUN_SWAP=412
run_drainer_fg e2b
check "(e2b) DARWIN: free swap 412MB/3072MB with pressure=NORMAL dispatches (no swap floor)" \
  '[ "$LAST_RC" -eq 0 ] && [ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -ge 1 ] && ! grep -q "SKIP: swap" "$LAST_AI/logs/ai-drainer.log"' \
  "rc=$LAST_RC · $(grep -E "SKIP|START" "$LAST_AI/logs/ai-drainer.log" | head -1)"
check "(e2b) …and it NAMES the Darwin reading instead of the floor" \
  'grep -q "swap=412MB/3072MB (darwin: kernel-grown on demand, not a floor) pressure=normal" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep "START:" "$LAST_AI/logs/ai-drainer.log" | head -1)"

reset_run
# ── (e2c) THE DARWIN ARM IS A GATE, NOT A DELETION — the kernel's verdict must still refuse ──
# Removing a false refusal must not remove the refusal: a box the KERNEL says is critical takes no new
# lane, however much free memory the arithmetic claims.
RUN_DRAINER_OS=Darwin RUN_PRESSURE=4 RUN_TARGET=2 RUN_SWAP_TOTAL=3072 RUN_SWAP=412 RUN_MEM=32768
run_drainer_fg e2c
check "(e2c) DARWIN: CRITICAL pressure refuses even with 32 GB free" \
  '[ "$LAST_RC" -eq 0 ] && [ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 0 ] && grep -q "SKIP: memory pressure critical" "$LAST_AI/logs/ai-drainer.log"' \
  "rc=$LAST_RC · $(grep -E "SKIP|START" "$LAST_AI/logs/ai-drainer.log" | head -1)"

reset_run
# ── (e2d) THE THRESHOLD: the shipped default refuses at WARNING, and the seam moves it ───────
# MAX_MEM_PRESSURE_LEVEL=2 (default) is "refuse at warning and above"; 4 is "only at critical".
RUN_DRAINER_OS=Darwin RUN_PRESSURE=2 RUN_TARGET=2 RUN_SWAP_TOTAL=3072 RUN_SWAP=412
run_drainer_fg e2d
check "(e2d) DARWIN: WARNING at the default threshold (2) refuses" \
  '[ "$LAST_RC" -eq 0 ] && [ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 0 ] && grep -q "SKIP: memory pressure warning .* >= 2 " "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep -E "SKIP" "$LAST_AI/logs/ai-drainer.log" | head -1)"
RUN_DRAINER_OS=Darwin RUN_PRESSURE=2 RUN_MAX_PRESSURE=4 RUN_TARGET=2 RUN_SWAP_TOTAL=3072 RUN_SWAP=412
run_drainer_fg e2e
check "(e2e) DARWIN: …and MAX_MEM_PRESSURE_LEVEL=4 lets that same WARNING through (seam honoured)" \
  '[ "$LAST_RC" -eq 0 ] && [ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -ge 1 ]' \
  "rc=$LAST_RC dispatched=$(dispatched "$LAST_AI/logs/ai-drainer.log")"
# An out-of-range threshold must not silently disable the arm, and the LOW end is the dangerous one: an
# accepted `1` would be "refuse at NORMAL pressure", i.e. a permanently closed gate that exits 0 — the
# exact latch this change removes. Both ends fall back to the shipped default and say so.
RUN_DRAINER_OS=Darwin RUN_PRESSURE=4 RUN_MAX_PRESSURE=9 RUN_TARGET=2 RUN_SWAP_TOTAL=3072 RUN_SWAP=412
run_drainer_fg e2f
check "(e2f) DARWIN: MAX_MEM_PRESSURE_LEVEL=9 (above critical) is REFUSED as a value, not obeyed" \
  '[ "$LAST_RC" -eq 0 ] && [ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 0 ] && grep -q "MAX_MEM_PRESSURE_LEVEL=.9. is not a threshold this arm can refuse at" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep -E "WARN|SKIP" "$LAST_AI/logs/ai-drainer.log" | head -2 | tr '\n' ' ')"
# ⛔ THE LOW END IS THE ONE THAT MATTERS: `1` is the kernel's NORMAL level, so accepting it would refuse
# every box for ever while exiting 0. It must be rejected LOUDLY and the gate must still open.
RUN_DRAINER_OS=Darwin RUN_PRESSURE=1 RUN_MAX_PRESSURE=1 RUN_TARGET=2 RUN_SWAP_TOTAL=3072 RUN_SWAP=412
run_drainer_fg e2f2
check "(e2f2) DARWIN: MAX_MEM_PRESSURE_LEVEL=1 is REJECTED (it would refuse every box) — the gate still opens" \
  '[ "$LAST_RC" -eq 0 ] && [ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -ge 1 ] && grep -q "MAX_MEM_PRESSURE_LEVEL=.1. is not a threshold this arm can refuse at" "$LAST_AI/logs/ai-drainer.log"' \
  "rc=$LAST_RC dispatched=$(dispatched "$LAST_AI/logs/ai-drainer.log") · $(grep -E "WARN" "$LAST_AI/logs/ai-drainer.log" | head -1)"
# …and the same seam value on a box that IS critical must still refuse: rejecting the VALUE must not
# have disabled the arm (the ordered reading: the value fell back to 2, the level did the refusing).
RUN_DRAINER_OS=Darwin RUN_PRESSURE=4 RUN_MAX_PRESSURE=1 RUN_TARGET=2 RUN_SWAP_TOTAL=3072 RUN_SWAP=412
run_drainer_fg e2f3
check "(e2f3) DARWIN: …and a REJECTED threshold still leaves a CRITICAL box refused" \
  '[ "$LAST_RC" -eq 0 ] && [ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 0 ] && grep -q "SKIP: memory pressure critical .* >= 2 " "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep -E "SKIP" "$LAST_AI/logs/ai-drainer.log" | head -1)"

reset_run
# ── (e2g) THE DARWIN ARM FAILS CLOSED WHEN ITS SIGNAL IS UNREADABLE ─────────────────────────
# A swap floor cannot stand in for the pressure level (that is the whole defect), so an unreadable
# level is NOT a skip and NOT an OK: it fails the tick and names itself.
RUN_DRAINER_OS=Darwin RUN_PRESSURE=unreadable RUN_TARGET=2 RUN_SWAP_TOTAL=3072 RUN_SWAP=412
run_drainer_fg e2g
check "(e2g) DARWIN: an unreadable pressure read FAILS the tick (no swap-floor fallback)" \
  '[ "$LAST_RC" -ne 0 ] && grep -q "memory pressure could not be read on this Darwin box" "$LAST_AI/logs/ai-drainer.log" && ! grep -q "DISPATCHED:" "$LAST_AI/logs/ai-drainer.log"' \
  "rc=$LAST_RC · $(grep -E "FAIL" "$LAST_AI/logs/ai-drainer.log" | head -1)"

reset_run
# ── (e3) AN UNREADABLE PROBE FAILS CLOSED ───────────────────────────────────────────────────
# Not a skip and not an OK: a probe that cannot answer must not look like an idle box.
RUN_SWAP=unreadable
run_drainer_fg e3
check "(e3) an unreadable swap read FAILS the tick" '[ "$LAST_RC" -ne 0 ]' "rc=$LAST_RC"
check "(e3) …and says why, instead of skipping" \
  'grep -q "swap could not be read" "$LAST_AI/logs/ai-drainer.log"' "$(cat "$LAST_AI/logs/ai-drainer.log" 2>/dev/null | tr '\n' ' ')"
RUN_MEM=unreadable
run_drainer_fg e3b
check "(e3) an unreadable MEMORY read FAILS the tick" \
  '[ "$LAST_RC" -ne 0 ] && grep -q "available memory could not be read" "$LAST_AI/logs/ai-drainer.log"' "rc=$LAST_RC"

reset_run
# ── (e3c) THE LINUX PROBES (the branch every CELL runs) ─────────────────────────────────────
# The cell is the box this job exists for, and its /proc parse is not what a macOS developer box
# executes. A fixture meminfo drives it here: MemAvailable 2048MB, SwapTotal 0 (a cell has NO swap).
reset_run
MEMINFO_FIX="$ROOT/meminfo"; cat >"$MEMINFO_FIX" <<'MI_EOF'
MemTotal:        8192000 kB
MemFree:          204800 kB
MemAvailable:    2097152 kB
Cached:           409600 kB
SwapTotal:             0 kB
SwapFree:              0 kB
MI_EOF
o="$ROOT/o-e3c"; ai="$ROOT/ai-e3c"; mkdir -p "$o/bg" "$ai"
O="$o" AI="$ai" DISPATCH="$DISPATCH" SEED_REPO="$SEED" SEED_REF="$SEED_REF" \
  PROC_MEMINFO="$MEMINFO_FIX" WT_MOD="$ROOT/no-such-worker-terminal.sh" TARGET_LANES=2 \
  NCPU=4 LOAD1_100=100 LANE_TIMEOUT=60 RC_GRACE_S=1 FAKE_LANE_SECS=0 \
  bash "$DRAINER" >/dev/null 2>&1; rc=$?
check "(e3c) a Linux /proc/meminfo fixture parses: MemAvailable 2048MB read, SwapTotal 0 = NO swap" \
  '[ "$rc" -eq 0 ] && grep -q "alive=0 .* swap=none" "$ai/logs/ai-drainer.log" && grep -q "dispatching 2 " "$ai/logs/ai-drainer.log"' \
  "rc=$rc · $(grep "START:" "$ai/logs/ai-drainer.log" 2>/dev/null | head -1)"
# The same fixture WITH swap: the pair is read from the same file, so the floor sees a real total.
sed 's/^SwapTotal:             0 kB/SwapTotal:         4096000 kB/; s/^SwapFree:              0 kB/SwapFree:           102400 kB/' \
  "$MEMINFO_FIX" >"$ROOT/meminfo-swap"
o="$ROOT/o-e3d"; ai="$ROOT/ai-e3d"; mkdir -p "$o/bg" "$ai"
O="$o" AI="$ai" DISPATCH="$DISPATCH" SEED_REPO="$SEED" SEED_REF="$SEED_REF" \
  PROC_MEMINFO="$ROOT/meminfo-swap" WT_MOD="$ROOT/no-such-worker-terminal.sh" TARGET_LANES=2 \
  NCPU=4 LOAD1_100=100 LANE_TIMEOUT=60 RC_GRACE_S=1 FAKE_LANE_SECS=0 \
  bash "$DRAINER" >/dev/null 2>&1; rc=$?
check "(e3d) the same file WITH swap 100MB of 4000MB → the floor applies and the tick SKIPS" \
  '[ "$rc" -eq 0 ] && grep -q "SKIP: swap 100MB < 700MB floor (of 4000MB)" "$ai/logs/ai-drainer.log"' \
  "rc=$rc · $(grep -E "SKIP|START" "$ai/logs/ai-drainer.log" 2>/dev/null | head -1)"

reset_run
# ── (e4) THE MEMORY CEILING STILL BINDS (the bound that may not be removed) ─────────────────
# 600MB available, 512MB floor → an 88MB pool → zero lanes at any LANE_MEM_MB ≥ 88.
RUN_MEM=600 RUN_NCPU=8 RUN_TARGET=
run_drainer_fg e4
check "(e4) a box below its memory floor dispatches NOTHING (mem bound intact)" \
  '[ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 0 ] && [ "$LAST_RC" -eq 0 ]' \
  "rc=$LAST_RC dispatched=$(dispatched "$LAST_AI/logs/ai-drainer.log")"
check "(e4) …and names the memory ceiling in the reasoning" \
  'grep -q "mem=0 from mem_avail=600MB" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep "nothing to add" "$LAST_AI/logs/ai-drainer.log" | head -1)"

reset_run
# ── (e5) THE CPU CEILING IS DERIVED FROM CORES (2.5 × cores, the fleet's recorded ruling) ───
# 4 cores → 10; the slice clamp then holds it to 7 distinct windows (SLICE_TOTAL/SLICE_WIDTH), so
# two lanes never work the same PRs. Both numbers are asserted, in the same line.
RUN_NCPU=4 RUN_MEM=8192 RUN_TARGET= RUN_SLICE_TOTAL=70 RUN_SLICE_WIDTH=10
run_drainer_fg e5
check "(e5) 4 cores → cpu ceiling 10, clamped to the 7 distinct slices" \
  'grep -q "target=10 (cpu=10 mem=" "$LAST_AI/logs/ai-drainer.log" && grep -q "dispatching 7 " "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep "START:" "$LAST_AI/logs/ai-drainer.log" | head -1)"
check "(e5) …and the clamp is STATED, not silent" \
  'grep -q "exceeds the 7 distinct slice(s)" "$LAST_AI/logs/ai-drainer.log"'

reset_run
# ── (e6) THE MEMORY TERM BINDS WHEN IT IS SMALLER THAN THE CPU TERM ─────────────────────────
# 8 cores → cpu 20; 2000MB → pool 1488 → usable 1116 → 2 lanes of 512MB. Memory wins: target=2.
RUN_NCPU=8 RUN_MEM=2000 RUN_TARGET=
run_drainer_fg e6
check "(e6) 8 cores / 2000MB → target 2 (memory binds, not cores)" \
  'grep -q "target=2 (cpu=20 mem=2" "$LAST_AI/logs/ai-drainer.log" && [ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 2 ]' \
  "$(grep "START:" "$LAST_AI/logs/ai-drainer.log" | head -1) dispatched=$(dispatched "$LAST_AI/logs/ai-drainer.log")"

reset_run
# ── (e7) THE LOAD ARM REFUSES TO ADD WORK TO A SATURATED BOX (8 × cores) ────────────────────
RUN_NCPU=4 RUN_LOAD=3300 RUN_MEM=8192 RUN_TARGET=        # 33.00 load on 4 cores ≥ 8 × 4
run_drainer_fg e7
check "(e7) load ≥ 8×cores → nothing dispatched, and the line names the line" \
  '[ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 0 ] && grep -q "SKIP: load 33.00 >= 8x4 (32.00)" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep -E "SKIP" "$LAST_AI/logs/ai-drainer.log" | head -1)"
RUN_NCPU=4 RUN_LOAD=3100 RUN_TARGET=2                     # 31.00 < 32.00 → allowed
run_drainer_fg e7b
check "(e7) one notch under it (31.00 of 32.00) the tick DOES dispatch" \
  '[ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 2 ]' "dispatched=$(dispatched "$LAST_AI/logs/ai-drainer.log")"

reset_run
# ── ARM (f): THE CENSUS COUNTS THE LAUNCHER'S WORKERS TOO (durable terminals have no pidfile) ──
# The evidence census must come from the LAUNCHER (`wt_count`), not `pgrep` and not `tmux ls`: a
# durable-terminal worker's tree hangs off the daemon, so no pidfile here names it and no process
# pattern finds it. `worker-terminal.sh` is stubbed with a controlled count, which is the only way to
# assert the union deterministically.
STUB="$ROOT/stubwt"; mkdir -p "$STUB"
# The clamp's PROBE is pinned from here on, for every arm that asserts a launcher count: an arm that
# let the real `ps` answer would count the operator's own fleet (39 lane-shaped processes on this Mac)
# and would assert different things on a Mac than on a quiet cell.
fake_ps "$ROOT/ps-9" 9
cat >"$STUB/worker-terminal.sh" <<'WT_EOF'
WT_TREE_PY="stub"; WT_WS_PY="stub"
wt_table() { printf 'lane-1\talive\nlane-2\talive\n'; }
wt_count() { local n=0 p; for p in "$@"; do n=$((n + 2)); done; printf '%s\n' "${WT_CENSUS_N:-2}"; }
WT_EOF
RUN_WT_MOD="$STUB/worker-terminal.sh" RUN_PS="$ROOT/ps-9" RUN_TARGET=3
run_drainer_fg f
check "(f) 2 launcher workers + target 3 → 1 dispatched, and the START line attributes the count" \
  '[ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 1 ] && grep -q "alive=2 (dispatcher=0 launcher=2)" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep "START:" "$LAST_AI/logs/ai-drainer.log" | head -1)"
# A STALE module (verbs present, embedded python empty) must not read as "no workers" — that is the
# measured macOS bash-3.2 mis-parse, and on this path it silently over-dispatches.
cat >"$STUB/worker-terminal.sh" <<'WT_EOF'
WT_TREE_PY=""; WT_WS_PY=""
wt_table() { printf ''; }
wt_count() { printf '0\n'; }
WT_EOF
run_drainer_fg f2
check "(f) a STALE worker-terminal.sh is NAMED, and the census degrades to the dispatcher's" \
  'grep -q "launcher census unavailable: .*stale" "$LAST_AI/logs/ai-drainer.log" && grep -q "alive=0 (dispatcher=0" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep "START:" "$LAST_AI/logs/ai-drainer.log" | head -1)"

reset_run
# ── ARM (s): THE LAUNCHER CENSUS IS A BOUND, NOT A COUNT (agent-infra#3882) ────────────────
# ⛔ THE MEASURED DEFECT. On pi-cell-3 (2026-11-10) a tick printed
# `SKIP: nothing to add — alive=36 (dispatcher=2 launcher=34)` while the SAME box held **9** live `pi`
# processes, 25 GB RAM free and 0 OOM kills. `wt_count` counts cmux `terminals[].running` — "a shell is
# running in that terminal", i.e. UI liveness — so a `wt-*` terminal whose `pi` has exited counts as a
# live lane for ever, `target − alive ≈ 0`, and the tick stands down with exit 0 and a message that
# looks healthy. The clamp is `min(wt_count, live lane processes)` and it is LOUD when it fires.
# The numbers below are the issue's own fixture values, not invented ones.
cat >"$STUB/worker-terminal.sh" <<'WT_EOF'
WT_TREE_PY="stub"; WT_WS_PY="stub"
wt_table() { printf 'lane-1\talive\nlane-2\talive\n'; }
wt_count() { printf '34\n'; }
WT_EOF
fake_ps "$ROOT/ps-9" 9
RUN_WT_MOD="$STUB/worker-terminal.sh" RUN_PS="$ROOT/ps-9" RUN_TARGET=10
run_drainer_fg s
check "(s) 34 terminal rows + 9 lane processes → the census is CLAMPED to 9" \
  'grep -q "alive=9 (dispatcher=0 launcher=9)" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep "START:" "$LAST_AI/logs/ai-drainer.log" | head -1)"
check "(s) …and it DISPATCHES into the capacity the phantom terminals were hiding" \
  '[ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 1 ]' "dispatched=$(dispatched "$LAST_AI/logs/ai-drainer.log")"
check "(s) …and the drift is LOUD, on its OWN line (the issue's indicator 3)" \
  'grep -q "census-mismatch launcher=34 pi=9 clamped=9 disp=0" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep -c "census-mismatch" "$LAST_AI/logs/ai-drainer.log" 2>/dev/null) mismatch line(s)"
# ⛔ THE "SEPARATE FROM alive=" ASSERTION THAT LIVED HERE IS DELETED (#3886 review, P2-2), not reworded:
# `! grep -q "alive=[0-9]* .*census-mismatch"` PASSED on the PRE-FIX code and no mutation of this diff
# could redden it — `log_line` writes its own timestamped line and the `alive=` builder is unchanged, so
# the two can never merge. The positive assertion directly above is the whole claim (if the line is
# missing, it fails), so the dead one only told the next reader indicator 3 was covered twice.

reset_run
# ── (s2) A CENSUS THAT IS RIGHT SAYS NOTHING (no noise on the healthy path) ────────────────────
cat >"$STUB/worker-terminal.sh" <<'WT_EOF'
WT_TREE_PY="stub"; WT_WS_PY="stub"
wt_table() { printf 'lane-1\talive\n'; }
wt_count() { printf '9\n'; }
WT_EOF
RUN_WT_MOD="$STUB/worker-terminal.sh" RUN_PS="$ROOT/ps-9" RUN_TARGET=9
run_drainer_fg s2
check "(s2) 9 terminal rows vs 9 lane processes → counted as 9, and NO mismatch line" \
  'grep -q "alive=9 (dispatcher=0 launcher=9)" "$LAST_AI/logs/ai-drainer.log" && ! grep -q "census-mismatch" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep -E "alive=|census-mismatch" "$LAST_AI/logs/ai-drainer.log" | head -2 | tr '\n' ' ')"

reset_run
# ── (s3) ⛔ THE MOST IMPORTANT ARM: AN UNREADABLE PROCESS COUNT NEVER CLAMPS ──────────────────
# This file's own polarity (`_census_dispatcher`: "AN UNREADABLE COMMAND LINE IS ALIVE") is that
# UNKNOWN IS ALIVE, and the census is now the only thing bounding the lane total. So a `ps` that cannot
# answer must leave `wt_count` intact: clamping to 0 here would read "the box is empty" from a reading
# that never happened — the OVER-DISPATCH direction, which is the expensive one. BOTH failure shapes are
# asserted, because a `ps` that prints NOTHING and exits 0 is the one that looks like success.
cat >"$STUB/worker-terminal.sh" <<'WT_EOF'
WT_TREE_PY="stub"; WT_WS_PY="stub"
wt_table() { printf 'lane-1\talive\n'; }
wt_count() { printf '34\n'; }
WT_EOF
fake_ps "$ROOT/ps-empty" empty
RUN_WT_MOD="$STUB/worker-terminal.sh" RUN_PS="$ROOT/ps-empty" RUN_TARGET=10
run_drainer_fg s3
check "(s3) a ps that SUCCEEDS with no output → the census stays 34 (NOT clamped to 0)" \
  'grep -q "alive=34 (dispatcher=0 launcher=34)" "$LAST_AI/logs/ai-drainer.log" && ! grep -q "census-mismatch" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep -E "alive=|census-mismatch" "$LAST_AI/logs/ai-drainer.log" | head -1)"
check "(s3) …and with 34 counted against target 10 the tick dispatches NOTHING, exit 0" \
  '[ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 0 ] && [ "$LAST_RC" -eq 0 ]' \
  "rc=$LAST_RC dispatched=$(dispatched "$LAST_AI/logs/ai-drainer.log")"
fake_ps "$ROOT/ps-fail" fail
RUN_PS="$ROOT/ps-fail"
run_drainer_fg s3b
check "(s3) a ps that FAILS → the census still stays 34" \
  'grep -q "alive=34 (dispatcher=0 launcher=34)" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep -E "alive=" "$LAST_AI/logs/ai-drainer.log" | head -1)"

reset_run
# ── (s4) A GENUINELY IDLE BOX CLAMPS TO ZERO — the direction the fix exists for ──────────────
# If the clamp could not reach 0 it would be inert for the measured case one notch further (every
# terminal phantom, no lane alive at all), so 0 must be reachable. The fake `ps` population also holds
# the `case`-pattern mention line described above, which is why the expected reading is `pi=0` and not
# `pi=1`: a substring predicate counts it (measured on the operator's Mac 2026-11-11: 43 matches, 4 of
# them this shape, the same self-match lane.sh:88 records for `pgrep -f`), and this arm is what would go
# red if this predicate ever drifted back to substring matching.
fake_ps "$ROOT/ps-0" 0
RUN_WT_MOD="$STUB/worker-terminal.sh" RUN_PS="$ROOT/ps-0" RUN_TARGET=2
run_drainer_fg s4
check "(s4) 34 rows + zero lane processes → clamped to 0, and the box dispatches again" \
  'grep -q "alive=0 (dispatcher=0 launcher=0)" "$LAST_AI/logs/ai-drainer.log" && grep -q "census-mismatch launcher=34 pi=0 clamped=0" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep -E "alive=|census-mismatch" "$LAST_AI/logs/ai-drainer.log" | head -2 | tr '\n' ' ')"
check "(s4) …and a shell whose argv only NAMES a lane script is NOT counted as one" \
  'grep -q "pi=0 " "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep "census-mismatch" "$LAST_AI/logs/ai-drainer.log" | head -1)"

reset_run
# ── (s5) ⛔ THE TOKEN SPLIT MUST NOT PATHNAME-EXPAND (#3882 review, P3) ───────────────────────
# The split in `_is_lane_process` is UNQUOTED, so `for t in $c` GLOBS as well as splits. A process whose
# argv holds a wildcard (`bash -c 'rm -f *.log'`) had that token expanded against the drainer's CWD — and
# on the launchd path that CWD is `$O`, which holds `lane.sh` / `fix-one.sh`. So a wildcard could MATCH a
# lane script and inflate `procs`, holding the clamp inert exactly when someone is diagnosing the box.
# MEASURED before the `set -f` fix — with lane.sh + fix-one.sh + pi in the CWD:
#   _is_lane_process "bash -c echo *"   → COUNTED (the `*` expanded to lane.sh)
# This arm is what goes red if the globbing ever returns: the population is ONE command line whose only
# lane-ish text is a wildcard, from a CWD that holds three lane-shaped filenames, and the reading must
# be pi=0.
cat >"$STUB/worker-terminal.sh" <<'WT_EOF'
WT_TREE_PY="stub"; WT_WS_PY="stub"
wt_table() { printf 'lane-1\talive\n'; }
wt_count() { printf '34\n'; }
WT_EOF
mkdir -p "$ROOT/globby"
: >"$ROOT/globby/lane.sh"; : >"$ROOT/globby/fix-one.sh"; : >"$ROOT/globby/pi"
cat >"$ROOT/ps-glob" <<'PSG_EOF'
#!/usr/bin/env bash
case "$*" in *"-p "*) exec ps "$@" ;; esac
printf '%s\n' "1000 1 /bin/bash -c echo *"
PSG_EOF
chmod +x "$ROOT/ps-glob"
RUN_WT_MOD="$STUB/worker-terminal.sh" RUN_PS="$ROOT/ps-glob" RUN_CWD="$ROOT/globby" RUN_TARGET=2
run_drainer_fg s5
check "(s5) a WILDCARD in an argv is not expanded into a lane (CWD holds lane.sh, fix-one.sh, pi)" \
  'grep -q "census-mismatch launcher=34 pi=0 clamped=0" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep -E "alive=|census-mismatch" "$LAST_AI/logs/ai-drainer.log" | head -2 | tr '\n' ' ')"

reset_run
# ── (s6) ⛔ THE DISPATCHER CENSUS IS GLOB-FREE TOO (#3886 review round 3) ───────────────────
# `(s5)` covers `_is_lane_process` only: its `ps` stub feeds `_live_lane_processes` (the LAUNCHER
# clamp). `_counts_as_lane` — the DISPATCHER census — had the identical unguarded split, and MEASURED
# a mutation of exactly that guard left the whole suite green:
#   M1: `_counts_as_lane` guard+restore deleted → 109 passed, 0 failed  (invisible)
#   M2: `_is_lane_process` guard+restore deleted → 108 passed, 1 failed  ((s5), the control)
# This class had already shipped twice (#3882 → #3886) for want of an arm, so here is the arm: ONE live
# dispatcher pidfile whose `ps -p` answer is a wildcard, run from a CWD holding lane-shaped filenames.
# With the guard the census reads 0; without it the `*` expands to the file named `pi` and it reads 1.
o="$ROOT/o-s6"; ai="$ROOT/ai-s6"; mkdir -p "$o/bg" "$ai"
plant_lane s6 1 >/dev/null
cat >"$STUB/worker-terminal.sh" <<'WT_EOF'
WT_TREE_PY="stub"; WT_WS_PY="stub"
wt_table() { printf 'lane-1\talive\n'; }
wt_count() { printf '0\n'; }
WT_EOF
cat >"$ROOT/ps-disp" <<'PSD_EOF'
#!/usr/bin/env bash
case "$*" in
  *"-p "*) printf '%s\n' "/bin/bash -c echo *" ;;   # the argv the dispatcher census will test
  *)       : ;;                                      # `-A`: no lane-shaped processes for the clamp
esac
PSD_EOF
chmod +x "$ROOT/ps-disp"
RUN_WT_MOD="$STUB/worker-terminal.sh" RUN_PS="$ROOT/ps-disp" RUN_CWD="$ROOT/globby" RUN_TARGET=2
run_drainer_fg s6
check "(s6) the DISPATCHER census does not expand a wildcard into a lane either" \
  'grep -q "alive=0 (dispatcher=0 launcher=0)" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep -E "alive=" "$LAST_AI/logs/ai-drainer.log" | head -1)"

reset_run
# ── (s7) ⛔ THE TWO POPULATIONS COMPOSED: NO LANE IS COUNTED TWICE (#3886 review, P2-1) ─────────
# Every arm above runs with `dispatcher=0` (no live pidfile), and the only one WITH a live pidfile —
# `(s6)` — has `wt_count=0`. So the shipped arithmetic `alive = disp_alive + min(wt_count, procs)` was
# never exercised with both terms non-zero, and it counted each live dispatcher lane TWICE: once in
# `disp_alive`, and again in `procs` (the SAME `bash …/nonblocking-dispatch.sh` subshell). The safe
# direction is over-count, but over-count STANDS THE TICK DOWN — on a cell (MAX_LANES = 2.5 × 4 = 10)
# `disp_alive=2` + `procs=9` ⇒ `alive=11 > 10` with a slot free, which is the exact failure #3882 exists
# to end, one term smaller. `census-mismatch` could not reveal it: its `pi=` was truthful, the SUM was not.
# Here: 1 live dispatcher lane, 34 terminal rows, 3 lane-shaped processes (the planted lane's own argv +
# 2 real launcher lanes). Disjoint arithmetic ⇒ launcher = min(34, 3 − 1) = 2, alive = 1 + 2 = 3 ⇒ one
# of a 4-target dispatched. The pre-fix code reads alive = 1 + min(34, 3) = 4 ⇒ dispatched 0: the mutant
# of this fix reddens exactly these rows.
o="$ROOT/o-s7"; ai="$ROOT/ai-s7"; mkdir -p "$o/bg" "$ai"
plant_lane s7 1 >/dev/null
cat >"$STUB/worker-terminal.sh" <<'WT_EOF'
WT_TREE_PY="stub"; WT_WS_PY="stub"
wt_table() { printf 'lane-1\talive\n'; }
wt_count() { printf '34\n'; }
WT_EOF
# `-p` delegates to the REAL ps (the planted lane is a real process, and the dispatcher census reads its
# argv); `-A` is the injected population, and it CONTAINS that lane's argv — which is the whole point.
cat >"$ROOT/ps-composed" <<PSC_EOF
#!/usr/bin/env bash
case "\$*" in *"-p "*) exec ps "\$@" ;; esac
printf '%s\n' "1000 1 bash $ROOT/nonblocking-dispatch.sh 60 0 /dev/null"
printf '%s\n' "1001 1 /usr/local/bin/pi -p --provider deepseek --model deepseek-flash brief-0"
printf '%s\n' "1002 1 /usr/local/bin/pi -p --provider deepseek --model deepseek-flash brief-1"
PSC_EOF
chmod +x "$ROOT/ps-composed"
RUN_WT_MOD="$STUB/worker-terminal.sh" RUN_PS="$ROOT/ps-composed" RUN_TARGET=4
run_drainer_fg s7
check "(s7) a live dispatcher lane is NOT counted twice: alive=3, not 4" \
  'grep -q "alive=3 (dispatcher=1 launcher=2)" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep "START:" "$LAST_AI/logs/ai-drainer.log" | head -1)"
check "(s7) …so the tick DISPATCHES into the slot the double count was hiding" \
  '[ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 1 ]' "dispatched=$(dispatched "$LAST_AI/logs/ai-drainer.log")"
check "(s7) …and the mismatch line carries the overlap, so pi= is not read as the launcher's share" \
  'grep -q "census-mismatch launcher=34 pi=3 clamped=2 disp=1" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep "census-mismatch" "$LAST_AI/logs/ai-drainer.log" | head -1)"

reset_run
# ── (s7b) ONE PROCESS NAMED BY TWO PIDFILES IS ONE LANE ────────────────────────────────────────
# The overlap in `(s7)` is SUBTRACTED from the launcher's process count, so a process counted twice
# under the dispatcher's name would remove two processes `procs` held once — an under-read of the
# launcher's share, i.e. the over-dispatch direction. `(s7)` cannot see that (its overlap is 1 either
# way and the totals coincidentally agree), so here is the arm that can: the SAME pid in two pidfiles,
# `wt_count=0` so `alive` IS the dispatcher count. Deduped ⇒ 1. Without the dedupe ⇒ 2.
o="$ROOT/o-s7b"; ai="$ROOT/ai-s7b"; mkdir -p "$o/bg" "$ai"
# ⛔ `plant_lane` OUTSIDE a `$(…)` here. Called inside one, its backgrounded lane inherits the command
# substitution's pipe and does not survive it — MEASURED: the pidfile was written but the pid was already
# gone by the time the drainer censused (dispatcher=0, and the arm failed for a reason unrelated to itself).
plant_lane s7b 1 >/dev/null
p7="$(cat "$o/bg/seed-lane-1.pid")"
printf '%s' "$p7" >"$o/bg/seed-lane-2.pid"
cat >"$STUB/worker-terminal.sh" <<'WT_EOF'
WT_TREE_PY="stub"; WT_WS_PY="stub"
wt_table() { printf 'lane-1\talive\n'; }
wt_count() { printf '0\n'; }
WT_EOF
RUN_WT_MOD="$STUB/worker-terminal.sh" RUN_PS="$ROOT/ps-composed" RUN_TARGET=2
run_drainer_fg s7b
check "(s7b) two pidfiles naming ONE pid count as ONE dispatcher lane" \
  'grep -q "alive=1 (dispatcher=1 launcher=0)" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep "START:" "$LAST_AI/logs/ai-drainer.log" | head -1)"

reset_run
# ── (s9) ⛔ THE OVERLAP USES THE PREDICATE THAT COUNTED THE LANE (round 5, P2) ────────────────
# The overlap is the INTERSECTION of "in `disp_alive`" and "inside `procs`", so it must be measured with
# `_counts_as_lane` — the narrower rule that actually added the lane to `n`. Measured with the broader
# `_is_lane_process`, a pidfile lane whose argv only THAT rule accepts (`./pi -p x`: `_counts_as_lane`=N
# because it only takes a bare `pi` or an absolute-path basename; `_is_lane_process`=Y) was SUBTRACTED
# from `procs` and added to nothing — one live lane in NEITHER half, so `alive` read one lane too low and
# the tick dispatched into a full box. Broad is the safe direction for a BOUND, never for a SUBTRACTION.
o="$ROOT/o-s9"; ai="$ROOT/ai-s9"; mkdir -p "$o/bg" "$ai"
# a real process whose argv[0] is `./pi` (so `_counts_as_lane` rejects it and `_is_lane_process` takes it)
/bin/bash -c 'exec -a ./pi sleep 60' &
p9=$!
echo "$p9" >>"$ROOT/pids"
printf '%s' "$p9" >"$o/bg/seed-lane-1.pid"
rows_s9="$ROOT/rows-s9"
{ printf '%s 1 ./pi -p x\n' "$p9"
  printf '200 1 /usr/local/bin/pi -p --provider deepseek brief-0\n'
  printf '201 1 /usr/local/bin/pi -p --provider deepseek brief-1\n'; } >"$rows_s9"
cat >"$ROOT/ps-s9" <<PSS_EOF
#!/usr/bin/env bash
case "\$*" in *"-p "*) exec ps "\$@" ;; esac
cat "$rows_s9" 2>/dev/null || exit 0
PSS_EOF
chmod +x "$ROOT/ps-s9"
cat >"$STUB/worker-terminal.sh" <<'WT_EOF'
WT_TREE_PY="stub"; WT_WS_PY="stub"
wt_table() { printf 'lane-1\talive\n'; }
wt_count() { printf '34\n'; }
WT_EOF
RUN_WT_MOD="$STUB/worker-terminal.sh" RUN_PS="$ROOT/ps-s9" RUN_TARGET=10
run_drainer_fg s9
check "(s9) a lane the dispatcher half REJECTS stays in the launcher's share — alive=3, not 2" \
  'grep -q "alive=3 (dispatcher=0 launcher=3)" "$ai/logs/ai-drainer.log"' \
  "$(grep -E "START:|SKIP:" "$ai/logs/ai-drainer.log" | head -1)"
check "(s9) …and it is NOT subtracted from procs, so no lane vanishes from both halves" \
  'grep -q "census-mismatch launcher=34 pi=3 clamped=3 disp=0" "$ai/logs/ai-drainer.log"' \
  "$(grep "census-mismatch" "$ai/logs/ai-drainer.log" | head -1)"

reset_run
# ── (s8b) ⛔ "ps PRODUCED OUTPUT" IS NOT "ps ANSWERED" (#3886 review round 4) ────────────────
# The root rule reads `ps -A -o pid=,ppid=,command=` and requires pid-prefixed rows, so a `ps` that
# prints its USAGE TEXT to stdout and exits 0 is UNREADABLE, not "a table with no lane in it" — the
# difference between `wt_count` standing and the census clamping to 0, i.e. the over-dispatch direction.
# `(s8)` covers the parent test and nothing covered this guard: deleting it left the suite green
# (MEASURED), which is why the doc and the code disagreed about this exact shape until now.
cat >"$STUB/worker-terminal.sh" <<'WT_EOF'
WT_TREE_PY="stub"; WT_WS_PY="stub"
wt_table() { printf 'lane-1\talive\n'; }
wt_count() { printf '34\n'; }
WT_EOF
cat >"$ROOT/ps-usage" <<'PSU_EOF'
#!/usr/bin/env bash
case "$*" in *"-p "*) exec ps "$@" ;; esac
printf 'ps: illegal option -- A\nusage: ps [-AaCcEefhjlMmrSTvwXx]\n'
exit 0
PSU_EOF
chmod +x "$ROOT/ps-usage"
RUN_WT_MOD="$STUB/worker-terminal.sh" RUN_PS="$ROOT/ps-usage" RUN_TARGET=10
run_drainer_fg s8b
check "(s8b) a ps printing USAGE TEXT and exiting 0 is UNREADABLE — the census stays 34, not 0" \
  'grep -q "alive=34 (dispatcher=0 launcher=34)" "$LAST_AI/logs/ai-drainer.log" && ! grep -q "census-mismatch" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep -E "alive=|census-mismatch" "$LAST_AI/logs/ai-drainer.log" | head -1)"
check "(s8b) …so a phantom-full box dispatches NOTHING rather than clamping on a reading that never happened" \
  '[ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 0 ] && [ "$LAST_RC" -eq 0 ]' \
  "rc=$LAST_RC dispatched=$(dispatched "$LAST_AI/logs/ai-drainer.log")"

reset_run
# ── (s8) ⛔ A LANE IS NOT A PROCESS (#3886 review round 4, P2) ────────────────────────────────
# Every lane this box runs contributes more than one lane-shaped process: the `bash …/lane.sh` wrapper
# AND the `pi` it execs. Counting processes therefore read ~2× the lane count, so
# `share = procs − overlap` landed at ~2× the launcher's lanes — and an over-count STANDS THE TICK DOWN,
# which is precisely the argument (s7) was fixed with, at twice the size. MEASURED on a 9-lane table in
# that shape at target 10: `alive=18`, `SKIP: nothing to add`, one slot free — #3882's own symptom, with
# a `census-mismatch` line reporting `pi=18` truthfully while the reading was wrong.
# Here: 9 lanes, each as TWO lane-shaped rows (wrapper + its `pi` child, child's ppid = wrapper pid),
# 34 terminal rows, target 10. Roots ⇒ procs=9 ⇒ launcher=9 ⇒ one slot, and the tick dispatches it.
fake_ps "$ROOT/ps-pair" 9 pair
cat >"$STUB/worker-terminal.sh" <<'WT_EOF'
WT_TREE_PY="stub"; WT_WS_PY="stub"
wt_table() { printf 'lane-1\talive\n'; }
wt_count() { printf '34\n'; }
WT_EOF
RUN_WT_MOD="$STUB/worker-terminal.sh" RUN_PS="$ROOT/ps-pair" RUN_TARGET=10
run_drainer_fg s8
check "(s8) 9 lanes × 2 lane-shaped processes each → the census counts 9 LANES, not 18 processes" \
  'grep -q "census-mismatch launcher=34 pi=9 clamped=9 disp=0" "$LAST_AI/logs/ai-drainer.log"' \
  "$(grep "census-mismatch" "$LAST_AI/logs/ai-drainer.log" | head -1)"
check "(s8) …so the tick DISPATCHES into the slot the doubled count was hiding" \
  'grep -q "alive=9 (dispatcher=0 launcher=9)" "$LAST_AI/logs/ai-drainer.log" && [ "$(dispatched  "$LAST_AI/logs/ai-drainer.log")" -eq 1 ]' \
  "$(grep "START:" "$LAST_AI/logs/ai-drainer.log" | head -1) dispatched=$(dispatched "$LAST_AI/logs/ai-drainer.log")"

reset_run
# ── ARM (g): THE VERDICT — a lane's own exit status, settled by the NEXT tick ────────────────
FAKE_LANE_SECS=0 FAKE_RC=0 RUN_TARGET=1
run_drainer_fg g
sleep 0.5
run_drainer_fg g                       # same state dir: settles the lane the first tick started
check "(g) a lane that finished rc=0 is reported DONE, and the settling tick exits 0" \
  '[ "$LAST_RC" -eq 0 ] && grep -q "DONE: lane ai-drain-.* finished rc=0" "$LAST_AI/logs/ai-drainer.log"' \
  "rc=$LAST_RC · $(grep -E "DONE|FAIL" "$LAST_AI/logs/ai-drainer.log" | tail -1)"
check "(g) …and its worktree was removed once its pid was gone" \
  '[ "$(ls -d "$LAST_AI"/wt-drainer-ai-drain-* 2>/dev/null | grep -vc "\.lane-pid$")" -eq 0 ]' \
  "$(ls -d "$LAST_AI"/wt-drainer-ai-drain* 2>/dev/null | wc -l | tr -d " ")"
FAKE_RC=3
run_drainer_fg g
sleep 0.5
run_drainer_fg g
check "(g) a lane that REFUSED (rc=3) makes the settling tick FAIL and names it" \
  '[ "$LAST_RC" -ne 0 ] && grep -q "exited 3" "$LAST_AI/logs/ai-drainer.log"' "rc=$LAST_RC"
check "(g) a settled record is reported EXACTLY ONCE (the record is deleted)" \
  '[ "$(grep -c "exited 3" "$LAST_AI/logs/ai-drainer.log")" -eq 1 ]' \
  "mentions=$(grep -c "exited 3" "$LAST_AI/logs/ai-drainer.log")"
FAKE_RC=0 FAKE_NO_PIDFILE=1
run_drainer_fg g
check "(g) a dispatcher that returns with NO pidfile makes the tick FAIL" \
  '[ "$LAST_RC" -ne 0 ] && grep -q "missing or unreadable" "$LAST_AI/logs/ai-drainer.log"' "rc=$LAST_RC"
FAKE_NO_PIDFILE=0

reset_run
# ── ARM (h): a dispatcher with no status file is a WARN, not a fabricated verdict ───────────
# The older overlay `bg-dispatch.sh` — this script's FIRST preference, and the dispatcher in use on the
# box tonight — writes `<name>.pid` and `<name>.log` and no `.rc` at all. Demanding one turned every
# healthy lane into FAIL: a permanent false red on the one health screen.
NORC="$ROOT/dispatch-norc.sh"
cat >"$NORC" <<'NORC_EOF'
#!/usr/bin/env bash
set -u
NAME="$1"; O="${O:?}"; D="$O/bg"; mkdir -p "$D"
( sleep 0 ) &
echo "$!" > "$D/$NAME.pid"
exit 0
NORC_EOF
chmod +x "$NORC"
o="$ROOT/o-h"; ai="$ROOT/ai-h"; mkdir -p "$o/bg" "$ai"
_dr_h() { O="$o" AI="$ai" DISPATCH="$NORC" SEED_REPO="$SEED" SEED_REF="$SEED_REF" \
  NCPU=4 MEM_AVAIL_MB=8192 LOAD1_100=100 SWAP_TOTAL_MB=9999 SWAP_FREE_MB=9999 \
  WT_MOD="$ROOT/no-such-worker-terminal.sh" TARGET_LANES=1 LANE_TIMEOUT=60 SLICE_WIDTH=10 \
  SLICE_TOTAL=70 RC_GRACE_S=1 bash "$DRAINER" >/dev/null 2>&1; echo $?; }
rc="$(_dr_h)"; sleep 0.5; rc2="$(_dr_h)"
check "(h) a dispatcher with no status file: the settling tick exits 0 and NAMES the gap" \
  '[ "$rc2" -eq 0 ] && grep -q "records no exit status" "$ai/logs/ai-drainer.log"' "rc=$rc rc2=$rc2"
check "(h) …and it does not claim DONE for it" '! grep -q "DONE: lane" "$ai/logs/ai-drainer.log"'

reset_run
# ── ARM (i): the leftover reaper must not eat a LIVE lane's checkout, and must not guess ────
# The measured defect it replaces: a worktree's name carried the TICK's pid, which is dead the moment
# the tick exits, so the next tick removed a live lane's checkout with its uncommitted work.
o="$ROOT/o-i"; ai="$ROOT/ai-i"; mkdir -p "$o/bg" "$ai/state" "$ai/wt-drainer-ai-drain-999999-1-1"
bash "$ROOT/nonblocking-dispatch.sh" 60 0 /dev/null & live_p=$!
echo "$live_p" >>"$ROOT/pids"
printf '%s' "$live_p" >"$ai/wt-drainer-ai-drain-999999-1-1.lane-pid"
mkdir -p "$ai/wt-drainer-ai-drain-999999-2-1"                 # UNKNOWN: no sidecar at all
RUN_TARGET=1 run_drainer_fg i
check "(i) a LIVE lane's leftover worktree is left alone" \
  '[ -d "$ai/wt-drainer-ai-drain-999999-1-1" ]' "tree gone"
check "(i) a tree with NO sidecar is UNKNOWN and left for an operator" \
  '[ -d "$ai/wt-drainer-ai-drain-999999-2-1" ]' "tree gone"
kill "$live_p" 2>/dev/null; wait "$live_p" 2>/dev/null; sleep 0.5   # reap it: `kill -0` is TRUE for a zombie
RUN_TARGET=1 run_drainer_fg i
check "(i) once its lane is gone the leftover IS reclaimed (the reaper is not inert either)" \
  '[ ! -d "$ai/wt-drainer-ai-drain-999999-1-1" ]' "tree still present"

reset_run
# ── ARM (j): the SLICE ROTATES ACROSS TICKS AND WRAPS ───────────────────────────────────────
RUN_TARGET=1 RUN_SLICE_WIDTH=10 RUN_SLICE_TOTAL=20
for i in 1 2 3; do
  run_drainer_fg d
  cp "$LAST_AI/state/drainer-brief.md" "$ROOT/brief-$i.md" 2>/dev/null
done
off() { sed -n 's/.*Start at PR offset \*\*\([0-9][0-9]*\)\*\*.*/\1/p' "$1" 2>/dev/null | head -1; }
check "(j) pass 1 starts at offset 0"  '[ "$(off "$ROOT/brief-1.md")" = "0" ]'  "$(off "$ROOT/brief-1.md")"
check "(j) pass 2 advances to offset 10" '[ "$(off "$ROOT/brief-2.md")" = "10" ]' "$(off "$ROOT/brief-2.md")"
check "(j) pass 3 WRAPS back to offset 0" '[ "$(off "$ROOT/brief-3.md")" = "0" ]' "$(off "$ROOT/brief-3.md")"

reset_run
# ── ARM (k): a non-numeric LANE_TIMEOUT must not disable the tick ───────────────────────────
# `LANE_TIMEOUT=30m` used to leave a derived bound unset (bash: "value too great for base") and the
# `set -u` read of it killed the tick mid-lock. The value is still validated, and the tick still runs.
RUN_TARGET=1 RUN_LANE_TIMEOUT=30m
run_drainer_fg k
check "(k) a non-numeric LANE_TIMEOUT still dispatches, and the bad value is reported" \
  '[ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 1 ] && grep -q "WARN: LANE_TIMEOUT=.*is not a whole number" "$LAST_AI/logs/ai-drainer.log"' \
  "dispatched=$(dispatched "$LAST_AI/logs/ai-drainer.log")"

reset_run
# ── ARM (n): THE GENERATED BRIEF PASSES THE DISPATCHER'S OWN GATE ───────────────────────────
# ⛔ THE BRIEF IS NOT PROSE, IT IS AN INPUT TO A GATE. `nonblocking-dispatch.sh` runs
# `brief-gate.sh --check <brief> worker` BEFORE the fork and exits 80 without a `## RESEARCH FIRST`
# section and a `CONTRADICTION TEST:` line (#2258). A brief without them is REFUSED at the dispatch
# path, so on any box using the versioned dispatcher every drainer lane would die with "dispatcher
# refused" and the top-up would never run — while a fake dispatcher in a test fixture happily accepts
# it. So the arm pipes the REAL generated brief through the REAL gate.
GATE="$HERE/brief-gate.sh"
RUN_TARGET=1 FAKE_LANE_SECS=0
run_drainer_fg n
brief_n="$(ls "$LAST_AI"/state/drainer-brief-ai-drain-*.md 2>/dev/null | head -1)"
if [ -f "$GATE" ]; then
  bash "$GATE" --check "$brief_n" worker >/dev/null 2>&1; grc=$?
  check "(n) the generated brief PASSES brief-gate.sh --check <brief> worker" '[ "$grc" -eq 0 ]' "gate rc=$grc on ${brief_n:-<no brief>}"
  # …and the arm is not vacuous: the same gate REFUSES a brief with the block stripped.
  sed '/RESEARCH FIRST/,$d' "$brief_n" >"$ROOT/brief-nogate.md" 2>/dev/null
  bash "$GATE" --check "$ROOT/brief-nogate.md" worker >/dev/null 2>&1; grc2=$?
  check "(n) non-vacuity: the same gate REFUSES the brief with the block stripped" '[ "$grc2" -ne 0 ]' "gate rc=$grc2"
else
  bad "(n) brief-gate.sh missing at $GATE"
fi

reset_run
# ── ARM (o): A LIVE LANE'S WINDOW IS NEVER REUSED BY A LATER TICK ───────────────────────────
# ⛔ THE DEFECT THIS ARM EXISTS FOR: the ring clamp bounds ONE tick's fan-out but not disjointness
# ACROSS ticks. A lane keeps its window for up to LANE_TIMEOUT (3000s ≈ 2.5 ticks), so with target 3
# and SLICE_TOTAL=30/SLICE_WIDTH=10 (3 windows), tick 2 walks the ring back to the offsets tick 1's
# still-running lanes hold and hands them to NEW lanes — two lanes per window, two reviews per head.
# ⛔ TARGET 6 ON A 3-WINDOW RING, ON PURPOSE: with target == 3 the second tick has nothing to add
# whether or not held windows are respected (`n = target − alive = 0`), so the arm would pass on the
# MUTATION too. Above the ring, a tick that ignored the held set would issue 3 more.
RUN_TARGET=6 FAKE_LANE_SECS=40 RUN_SLICE_WIDTH=10 RUN_SLICE_TOTAL=30
run_drainer_fg o
RUN_TARGET=6 FAKE_LANE_SECS=0
run_drainer_fg o                      # the lanes are STILL LIVE; the ring has no free window
check "(o) tick 1 took all 3 windows" \
  '[ "$(sed -n "s/.*slice-offset=\([0-9]*\).*/\1/p" "$LAST_AI/logs/ai-drainer.log" | sort -u | wc -l | tr -d " ")" -eq 3 ]' \
  "$(sed -n 's/.*slice-offset=\([0-9]*\).*/\1/p' "$LAST_AI/logs/ai-drainer.log" | tr '\n' ' ')"
check "(o) the next tick does NOT re-issue a window a LIVE lane holds" \
  '[ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 3 ] && grep -q "free_windows=0/3" "$LAST_AI/logs/ai-drainer.log"' \
  "dispatched=$(dispatched "$LAST_AI/logs/ai-drainer.log") — $(grep -E "SKIP|NOTE" "$LAST_AI/logs/ai-drainer.log" | tail -1)"

reset_run
# ── ARM (p): A SETTLED LANE'S FAILURE SURVIVES A SKIP (the false PASS) ──────────────────────
# ⛔ The at-target path is the NORMAL steady state, and it used to `exit 0` BEFORE the settle's verdict
# was read: a lane that exited 3 was logged FAIL and the unit still reported success.
o="$ROOT/o-p"; ai="$ROOT/ai-p"; mkdir -p "$o/bg" "$ai/state/lanes"
printf '999999' >"$ai/state/lanes/ai-drain-dead-1.pid"          # a dead lane's record
printf '10' >"$ai/state/lanes/ai-drain-dead-1.slice"
printf '3\n' >"$o/bg/ai-drain-dead-1.rc"                          # …that exited 3
RUN_TARGET=0 FAKE_LANE_SECS=0
run_drainer_fg p
check "(p) at target with a settled FAILURE the tick exits 1 (no false PASS)" \
  '[ "$LAST_RC" -ne 0 ] && grep -q "exited 3" "$ai/logs/ai-drainer.log" && grep -q "SKIP: nothing to add" "$ai/logs/ai-drainer.log"' \
  "rc=$LAST_RC · $(grep -E "exited 3|SKIP: nothing to add" "$ai/logs/ai-drainer.log" | tr '\n' ' ')"

reset_run
# ── ARM (q): AN UNREADABLE `ps` COUNTS A LANE AS ALIVE (the census is fail-closed) ──────────
# The census is the ONLY thing bounding the lane total now (the lock no longer is), so a pidfile whose
# command line cannot be read must count as a lane. `PS=/bin/false` is exactly "the probe cannot
# answer", which is what a missing `ps` under a unit's PATH, `hidepid`, or another uid looks like.
o="$ROOT/o-q"; ai="$ROOT/ai-q"; mkdir -p "$o/bg" "$ai"
bash "$ROOT/nonblocking-dispatch.sh" 60 0 /dev/null & q1=$!
bash "$ROOT/nonblocking-dispatch.sh" 60 0 /dev/null & q2=$!
echo "$q1" >>"$ROOT/pids"; echo "$q2" >>"$ROOT/pids"
printf '%s' "$q1" >"$o/bg/lane-a.pid"; printf '%s' "$q2" >"$o/bg/lane-b.pid"
RUN_TARGET=2 RUN_PS=/bin/false
run_drainer_fg q
check "(q) an unreadable command line counts as a LIVE lane (2 alive, target 2 → 0 added)" \
  '[ "$LAST_RC" -eq 0 ] && grep -q "alive=2 (dispatcher=2" "$ai/logs/ai-drainer.log" && [ "$(dispatched "$ai/logs/ai-drainer.log")" -eq 0 ]' \
  "$(grep -E "alive=|DISPATCHED" "$ai/logs/ai-drainer.log" | head -1)"
wait "$q1" "$q2" 2>/dev/null

# ── ARM (r): AN EMPTY LAUNCHER TABLE IS NOT "NO WORKERS" ────────────────────────────────────
# `wt_count` is `wt_table | awk … END{print n+0}`, so an aborted table prints a valid `0` — which the
# drainer would read as "no launcher workers" and dispatch on top of the live ones. The cross-check is
# the worker records this box has: an EMPTY table while records exist is a FAULT (fail closed); an
# empty table with no records is a genuinely empty box (dispatch normally, not a permanent red).
cat >"$STUB/worker-terminal.sh" <<'WT_EOF'
WT_TREE_PY="stub"; WT_WS_PY="stub"
wt_table() { printf ''; }
wt_count() { printf '0\n'; }
WT_EOF
RUN_WT_MOD="$STUB/worker-terminal.sh" RUN_TARGET=2
o="$ROOT/o-r"; ai="$ROOT/ai-r"; mkdir -p "$o/bg" "$o/state" "$ai"
printf '#!/bin/sh\n' >"$o/state/run-lane-1.sh"
run_drainer_fg r
check "(r) an EMPTY table with a worker record present FAILS the tick (never 0-alive)" \
  '[ "$LAST_RC" -ne 0 ] && [ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 0 ] \
     && grep -q "returned an EMPTY table" "$LAST_AI/logs/ai-drainer.log"' "rc=$LAST_RC"
rm -f "$o/state/run-lane-1.sh"
run_drainer_fg r
check "(r) …and an empty table with NO records still dispatches (not a permanent red)" \
  '[ "$LAST_RC" -eq 0 ] && [ "$(dispatched "$LAST_AI/logs/ai-drainer.log")" -eq 2 ]' \
  "rc=$LAST_RC dispatched=$(dispatched "$LAST_AI/logs/ai-drainer.log")"
RESET_BEFORE_R=1

reset_run
# ── ARM (l): TWO TICKS AT ONCE → ONE OF THEM DISPATCHES (the lock is still a lock) ──────────
# Without the lock, BOTH ticks compute `target − alive` from the same reading and each dispatches the
# full remainder — a double dispatch, which is what the old lane-lifetime lock was (wrongly) buying.
o="$ROOT/o-l"; ai="$ROOT/ai-l"; mkdir -p "$o/bg" "$ai"
FAKE_DISPATCH_SLEEP=2 FAKE_LANE_SECS=10 RUN_TARGET=3
( O="$o" AI="$ai" DISPATCH="$DISPATCH" SEED_REPO="$SEED" SEED_REF="$SEED_REF" \
  NCPU=4 MEM_AVAIL_MB=8192 LOAD1_100=100 SWAP_TOTAL_MB=9999 SWAP_FREE_MB=9999 \
  WT_MOD="$ROOT/no-such-worker-terminal.sh" TARGET_LANES=3 LANE_TIMEOUT=60 FAKE_DISPATCH_SLEEP=2 \
  FAKE_LANE_SECS=10 RC_GRACE_S=1 bash "$DRAINER" >/dev/null 2>&1 & echo "$!" >>"$ROOT/pids" )
wait_for_path "$ai/state/ai-drainer.lock" 60 || bad "(l) the first tick never took the lock"
O="$o" AI="$ai" DISPATCH="$DISPATCH" SEED_REPO="$SEED" SEED_REF="$SEED_REF" \
  NCPU=4 MEM_AVAIL_MB=8192 LOAD1_100=100 SWAP_TOTAL_MB=9999 SWAP_FREE_MB=9999 \
  WT_MOD="$ROOT/no-such-worker-terminal.sh" TARGET_LANES=3 LANE_TIMEOUT=60 FAKE_DISPATCH_SLEEP=2 \
  FAKE_LANE_SECS=10 RC_GRACE_S=1 bash "$DRAINER" >/dev/null 2>&1
check "(l) the second tick SKIPS on the lock" \
  'grep -q "SKIP: drainer already running" "$ai/logs/ai-drainer.log"' \
  "$(grep -E "SKIP|START" "$ai/logs/ai-drainer.log" | tr '\n' ' ')"
# Poll for the FIRST tick to finish its loop: it blocks FAKE_DISPATCH_SLEEP=2 per lane, so a fixed
# sleep would count a half-dispatched tick and report a top-up defect that is a fixture race.
i=0; while [ "$i" -lt 100 ]; do
  [ "$(dispatched "$ai/logs/ai-drainer.log")" -ge 3 ] && break
  sleep 0.3; i=$((i + 1))
done
sleep 1
check "(l) exactly ONE tick dispatched, and it dispatched the full target" \
  '[ "$(grep -c "START:" "$ai/logs/ai-drainer.log")" -eq 1 ] && [ "$(dispatched "$ai/logs/ai-drainer.log")" -eq 3 ]' \
  "starts=$(grep -c "START:" "$ai/logs/ai-drainer.log") dispatched=$(dispatched "$ai/logs/ai-drainer.log")"

reset_run
# ── ARM (m): THREE TICKS RACING OVER ONE STALE LOCK → STILL ONE DISPATCHING TICK ────────────
# The measured race: with `rm -rf "$LOCK"; mkdir "$LOCK"` BOTH contenders reclaim, B deletes A's fresh
# lock, and both dispatch. `mv` can only succeed once.
o="$ROOT/o-m2"; ai="$ROOT/ai-m2"; mkdir -p "$o/bg" "$ai/state"
mkdir -p "$ai/state/ai-drainer.lock"; printf '999999' >"$ai/state/ai-drainer.lock/pid"   # dead holder
: >"$ROOT/pids-m"
for i in 1 2 3; do
  ( O="$o" AI="$ai" DISPATCH="$DISPATCH" SEED_REPO="$SEED" SEED_REF="$SEED_REF" \
    NCPU=4 MEM_AVAIL_MB=8192 LOAD1_100=100 SWAP_TOTAL_MB=9999 SWAP_FREE_MB=9999 \
    WT_MOD="$ROOT/no-such-worker-terminal.sh" TARGET_LANES=2 LANE_TIMEOUT=60 \
    FAKE_LANE_SECS=90 RC_GRACE_S=1 bash "$DRAINER" >/dev/null 2>&1 & echo "$!" >>"$ROOT/pids-m" ) 2>/dev/null
done
i=0; while [ "$i" -lt 100 ]; do
  # ⛔ `grep -c` PRINTS `0` AND EXITS 1, so `|| echo 0` appended a SECOND `0` and the `[ … -ge 1 ]`
  # below died with "integer expression expected" — the loop then polled to its bound instead of
  # breaking early. Slow, not wrong, which is why it survived (#3882 review, pre-existing).
  n="$(grep -c 'START:' "$ai/logs/ai-drainer.log" 2>/dev/null)" || n=0
  [ "$n" -ge 1 ] && break
  sleep 0.2; i=$((i + 1))
done
# ⛔ WAIT FOR THE CONTENDERS TO EXIT, NOT FOR A FIXED WINDOW (review round 3). Each tick now also takes
# the fleet reading (a `git ls-remote`, a provider probe, an `awk` pass) before its guards, so a fixed
# `sleep 2` that was ample when a tick only probed the local box can close while a slow contender is
# still inside its guard — measured 1 red in 4 runs on this branch, 0 in 2 on the pre-change tree. The
# determinate event is EXIT; the bound only stops a hung tick from hanging the suite.
for pid in $(cat "$ROOT/pids-m" 2>/dev/null); do
  i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i + 1)); done
done
check "(m) three ticks racing over ONE stale lock dispatch from exactly ONE of them" \
  'n="$(grep -c "START:" "$ai/logs/ai-drainer.log" 2>/dev/null)" || n=0; [ "$n" -eq 1 ] && [ "$(dispatched "$ai/logs/ai-drainer.log")" -eq 2 ]' \
  "starts=$(grep -c 'START:' "$ai/logs/ai-drainer.log" 2>/dev/null) dispatched=$(dispatched "$ai/logs/ai-drainer.log")"

reset_run
# ── NON-VACUITY: remove the top-up loop (n=1) and arm (a) MUST fail ─────────────────────────
# The mutation is the DEFECT ITSELF — "one lane per tick" — injected at the shipped marker. If arm (a)
# still passed here, its three dispatched lanes would be proving nothing about top-up.
MUT="$ROOT/ai-drainer-oneshot.sh"
awk '/──8<── topup-loop/{print; print "n=1   # MUTATION: one lane per tick (the #2639 shape)"; next} {print}' \
  "$DRAINER" >"$MUT"
check "mutation: n=1 was injected at the topup-loop marker" \
  'grep -q "^n=1   # MUTATION" "$MUT" && [ -s "$MUT" ]'
RUN_TARGET=3 FAKE_LANE_SECS=10
run_drainer_fg mut "$MUT"
n_mut="$(dispatched "$LAST_AI/logs/ai-drainer.log")"
check "non-vacuity: with the top-up removed arm (a) FAILS (1 lane, not 3)" \
  '[ "${n_mut:-0}" -eq 1 ]' "dispatched=$n_mut (if this is 3, arm (a) is vacuous)"

# ── NON-VACUITY (HELD WINDOWS): ignore what LIVE lanes hold and arm (o) MUST fail ───────────
MUTH="$ROOT/ai-drainer-heldblind.sh"
python3 - "$DRAINER" "$MUTH" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = """  case "$held" in
    *" $off "*) : ;;                    # a live lane is working it — not this tick's to give
    *) FREE+=("$off") ;;
  esac"""
new = """  FREE+=("$off")   # MUTATION: held windows ignored"""
assert old in s, "the held-window skip is not in the shipped script"
open(dst, "w").write(s.replace(old, new))
PYEOF
check "mutation: the held-window skip was removed from the copy" \
  'grep -q "MUTATION: held windows ignored" "$MUTH"' 2>/dev/null
if [ -s "$MUTH" ]; then
  mo2="$ROOT/o-mh"; mai2="$ROOT/ai-mh"; mkdir -p "$mo2/bg" "$mai2"
  RUN_TARGET=6 FAKE_LANE_SECS=40 RUN_SLICE_WIDTH=10 RUN_SLICE_TOTAL=30
  ( O="$mo2" AI="$mai2" DISPATCH="$DISPATCH" SEED_REPO="$SEED" SEED_REF="$SEED_REF" \
    NCPU=4 MEM_AVAIL_MB=8192 LOAD1_100=100 SWAP_TOTAL_MB=9999 SWAP_FREE_MB=9999 \
    WT_MOD="$ROOT/no-such-worker-terminal.sh" TARGET_LANES=6 LANE_TIMEOUT=60 SLICE_WIDTH=10 \
    SLICE_TOTAL=30 FAKE_LANE_SECS=40 RC_GRACE_S=1 bash "$MUTH" >/dev/null 2>&1 )
  O="$mo2" AI="$mai2" DISPATCH="$DISPATCH" SEED_REPO="$SEED" SEED_REF="$SEED_REF" \
    NCPU=4 MEM_AVAIL_MB=8192 LOAD1_100=100 SWAP_TOTAL_MB=9999 SWAP_FREE_MB=9999 \
    WT_MOD="$ROOT/no-such-worker-terminal.sh" TARGET_LANES=6 LANE_TIMEOUT=60 SLICE_WIDTH=10 \
    SLICE_TOTAL=30 FAKE_LANE_SECS=0 RC_GRACE_S=1 bash "$MUTH" >/dev/null 2>&1
  check "non-vacuity: ignoring held windows re-issues them (so arm (o) can fail)" \
    '[ "$(dispatched "$mai2/logs/ai-drainer.log")" -ge 6 ]' \
    "dispatched=$(dispatched "$mai2/logs/ai-drainer.log") offsets=$(sed -n "s/.*slice-offset=\([0-9]*\).*/\1/p" "$mai2/logs/ai-drainer.log" | tr "\n" " ")"
  FAKE_LANE_SECS=0
else
  bad "non-vacuity(held): the mutation copy was not produced"
fi

# ── NON-VACUITY (LOCK): with the lock block deleted, TWO ticks dispatch ──────────────────────
# The companion of the top-up mutation: arm (l) says two ticks dispatch from one, so the same two ticks
# are re-run against a copy with the lock block removed and must then BOTH dispatch — otherwise arm (l)
# would pass whether or not the lock exists.
MUTL="$ROOT/ai-drainer-nolock.sh"
awk '/──8<── lock-guard/{skip=1} !skip{print} /──8<── \/lock-guard/{skip=0; print ""}' "$DRAINER" >"$MUTL"
check "mutation: the lock block was actually removed from the copy" \
  '! grep -q "_lock_claim()" "$MUTL" && [ -s "$MUTL" ]'
o="$ROOT/o-ml"; ai="$ROOT/ai-ml"; mkdir -p "$o/bg" "$ai"
FAKE_DISPATCH_SLEEP=2 FAKE_LANE_SECS=30
( O="$o" AI="$ai" DISPATCH="$DISPATCH" SEED_REPO="$SEED" SEED_REF="$SEED_REF" \
  NCPU=4 MEM_AVAIL_MB=8192 LOAD1_100=100 SWAP_TOTAL_MB=9999 SWAP_FREE_MB=9999 \
  WT_MOD="$ROOT/no-such-worker-terminal.sh" TARGET_LANES=1 LANE_TIMEOUT=60 \
  FAKE_DISPATCH_SLEEP=2 FAKE_LANE_SECS=30 RC_GRACE_S=1 bash "$MUTL" >/dev/null 2>&1 & echo "$!" >>"$ROOT/pids" )
sleep 1
O="$o" AI="$ai" DISPATCH="$DISPATCH" SEED_REPO="$SEED" SEED_REF="$SEED_REF" \
  NCPU=4 MEM_AVAIL_MB=8192 LOAD1_100=100 SWAP_TOTAL_MB=9999 SWAP_FREE_MB=9999 \
  WT_MOD="$ROOT/no-such-worker-terminal.sh" TARGET_LANES=1 LANE_TIMEOUT=60 \
  FAKE_DISPATCH_SLEEP=2 FAKE_LANE_SECS=30 RC_GRACE_S=1 bash "$MUTL" >/dev/null 2>&1
check "non-vacuity: without the lock TWO ticks start lanes (so arm (l) can fail)" \
  '[ "$(dispatched "$ai/logs/ai-drainer.log")" -ge 2 ]' \
  "dispatched=$(dispatched "$ai/logs/ai-drainer.log") (the lock, not the fixture, is what makes (l) pass)"
FAKE_DISPATCH_SLEEP=0

# ── the TIMER INSTALLER's refusals (a false PASS here installs an inert job) ─────────────────
echo "== install-drainer-timer refusals =="
INSTALLER="$HERE/install-drainer-timer.sh"
if [ -f "$INSTALLER" ]; then
  T="$ROOT/inst"; mkdir -p "$T/bin" "$T/units"
  cat >"$T/bin/systemctl" <<'SC_EOF'
#!/bin/sh
case "$*" in
  *is-active*) echo active ;;
esac
exit 0
SC_EOF
  chmod +x "$T/bin/systemctl"
  out="$(PATH="$T/bin:$PATH" SYSTEMD_UNIT_DIR="$T/units" DRAINER=/nonexistent \
        DRAINER_STATE="$T/state" bash "$INSTALLER" 2>&1)"; rc=$?
  check "installer: a missing DRAINER ABORTS instead of installing a dead unit" \
    '[ "$rc" -ne 0 ] && [ -z "$(ls -A "$T/units" 2>/dev/null)" ]' "rc=$rc units=$(ls "$T/units" | tr '\n' ' ')"
  out="$(PATH="$T/bin:$PATH" SYSTEMD_UNIT_DIR="$T/units" DRAINER="$DRAINER" \
        DRAINER_STATE="$T/state" DRAINER_REPO_SLUG='a|b' bash "$INSTALLER" 2>&1)"; rc=$?
  check "installer: a value that breaks the render ABORTS (no zero-byte unit, no success line)" \
    '[ "$rc" -ne 0 ] && ! grep -q "scheduled" <<<"$out"' \
    "rc=$rc · $(printf "%s" "$out" | tail -1)"
  T3="$ROOT/inst3"; mkdir -p "$T3"
  PATH="$T/bin:$PATH" SYSTEMD_UNIT_DIR="$T3/units" DRAINER="$DRAINER" DRAINER_STATE="$T3/state" \
    DRAINER_O="$T3" bash "$INSTALLER" --dry-run >/dev/null 2>&1
  check "installer: --dry-run creates nothing (not even the state dir)" \
    '[ ! -d "$T3/state" ] && [ ! -d "$T3/units" ]'
  out="$(PATH="$T/bin:$PATH" SYSTEMD_UNIT_DIR="$T/units" DRAINER="$DRAINER" \
        DRAINER_STATE="$T/state" DRAINER_O="$T" bash "$INSTALLER" 2>&1)"; rc=$?
  check "installer: a good install writes BOTH units and reports the timer active" \
    '[ "$rc" -eq 0 ] && [ -s "$T/units/eldato-ai-drainer.service" ] && [ -s "$T/units/eldato-ai-drainer.timer" ] \
      && grep -q "active" <<<"$out"' "rc=$rc · $(printf "%s" "$out" | tail -1)"
  check "installer: the installed service carries an ExecStart" \
    'grep -q "^ExecStart=" "$T/units/eldato-ai-drainer.service"'
  # ⛔ THE UNIT IS AN `Environment=` PIN, SO WHATEVER IS RENDERED HERE WINS FOREVER (agent-infra#2888
  # review, P2 — verified). It used to render a retired 3000 s literal, which shadowed
  # ai-drainer.sh's own `${LANE_TIMEOUT:-${LANE_BACKSTOP_S:-7200}}` on every installed box: drainer lanes
  # stayed capped at 50 min (300 s above the 2700 s progress allowance) and raising the seam changed
  # nothing there — the censoring surviving on the box whose job is to drain the backlog. Rendered with
  # LANE_TIMEOUT scrubbed so this measures the SEAM, not whatever the harness env happens to carry.
  T4="$ROOT/inst4"; mkdir -p "$T4"
  SEAM_T="$(sed -n 's/^LANE_BACKSTOP_S="${LANE_BACKSTOP_S:-\([0-9][0-9]*\)}".*/\1/p' "$HERE/spawn-gate.sh" | head -1)"
  ( unset LANE_TIMEOUT; PATH="$T/bin:$PATH" SYSTEMD_UNIT_DIR="$T4/units" DRAINER="$DRAINER" \
      DRAINER_STATE="$T4/state" DRAINER_O="$T4" bash "$INSTALLER" >/dev/null 2>&1 )
  check "installer: the installed unit pins LANE_TIMEOUT to the SEAM (${SEAM_T:-?}s), not a retired 3000s literal" \
    'v="$(sed -n "s/^Environment=LANE_TIMEOUT=//p" "$T4/units/eldato-ai-drainer.service" 2>/dev/null)"; [ -n "$SEAM_T" ] && [ "$v" = "$SEAM_T" ]' \
    "rendered='$(sed -n 's/^Environment=LANE_TIMEOUT=//p' "$T4/units/eldato-ai-drainer.service" 2>/dev/null)' seam='${SEAM_T:-}'"
else
  bad "installer missing at $INSTALLER"
fi

# ── the LAUNCHER's refusals (the silent-sharing failures, by name) ───────────────────────────
echo "== multi-repo-controller refusals =="
if [ -f "$LAUNCHER" ]; then
  r="$ROOT/mr"; mkdir -p "$r/pin"; printf 'deadbeef\n' >"$r/pin/HARNESS-PIN"
  out="$(OR="" REPO="$SEED" O="$r/state" HARNESS_PIN="$r/pin/HARNESS-PIN" bash "$LAUNCHER" 2>&1)"; rc=$?
  check "launcher: an unset OR is REFUSED (never defaulted)" '[ "$rc" -ne 0 ] && grep -q -- "OR is unset" <<<"$out"'
  out="$(OR=o/r REPO="$SEED" O="$r/state" HARNESS_PIN="$r/pin/HARNESS-PIN" bash "$LAUNCHER" 2>&1)"; rc=$?
  check "launcher: a MISSING state dir is refused with the init remedy" \
    '[ "$rc" -ne 0 ] && grep -q -- "--init" <<<"$out"'
  check "launcher: a refusal does not CREATE the state dir it refuses" '[ ! -d "$r/state" ]'
  mkdir -p "$r/state"
  out="$(OR=o/r REPO="$SEED" O="$r/state" HARNESS_PIN="$r/pin/HARNESS-PIN" O_PRIMARY="$r/state" bash "$LAUNCHER" 2>&1)"; rc=$?
  check "launcher: O equal to the PRIMARY state dir is refused" \
    '[ "$rc" -ne 0 ] && grep -q -- "IS the primary controller" <<<"$out"'
  out="$(OR=o/r REPO="$SEED" O="$r/state" HARNESS_PIN="$r/pin/HARNESS-PIN" PIN_PRIMARY="$r/pin/HARNESS-PIN" bash "$LAUNCHER" 2>&1)"; rc=$?
  check "launcher: HARNESS_PIN equal to the PRIMARY pin is refused" \
    '[ "$rc" -ne 0 ] && grep -q -- "primary controller.s pin" <<<"$out"'
  # A differently-SPELLED path to the primary pin is the same pin.
  out="$(OR=o/r REPO="$SEED" O="$r/state" HARNESS_PIN="$r/pin/./HARNESS-PIN" PIN_PRIMARY="$r/pin/HARNESS-PIN" bash "$LAUNCHER" 2>&1)"; rc=$?
  check "launcher: a non-canonical path to the PRIMARY pin is refused too" \
    '[ "$rc" -ne 0 ] && grep -q -- "primary controller.s pin" <<<"$out"'
  : >"$r/pin/EMPTY"
  out="$(OR=o/r REPO="$SEED" O="$r/state" HARNESS_PIN="$r/pin/EMPTY" bash "$LAUNCHER" --check 2>&1)"; rc=$?
  check "launcher: an EMPTY pin is refused" '[ "$rc" -ne 0 ] && grep -q -- "absent or empty" <<<"$out"'
else
  bad "launcher missing at $LAUNCHER"
fi

# ── THE FLEET LINE: EXPECTED vs PUBLISHED (agent-infra#3446) ──────────────────────────────────
# A drainer measures THIS box (target, census, guards), so a tick that tops up one box while four of
# five cells have gone silent is inert for the fleet and looks healthy from inside. MEASURED
# 2026-11-04: `cmux vm ls` reported 5 of 5 machines running while `refs/boxes/*` held ONE ref, and the
# conclusion drawn was "there is no usable remote capacity" while ~87 lanes sat idle. Each tick now
# reports the reconciliation, and these arms grade that it is taken — and that it never fabricates a
# healthy one when the instrument is missing.
echo
# ⚠️ RUNNING THIS SUITE FROM A LANE WORKTREE: a direct `bash scripts/orchestrator-harness/ai-drainer.test.sh`
# is refused by the worktree guard (`Working-tree discard blocked … script-indirection`) because it reads
# every `bash <operand>` in this file and several are `$VAR` paths — this suite's own fixture dispatcher
# included, so changing the SPELLING does not lift it (measured 2026-11-05). The route that works is the
# shard runner, which invokes the suite by a literal path:
#   HARNESS_SUITE_ALLOW_LIVE_CELL=1 BASH_SHARD_SLICE=<i>/<n> bash scripts/run-bash-shards.sh
# Recorded on #3243. CI is unaffected — the same glob covers this file there.
echo "== the fleet line (#3446) =="
reset_run
RUN_EXPECTED="cell-1:10.0.0.1 cell-2:10.0.0.2"
run_drainer_fg fleet
FL="$(grep 'fleet:' "$LAST_AI/logs/ai-drainer.log" 2>/dev/null)"
check "(f1) every tick that owns the lock logs ONE fleet line ($(printf '%s' "$FL" | head -1))" \
  '[ "$(grep -c "fleet:" "$LAST_AI/logs/ai-drainer.log" 2>/dev/null)" -eq 1 ]'
check "(f2) the line carries expected/published/INELIGIBLE and its source" \
  'grep -q "fleet: expected=2 " <<<"$FL" && grep -q "published=" <<<"$FL" && grep -q "INELIGIBLE=" <<<"$FL" && grep -q "src=roster" <<<"$FL"'
# ⛔ THE CHANNEL HERE HAS NO ORIGIN, SO THE READING IS `UNREADABLE` — NOT `published=0`. A zero would be
# a claim that nobody publishes on a fleet whose channel was never read, which is the defect itself.
check "(f3) an unreadable channel reads published=UNREADABLE, never published=0" \
  'grep -q "published=UNREADABLE" <<<"$FL" && ! grep -q "published=0" <<<"$FL"'
# And with NO instrument beside the drainer the tick still says so, by name: silence here would make a
# box that cannot see the fleet indistinguishable from one on a healthy fleet.
reset_run
RUN_EXPECTED="cell-1:10.0.0.1"
RUN_CAPACITY_MOD="$ROOT/no-such-capacity.sh"
run_drainer_fg fleet2
FL2="$(grep 'fleet:' "$LAST_AI/logs/ai-drainer.log" 2>/dev/null)"
check "(f4) a missing instrument is NAMED (why=capacity.sh-unreachable), never silence ($(printf '%s' "$FL2" | head -1))" \
  'grep -q "why=capacity.sh-unreachable" <<<"$FL2" && grep -q "expected=UNKNOWN" <<<"$FL2"'
# ⛔ "ABSENT" AND "PRESENT BUT STALE" ARE DIFFERENT STATES WITH DIFFERENT REMEDIES (review round 2).
# The stale case is a module that sources cleanly and lacks `cap_fleet_line` — the case the controller's
# own `declare -f` interface gate exists for. Naming a present file "unreachable" sends the operator to
# the wrong remedy, and `published=UNKNOWN` is outside the vocabulary the instrument emits.
reset_run
RUN_EXPECTED="cell-1:10.0.0.1"
RUN_CAPACITY_MOD="$ROOT/stale-capacity.sh"
printf 'true\n' > "$ROOT/stale-capacity.sh"
run_drainer_fg fleet3
FL3="$(grep 'fleet:' "$LAST_AI/logs/ai-drainer.log" 2>/dev/null)"
check "(f5) a STALE instrument is named as such (why=capacity.sh-incomplete, never 'unreachable': $(printf '%s' "$FL3" | head -1))" \
  'grep -q "why=capacity.sh-incomplete" <<<"$FL3" && ! grep -q "why=capacity.sh-unreachable" <<<"$FL3" && grep -q "published=UNREADABLE" <<<"$FL3"'
reset_run
# ⛔ …AND THE GUARDED SEED FALLBACK FIRES, IT IS NOT ONLY THE REFUSAL BRANCH (fresh review round 10, P2):
# (f7) exercises "nothing configured" with an ORIGINLESS seed, so deleting the accepting arm of the
# comparison left every drainer arm green while the path the docs rely on ("a hand-run tick, the macOS
# arm, a box whose unit predates this") was gone.
SEEDW="$ROOT/seed-with-origin"
git init -q "$SEEDW" 2>/dev/null
( cd "$SEEDW" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m s \
  && git remote add origin "https://github.com/daniel-ospina/agent-infra.git" ) >/dev/null 2>&1
reset_run
RUN_EXPECTED="cell-1:10.0.0.1"
RUN_NO_FLEET_REPO=1 RUN_SEED_REPO="$SEEDW"
run_drainer_fg seedmatch
FL8="$(grep 'fleet:' "$LAST_AI/logs/ai-drainer.log" 2>/dev/null)"
check "(f8) an unset channel falls back to a seed whose ORIGIN IS the fleet repo, and says which ($(printf '%s' "$FL8" | head -1))" \
  'grep -q "chan=github.com/daniel-ospina/agent-infra" <<<"$FL8" && ! grep -q "why=channel-unverified" <<<"$FL8"'
SEEDF="$ROOT/seed-foreign"
git init -q "$SEEDF" 2>/dev/null
( cd "$SEEDF" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m s \
  && git remote add origin "https://github.com/daniel-ospina/tortoise.git" ) >/dev/null 2>&1
reset_run
RUN_EXPECTED="cell-1:10.0.0.1"
RUN_NO_FLEET_REPO=1 RUN_SEED_REPO="$SEEDF"
run_drainer_fg seedforeign
FL8F="$(grep 'fleet:' "$LAST_AI/logs/ai-drainer.log" 2>/dev/null)"
check "(f8) …while a FOREIGN seed origin still REFUSES ($(printf '%s' "$FL8F" | head -1))" \
  'grep -q "why=channel-unverified" <<<"$FL8F"'
# ⛔ A SKIPPING TICK STILL REPORTS THE FLEET (fresh review round 7, P2). The line is taken BEFORE the
# guards for the same reason the beat is: a swap-bound or load-bound box skips every tick in steady state,
# and a reading taken only after a dispatch would make every skip look like a silent fleet. Moving the
# call below the guards (the plausible "fix" for a slow tick) left all five arms above green while every
# skipping tick went blind — so the position itself is graded here. The skip is forced with LOAD (the
# swap seam is deliberately unset by the harness so the real box cannot mask it).
reset_run
RUN_EXPECTED="cell-1:10.0.0.1"
RUN_NCPU=4 RUN_LOAD=3300 RUN_MEM=8192 RUN_TARGET=
run_drainer_fg skip
FL6="$(grep 'fleet:' "$LAST_AI/logs/ai-drainer.log" 2>/dev/null)"
SK6="$(grep 'SKIP' "$LAST_AI/logs/ai-drainer.log" 2>/dev/null | head -1)"
check "(f6) a SKIPPING tick still logs its ONE fleet line ($(printf '%s' "$FL6" | head -1))" \
  '[ "$(grep -c "fleet:" "$LAST_AI/logs/ai-drainer.log" 2>/dev/null)" -eq 1 ] && grep -q "fleet: expected=1 " <<<"$FL6" && grep -q "SKIP: load" "$LAST_AI/logs/ai-drainer.log"' \
  "SKIP line: ${SK6:-<none>}"
# ⛔ …AND A LANE CHECKOUT IS NOT THE FLEET CHANNEL (fresh review round 7, P1). Unset `FLEET_REPO`/`REPO`
# used to fall back to `SEED_REPO` — this drainer's own lane checkout — so a tick read an agent-infra
# origin and reported `published=0 INELIGIBLE=5` rc 0 for a healthy 3-of-5 fleet, naming every box
# ineligible. Unset now REFUSES, by name, and never publishes a count it did not measure.
reset_run
RUN_EXPECTED="cell-1:10.0.0.1"
RUN_NO_FLEET_REPO=1
run_drainer_fg norepo
FL7="$(grep 'fleet:' "$LAST_AI/logs/ai-drainer.log" 2>/dev/null)"
check "(f7) no channel configured REFUSES by name, never a published=0 reading ($(printf '%s' "$FL7" | head -1))" \
  'grep -q "why=channel-unverified" <<<"$FL7" && grep -q "published=UNREADABLE" <<<"$FL7" && grep -q "expected=UNKNOWN" <<<"$FL7"'
reset_run

echo
printf 'ai-drainer.test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
