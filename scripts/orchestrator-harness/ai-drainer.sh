#!/usr/bin/env bash
# ai-drainer.sh — every tick, TOP the box UP to its MEASURED lane capacity against a repo's PR backlog.
#
# ── WHY THIS EXISTS (agent-infra #2281) ─────────────────────────────────────────────────────────
# A controller for `agent-infra` cycles but emits no dispatch: its candidate funnel stays empty, so it
# has nothing to start. Rather than leave a 70-PR backlog dependent on a human remembering to dispatch,
# this schedules the one thing that demonstrably works: a bounded lane that makes PRs mergeable
# (evidence + branch refresh) and merges what goes green. It is NOT the funnel's replacement.
#
# ── THE TWO DESIGN ERRORS THIS FILE SHIPPED WITH (#2639, removed here) ──────────────────────────
#   1. AN ARBITRARY CAP, NOT A MEASUREMENT. `MAX_LANES=4` refused a fifth lane on any box whatever its
#      cores, memory or load. Measured consequence: **5 lanes across 20 cores and 16 GB free RAM**, and
#      `pi-cell-3` (4 cores, 5 GB free, load 6) showing **0 lanes alive** between ticks.
#   2. ONE LANE PER TICK, AND THE TICK BLOCKED UNTIL IT DIED. `bash "$DISPATCH" …` once, then a wait
#      loop up to `LANE_TIMEOUT`. A 20-minute tick holding itself for a 50-minute lane is a machine
#      idle most of the hour: at one lane per 20 min a 34-PR backlog cannot move, whatever the box can
#      carry. Capacity was never the constraint — the SHAPE was.
# The tick now measures what this box can carry, counts what is already ALIVE, and dispatches
# `target − alive` lanes, each on its own slice of the PR list. Zero when already at target.
#
# ── ⛔ THE LOCK IS THE DRAINER'S, NOT THE LANE'S (the correction that makes top-up possible) ─────
# #2639 held the lock for the LANE's lifetime, reasoning that the dispatcher backgrounds the worker
# and returns immediately, so releasing at that point would "let the next tick start a SECOND lane
# while the first is still running". That answered two different questions with one lock:
#
#   * "may two DRAINER TICKS run the census and the dispatch decision at the same time?" — **NO**.
#     Two ticks each computing `target − alive` from the same reading would each dispatch the full
#     remainder: a double-count, not a double-lane. That is what the lock is for, and its scope is
#     ONE TICK'S CRITICAL SECTION (settle → census → cursor → dispatch), which ends when the tick
#     has finished DISPATCHING — not when the lanes it dispatched have finished working.
#   * "may another LANE exist beside this one?" — **YES**, up to the measured target. A lane outliving
#     its tick is not a defect; it is a lane doing its up-to-`LANE_TIMEOUT` worth of work.
#
# The census answers the second question, so it needs no lock at all: the next tick counts that live
# lane in `alive` and dispatches only the remainder. **The count IS the guard.** The overlap hazard
# the old lock chased cannot occur, because a tick never dispatches a lane it has not subtracted from
# the target it just measured. (`ai-drainer.test.sh` arm (d) is the regression test: a lane outliving
# a tick must not block the next tick's top-up, and it must still be counted.)
#
# ── THE CAPACITY TARGET: a formula, its constants, and why each one ────────────────────────────
#     target = min( cpu_ceiling , mem_ceiling )               (0 when a hard guard refuses)
#
#     cpu_ceiling = MAX_LANES = floor(ncpu × 5/2)             ← the fleet's recorded owner ruling
#     mem_ceiling = floor( (MemAvailable − MIN_MEM_FREE_MB) × MEM_BUDGET_PCT/100 ÷ LANE_MEM_MB )
#
#   * `cpu_ceiling` — **2.5 × cores** is the owner's ruling of 2026-10-17 ("the lane ceiling is 2.5x
#     the number of CPUs"), the same derivation `orch-loop.sh`/`install.sh` ship as `MAX_LANES`. It is
#     a REAL ceiling, not a target: a lane spends most of its life waiting on a model response or a
#     `gh` call, so a CPU-count ceiling of 1 lane/core would leave cores idle while lanes queue.
#     On a big-memory box this term is what stops a memory-only rule from forking thirty lanes; on the
#     cells measured it does not bind (see below), the memory term does.
#   * `mem_ceiling` — LANES ARE MEMORY-BOUND, and memory is the resource whose exhaustion kills a box
#     rather than slowing it (#1985/#1961). `MIN_MEM_FREE_MB` (512) is the SAME floor the controller's
#     own spawn gate uses (`mem_spawn_ok`), so the drainer and the controller cannot disagree about
#     what "no memory" means. `MEM_BUDGET_PCT=75` stops the target at the boundary: filling available
#     memory to the last megabyte leaves nothing for page cache, the OS, or one lane's spike above
#     `LANE_MEM_MB`. `LANE_MEM_MB=512` is measured, not invented: a `pi -p --no-session` host idles at
#     77–85 MB RSS on this box and the fleet measures ~250–400 MB per working pass
#     (`docs/ops/pi-idle-repl-reaper-policy.md`), so 512 MB is the round figure ABOVE the measured
#     peak — one host, its sub-agent host, and its tool children.
#   * The LOAD arm does not size the target; it refuses to ADD work. At `load1 ≥ 8 × ncpu`
#     (`LPC_CEILING=8`) the box is past the fleet's own "do not place here" line
#     (`CAP_LPC_CEILING=800`, `docs/ops/fleet-capacity.md` §5), so the tick dispatches nothing and says
#     so. It is a `load` reading, not a lane count: the guidance is 8–10× cpu in LOAD.
#
# ⛔ **A LANE CEILING TIED TO CPU COUNT is normally the wrong instrument** — `capacity.sh` says so at
# length, and the owner's 2026-10-17 ruling gates dispatch on capacity, not on a lane count. The two
# are not in conflict: that ruling's objection is to a lane count standing in for capacity *between
# boxes* (`cap_place`), and it names the 2.5×cores ceiling as the LOCAL one. This file's target is
# `min` of that ceiling and a live memory measurement, so on the cells it matters for the memory term
# is the binding one.
#
# ⛔ **OVERRIDES:** the common "one lane per core" sizing, and the reading of a swap floor as a
# capacity signal on a box that HAS no swap — lanes are I/O-bound so 2.5×cores is the fleet's ceiling
# (owner ruling 2026-10-17), and a box with `SwapTotal=0` has no swap to run out of, so "0 MB free
# swap" there means ABSENT, never "no capacity" (the defect that made every cell tick skip: cells ship
# with no swap at all).
#
# ⛔ **OVERRIDES:** the "a swap floor is a capacity signal everywhere" default — on **Darwin it is
# not one**, and there is NO free-swap floor there: macOS grows its swap files on demand, so
# `free = total − used` is low because the kernel grew the file, and `used` is a high-water mark it
# does not release; a floor on that is a LATCH that refuses a healthy box forever (measured
# 2026-10-29: `free=412M/3072M` refused while the kernel's own
# `kern.memorystatus_vm_pressure_level` read **1 = normal** and `memory_pressure -Q` read **52%
# free**). Darwin refuses on THAT level instead, which is the number the kernel acts on; Linux keeps
# the `SwapFree` floor, where it is real. Same root as agent-infra#2016, which corrected the same
# reading in `orch-loop.sh`'s `[cap]` gate — do not "restore symmetry" by porting the Linux floor
# back to a Mac.
#
# ── ALL FOUR GUARDS ────────────────────────────────────────────────────────────────────────────
#   * LOCK — one tick's critical section at a time; never held for a lane's lifetime (see above).
#   * CAPACITY — the formula above, plus the swap arm **where swap is a capacity signal**: the
#     `SwapFree` floor on Linux, the kernel's pressure level on Darwin (see the OVERRIDES block), plus
#     fail-closed handling of an unreadable probe (a guard that could not be evaluated must not look
#     like an idle box — `docs/ops/fleet-liveness.md`'s abstention doctrine).
#   * SLICE — a rotating window over the open list that advances PER LANE, so N lanes in one tick work
#     N DISJOINT windows. Rotation is capped at the number of distinct slices
#     (`SLICE_TOTAL/SLICE_WIDTH`), because a 13th lane on 7 windows would land on lane 6's: fewer
#     lanes is the correct answer, not overlapping ones. ⛔ AND ACROSS TICKS: a lane keeps its window
#     for up to LANE_TIMEOUT (the 2 h backstop, ~6 ticks at the shipped cadence), so the windows LIVE
#     lanes hold are read from their records and skipped — a tick whose ring is fully held dispatches
#     nothing and says so.
#   * NO RUN-AWAY — the tick can never start more than `target − alive`, `target` is bounded by memory
#     AND by the cpu ceiling, and each lane is one dispatcher call (not a fork fan-out).
#
# ── ENV (every path/label overridable; defaults are the shipped layout) ────────────────────────
#   O                 controller runtime dir — holds `bg/` (dispatcher + per-lane pidfiles)
#                     default: $HOME/orchestrator
#   AI                this drainer's STATE dir — lock, slice cursor, briefs, lane records, log
#                     default: $HOME/orchestrator-ai
#   DISPATCH          the async dispatcher to call: <name> <worktree> <brief-file> <timeout>
#                     default: $O/bg/bg-dispatch.sh, else nonblocking-dispatch.sh beside this script
#   SEED_REPO         checkout to branch the lane's worktree from   default: $HOME/agent-infra-main
#   SEED_REF          ref the worktree is created at                default: origin/main
#   REPO_SLUG         owner/name the brief names                    default: daniel-ospina/agent-infra
#   FLEET_REPO        checkout whose origin carries `refs/boxes/*` default: $REPO, else $SEED_REPO when
#                     its origin IS $REPO_SLUG, else the line refuses with `why=channel-unverified`
#                     (`REPO` is accepted too — it is the fleet's ambient work repo)
#   MAX_LANES         CPU-side ceiling of the target        default: DERIVED — floor(ncpu × 5/2)
#                     (0 is legal and means "never dispatch"; an explicit value is never recomputed)
#   TARGET_LANES      pin the WHOLE target, overriding both derivations (operator's explicit call)
#   LANE_MEM_MB       resident budget per lane (MB)                  default: 512  (see above)
#   MEM_BUDGET_PCT    share of the available pool the target may use  default: 75
#   MIN_MEM_FREE_MB   memory floor a lane may not eat into (MB)       default: 512
#   MIN_SWAP_MB       free-SWAP floor — **LINUX ONLY**, and only where swap EXISTS (MB) default: 700
#                     (a Darwin box has no such floor: its swap file is grown on demand, so `free` is
#                     not headroom — see the DARWIN block at the capacity guard)
#   MAX_MEM_PRESSURE_LEVEL  **Darwin only** — refuse at or above this kernel pressure level default: 2
#                     valid: 2 (warning), 3, 4 (critical). **1 is REJECTED** — it is the kernel's NORMAL
#                     level, so it would refuse EVERY box silently; a deliberate stop is MAX_LANES=0.
#                     An unusable value warns and falls back to 2, never silently.
#   LPC_CEILING       load-per-cpu at which no lane is added          default: 8
#   LANE_TIMEOUT      the lane's BACKSTOP (seconds) — the absolute ceiling, not the primary bound
#                                                            default: $LANE_BACKSTOP_S (7200)
#   RC_GRACE_S        grace after a lane's pid dies for its status file (s)  default: 30
#   PR_BUDGET         PRs one lane may process                        default: 6
#   SLICE_WIDTH       PRs per slice                                   default: 10
#   SLICE_TOTAL       open-list length the slice wraps over            default: 70
#   LOG               drainer log        default: $AI/logs/ai-drainer.log
#
# TEST SEAMS (read-only overrides; production sets none of them):
#   NCPU LOAD1_100 MEM_AVAIL_MB SWAP_TOTAL_MB SWAP_FREE_MB   skip the platform probes
#   PROC_ROOT         the /proc tree the cwd witness walks              default: /proc
#                     (a PLATFORM seam, the same class as DRAINER_OS: Darwin has no /proc, so the arm
#                     that must exercise "this box has one witness fewer" has to be able to say so. It
#                     does NOT disarm the gate — `wt_live_holders` is still consulted, and only when
#                     BOTH witnesses are unavailable does the probe refuse to prove anything, which
#                     keeps the tree rather than deleting it.)
#   WTL               wt-lifecycle.sh to source for the live-holder witness (default: $O, then beside
#                     this script) — the same resolution the launcher census uses for WT_MOD
#   DRAINER_OS        the platform whose swap semantics apply: Darwin | Linux  default: `uname -s`
#                     (the suite's seam — the Darwin arm must be exercisable on a Linux cell, which
#                     has no `sysctl`, and the Linux arm on the operator's Mac)
#   MEM_PRESSURE_LEVEL  the Darwin pressure level to assume (1|2|4); "unreadable" fails the tick
#   PROC_MEMINFO      the meminfo file the memory/swap probes read  default: /proc/meminfo
#                     (unreadable ⇒ the macOS `vm_stat`/`vm.swapusage` probes — this is how the LINUX
#                     branch, the one every cell runs, is exercised from a macOS developer box)
#   (100ths-of-load integer for LOAD1_100; "unreadable" for any of them drives the fail-closed arm)
#   PS                `ps` binary to call                            default: ps
#   SLEEP_BIN         `sleep` binary to call                         default: sleep
#   WT_MOD            worker-terminal.sh to source for the launcher census (default: $O, then beside)
#
# ⛔ REMOVED SEAMS: `LANE_WAIT_MAX` / `LANE_POLL_S`. They bounded the wait that released the lock on
# the lane's death; the tick no longer waits for a lane at all (see the lock section), so a bound on
# that wait would be a knob wired to nothing.
#
# Exit: 0 = ran, or skipped for a guard (a skip is not a failure — the tick correctly did nothing).
#       1 = the dispatcher REFUSED/FAILED, a worktree could not be created, a probe could not be
#           read (fail closed), or a lane dispatched by an EARLIER tick died without a clean status.
#           `orchestrator-bringup.sh status` renders 1 as FAILING (last exit != 0).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || printf '.')"

O="${O:-${HOME:?HOME is required}/orchestrator}"
AI="${AI:-${HOME:?HOME is required}/orchestrator-ai}"
LOG="${LOG:-$AI/logs/ai-drainer.log}"
SEED_REPO="${SEED_REPO:-${HOME:?HOME is required}/agent-infra-main}"
SEED_REF="${SEED_REF:-origin/main}"
REPO_SLUG="${REPO_SLUG:-daniel-ospina/agent-infra}"
MAX_LANES="${MAX_LANES:-}"          # DERIVED from cores below unless pinned
TARGET_LANES="${TARGET_LANES:-}"    # pin the whole target
LANE_MEM_MB="${LANE_MEM_MB:-512}"
MEM_BUDGET_PCT="${MEM_BUDGET_PCT:-75}"
MIN_MEM_FREE_MB="${MIN_MEM_FREE_MB:-512}"
MIN_SWAP_MB="${MIN_SWAP_MB:-700}"
MAX_MEM_PRESSURE_LEVEL="${MAX_MEM_PRESSURE_LEVEL:-2}"
LPC_CEILING="${LPC_CEILING:-8}"
# ⛔ THIS IS THE BACKSTOP, NOT THE LANE'S PRIMARY BOUND (agent-infra#2888), and it takes the harness
# seam rather than a literal of its own. Two things read it, and a flat 3000 broke BOTH once the wall
# stopped being the primary bound:
#   * it is passed to `nonblocking-dispatch.sh` as the spawn's ceiling, and 3000 sat above the 2700
#     progress allowance by only 5 minutes, so a lane doing real work was still wall-killed at 50 min;
#   * it is the window a LIVE lane holds its rotation window for (§ rotation), so a lane allowed to run
#     past it gets its slice re-dispatched to a second lane — duplicate work on the same PRs.
# `LANE_BACKSTOP_S` is spawn-gate.sh's one default; it is not sourced here, so the literal fallback is
# pinned to that seam by `lane-bound.test.sh` (i0).
LANE_TIMEOUT="${LANE_TIMEOUT:-${LANE_BACKSTOP_S:-7200}}"
PR_BUDGET="${PR_BUDGET:-6}"
SLICE_WIDTH="${SLICE_WIDTH:-10}"
SLICE_TOTAL="${SLICE_TOTAL:-70}"
PS="${PS:-ps}"
SLEEP_BIN="${SLEEP_BIN:-sleep}"

LOCK="$AI/state/ai-drainer.lock"
BRIEF="$AI/state/drainer-brief.md"
CURSOR="$AI/state/drainer-slice"
LANES_DIR="$AI/state/lanes"

mkdir -p "$AI/state" "$AI/logs" "$LANES_DIR" 2>/dev/null || {
  # ⛔ LOUD, not silent: a drainer that cannot write its own state can never take the lock, so every
  # tick would be a no-op that exits 0 — the "installed but inert" state this repo keeps removing.
  printf 'ai-drainer: cannot create %s — every tick would be a silent no-op\n' "$AI/state" >&2
  exit 1
}
log_line() { printf '%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG" 2>/dev/null; }

# ── THE FLEET LINE — EXPECTED vs PUBLISHED, ONE LINE PER TICK (agent-infra#3446) ────────────────
# WHY A *DISPATCHER* OWES THIS READING. Everything in this file measures THIS box: the target is this
# box's memory and cores, the census counts this box's lanes, the guards are this box's floors. A tick
# that tops up one box while four of five cells have gone silent is INERT for the fleet and looks
# perfectly healthy from inside, and MEASURED 2026-11-04 that is exactly what happened: `cmux vm ls`
# reported 5 of 5 machines running while `refs/boxes/*` held ONE ref, and the conclusion drawn was
# "there is no usable remote capacity" while ~87 lanes sat idle. The drainer is the component that ACTS
# on that reading, so it must also REPORT when the fleet it is filling is not the fleet that exists.
#
# The instrument is `capacity.sh`'s (`cap_fleet_line`), never a second derivation here — the same rule
# the census already applies to `worker-terminal.sh`: one implementation, two adapters. A missing or
# stale module is NAMED on the line (`why=capacity.sh-unreachable`), never silence: a tick that cannot
# see the fleet is not a tick on a healthy fleet.
CAPACITY_MOD="${CAPACITY_MOD:-}"
if [ -z "$CAPACITY_MOD" ]; then
  for _cap_cand in "$O/capacity.sh" "$SELF_DIR/capacity.sh"; do
    [ -f "$_cap_cand" ] && { CAPACITY_MOD="$_cap_cand"; break; }
  done
fi
# The queue repo whose origin carries `refs/boxes/*` — the SAME channel the controller reads. `REPO`
# is the fleet's ambient work repo; `SEED_REPO` is this drainer's own checkout, used as the last resort
# because a checkout of ANY repo that shares that origin answers the identical question.
# ⛔ AND A LANE CHECKOUT IS NOT THE FLEET CHANNEL (fresh review round 7, P1). This defaulted to
# `SEED_REPO` — this drainer's own lane checkout — on the reasoning that "a checkout of ANY repo that
# shares that origin answers the identical question". The origin is never compared: measured, with no
# `FLEET_REPO`/`REPO` and `SEED_REPO` on an agent-infra checkout, a tick read `published=0
# INELIGIBLE=5 (cell-1 … cell-5)` rc 0 — all five named ineligible, three of them publishing on the real
# channel — and nothing on the line said which repo it had read. That is the 2026-11-04 "no usable
# remote capacity" conclusion, produced by the instrument built to prevent it. So: an explicit
# `FLEET_REPO`/`REPO` is used; otherwise this drainer's own checkout is used ONLY IF ITS ORIGIN IS THE
# FLEET'S (the `REPO_SLUG` this drainer already knows) — the comparison the old default assumed instead of
# checking; otherwise REFUSE by name. `cap_fleet_line` stamps `chan=` so a `published=0` is attributable.
FLEET_REPO="${FLEET_REPO:-${REPO:-}}"
if [ -z "$FLEET_REPO" ] && [ -n "${SEED_REPO:-}" ] && [ -n "${REPO_SLUG:-}" ]; then
  _seed_origin="$(git -C "$SEED_REPO" remote get-url origin 2>/dev/null)" || _seed_origin=""
  _seed_slug="${_seed_origin%.git}"
  # ⛔ ONLY THE ALTERNATIVES THAT CAN ACTUALLY MATCH (fresh review round 10, P2). Two of the original
  # four were unreachable — `*":${REPO_SLUG}.git"` cannot match because `.git` is stripped above, and
  # `git@${REPO_SLUG%%/*}:${REPO_SLUG#*/}` expands to `git@daniel-ospina:agent-infra`, not an scp URL —
  # so a reader would believe the guard accepted spellings it never accepted. The scp form is handled by
  # the second arm, which normalises it first.
  case "$_seed_slug" in
    "$REPO_SLUG"|*"/$REPO_SLUG") FLEET_REPO="$SEED_REPO" ;;
    git@*) _seed_slug="${_seed_slug#*:}"; [ "$_seed_slug" = "$REPO_SLUG" ] && FLEET_REPO="$SEED_REPO" ;;
  esac
fi
[ -n "$CAPACITY_MOD" ] && [ -f "$CAPACITY_MOD" ] && . "$CAPACITY_MOD" 2>/dev/null
fleet_line() { # log ONE `fleet:` line per tick — the reading, or a NAMED reason it could not be taken
  local line=""
  if [ -z "${FLEET_REPO:-}" ]; then
    line="fleet: expected=UNKNOWN published=UNREADABLE INELIGIBLE=unknown why=channel-unverified(no FLEET_REPO/REPO, and $SEED_REPO is not a checkout of $REPO_SLUG — a lane origin is not necessarily the fleet channel: set FLEET_REPO to the queue repo)"
  elif command -v cap_fleet_line >/dev/null 2>&1; then
    line="$(cap_fleet_line "$FLEET_REPO" 2>/dev/null)" || true   # rc says completeness; the LINE is the answer
  fi
  case "${line:-}" in
    'fleet: '*) : ;;
    *)
      # ⛔ THE REASON IS DERIVED, NOT ASSUMED (review, P2). "absent" and "present but stale" are
      # different states with different remedies (`re-seed $O`, vs install the instrument), and the
      # stale case is the one the `declare -f` interface gate exists for in the controller. Naming a
      # file "unreachable" while it sits there sourced sends the operator to the wrong remedy.
      if [ -n "${CAPACITY_MOD:-}" ] && [ -f "$CAPACITY_MOD" ]; then
        line="fleet: expected=UNKNOWN published=UNREADABLE INELIGIBLE=unknown why=capacity.sh-incomplete($CAPACITY_MOD is present and was sourced, but defines no cap_fleet_line — a STALE copy: re-seed \$O)"
      else
        line="fleet: expected=UNKNOWN published=UNREADABLE INELIGIBLE=unknown why=capacity.sh-unreachable(the expected-vs-published instrument is neither beside this drainer nor in \$O: ${CAPACITY_MOD:-<none>})"
      fi ;;
  esac
  log_line "$line"
}

# Every numeric seam is validated: an unvalidated value turns a fence into an abort (`[ '' -lt 700 ]`
# is a bash error) or a silent skip. A bad value falls back to the shipped default and says so.
_num() { # <name> <value> <default>
  case "${2:-}" in
    '') printf '%s' "$3" ;;                     # an unset seam is the DEFAULT, not a mistake
    # ⛔ `say … && printf` LOST THE DEFAULT when the log was unwritable (a full disk, a read-only
    # remount, `LOG` pointed at a directory): `say` returns its redirect's status, so the `&&`
    # short-circuits and the caller got `""` — which defeats the very fence this function is.
    *[!0-9]*) log_line "WARN: ${1}='${2}' is not a whole number — using ${3}"; printf '%s' "$3" ;;
    *) printf '%s' "$((10#$2))" ;;
  esac
}
MIN_SWAP_MB="$(_num MIN_SWAP_MB "$MIN_SWAP_MB" 700)"
# ⛔ THE DARWIN THRESHOLD IS VALIDATED BY VOCABULARY, NOT BY CLAMPING A NUMBER — because a clamp has
# two traps and only one of them is visible.
#   * `1` IS THE KERNEL'S NORMAL LEVEL, so "refuse at >= 1" is TRUE ON EVERY POSSIBLE READING: a seam
#     mistuned to 1 (and `MAX_…_LEVEL=1` reads like "be lenient" to anyone who has not checked which
#     direction the comparison runs) shuts the drainer PERMANENTLY while every tick exits 0 — exactly
#     the silent latch this change removed from the swap arm, re-created one layer up. A deliberate
#     stop has its own documented knob (`MAX_LANES=0` / `TARGET_LANES=0`), so a threshold can never be
#     the right way to say "dispatch nothing".
#   * anything above `4` names a level the kernel does not publish, so the arm could never fire — the
#     inert enforcer, the mirrored failure.
# So an unusable value falls back to the SHIPPED DEFAULT and says which value it saw — the `_num`
# contract, minus the arithmetic: the raw string is compared as a STRING first, so a 20-digit value
# cannot overflow into a negative one and be reported as a number nobody typed.
case "$MAX_MEM_PRESSURE_LEVEL" in
  2|3|4) : ;;
  *) log_line "WARN: MAX_MEM_PRESSURE_LEVEL='${MAX_MEM_PRESSURE_LEVEL}' is not a threshold this arm can refuse at (2 = warning, 3, 4 = critical; 1 = normal would refuse EVERY box) — using 2. To stop dispatch deliberately use MAX_LANES=0 or TARGET_LANES=0"; MAX_MEM_PRESSURE_LEVEL=2 ;;
esac
MIN_MEM_FREE_MB="$(_num MIN_MEM_FREE_MB "$MIN_MEM_FREE_MB" 512)"
LANE_MEM_MB="$(_num LANE_MEM_MB "$LANE_MEM_MB" 512)"
[ "$LANE_MEM_MB" -ge 1 ] || { log_line "WARN: LANE_MEM_MB=0 — using 1"; LANE_MEM_MB=1; }
MEM_BUDGET_PCT="$(_num MEM_BUDGET_PCT "$MEM_BUDGET_PCT" 75)"
[ "$MEM_BUDGET_PCT" -ge 1 ] || { log_line "WARN: MEM_BUDGET_PCT=0 would allow no lanes at all — using 1"; MEM_BUDGET_PCT=1; }
[ "$MEM_BUDGET_PCT" -le 100 ] || { log_line "WARN: MEM_BUDGET_PCT=$MEM_BUDGET_PCT > 100 — using 100"; MEM_BUDGET_PCT=100; }
LPC_CEILING="$(_num LPC_CEILING "$LPC_CEILING" 8)"
[ "$LPC_CEILING" -ge 1 ] || { log_line "WARN: LPC_CEILING=0 — using 1"; LPC_CEILING=1; }
LANE_TIMEOUT="$(_num LANE_TIMEOUT "$LANE_TIMEOUT" 7200)"
# (No LANE_WAIT_MAX any more — but `LANE_TIMEOUT` still feeds the dispatcher, so it still gets the
# validation that `30m` used to defeat: an unvalidated value made bash print "value too great for
# base" and left a variable UNSET, which under `set -u` killed the tick mid-lock.)
RC_GRACE_S="$(_num RC_GRACE_S "${RC_GRACE_S:-}" 30)"
PR_BUDGET="$(_num PR_BUDGET "$PR_BUDGET" 6)"
SLICE_WIDTH="$(_num SLICE_WIDTH "$SLICE_WIDTH" 10)"
SLICE_TOTAL="$(_num SLICE_TOTAL "$SLICE_TOTAL" 70)"
[ "$SLICE_WIDTH" -ge 1 ] || { log_line "WARN: SLICE_WIDTH=0 — using 1"; SLICE_WIDTH=1; }
[ "$SLICE_TOTAL" -ge 1 ] || { log_line "WARN: SLICE_TOTAL=0 — using 1"; SLICE_TOTAL=1; }
[ "$SLICE_TOTAL" -ge "$SLICE_WIDTH" ] || SLICE_TOTAL="$SLICE_WIDTH"

# ── CPU CEILING: DERIVED, exactly as the controller derives it ────────────────────────────────
# `orch-loop.sh`/`install.sh`: `MAX_LANES=${MAX_LANES:-$(( _NCPU * 5 / 2 ))}` (2.5 × cores, floored)
# with a fallback of 10. Same derivation, same fallback, so the drainer and the controller agree about
# what a box of N cores may run.
# ⛔ BOUND THE PRODUCT, not just the probe: `_NCPU=999999999` passes a digit check, and `× 5 / 2`
# turns it into a ten-digit lane count (MEMORY.md). A failed or absurd probe falls back to 10 — a
# plausible default rather than a fan-out.
_ncpu_probe() {
  local n=""
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null)"
  [ -n "$n" ] || n="$(sysctl -n hw.ncpu 2>/dev/null)"
  [ -n "$n" ] || n="$(nproc 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$((10#$n))" ;; esac
}
NCPU="$(_num NCPU "${NCPU:-}" "$(_ncpu_probe)")"
[ "$NCPU" -ge 1 ] 2>/dev/null || { log_line "WARN: the core probe could not answer — assuming 4 cores"; NCPU=4; }
MAX_LANES_DERIVED=$(( NCPU * 5 / 2 ))
[ "$MAX_LANES_DERIVED" -ge 1 ] || MAX_LANES_DERIVED=10
[ "$MAX_LANES_DERIVED" -le 100 ] || MAX_LANES_DERIVED=10
MAX_LANES="$(_num MAX_LANES "$MAX_LANES" "$MAX_LANES_DERIVED")"
TARGET_PIN=""
case "${TARGET_LANES:-}" in
  '') : ;;
  *[!0-9]*) log_line "WARN: TARGET_LANES='${TARGET_LANES}' is not a whole number — deriving the target instead" ;;
  *) TARGET_PIN="$((10#$TARGET_LANES))" ;;
esac

# ── DISPATCHER RESOLUTION ──────────────────────────────────────────────────────────────────────
# The live box's dispatcher is `$O/bg/bg-dispatch.sh` (unversioned). The VERSIONED equivalent is
# `nonblocking-dispatch.sh`, whose argv is compatible for the first four arguments, so a fresh box
# works without a hand-copied script — and a box that has neither fails LOUDLY instead of reporting a
# tick that dispatched nothing.
if [ -z "${DISPATCH:-}" ]; then
  for _c in "$O/bg/bg-dispatch.sh" "$SELF_DIR/nonblocking-dispatch.sh"; do
    [ -f "$_c" ] && { DISPATCH="$_c"; break; }
  done
fi
if [ -z "${DISPATCH:-}" ] || [ ! -f "$DISPATCH" ]; then
  log_line "FAIL: no dispatcher found (looked at \$DISPATCH, $O/bg/bg-dispatch.sh, $SELF_DIR/nonblocking-dispatch.sh)"
  exit 1
fi
# ⛔ THE CONTRACT IS THE DISPATCHER'S, NOT THIS SCRIPT'S. `nonblocking-dispatch.sh` writes
# `$O/bg/<name>.rc` from the dying worker; the older overlay `bg-dispatch.sh` writes NO status file at
# all. Demanding one from a dispatcher that never produces it turns EVERY healthy lane on that box
# into a FAIL — the same defect from the other side. So the capability is DETECTED (a dispatcher that
# names a `.rc` file writes one) and a dispatcher without it gets a WARN naming the gap.
if grep -q '\.rc' "$DISPATCH" 2>/dev/null; then RC_CAPABLE=1; else RC_CAPABLE=0; fi

# ── GUARD 1: ONE TICK AT A TIME — AND THE LOCK ENDS WHEN THE DISPATCHING ENDS ──────────────────
# ──8<── lock-guard ────────────────────────────────────────────────────────────────────────────
# ⛔ THE LOCK IS CREATED ALREADY LABELLED. `mkdir "$LOCK"` and then writing `$LOCK/pid` leaves a
# window in which the lock EXISTS AND NAMES NOBODY — and a contender that sees a pid-less lock calls it
# stale and takes it, which is two ticks (the very double-count the atomic reclaim was meant to close).
# So: stage a labelled directory, then `rename(2)` it into place, then VERIFY the pid inside is ours.
_lock_claim() {
  local stage="$AI/state/.ai-drainer.lock.$$" pid_now
  rm -rf "$stage" 2>/dev/null
  mkdir -p "$stage" 2>/dev/null || return 1
  printf '%s' "$$" >"$stage/pid" 2>/dev/null || { rm -rf "$stage"; return 1; }
  if [ -e "$LOCK" ]; then rm -rf "$stage" 2>/dev/null; return 2; fi
  # rename is atomic; if a competitor won, our staged dir lands INSIDE theirs, and the ownership check
  # below sees their pid — we then remove our own staged dir and report the lock as taken.
  mv "$stage" "$LOCK" 2>/dev/null || { rm -rf "$stage" 2>/dev/null; return 2; }
  pid_now="$(cat "$LOCK/pid" 2>/dev/null || printf '')"
  if [ "$pid_now" = "$$" ]; then return 0; fi
  # The staged dir is `$AI/state/.ai-drainer.lock.$$`; after a lost `mv` race it sits at
  # `$LOCK/.ai-drainer.lock.$$`, NOT `$LOCK/$$` (pre-existing bug: the line deleted nothing and a
  # loser's staging dir lingered inside the winner's lock).
  rm -rf "$LOCK/.ai-drainer.lock.$$" 2>/dev/null
  return 2
}
_lock_holder_alive() { # prints the live holder's pid, or nothing
  local p
  p="$(cat "$LOCK/pid" 2>/dev/null || printf '')"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && { printf '%s' "$p"; return 0; }
  return 1
}
if ! _lock_claim; then
  holder="$(_lock_holder_alive)" \
    && { log_line "SKIP: drainer already running (pid $holder)"; exit 0; }
  pid="$(cat "$LOCK/pid" 2>/dev/null || printf '')"
  # ⛔ RECLAIM IS ATOMIC — `mv`, never `rm -rf` followed by `mkdir`. That pair is a race with a
  # measured failure: two ticks both fail to claim, both read the dead pid, both log "reclaiming"; A
  # re-creates the lock, then B's `rm -rf` DELETES A'S FRESH LOCK and B's own claim succeeds — two
  # ticks dispatch, and A's exit trap later removes B's lock so a third can start too. `mv` of a
  # directory succeeds for exactly ONE contender.
  if mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
    log_line "STALE lock from pid ${pid:-?} — reclaimed atomically"
    rm -rf "$LOCK.stale.$$" 2>/dev/null
  else
    holder="$(_lock_holder_alive)" \
      && { log_line "SKIP: drainer already running (pid $holder)"; exit 0; }
    log_line "SKIP: another tick won the lock reclaim — it dispatches, not this one"; exit 0
  fi
  _lock_claim || { log_line "SKIP: cannot take the lock at $LOCK"; exit 0; }
fi
# ⛔ RELEASE IS OWNERSHIP-CHECKED. `rm -rf "$LOCK"` on any exit is how a finished tick deletes a
# SUCCESSOR's lock: the signal path ran it, then the EXIT trap ran it again, and a tick that had claimed
# the lock in that gap lost it to a rm of a directory it did not own (the #1761 shape). Only the pid
# file that names US may be removed.
cleanup() {
  [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] || return 0
  rm -rf "$LOCK" 2>/dev/null
  return 0
}
trap cleanup EXIT
# ──8<── /lock-guard ───────────────────────────────────────────────────────────────────────────
# ⛔ THE BEAT IS WRITTEN AS SOON AS THE TICK OWNS THE LOCK, BEFORE any guard that can skip. Its
# inventory row reads this file as the freshness signal, and a skipped tick is a NORMAL steady state on
# a full or swap-bound box — written only after a dispatch, every legitimate skip would read LATE.
beat() { printf '%s\n' "$(date +%s)" >"$AI/state/ai-drainer.beat" 2>/dev/null; }
beat
# ⛔ AND THE FLEET LINE IS TAKEN HERE TOO, for the SAME reason the beat is: a skipped tick (swap floor,
# load ceiling, pressure) is a normal steady state, and a fleet reading taken only after a dispatch
# would make every skip look like a silent fleet. One line per tick that owns the lock.
fleet_line

# ── THE PROBES (each one fail-closed: an unreadable probe is a FAILURE, never "0", never a skip) ──
# `0` is a real answer for every one of these numbers, so an empty read folded into 0 is the defect the
# fleet keeps hunting: it makes a box whose instrument failed look correctly idle.
_load1_100() { # prints the 1-min load average × 100
  local l=""
  if [ -r /proc/loadavg ]; then
    l="$(awk 'NR==1{print $1; exit}' /proc/loadavg 2>/dev/null)"
  else
    l="$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1; exit}')"
  fi
  case "$l" in ''|*[!0-9.]*) return 1 ;; esac
  awk -v l="$l" 'BEGIN{printf "%d", (l * 100) + 0.5}' 2>/dev/null
}
# The memory read is the controller's own (`mem_avail_mb`, orch-loop.sh) — ONE definition of "available
# memory" in the fleet, so its 512 MB floor and this one mean the same thing. macOS's page size is
# derived from vm_stat's own header (16 KiB on Apple silicon, 4 KiB on Intel): a hardcoded 16384
# over-reports memory 4× on Intel, which is the unsafe direction.
_mem_avail_mb() {
  local p="${1:-${PROC_MEMINFO:-/proc/meminfo}}" mb
  if [ -r "$p" ]; then
    mb="$(awk '
      /^MemAvailable:/ {a=$2}
      /^MemFree:/ {f=$2}
      /^Cached:/ {c=$2}
      END {if (a!="") v=a; else if (f!="" && c!="") v=f+c; else exit 1
           printf "%d", v/1024}' "$p" 2>/dev/null)" || return 1
  else
    mb="$(vm_stat 2>/dev/null | awk '
      /page size of/ {ps=$8}
      /Pages free/ {gsub(/[.]/,"",$3); f=$3}
      /Pages inactive/ {gsub(/[.]/,"",$3); i=$3}
      END {if (ps=="") ps=16384; if (f=="" || i=="") exit 1
           printf "%d", (f+i)*ps/1048576}')" || return 1
  fi
  case "$mb" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$mb"
}
# ⛔ SWAP: TOTAL MATTERS AS MUCH AS FREE. A cell ships with NO swap, so `SwapFree` is 0 and the old
# floor test (`0 < 700`) skipped EVERY tick on EVERY cell — the drainer was inert on exactly the boxes
# it was installed on, and the skip looked like a correctly-idle box. So the pair is read together and
# `total=0` means "this box has no swap": the floor cannot apply to a resource that does not exist.
_swap_pair_mb() { # prints "<total_mb> <free_mb>"
  local p="${PROC_MEMINFO:-/proc/meminfo}"
  if [ -r "$p" ]; then
    awk '/^SwapTotal:/ {t=$2} /^SwapFree:/ {f=$2}
         END {if (t=="") exit 1; printf "%d %d", t/1024, f/1024}' "$p" 2>/dev/null
  else
    sysctl -n vm.swapusage 2>/dev/null | awk '
      {for (i=1;i<=NF;i++) {if ($i=="total") t=$(i+2); if ($i=="free") f=$(i+2)}
       if (t=="" || f=="") exit 1
       sub(/M.*/,"",t); sub(/M.*/,"",f)
       printf "%d %d", t, f}' 2>/dev/null
  fi
}

# ⛔ WHICH PLATFORM'S SWAP SEMANTICS APPLY — asked ONCE, because the two `free` numbers are different
# quantities and one gate cannot honestly use both.
#   Linux  — swap is a fixed partition/volume: `SwapFree` IS headroom, and a floor on it is meaningful.
#   Darwin — the swap file is grown ON DEMAND by the kernel (`com.apple.dynamic_pager`), and
#            `vm.swapusage` reports total/used/free over the files that exist RIGHT NOW. MEASURED on
#            this box 2026-10-29: three 1 GiB swapfiles under `/System/Volumes/VM/`, created at
#            26 Oct 13:55, 26 Oct 14:28 and 28 Oct 19:29, and `total` = their sum EXACTLY (3072M). So
#            `free = total − used` is low BECAUSE the kernel grew the file to meet a past spike, and
#            `used` is a high-water mark macOS does not release (`scripts/objective.py` measured it
#            drifting 90.1% → 86.8% across 18 beats on a calm box). A floor on that number is a
#            LATCH, not a capacity reading: it refuses a healthy box and can never reopen.
# `DRAINER_OS` is the SEAM, following `harness-roles.sh`'s `HARNESS_UP_OS` precedent: the Darwin arm
# has to be exercisable on a Linux cell (no `sysctl`) and the Linux arm on the operator's Mac.
_platform() { # prints darwin | linux | unknown
  local v
  if [ -n "${DRAINER_OS:-}" ]; then
    case "$DRAINER_OS" in
      Darwin|darwin|macOS|macos|MacOS|Mac) printf 'darwin'; return 0 ;;
      Linux|linux) printf 'linux'; return 0 ;;
      *) log_line "WARN: DRAINER_OS='${DRAINER_OS}' is not a platform this gate knows (Darwin|Linux) — falling back to uname -s" ;;
    esac
  fi
  v="$(uname -s 2>/dev/null)" || v=""
  case "$v" in
    Darwin) printf 'darwin' ;;
    Linux) printf 'linux' ;;
    *) printf 'unknown' ;;
  esac
}
PLATFORM="$(_platform)"
# ⛔ THE SIGNAL A DARWIN BOX ACTUALLY PUBLISHES, READ RATHER THAN INFERRED. `kern.memorystatus_vm_
# pressure_level` is the verdict macOS itself acts on when it starts killing processes: 1 = normal,
# 2 = warning, 4 = critical. It is a CURRENT reading, which is exactly what the free-swap figure on
# this platform is not — so it is the arm that replaces the floor there, and a box that IS sick still
# refuses. `memory_pressure -Q` ("System-wide memory free percentage") is the corroborating reading and
# is deliberately NOT a second gate: two numbers that can disagree must not both be able to refuse.
_pressure_level() { # prints the kernel's level; absent or not a number ⇒ return 1 (fail closed)
  local v
  v="$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)" || return 1
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$v))"
}
_pressure_name() { case "$1" in 1) printf 'normal' ;; 2) printf 'warning' ;; 4) printf 'critical' ;; *) printf 'level-%s' "$1" ;; esac; }
# The GATE is the numeric comparison, not a vocabulary check, and that is deliberate: a level macOS adds
# later (a 3, say) REFUSES rather than sneaking through a case-statement gap — the same allow-list
# polarity the merge rail adopted after an unrecognised conclusion slipped past a name list.

lo100="${LOAD1_100:-}"
[ -n "$lo100" ] || lo100="$(_load1_100)"
case "$lo100" in
  ''|*[!0-9]*) log_line "FAIL: the 1-minute load average could not be read (no /proc/loadavg, no sysctl vm.loadavg) and LOAD1_100 was not set — the load arm cannot be evaluated"; exit 1 ;;
esac
mem_avail="${MEM_AVAIL_MB:-}"
[ -n "$mem_avail" ] || mem_avail="$(_mem_avail_mb)"
case "$mem_avail" in
  ''|*[!0-9]*) log_line "FAIL: available memory could not be read (no /proc/meminfo MemAvailable, no vm_stat) and MEM_AVAIL_MB was not set — the memory ceiling cannot be evaluated"; exit 1 ;;
  # `unreadable` lands here (a non-numeric seam), which is the arm that proves the fail-closed path.
esac
sw_pair=""
if [ -n "${SWAP_TOTAL_MB:-}" ] || [ -n "${SWAP_FREE_MB:-}" ]; then
  # ⛔ A HALF-SET OR NON-NUMERIC PAIR IS UNREADABLE, NOT ZERO. `_num` would fold `unreadable` into 0,
  # which on a seam means "swap present and exhausted" — a skip. The seam must drive the same
  # fail-closed path the platform probe does, or the fail-closed arm cannot be exercised at all.
  st="${SWAP_TOTAL_MB:-}"; sf="${SWAP_FREE_MB:-}"
  [ -n "$st" ] || st="$sf"          # a free-only seam keeps the LEGACY meaning: swap exists
  case "$st" in ''|*[!0-9]*) : ;; *) case "$sf" in ''|*[!0-9]*) : ;; *) sw_pair="$((10#$st)) $((10#$sf))" ;; esac ;; esac
else
  sw_pair="$(_swap_pair_mb)"
fi
case "$sw_pair" in
  ''|*[!0-9\ ]*) log_line "FAIL: swap could not be read (no /proc/meminfo SwapTotal/SwapFree, no sysctl vm.swapusage) and SWAP_TOTAL_MB/SWAP_FREE_MB were not set — the capacity floor cannot be evaluated"; exit 1 ;;
esac
swap_total="${sw_pair% *}"
swap_free="${sw_pair#* }"
# ── THE SWAP ARM'S PLATFORM READING ────────────────────────────────────────────────────────────
# Read here, with the other probes, so a probe that cannot answer fails the tick BEFORE any guard is
# evaluated — and so the SKIP/START line can NAME it (`docs/ops/fleet-capacity.md` §5).
pressure_level=""
if [ "$PLATFORM" = "darwin" ]; then
  pressure_level="${MEM_PRESSURE_LEVEL:-}"
  if [ -z "$pressure_level" ]; then pressure_level="$(_pressure_level)" || pressure_level=""; fi
  case "$pressure_level" in
    ''|*[!0-9]*) log_line "FAIL: memory pressure could not be read on this Darwin box (no kern.memorystatus_vm_pressure_level, no numeric MEM_PRESSURE_LEVEL) — free swap is NOT a substitute for it (the kernel grows the swap file on demand), so the swap arm cannot be evaluated"; exit 1 ;;
  esac
  pressure_level="$((10#$pressure_level))"
elif [ "$PLATFORM" = "unknown" ]; then
  # ⛔ FAIL CLOSED ON AN UNKNOWN PLATFORM, BY NAME. A `SwapFree` floor and a pressure level are
  # DIFFERENT gates, so choosing one for a box whose platform was never identified picks a gate on a
  # guess — and the wrong guess is the latch this file just removed.
  log_line "FAIL: this is neither a Darwin nor a Linux box (uname -s='$(uname -s 2>/dev/null || printf unknown)', DRAINER_OS unset) — the swap arm differs per platform, so it cannot be chosen on a guess"; exit 1
else
  [ -z "${MEM_PRESSURE_LEVEL:-}" ] || log_line "WARN: MEM_PRESSURE_LEVEL is set but this is a Linux box — the Darwin pressure arm does not apply here (the SwapFree floor does)"
fi

# ── SETTLE: THE OUTCOME OF LANES AN EARLIER TICK DISPATCHED ────────────────────────────────────
# ⛔ THE LANE'S OWN EXIT STATUS IS STILL THE VERDICT — it is just read by the NEXT tick instead of by
# this one. The tick never blocks on a lane (that is what starved the box), so a lane's record outlives
# it: this pass reports every record whose pid has died, removes its worktree once the pid is provably
# gone, and deletes the record so it is reported EXACTLY once. A lane still alive is left alone and
# still counted by the census.
SETTLED_FAIL=0
# ⛔ LANES WHOSE RECORDED PID IS GONE BUT WHOSE CHECKOUT IS STILL HELD (agent-infra#2787). They are NOT
# settled: they are still working, so their window stays theirs and they still count as live. The list
# is filled by `_settle_lanes` (which is what probes) and read by `_held_offsets` and the census.
SETTLE_HELD=0
SETTLE_HELD_NAMES=" "
# ⛔ EVERY PATH AFTER THE SETTLE GOES THROUGH `finish`. `_settle_lanes` can report a lane that died
# without a clean status, and three early `exit 0`s (swap floor / load ceiling / at target) used to
# bypass that report: on a healthy box at target — the normal steady state — a lane that exited 3 was
# logged FAIL and the unit still exited 0, i.e. a false PASS on the one health surface.
finish() { # [<rc>] — 1 when a lane from an earlier tick failed, whatever this tick decided
  if [ "$SETTLED_FAIL" -gt 0 ]; then
    log_line "FAIL: $SETTLED_FAIL lane(s) from an earlier tick died without a clean status — see the FAIL lines above"
    exit 1
  fi
  exit "${1:-0}"
}
# ⛔ WHO OWNS THE WORKTREE'S LIFETIME (agent-infra#2787, MEASURED 2026-10-25). The drainer removed a
# lane's checkout TWO MINUTES after launching it into a `cap=3000s` lane, and the worker kept running
# with `getcwd: cannot access parent directories` — its uncommitted work went with the directory. The
# only proof of "the lane has ended" in this file was `kill -0 <recorded pid>`, and a dead RECORDED pid
# is a fact about the process the dispatcher chose to name, NOT about the lane: the launcher's pid was
# gone while the worker it started was alive and mid-task.
#
# So the removal now needs the REAPER'S OWN PROOF before it happens — the same requirement
# `scripts/pi-reap-worktrees.sh` applies to its own reclaim (a live holder refuses the removal, and a
# probe that cannot be evaluated refuses it too). Two witnesses, both silent before anything is deleted:
#   A. `wt_live_holders` (wt-lifecycle.sh, the module every other lane-worktree removal goes through):
#      a process whose ARGV names the checkout, or whose CWD is inside it (via `lsof`).
#   B. `/proc/<pid>/cwd`, where `/proc` exists. ⛔ THIS IS NOT REDUNDANT: a real holder here is a
#      `pi -p … <brief-file>` lane whose argv NEVER names the checkout — witness A sees it only through
#      `lsof`, and a cell without `lsof` installs one witness fewer. On Linux witness B is dependency-free
#      and catches exactly that shape.
# The module is resolved the way the launcher census resolves `worker-terminal.sh` ($O first, then beside
# this script), because `$O` is seeded file by file and a STALE `wt-lifecycle.sh` would otherwise be read
# as "no holders". A missing/stale module is NOT read as "no holder" — see `_drain_holder`'s rc 2.
WTL="${WTL:-}"
if [ -z "$WTL" ]; then
  for _wtl_cand in "$O/wt-lifecycle.sh" "$SELF_DIR/wt-lifecycle.sh"; do
    [ -f "$_wtl_cand" ] && { WTL="$_wtl_cand"; break; }
  done
fi
HOLDER_PROBE_WHY="wt-lifecycle.sh not found (looked in $O, $SELF_DIR)"
if [ -n "$WTL" ] && [ -f "$WTL" ]; then
  # shellcheck disable=SC1090
  . "$WTL" 2>/dev/null
  if command -v wt_live_holders >/dev/null 2>&1; then
    HOLDER_PROBE="1"; HOLDER_PROBE_WHY="ok ($WTL)"
  else
    HOLDER_PROBE="0"
    HOLDER_PROBE_WHY="wt-lifecycle.sh at $WTL is stale (no wt_live_holders) — fix: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O"
  fi
else
  HOLDER_PROBE="0"
fi
# ⛔ WITNESS B RUNS WITH NO FORK THAT INHERITS A WORKTREE CWD. This is the measurement `wt-lifecycle.sh`
# records for the same class (its `wt_run_bounded`): a subshell does not `exec`, so it inherits its
# parent's cwd AND argv, and a probe that runs INSIDE the tree it inspects finds ITSELF and refuses every
# removal for ever. This tick never cds into a lane checkout, so the only requirement here is not to
# start doing so.
_proc_cwd_holder() { # <canon path> → 0 + "<pid>\t<cwd-inside-the-worktree>" · 1 none · 2 not evaluable
  local d tgt root="${PROC_ROOT:-/proc}" n
  [ -d "$root" ] || return 2
  for d in "$root"/[0-9]*; do
    tgt="$(readlink "$d/cwd" 2>/dev/null)" || continue
    [ -n "$tgt" ] || continue
    n="${d##*/}"
    case "$tgt" in
      "$1"|"$1"/*) printf '%s\t%s\n' "$n" "cwd-inside-the-worktree"; return 0 ;;
    esac
  done
  return 1
}
_drain_holder() { # <path> → 0 a live holder (prints pid<TAB>reason) · 1 none · 2 could not be evaluated
  local path out rc=0 proc_rc=0
  # Canonical, because `/proc/<pid>/cwd` and `lsof` both answer with RESOLVED paths: a `$AI` reached
  # through a symlink (`/tmp` → `/private/tmp` on Darwin, a linked state dir on a cell) would otherwise
  # never match, and a holder would read as absent — the direction that destroys work.
  path="$(cd "$1" 2>/dev/null && pwd -P)" || return 2
  [ -n "$path" ] || return 2
  if [ "$HOLDER_PROBE" = "1" ]; then
    out="$(wt_live_holders "$path")"; rc=$?
    case "$rc" in
      0) printf '%s\n' "$out"; return 0 ;;
      1) rc=1 ;;
      *) rc=2 ;;
    esac
  else
    rc=2                                   # witness A cannot be evaluated on this box
  fi
  out="$(_proc_cwd_holder "$path")"; proc_rc=$?
  case "$proc_rc" in
    0) printf '%s\n' "$out"; return 0 ;;
    1) rc=1 ;;
    *) : ;;                                # witness B absent (no /proc): keep witness A's verdict
  esac
  return "$rc"
}
_rm_wt() { # <worktree path> — only ever called for a lane whose pid is PROVABLY DEAD
  #                         → 0 removed · 2 kept (the probe could not be evaluated) · 3 kept (held)
  local holder="" hrc=0 hpid="" hwhy=""
  # ──8<── holder-gate ───────────────────────────────────────────────────────────────────────
  holder="$(_drain_holder "$1")"; hrc=$?
  case "$hrc" in
    0)
      hpid="${holder%%$'\t'*}"; hwhy="${holder#*$'\t'}"
      log_line "KEEP: not removing $1 — ${hwhy:-a live process} (pid ${hpid:-?}) still holds it, so the lane is STILL RUNNING whatever its pidfile says (agent-infra#2787); its record stands and a later tick retries"
      return 3 ;;
    2)
      log_line "KEEP: not removing $1 — the live-holder probe could not be evaluated ($HOLDER_PROBE_WHY), and an unproven removal is the one thing this pass may not do (agent-infra#2787); a later tick retries"
      return 2 ;;
  esac
  # ──8<── /holder-gate ──────────────────────────────────────────────────────────────────────
  # ⛔ THE `|| rm -rf` FALLBACK IS NOT REDUNDANT: a leftover directory is not always a REGISTERED git
  # worktree (a wiped $SEED_REPO, a hand-made copy, a half-created tree), and `git worktree remove`
  # refuses those — so a reaper that only called git would leave them for ever and log "could not
  # remove" every tick (the shape that made 407 worktrees / 179 GB accumulate, #1095).
  git -C "$SEED_REPO" worktree remove --force "$1" >/dev/null 2>&1 && { rm -f "$1.lane-pid" 2>/dev/null; return 0; }
  rm -rf "$1" 2>/dev/null && { rm -f "$1.lane-pid" 2>/dev/null; return 0; }
  log_line "WARN: could not remove the worktree at $1 — a later tick reaps it; it is named, not silent"
  return 1
}
_settle_lanes() {
  local f name pid rc rc_file g w
  for f in "$LANES_DIR"/*.pid; do
    [ -f "$f" ] || continue
    name="${f##*/}"; name="${name%.pid}"
    pid="$(tr -dc '0-9' 2>/dev/null <"$f")"
    [ -n "$pid" ] || { rm -f "$f" "$LANES_DIR/$name.slice"; continue; }
    kill -0 "$pid" 2>/dev/null && continue          # still working — not this tick's news
    # ⛔ A DEAD RECORDED PID IS NOT A FINISHED LANE (agent-infra#2787). If something is still working in
    # the checkout, this lane has NOT ended: it is not settled (so its verdict is reported when it truly
    # ends, exactly once), its record stands, its slice window stays held, and it still counts as alive.
    # The tree decides first — before the rc grace below, which would otherwise stall a kept lane for
    # `RC_GRACE_S` on EVERY tick.
    w="$AI/wt-drainer-$name"
    if [ -d "$w" ]; then
      _rm_wt "$w"
      if [ $? -ne 0 ]; then
        SETTLE_HELD=$((SETTLE_HELD + 1)); SETTLE_HELD_NAMES="$SETTLE_HELD_NAMES$name "
        continue
      fi
    fi
    rc_file="$O/bg/$name.rc"
    rc="$(cat "$rc_file" 2>/dev/null || printf '')"
    # A dispatcher that records the status from a DETACHED watcher writes it a moment AFTER the pid
    # dies; read it with a bounded grace so a healthy lane is not called a refusal for being prompt.
    g=0
    while [ -z "$rc" ] && [ "$RC_CAPABLE" = "1" ] && [ "$g" -lt "$RC_GRACE_S" ]; do
      "$SLEEP_BIN" 1 2>/dev/null || true
      g=$((g + 1))
      rc="$(cat "$rc_file" 2>/dev/null || printf '')"
    done
    if [ -z "$rc" ]; then
      if [ "$RC_CAPABLE" = "1" ]; then
        log_line "FAIL: lane $name (pid $pid) vanished with NO exit status at $rc_file after ${g}s — it was refused or lost, not completed (see $O/bg/$name.log)"
        SETTLED_FAIL=$((SETTLED_FAIL + 1))
      else
        # Not this tick's failure to report: the DISPATCHER records no status. Say so, every tick, so
        # the gap is visible in the log rather than being either invented or hidden.
        log_line "WARN: lane $name (pid $pid) finished, but $DISPATCH records no exit status ($rc_file absent) — this tick cannot tell a completed lane from a refused spawn; ship a dispatcher that writes .rc"
      fi
    elif [ "$rc" != "0" ]; then
      log_line "FAIL: lane $name (pid $pid) exited $rc — see $O/bg/$name.log"
      SETTLED_FAIL=$((SETTLED_FAIL + 1))
    else
      log_line "DONE: lane $name (pid $pid) finished rc=0"
    fi
    rm -f "$f" "$LANES_DIR/$name.slice" 2>/dev/null
  done
}
# ⛔ `git worktree prune` IS NOT A LEFTOVER REAPER: it only drops administrative entries whose directory
# is ALREADY GONE, and a leftover from a SIGKILLed tick still has its directory. Reap by the pid the
# tree's own sidecar carries: a `wt-drainer-*` whose sidecar pid is dead is reclaimable; a live one is
# still in use; NO SIDECAR means UNKNOWN, and an unknown tree is left for an operator (a health job
# does not guess).
_reap_leftovers() {
  local w lane n=0 nm
  for w in "$AI"/wt-drainer-*; do
    case "$w" in *.lane-pid) continue ;; esac       # the sidecar is not a worktree
    [ -d "$w" ] || continue
    # ⛔ A TREE THIS TICK'S SETTLE ALREADY KEPT IS NOT PROBED A SECOND TIME. `_settle_lanes` runs first
    # and holds the same verdict; re-probing it here cost a second probe per kept tree per tick and
    # logged the identical `KEEP:` line twice, which reads like two different refusals.
    nm="${w##*/wt-drainer-}"
    case "$SETTLE_HELD_NAMES" in *" $nm "*) continue ;; esac
    lane=""
    [ -f "$w.lane-pid" ] && lane="$(tr -dc '0-9' 2>/dev/null <"$w.lane-pid")"
    [ -n "$lane" ] || continue
    kill -0 "$lane" 2>/dev/null && continue
    # ⛔ COUNTED ONLY WHEN IT WAS ACTUALLY REMOVED. A tree kept by the holder gate (or by an
    # unevaluable probe) is not a reap, and `REAPED: n` must not claim one.
    _rm_wt "$w" && n=$((n + 1))
  done
  git -C "$SEED_REPO" worktree prune >/dev/null 2>&1 || true
  [ "$n" -eq 0 ] || log_line "REAPED: $n leftover worktree(s) whose lane was gone"
}

# ── GUARD 2: THE CENSUS — how many lanes this box is ALREADY running ───────────────────────────
# ⛔ TWO POPULATIONS, BOTH COUNTED, because either one alone is blind:
#   * DISPATCHER lanes — `$O/bg/*.pid` whose pid is alive and whose argv is a worker. This is where
#     THIS drainer's lanes live, and it is why the census is not a lock: the next tick sees them.
#     LB Liveness by ARGV SHAPE, not by "the command line starts with pi": both shipped dispatchers
#     record the pid of a BACKGROUNDED SUBSHELL (`( … run_agent … ) &`) whose argv is
#     `bash …/nonblocking-dispatch.sh …` — `pi` is that subshell's CHILD. A `case "$c" in pi*)` test
#     counted ZERO lanes on every real dispatch.
#   * LAUNCHER workers — `wt_table`/`wt_count` (worker-terminal.sh): DURABLE TERMINAL and tmux workers,
#     which have no pidfile here at all and which `pgrep` cannot see either (a durable terminal's tree
#     hangs off the daemon, not a pane). These are lanes on the SAME box eating the SAME memory, so
#     they belong in `alive`. `wt_count` counts `unknown` as alive (the launcher's own polarity: a
#     daemon read failure must never RAISE a ceiling).
# A worker is NEVER `pgrep`-ed for: `pgrep` answers a different population than the launcher's.
_counts_as_lane() { # <command-line>
  local c="$1" t b rc=1 had_f=0
  [ -n "$c" ] || return 1
  # ⛔ GLOB-FREE, for the SAME reason `_is_lane_process` below is (see its comment): the split is
  # UNQUOTED, so `for t in $c` pathname-expands as well as word-splits, and an argv token holding a
  # wildcard would expand against the CWD. MEASURED with a file literally named `pi` in the CWD:
  # `_counts_as_lane "bash -c echo *"` matched it and COUNTED. That inflates `disp_alive`, which stands
  # the tick down — the same inertness #3882's clamp exists to end, one census over (#3886 review).
  # Restored on the single exit path, and the only call site (`_census_dispatcher`) is itself read
  # through a `$(…)`, so a leak is not reachable either way.
  case $- in *f*) had_f=1 ;; *) set -f ;; esac
  for t in $c; do
    case "$t" in
      /*) b="${t##*/}"; if [ "$b" = "pi" ]; then rc=0; break; fi ;;
      pi) rc=0; break ;;                     # argv[0] literally `pi` (no shebang rewrite)
    esac
  done
  if [ "$rc" -ne 0 ]; then
    for b in nonblocking-dispatch.sh bg-dispatch.sh lane.sh fix-one.sh merge-one.sh \
             chain-merge.sh dispatch-merge.sh; do
      case "$c" in *"$b"*) rc=0; break ;; esac
    done
  fi
  [ "$had_f" = "1" ] || set +f
  return "$rc"
}
_census_dispatcher() { # prints "<alive> <overlap>" — dispatcher lanes, then how many of them the
  #                        LAUNCHER predicate also counts (the intersection `_census_launcher` removes)
  local f p c n=0 ov=0 seen=" "
  for f in "$O"/bg/*.pid; do
    [ -f "$f" ] || continue
    p="$(tr -dc '0-9' 2>/dev/null <"$f")"
    [ -n "$p" ] || continue
    kill -0 "$p" 2>/dev/null || continue          # a dead pidfile is not a lane
    # ⛔ A PID NAMED BY TWO PIDFILES IS ONE PROCESS. The overlap below is SUBTRACTED from the
    # launcher's process count, so counting one process twice here would under-read the launcher's
    # share — the over-dispatch direction, which is the expensive one (#3886 review, P2-1).
    case "$seen" in *" $p "*) continue ;; esac
    seen="$seen$p "
    c="$("$PS" -p "$p" -o command= 2>/dev/null | head -1)"
    # ⛔ AN UNREADABLE COMMAND LINE IS ALIVE (the fleet's own liveness polarity: unknown is alive).
    # Counting it as absent was the over-dispatch direction, and the census is now the ONLY thing
    # bounding the lane total (the lock no longer is) — so a `ps` that cannot answer (absent under the
    # unit's PATH, `hidepid`, another uid) must never read as "no lanes".
    if [ -z "$c" ]; then n=$((n + 1)); elif _counts_as_lane "$c"; then n=$((n + 1)); fi
    # ⛔ THE PREDICATE MUST BE THE ONE THAT COUNTED THE LANE (#3886 review round 5, P2). The overlap is
    # the INTERSECTION of "in `n`" and "inside `procs`", so it is measured with `_counts_as_lane` — the
    # NARROWER predicate, the one that actually added this lane to `n`. Measuring it with the broader
    # `_is_lane_process` counted a lane the dispatcher half never accepted (an argv like `./pi -p x`, which
    # only the broad rule matches) and SUBTRACTED it from `procs` while adding it to nothing: that lane was
    # in NEITHER half, so one live lane on the box read as `alive=0` and a full target's worth of new lanes
    # was dispatched into it. Broad is the safe direction for a BOUND; for a SUBTRACTION it is the
    # over-dispatch direction. A lane that is in `procs` but not in `n` now stays in the launcher's share —
    # over-counted, which is the direction this file accepts everywhere else.
    if [ -n "$c" ] && _counts_as_lane "$c"; then ov=$((ov + 1)); fi
  done
  printf '%s %s' "$n" "$ov"
}
# ⛔ THE LAUNCHER MODULE IS SOURCED THE WAY THE CONTROLLER SOURCES IT (orch-loop.sh): from `$O` first,
# then beside this script, then the verbs AND the embedded-python data are checked. A module that
# defines the verbs but whose `WT_TREE_PY` came out empty (measured: a bash 3.2 mis-parse on macOS)
# makes `wt_table` return nothing, which reads EXACTLY like "no workers" — so the data is checked too.
WT_MOD="${WT_MOD:-}"
WT_MOD_PINNED=0
[ -n "$WT_MOD" ] && WT_MOD_PINNED=1
if [ -z "$WT_MOD" ]; then
  for _wt_cand in "$O/worker-terminal.sh" "$SELF_DIR/worker-terminal.sh"; do
    [ -f "$_wt_cand" ] && { WT_MOD="$_wt_cand"; break; }
  done
fi
CENSUS_LAUNCHER=0
CENSUS_LAUNCHER_WHY="worker-terminal.sh not found (looked in $O, $SELF_DIR)"
[ "$WT_MOD_PINNED" = "1" ] && CENSUS_LAUNCHER_WHY="WT_MOD=$WT_MOD is not a readable file"
if [ -n "$WT_MOD" ] && [ -f "$WT_MOD" ]; then
  # shellcheck disable=SC1090
  . "$WT_MOD" 2>/dev/null
  if command -v wt_table >/dev/null 2>&1 && command -v wt_count >/dev/null 2>&1 \
     && [ -n "${WT_TREE_PY:-}" ] && [ -n "${WT_WS_PY:-}" ]; then
    CENSUS_LAUNCHER=1
    CENSUS_LAUNCHER_WHY="ok"
  else
    CENSUS_LAUNCHER_WHY="worker-terminal.sh at $WT_MOD is stale (no wt_table/wt_count, or its embedded python is empty)"
  fi
fi
# ⛔ THE LAUNCHER CENSUS IS AN UPPER BOUND, NOT A COUNT — clamp it to the lane ROOTS present (a lane's
# `pi` child is the same lane, so the count is lanes, not processes).
# MEASURED 2026-11-10 on pi-cell-3: `alive=36 (dispatcher=2 launcher=34)` with **9** live `pi`
# processes on the same box, 25 GB RAM free, 0 OOM kills — so the tick printed `SKIP: nothing to add`
# and exited 0 on a box with idle capacity, and the starved queue had no error to point at.
# The reason is in `wt_count`'s own signal: it counts `wt_table` rows that are not `dead`, and `dead`
# comes from the cmux daemon document's `terminals[].running` flag (worker-terminal.sh:1287-1305) —
# **"a shell is running in that terminal"**, i.e. UI liveness. A `wt-*` terminal whose `pi` has exited
# still reports `running=true`, so it is a live lane forever and `target − alive ≈ 0` for ever.
# The clamp is one-sided (`min`): it can only REMOVE phantom lanes, never invent one. ⛔ It CAN lower a
# real count, and that is the price of the fix, not an oversight (#3886 review): a probe that ANSWERS
# with a view that omits the lanes — `hidepid=2` for another uid, a PID namespace, a filtered `$PS`
# wrapper — reads 0 and the clamp then lowers a real count, which is the OVER-DISPATCH direction. The
# alternative (treating an answered probe as unreadable) restores the original bug, so the trade is
# deliberate; it is stated here and in docs/ops/ai-drainer.md rather than left implied.
# When it fires it is LOUD — `census-mismatch launcher=34 pi=9 clamped=9 disp=0` — so the drift is
# visible in the log instead of silently suppressing dispatch.
#
# ⛔ THE TWO HALVES ARE DISJOINT, AND THAT IS THE ARGUMENT OF THIS BLOCK (#3886 review, P2-1). `procs`
# counts every lane ROOT on the box, so a live dispatcher lane is already in it; summing
# `disp_alive + min(wt_count, procs)` therefore counted each live dispatcher lane TWICE and over-stated
# the total by `disp_alive`. Harmless against a big target, fatal on a cell (MAX_LANES = 2.5 × 4 = 10):
# `disp_alive=2` + `procs=9` ⇒ `alive=11 > 10` ⇒ the tick dispatched nothing with a slot free — the
# stand-down #3882 exists to end, one term smaller. So the clamp bounds the LAUNCHER's share only:
#   launcher = min(wt_count, procs − overlap)      # overlap = pidfile processes `procs` also counts
#   alive    = disp_alive + launcher               # disjoint by construction
# The subtraction is the INTERSECTION (inclusion–exclusion), never `disp_alive`: a pidfile whose argv
# the launcher predicate cannot read is counted as a dispatcher lane and NOT subtracted, which is the
# safe direction (over-count → fewer dispatches) rather than an under-read (`_census_dispatcher`).
#
# ⛔ UNKNOWN IS ALIVE (the polarity the dispatcher census above states, and the reason this is safe):
# when the PROCESS count cannot be measured the clamp does NOT apply and `wt_count` is returned
# unchanged. Clamping on an unreadable reading would be the OVER-DISPATCH direction — the census is
# now the only thing bounding the lane total — so the fail-safe answer is the LARGER (terminal) number.
# A `ps` that prints NOTHING did not answer (every live box has at least a shell and this tick); a
# `ps` that answered with no lane in it counts as 0 — a genuinely idle box **as seen by that probe**
# (a partial view reads 0 too: see the one-sidedness note above).
# ⛔ THE PREDICATE IS TOKEN-STRICT, AND THAT IS A MEASURED CHOICE, NOT A STYLE ONE.
# A lane process is one whose OWN argv names it as a lane: a token whose basename is `pi` (pi sets its
# process title, so a live lane reads as `pi` or `pi -p --provider …` in `ps`), or a token naming one of
# the lane scripts the launcher runs. It covers BOTH shapes this box runs — the durable-terminal `pi` and
# the `bash …/nonblocking-dispatch.sh …` subshell the drainer records.
# ⛔ IT IS A SUPERSET OF `_counts_as_lane`'s FIRST LOOP, NOT THE SAME RULE (#3882 review). That loop
# accepts a bare `pi` or a token whose ABSOLUTE-PATH basename is `pi` (`case "$t" in /*) b="${t##*/}" ;;`),
# so `./pi` and `bin/pi` do NOT match there — while `pi` here comes from `${t##*/}` on EVERY token
# (MEASURED: `./pi -p x` → `_counts_as_lane`=N, `_is_lane_process`=Y; `node /usr/local/bin/pi` → Y in
# both). Broader is the safe direction for a bound, but it is a DIFFERENT rule and must not be cited as
# the same one.
# ⛔ IT IS DELIBERATELY STRICTER THAN `_counts_as_lane`'s SECOND LOOP, which matches those script names as
# a SUBSTRING of the whole command line. Measured on the operator's Mac 2026-11-11: that form returned
# **43** matches, four of which were the diagnostic's own `bash -c '… nonblocking-dispatch.sh …'` text —
# the same self-match lane.sh:88 records for `pgrep -f "pi -p"`. A predicate that counts the shells which
# merely MENTION a lane script cannot bound anything: on a box whose agents quote these names it reads
# high enough that the clamp never fires, i.e. the fix would be INERT and the log would look clean.
# Token-strict returned 39 on that same box: the same real lanes, none of the quoted diagnostic text.
# ⛔ BUT STRICTER IS NOT IMMUNE, and the residual is stated rather than implied (#3882 review). A mention
# that is a BARE TOKEN still counts: `bash -c sleep 1; nonblocking-dispatch.sh --flag` → counted. So does
# any diagnostic whose own argv carries a bare lane token — `ps -A -o command= | grep -c pi` matches on
# `pi` (MEASURED), which is exactly the shape an operator types on the affected box. The consequence is
# therefore REDUCED, not eliminated: such a process raises the bound and keeps the clamp inert for that
# tick. That is still the safe direction (over-count → fewer dispatches), and it is why this is a bound
# and never a census.
# WHAT IT OVER-INCLUDES, stated so nobody reads it as a true lane count: an INTERACTIVE `pi` session on
# the operator's Mac matches too, as does the `grep -c pi` shape above. That is the safe direction — it
# can only raise the bound, never lower it — and it is why this is a bound and not a census.
# ⛔ ONE `ps` PER TICK, not one per lane: the census runs inside the lock on a 20-minute cadence, and a
# per-lane process walk is the cost option 2 of #3882 declines.
_is_lane_process() { # <command-line> → true when THIS argv IS a lane, not when it merely names one
  local c="$1" t b rc=1 had_f=0
  [ -n "$c" ] || return 1
  # ⛔ GLOB-FREE, and that is the point of this line (#3882 review, MEASURED). The split below is
  # UNQUOTED, so `for t in $c` does pathname expansion as well as word-splitting: an argv token holding a
  # wildcard (`bash -c 'rm -f *.log'`) expands against the CWD, and this script's CWD holds `lane.sh` /
  # `fix-one.sh` on the launchd path (`$O`). Measured with `lane.sh` and `pi` in the CWD:
  # `_is_lane_process "bash -c echo *"` matched `lane.sh` and COUNTED. `set -f` makes the split a pure
  # word-split, so a token can only match by its own text. The prior option is preserved and restored on
  # the single exit path; the blast radius is a subshell anyway — BOTH callers are read through a `$(…)`:
  # `_census_launcher` → `_live_lane_processes` → here (the clamp), and `_census_dispatcher` → here (the
  # OVERLAP that clamp removes, #3886 P2-1; the same read must use the same predicate, which is why that
  # is this function and not a second copy of the rule).
  case $- in *f*) had_f=1 ;; *) set -f ;; esac
  for t in $c; do
    b="${t##*/}"
    if [ "$b" = "pi" ]; then rc=0; break; fi
    case "$b" in
      nonblocking-dispatch.sh|bg-dispatch.sh|lane.sh|fix-one.sh|merge-one.sh|chain-merge.sh|dispatch-merge.sh) rc=0; break ;;
    esac
  done
  [ "$had_f" = "1" ] || set +f
  return "$rc"
}
_live_lane_processes() { # prints the count of live lane ROOTS, or nothing when `ps` cannot answer
  local out c pid ppid rest own=" " pairs=" " n=0 rows=0
  # ⛔ `pid=,ppid=,command=` BECAUSE A LANE IS NOT A PROCESS (#3886 review round 4, P2). Every lane this
  # box runs contributes MORE than one lane-shaped process — the `bash …/lane.sh` wrapper AND the `pi` it
  # execs (a `dispatch-merge.sh` ladder is three) — so counting processes read ~2× the lane count, and
  # `share = procs − overlap` then landed at ~2× the launcher's lanes. The consequence is the one the
  # overlap fix above was made for, at twice the size: MEASURED on a 9-lane table in that shape at
  # `MAX_LANES`-style target 10, `alive=18` and the tick STAND DOWN with a slot free — #3882's own
  # symptom, and `census-mismatch` reports it truthfully (`pi=18`) while the reading is wrong. So the
  # count is the number of lane processes whose PARENT is not itself a lane process: one per lane, and a
  # lane's `pi` child (or a `pi` sub-agent child) is the SAME lane, not a second one.
  # The ppid column also keeps this cheap: ONE `ps -A` per tick, no per-lane walk (option 2 of #3882).
  out="$("$PS" -A -o pid=,ppid=,command= 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1        # a `ps` with no output at all did NOT answer (see above)
  while IFS= read -r c; do
    c="${c#"${c%%[![:blank:]]*}"}"      # ltrim: BSD/Linux `ps -o pid=` right-aligns the pid
    pid="${c%% *}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac   # not a process row — never read it as "no lanes"
    rows=$((rows + 1))
    rest="${c#* }"; rest="${rest#"${rest%%[![:blank:]]*}"}"      # drop the pid
    ppid="${rest%% *}"
    rest="${rest#* }"; rest="${rest#"${rest%%[![:blank:]]*}"}"    # drop the ppid → the command line
    _is_lane_process "$rest" || continue
    own="$own$pid "                       # every lane-shaped pid, for the parent test below
    pairs="$pairs$pid:$ppid "
  done <<<"$out"
  [ "$rows" -ge 1 ] || return 1        # a table of no process rows did not come from `ps -A`
  for c in $pairs; do
    pid="${c%%:*}"; ppid="${c#*:}"
    case "$own" in *" $ppid "*) continue ;; esac   # its parent IS a lane — the same lane, not a new one
    n=$((n + 1))
  done
  printf '%s' "$n"
}
_census_launcher() { # <dispatcher-overlap> — prints the count, or nothing when unreadable
  local n wtn procs share ov
  ov="${1:-0}"
  case "$ov" in ''|*[!0-9]*) ov=0 ;; esac
  wtn="$(wt_count lane- fix- merge- chain- 2>/dev/null)"
  case "$wtn" in ''|*[!0-9]*) return 1 ;; esac
  n="$wtn"
  # The clamp (see the block above). An unreadable process count leaves `n` EXACTLY as today.
  procs="$(_live_lane_processes)" || procs=""
  case "$procs" in
    ''|*[!0-9]*) : ;;
    *) # ⛔ INCLUSION–EXCLUSION, NOT A SUM (#3886 review, P2-1). `procs` counts BOTH populations, so the
       # dispatcher's share of it is removed before it bounds the LAUNCHER's: a live dispatcher lane is
       # in `disp_alive` AND in `procs`, and clamping against the un-subtracted `procs` over-stated the
       # launcher half by exactly that share. MEASURED shape on the issue's own cell (MAX_LANES = 2.5 × 4
       # = 10): disp_alive=2 + min(34, 9) ⇒ alive=11 > 10 ⇒ the tick dispatched NOTHING with a slot free
       # — the same stand-down #3882 exists to end, one term smaller, and `census-mismatch` could not show
       # it (`pi=` was truthful; the SUM was not).
       # The overlap SUBTRACTED is the intersection, not `disp_alive`: only a pidfile process whose argv
       # the launcher predicate actually counts is known to be inside `procs`.
       # ⛔ THE CHILD QUESTION, stated rather than implied: a dispatcher lane's CHILD processes (the `pi` a
       # `nonblocking-dispatch.sh` subshell spawns) are NOT in this half — `_live_lane_processes` counts
       # lane roots, so that `pi` is the same lane as its wrapper and is skipped by the parent test. What
       # is left here is the dispatcher's ROOT (the process its pidfile names), which is exactly what the
       # overlap removes; every other root is a launcher lane.
       share="$procs"
       [ "$ov" -le "$share" ] || ov="$share"          # cannot subtract more processes than were counted
       share=$((share - ov))
       if [ "$share" -lt "$wtn" ]; then
         n="$share"
         # ⛔ LOGGED HERE, not by the caller, because the caller reads this function through a COMMAND
         # SUBSTITUTION (a subshell) — a value returned that way would never be seen by it, so a caller
         # that logged the drift would log nothing and the clamp would apply silently. `log_line`
         # appends to `$LOG`, which the subshell can write.
         # `disp=` is the overlap removed, so `pi=` is not read as the launcher's share (it is the BOX's).
         log_line "census-mismatch launcher=$wtn pi=$procs clamped=$n disp=$ov"
       fi ;;
  esac
  printf '%s' "$n"
}

# ── WHICH SLICES ARE ALREADY BEING WORKED ────────────────────────────────────────────────────
# ⛔ THE RING CLAMP ALONE DOES NOT PREVENT A DOUBLE-DISPATCH ACROSS TICKS. `n` is capped at the
# number of distinct windows (SLICE_TOTAL/SLICE_WIDTH = 7 at the shipped defaults), but a LIVE lane
# keeps its window for up to LANE_TIMEOUT (~2 backstop-hours ≈ 6 ticks at the shipped 20 m cadence):
# tick 1 takes offsets 0…60, tick 2
# walks the ring from cursor=7 back to 0 and hands 0/10/20 to NEW lanes while the first lanes are
# still on them — two lanes per window, two reviews per head, two merge attempts per PR. So the
# cursor alone is not enough: the offsets a live lane HOLDS are read from the lane records and
# skipped, and if the ring holds no free window the tick dispatches nothing and says so.
_held_offsets() { # prints " 0 10 30 " — offsets held by lanes that are still working
  # ⛔ "STILL WORKING" IS NOT "RECORDED PID ALIVE" (agent-infra#2787). `_settle_lanes` already probed
  # every dead-pid record and left the ones whose checkout is still held in `SETTLE_HELD_NAMES`; those
  # lanes are alive, so their window is theirs and must not be re-issued to a second lane that would
  # work the same PRs. Reading that verdict (rather than probing again here) keeps ONE probe per record
  # per tick, in the pass that already visits them.
  local f name pid off held=" " still
  for f in "$LANES_DIR"/*.pid; do
    [ -f "$f" ] || continue
    name="${f##*/}"; name="${name%.pid}"
    pid="$(tr -dc '0-9' 2>/dev/null <"$f")"
    still=0
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && still=1
    [ "$still" = "1" ] || case "$SETTLE_HELD_NAMES" in *" $name "*) still=1 ;; esac
    [ "$still" = "1" ] || continue
    off="$(tr -dc '0-9' 2>/dev/null <"$LANES_DIR/$name.slice")"
    [ -n "$off" ] && held="$held$off "
  done
  printf '%s' "$held"
}

# ── THE TARGET ────────────────────────────────────────────────────────────────────────────────
_capacity_target() { # prints "<target> <cpu_ceiling> <mem_ceiling> <mem_pool_mb>"
  local pool usable mem_ceiling target
  pool=$((mem_avail - MIN_MEM_FREE_MB))
  [ "$pool" -ge 0 ] || pool=0
  usable=$((pool * MEM_BUDGET_PCT / 100))
  mem_ceiling=$((usable / LANE_MEM_MB))
  [ "$mem_ceiling" -ge 0 ] || mem_ceiling=0
  target="$MAX_LANES"
  [ "$mem_ceiling" -lt "$target" ] && target="$mem_ceiling"
  printf '%s %s %s %s' "$target" "$MAX_LANES" "$mem_ceiling" "$pool"
}

# ── GUARD 3: ROTATE THE SLICE — PER LANE, never per tick ───────────────────────────────────────
# ⛔ EVERY BRIEF CARRIES THE RESEARCH-FIRST CONTRACT, BECAUSE THE DISPATCHER ENFORCES IT.
# `nonblocking-dispatch.sh` runs `brief-gate.sh --check <brief> worker` IN THE FOREGROUND BEFORE THE
# FORK and exits 80 without a `## RESEARCH FIRST` section (INTERNAL/EXTERNAL/RUNG) and a
# `CONTRADICTION TEST:` line (agent-infra#2258). A brief that lacks them is REFUSED at the dispatch
# path — so on any box whose dispatcher is the versioned one, every drainer lane would die with
# `dispatcher refused` and the top-up machinery would never run. The `bg-dispatch.sh` overlay the Mac
# happens to use has no such gate, which is exactly why this went unnoticed; the block is emitted from
# the gate's OWN text (`--section worker`) so the two cannot drift apart.
_gate_block() {
  local g
  for g in "$O/brief-gate.sh" "$SELF_DIR/brief-gate.sh" \
           "${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/brief-gate.sh" \
           "${HOME:-}/.pi/agent/scripts/brief-gate.sh"; do
    [ -n "$g" ] && [ -f "$g" ] || continue
    bash "$g" --section worker 2>/dev/null && return 0
  done
  # No gate script on this box: emit the minimum the gate checks, so the brief is valid wherever it
  # is dispatched. (A box without the script also cannot run it against us.)
  cat <<'GATE_EOF'
## RESEARCH FIRST — before you decide anything (agent-infra#2258)

INTERNAL: read what this repo and its tracker ALREADY hold before you change a PR: the PR's own
comments, `git log --all --grep` for a prior attempt, the issue the PR closes. If the work is already
done, report that with evidence instead of redoing it.
EXTERNAL: for anything non-obvious, look OUTSIDE this repo (vendor docs, a spec, the `research` skill)
and say what you looked up and what you took from it.
RUNG: 3 — `web_fetch` on the primary source (no paid search rung is needed for a PR-hygiene pass).

CONTRADICTION TEST: which RECORDED DECISION covers this work — an owner ruling, a decision section in
a plan doc, a decision comment on an issue? Quote it, or say `no recorded decision reaches this work`.
If a finding contradicts a recorded decision, it is NOT a candidate for adoption: reopen it in its own
home and argue it; never adopt over it.

## PREVIOUS WORK — did someone already start this? (agent-infra#3484)

CLAIM:     unclaimed — a drainer lane holds no single issue/PR key (it works a slice of PRs)
WIP:       keyless — this lane reads PRs; there is no `refs/wip/*` archive keyed to it
BRANCH:    none — it works each PR on that PR's own branch and pushes there
WORKTREE:  none — it does not create one
PRIOR:     check `state/prdisp.tsv` and the PR's own comments for the previous attempt before
redoing it; the last drainer's note is the cheapest evidence on the box.
GATE_EOF
  return 0
}
_write_brief() { # <start-offset> <brief-path> <lane-name> <lanes-this-tick>
  cat >"$2" <<BRIEFEOF
You are a scheduled drainer lane for **$REPO_SLUG** (lane $3, one of up to $4 started together, each on
a DISJOINT slice). Start at PR offset **$1** in the open list, and process **at most $PR_BUDGET PRs**.
Stay inside your own window — another lane may be working the next one.

Goal: make PRs *mergeable*, then merge the ones that go green. Evidence is the work —
\`pipeline-compliance\` blocks most PRs and its dominant letter is **[c] head-bound review record**.

Per PR:
1. \`gh pr checks <N> --repo $REPO_SLUG\` and \`gh pr view <N> --repo $REPO_SLUG --json mergeStateStatus,mergeable\`.
2. **Green + MERGEABLE** → merge (squash). Confirm the sha.
3. **Only \`bash-suites\` / \`sigpipe-grep\` red** → those causes are **already fixed on main**; the
   check-runs are stale. Refresh with
   \`gh api -X PUT repos/$REPO_SLUG/pulls/<N>/update-branch\`, then move on (do not wait).
4. **\`pipeline-compliance\` red** → read the diff, then record a REAL verdict for that head
   (\`record-review.sh\` from the controller's runtime dir, \`<N> <head-sha> <verdict> $REPO_SLUG\`), or a
   real scoping comment, or a line-initial issue ref. Re-run the repo's own compliance checker.
5. **Genuinely broken** → skip and say why in one line.

⛔ Never fabricate: no record for a diff you did not read, no clean verdict on a broken diff.
"Not sound, skipped" is a success. Never force-push, never admin-merge, never merge with a failing
check. Report to \`$AI/logs/REPORT-drainer-\$(date +%H%M)-$3.md\`: per PR one line, then totals.

$(_gate_block)
BRIEFEOF
}

# ── THE TICK ──────────────────────────────────────────────────────────────────────────────────
_settle_lanes
_reap_leftovers

# ⛔ THE LANES DISPATCHED HERE ARE REMOVED ONLY WHEN THEIR PID IS PROVABLY DEAD. A signal to THIS tick
# (launchd bootout, a reboot, an operator's Ctrl-C on a hand-run copy) says nothing about the lanes,
# which may be mid-edit in their checkouts — `git worktree remove --force` there destroys uncommitted
# work, the P0 this fleet has already paid for. The pid is the guard. (And because the tick never waits
# for a lane, EVERY lane it dispatches outlives it: the next tick's settle removes the tree once the
# pid is gone, which is why `_settle_lanes` — not this trap — is the normal removal path.)
LANE_PIDS=()
rm_worktrees_on_exit() { # [loud] — one aggregate line normally, per-lane detail on a signal
  local n pid w live=0
  for n in "${LANE_PIDS[@]:-}"; do
    [ -n "$n" ] || continue
    pid="$(tr -dc '0-9' 2>/dev/null <"$LANES_DIR/$n.pid")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      live=$((live + 1))
      [ "${1:-}" = "loud" ] && log_line "LEAVE: lane $n (pid $pid) is still live — leaving worktree $AI/wt-drainer-$n in place (a later tick reaps it once the pid is gone)"
      continue
    fi
    w="$AI/wt-drainer-$n"
    [ -d "$w" ] && _rm_wt "$w"
  done
  # ⛔ NOT A WARN. Every lane a tick dispatches outlives it (the tick never waits), so "left in place"
  # is the NORMAL state — a WARN per lane per tick is how a reader learns to ignore the log. The
  # removal path is `_settle_lanes` on the next tick, once the pid is gone.
  [ "$live" -eq 0 ] || [ "${1:-}" = "loud" ] || log_line "LEAVE: $live live lane(s) still working — their worktrees stay until the pid dies; the next tick reaps them"
}
_on_signal() { beat 2>/dev/null; rm_worktrees_on_exit loud; exit 143; }
trap 'beat 2>/dev/null; rm_worktrees_on_exit; cleanup' EXIT
trap _on_signal INT TERM

# The census runs INSIDE the lock (it is part of the decision the lock protects) and AFTER settle, so a
# lane that just died is no longer counted.
# `disp_shared` is the part of `procs` the dispatcher already accounts for; `_census_launcher` removes it
# so the two halves are disjoint and `alive` below is a sum of DISJOINT populations (#3886 review, P2-1).
read -r disp_alive disp_shared <<<"$(_census_dispatcher)"
case "${disp_alive:-}" in ''|*[!0-9]*) disp_alive=0 ;; esac
case "${disp_shared:-}" in ''|*[!0-9]*) disp_shared=0 ;; esac
lau_alive=""; lau_note=""
if [ "$CENSUS_LAUNCHER" = "1" ]; then
  lau_alive="$(_census_launcher "$disp_shared")" || lau_alive=""
  case "$lau_alive" in
    ''|*[!0-9]*) lau_note="launcher census UNREADABLE (wt_count gave '${lau_alive}') — counted dispatcher lanes only"; lau_alive="" ;;
  esac
else
  lau_note="launcher census unavailable: $CENSUS_LAUNCHER_WHY — counted dispatcher lanes only"
fi
# ⛔ `wt_count` CANNOT SAY "I COULD NOT READ THE TABLE".
# `wt_count` is `wt_table | awk … END{print n+0}` (`worker-terminal.sh`), so when `wt_table` aborts
# mid-loop — the octal-stamp / python / clock cases that module documents ("the census stays EMPTY:
# wt_count 0 (caps stop binding)") — it prints a perfectly valid `0`. Counting that as "no launcher
# workers" is the OVER-DISPATCH direction, and the census is now the only thing bounding the lane
# total. So the empty-table case is cross-checked against the worker records this box has: an empty
# table while records exist is a FAULT, not a quiet box. (The read is free: `wt_table` serves its own
# 10s memo.)
if [ "$CENSUS_LAUNCHER" = "1" ] && [ "${lau_alive:-0}" -eq 0 ]; then
  _rows="$(wt_table 2>/dev/null | grep -c . || true)"
  if [ "${_rows:-0}" -eq 0 ] && [ -n "$(ls "$O"/state/run-*.sh 2>/dev/null | head -1)" ]; then
    log_line "FAIL: the launcher census returned an EMPTY table while $O/state holds worker records — wt_table aborted, so the lane count is unknown and no lane may be added blind ($CENSUS_LAUNCHER_WHY)"
    finish 1
  fi
fi
# ⛔ `disp_alive` and `lau_alive` are DISJOINT (the launcher clamp removed the dispatcher's share of the
# process count — see `_census_launcher`), which is the only reason a plain sum is the live-lane count.
# ⛔ AND THE THIRD TERM IS A LANE THE PID CENSUS CANNOT SEE (agent-infra#2787): `SETTLE_HELD` counts the
# records whose pid is gone while their checkout is still held. It is named separately in `alive_src`
# because it is measured by a DIFFERENT instrument (the holder probe) and an operator must be able to
# see which one answered — the incident's tick printed `lanes=0` while a `cap=3000s` lane was alive.
lanes=$((disp_alive + ${lau_alive:-0} + SETTLE_HELD))
alive_src="dispatcher=$disp_alive"
[ -n "$lau_alive" ] && alive_src="$alive_src launcher=$lau_alive"
[ "$SETTLE_HELD" -gt 0 ] && alive_src="$alive_src held=$SETTLE_HELD(pid-gone-checkout-held)"
[ -n "$lau_note" ] && alive_src="$alive_src ($lau_note)"

# ⛔ THE HARD GUARDS COME FIRST AND EACH NAMES ITSELF. A guard that refuses without saying which read
# refused sends an operator to fix the wrong resource (`docs/ops/fleet-capacity.md` §5).
if [ "$PLATFORM" = "darwin" ]; then
  # ⛔ NO FREE-SWAP FLOOR ON DARWIN — see `_platform` and the OVERRIDES block. The floor that used to
  # live here refused THIS box at `swap_free=412MB < 700MB (of 3072MB)` while
  # `kern.memorystatus_vm_pressure_level` read 1 = normal and `memory_pressure -Q` read 52% free: it
  # was reading the size the kernel had already grown the swap FILE to, not the room this box has.
  # What refuses instead is the kernel's own pressure verdict, which is a CURRENT reading.
  if [ "$swap_total" -eq 0 ]; then
    swap_note="swap=none (no swap on this box) pressure=$(_pressure_name "$pressure_level")"
  else
    swap_note="swap=${swap_free}MB/${swap_total}MB (darwin: kernel-grown on demand, not a floor) pressure=$(_pressure_name "$pressure_level")"
  fi
  if [ "$pressure_level" -ge "$MAX_MEM_PRESSURE_LEVEL" ]; then
    log_line "SKIP: memory pressure $(_pressure_name "$pressure_level") (kern.memorystatus_vm_pressure_level=${pressure_level}) >= ${MAX_MEM_PRESSURE_LEVEL} — the box is under pressure NOW, so no lane is added; $swap_note"
    finish 0
  fi
elif [ "$swap_total" -eq 0 ]; then
  # ⛔ NO SWAP IS NOT ZERO CAPACITY (see OVERRIDES in the header): the cells ship with none, and
  # folding "absent" into "0 MB free" made every tick on every cell skip — a permanently inert job
  # that exited 0 and looked idle.
  swap_note="swap=none (this box has no swap — the floor does not apply)"
else
  swap_note="swap=${swap_free}MB/${swap_total}MB"
  if [ "$swap_free" -lt "$MIN_SWAP_MB" ]; then
    log_line "SKIP: swap ${swap_free}MB < ${MIN_SWAP_MB}MB floor (of ${swap_total}MB)"; finish 0
  fi
fi
load_ceiling_100=$((NCPU * LPC_CEILING * 100))
if [ "$lo100" -ge "$load_ceiling_100" ]; then
  log_line "SKIP: load $(awk -v l="$lo100" 'BEGIN{printf "%.2f", l/100}') >= ${LPC_CEILING}x${NCPU} ($(awk -v l="$load_ceiling_100" 'BEGIN{printf "%.2f", l/100}')) — do not ADD work to a saturated box; $alive_src; $swap_note"
  finish 0
fi
read -r target cpu_ceil mem_ceil mem_pool <<<"$(_capacity_target)"
if [ -n "$TARGET_PIN" ]; then
  target="$TARGET_PIN"
  target_why="target=$target (PINNED by TARGET_LANES)"
else
  target_why="target=$target (cpu=${cpu_ceil} mem=${mem_ceil} from mem_avail=${mem_avail}MB pool=${mem_pool}MB@${MEM_BUDGET_PCT}%/${LANE_MEM_MB}MB)"
fi

# ⛔ HOW MANY LANES MAY BE ADDED, and the one clamp that stops two lanes sharing a slice. With
# `SLICE_TOTAL/SLICE_WIDTH` = 7 distinct windows, a 13th lane would land on lane 6's: fewer lanes is
# the answer, never overlapping ones.
slices=$((SLICE_TOTAL / SLICE_WIDTH))
[ "$slices" -ge 1 ] || slices=1
# ⛔ BOUND THE LOOP'S OWN RANGE. Every other derived number here is clamped; `slices` was not, and
# SLICE_TOTAL=10000000000 with SLICE_WIDTH=1 is a multi-billion-iteration walk WHILE HOLDING THE LOCK
# — every later tick would then skip and the box would silently stop dispatching.
[ "$slices" -le 64 ] || { log_line "WARN: SLICE_TOTAL/SLICE_WIDTH=$slices > 64 windows — using 64"; slices=64; }
n=$((target - lanes))
[ "$n" -ge 0 ] || n=0
if [ "$n" -gt "$slices" ]; then
  log_line "NOTE: target−alive=$n exceeds the $slices distinct slice(s) (SLICE_TOTAL=$SLICE_TOTAL/SLICE_WIDTH=$SLICE_WIDTH) — dispatching at most $slices so one tick never reuses a window"
  n="$slices"
fi
cursor="$(cat "$CURSOR" 2>/dev/null || printf '0')"
case "$cursor" in '' | *[!0-9]*) cursor=0 ;; *) cursor=$((10#$cursor)) ;; esac
# The FREE windows this tick may take: the ring walked from the cursor, minus what a LIVE lane holds.
held="$(_held_offsets)"
FREE=()
k=0
while [ "$k" -lt "$slices" ]; do
  # ⛔ INDEX BY WINDOW, NOT BY BYTE OFFSET. `(cursor+k)*WIDTH % TOTAL` drifts off-grid when TOTAL is
  # not a multiple of WIDTH (TOTAL=75, WIDTH=10 issued 70 5 15 25 …, where 70 is past the end of the
  # list and [5,15) overlaps [10,20)). `((cursor+k) % slices) * WIDTH` is identical for the shipped
  # 70/10 and correct otherwise.
  off=$(( ((cursor + k) % slices) * SLICE_WIDTH ))
  case "$held" in
    *" $off "*) : ;;                    # a live lane is working it — not this tick's to give
    *) FREE+=("$off") ;;
  esac
  k=$((k + 1))
done
if [ "$n" -gt "${#FREE[@]}" ]; then
  [ "$n" -eq 0 ] || log_line "NOTE: $n lanes wanted but only ${#FREE[@]} of $slices window(s) are free (live lanes hold${held:- none yet}); dispatching ${#FREE[@]}"
  n="${#FREE[@]}"
fi
if [ "$n" -eq 0 ]; then
  # ⛔ ZERO IS A NORMAL ANSWER, and it is logged with the same arithmetic as a dispatch so nobody has
  # to guess why the box is quiet: at target, the ring is fully held by live lanes, or the target
  # itself is 0 because memory/cores say so.
  log_line "SKIP: nothing to add — $target_why alive=$lanes ($alive_src) free_windows=${#FREE[@]}/$slices $swap_note load=$(awk -v l="$lo100" 'BEGIN{printf "%.2f", l/100}')"
  finish 0
fi
# ⛔ THE SEED IS PROVEN BEFORE THE FIRST LANE, NOT DISCOVERED PER LANE (agent-infra#2787). MEASURED
# 2026-10-25: one tick could not create a replacement worktree (`FAIL: cannot create a worktree from
# /tmp/cell-ai-main (origin/main)` — that seed was simply gone), and the SAME tick had removed a live
# lane's checkout a minute earlier. A missing seed is a per-tick PRECONDITION, so it is refused once,
# BEFORE any brief, worktree, sidecar or record exists — which is what makes the tick's state
# unambiguous (nothing was half-dispatched) and what stops the per-lane message from being the first
# place an operator hears it. The per-lane check below STAYS: the seed can vanish between this line and
# the Nth lane, and a race is a different fact from a broken precondition.
if ! git -C "$SEED_REPO" rev-parse --git-dir >/dev/null 2>&1; then
  log_line "FAIL: SEED_REPO=$SEED_REPO is not a git checkout (missing, wiped, or not a repo) — no lane was dispatched, no worktree was created and no record was written; every earlier tick's record still stands"
  finish 1
fi
if ! git -C "$SEED_REPO" rev-parse --verify -q "$SEED_REF" >/dev/null 2>&1; then
  log_line "FAIL: SEED_REPO=$SEED_REPO has no ref '$SEED_REF' to branch a lane from — no lane was dispatched, no worktree was created and no record was written; fetch the seed (git -C $SEED_REPO fetch origin) or set SEED_REF"
  finish 1
fi
log_line "START: $target_why alive=$lanes ($alive_src) dispatching $n $swap_note load=$(awk -v l="$lo100" 'BEGIN{printf "%.2f", l/100}') slices=$slices free_windows=${#FREE[@]} dispatcher=$DISPATCH"

# ──8<── topup-loop ───────────────────────────────────────────────────────────────────────────
# ⛔ THIS LOOP IS THE WHOLE CHANGE. Before it, `bash "$DISPATCH"` ran ONCE per tick and the tick
# then blocked until that lane died; `ai-drainer.test.sh`'s non-vacuity arm re-runs this file with
# `n=1` injected immediately after the marker above and REQUIRES arm (a) to fail there — a top-up
# test that still passes with the top-up removed is testing nothing.
i=0
while [ "$i" -lt "$n" ]; do
  start="${FREE[$i]}"
  # ⛔ THE LANE NAME CARRIES THIS PID AND THE SLOT. A second-resolution name collides whenever two
  # lanes start in the same wall-clock second (all of them, in one tick), and the dispatchers TRUNCATE
  # `$O/bg/<name>.log` and `rm -f $O/bg/<name>.rc` on reuse: a running lane's transcript is destroyed
  # and its exit status is lost.
  NAME="ai-drain-$(date +%H%M%S)-$$-$((i + 1))"
  brief_lane="$AI/state/drainer-brief-$NAME.md"
  _write_brief "$start" "$brief_lane" "$NAME" "$n"
  # `drainer-brief.md` stays the LATEST brief, because `docs/ops/ai-drainer.md` names it as the artifact
  # an operator reads.
  cp "$brief_lane" "$BRIEF" 2>/dev/null || true
  wt="$AI/wt-drainer-$NAME"
  if ! git -C "$SEED_REPO" worktree add -f "$wt" "$SEED_REF" >/dev/null 2>&1; then
    log_line "FAIL: cannot create a worktree at $wt from $SEED_REPO ($SEED_REF) — dispatched ${i} of ${n} before this, their records stand"
    exit 1
  fi
  if ! bash "$DISPATCH" "$NAME" "$wt" "$brief_lane" "$LANE_TIMEOUT" >>"$LOG" 2>&1; then
    log_line "FAIL: dispatcher refused ($DISPATCH) on $NAME — dispatched ${i} of ${n} before this, their records stand"
    exit 1
  fi
  lane_pid="$(tr -dc '0-9' 2>/dev/null <"$O/bg/$NAME.pid")"
  # ⛔ AN UNREADABLE LANE PID IS A FAILURE, NOT A SKIPPED RECORD. An empty pid would make the record
  # claim a lane whose liveness can never be established, so its worktree would never be reapable and
  # its status never settled — the "dispatched and forgotten" shape.
  if [ -z "$lane_pid" ]; then
    log_line "FAIL: dispatcher returned but $O/bg/$NAME.pid is missing or unreadable — this lane cannot be counted or settled, so this tick reports failure instead of a false clean"
    exit 1
  fi
  # ⛔ THE SIDECAR AND THE WINDOW COME FIRST. The reaper keys on `<wt>.lane-pid` and the held-window
  # skip keys on `<name>.slice`: written after the checked record, a tick killed in between leaves a
  # LIVE lane whose tree is UNKNOWN (never reaped — the #1095 accumulation shape) or whose window
  # nothing claims (re-issued to a second lane — the double-dispatch this change exists to prevent).
  printf '%s' "$lane_pid" >"$wt.lane-pid" 2>/dev/null   # the reaper's evidence (see _reap_leftovers)
  printf '%s' "$start" >"$LANES_DIR/$NAME.slice" 2>/dev/null \
    || log_line "WARN: cannot write $LANES_DIR/$NAME.slice — a later tick cannot see that this window is held"
  # ⛔ EVERY RECORD WRITE IS CHECKED. An unchecked failure here is the "dispatched and forgotten"
  # shape this file refuses elsewhere: a lane whose record cannot be written is counted by the census
  # while alive but its `.rc` is NEVER read (settle iterates the records), so it is never DONE, never
  # FAILed, and its worktree is never reaped by settle. The pidfile read a few lines above is already
  # a hard FAIL for the same reason.
  if ! printf '%s' "$lane_pid" >"$LANES_DIR/$NAME.pid" 2>/dev/null; then
    log_line "FAIL: cannot write the lane record $LANES_DIR/$NAME.pid — the lane $NAME (pid $lane_pid) would never be counted or settled"
    finish 1
  fi
  LANE_PIDS+=("$NAME")
  # ⛔ THE CURSOR ADVANCES PER LANE, INSIDE THE LOOP. Written once after the loop, a tick killed
  # mid-loop would leave the cursor at the FIRST slice while its earlier lanes are already working the
  # ones after it — and the next tick would re-dispatch them.
  cursor=$((cursor + 1))
  if ! printf '%s' "$cursor" >"$CURSOR" 2>/dev/null; then
    log_line "FAIL: cannot write the slice cursor $CURSOR — the next tick would restart at this tick's first window and hand out windows live lanes already hold"
    finish 1
  fi
  log_line "DISPATCHED: lane $NAME pid=$lane_pid slice-offset=$start worktree=$wt"
  i=$((i + 1))
done
# ──8<── /topup-loop ──────────────────────────────────────────────────────────────────────────

log_line "DONE: dispatched $n lane(s) to fill target=$target (alive was $lanes, now $((lanes + n))); the tick does not wait for them — the next tick counts them and tops up"
finish 0
