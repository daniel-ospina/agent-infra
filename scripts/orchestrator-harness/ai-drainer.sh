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
# ── ALL FOUR GUARDS ────────────────────────────────────────────────────────────────────────────
#   * LOCK — one tick's critical section at a time; never held for a lane's lifetime (see above).
#   * CAPACITY — the formula above, plus the swap floor where a box HAS swap, plus fail-closed
#     handling of an unreadable probe (a guard that could not be evaluated must not look like an idle
#     box — `docs/ops/fleet-liveness.md`'s abstention doctrine).
#   * SLICE — a rotating window over the open list that advances PER LANE, so N lanes in one tick work
#     N DISJOINT windows. Rotation is capped at the number of distinct slices
#     (`SLICE_TOTAL/SLICE_WIDTH`), because a 13th lane on 7 windows would land on lane 6's: fewer
#     lanes is the correct answer, not overlapping ones. ⛔ AND ACROSS TICKS: a lane keeps its window
#     for up to LANE_TIMEOUT (~2.5 ticks), so the windows LIVE lanes hold are read from their records
#     and skipped — a tick whose ring is fully held dispatches nothing and says so.
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
#   MAX_LANES         CPU-side ceiling of the target        default: DERIVED — floor(ncpu × 5/2)
#                     (0 is legal and means "never dispatch"; an explicit value is never recomputed)
#   TARGET_LANES      pin the WHOLE target, overriding both derivations (operator's explicit call)
#   LANE_MEM_MB       resident budget per lane (MB)                  default: 512  (see above)
#   MEM_BUDGET_PCT    share of the available pool the target may use  default: 75
#   MIN_MEM_FREE_MB   memory floor a lane may not eat into (MB)       default: 512
#   MIN_SWAP_MB       swap floor, applied only where swap EXISTS (MB) default: 700
#   LPC_CEILING       load-per-cpu at which no lane is added          default: 8
#   LANE_TIMEOUT      the lane's own wall-clock cap (seconds)         default: 3000
#   RC_GRACE_S        grace after a lane's pid dies for its status file (s)  default: 30
#   PR_BUDGET         PRs one lane may process                        default: 6
#   SLICE_WIDTH       PRs per slice                                   default: 10
#   SLICE_TOTAL       open-list length the slice wraps over            default: 70
#   LOG               drainer log        default: $AI/logs/ai-drainer.log
#
# TEST SEAMS (read-only overrides; production sets none of them):
#   NCPU LOAD1_100 MEM_AVAIL_MB SWAP_TOTAL_MB SWAP_FREE_MB   skip the platform probes
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
LPC_CEILING="${LPC_CEILING:-8}"
LANE_TIMEOUT="${LANE_TIMEOUT:-3000}"
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
MIN_MEM_FREE_MB="$(_num MIN_MEM_FREE_MB "$MIN_MEM_FREE_MB" 512)"
LANE_MEM_MB="$(_num LANE_MEM_MB "$LANE_MEM_MB" 512)"
[ "$LANE_MEM_MB" -ge 1 ] || { log_line "WARN: LANE_MEM_MB=0 — using 1"; LANE_MEM_MB=1; }
MEM_BUDGET_PCT="$(_num MEM_BUDGET_PCT "$MEM_BUDGET_PCT" 75)"
[ "$MEM_BUDGET_PCT" -ge 1 ] || { log_line "WARN: MEM_BUDGET_PCT=0 would allow no lanes at all — using 1"; MEM_BUDGET_PCT=1; }
[ "$MEM_BUDGET_PCT" -le 100 ] || { log_line "WARN: MEM_BUDGET_PCT=$MEM_BUDGET_PCT > 100 — using 100"; MEM_BUDGET_PCT=100; }
LPC_CEILING="$(_num LPC_CEILING "$LPC_CEILING" 8)"
[ "$LPC_CEILING" -ge 1 ] || { log_line "WARN: LPC_CEILING=0 — using 1"; LPC_CEILING=1; }
LANE_TIMEOUT="$(_num LANE_TIMEOUT "$LANE_TIMEOUT" 3000)"
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

# ── SETTLE: THE OUTCOME OF LANES AN EARLIER TICK DISPATCHED ────────────────────────────────────
# ⛔ THE LANE'S OWN EXIT STATUS IS STILL THE VERDICT — it is just read by the NEXT tick instead of by
# this one. The tick never blocks on a lane (that is what starved the box), so a lane's record outlives
# it: this pass reports every record whose pid has died, removes its worktree once the pid is provably
# gone, and deletes the record so it is reported EXACTLY once. A lane still alive is left alone and
# still counted by the census.
SETTLED_FAIL=0
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
_rm_wt() { # <worktree path> — only ever called for a lane whose pid is PROVABLY DEAD
  # ⛔ THE `|| rm -rf` FALLBACK IS NOT REDUNDANT: a leftover directory is not always a REGISTERED git
  # worktree (a wiped $SEED_REPO, a hand-made copy, a half-created tree), and `git worktree remove`
  # refuses those — so a reaper that only called git would leave them for ever and log "could not
  # remove" every tick (the shape that made 407 worktrees / 179 GB accumulate, #1095).
  git -C "$SEED_REPO" worktree remove --force "$1" >/dev/null 2>&1 && { rm -f "$1.lane-pid" 2>/dev/null; return 0; }
  rm -rf "$1" 2>/dev/null && { rm -f "$1.lane-pid" 2>/dev/null; return 0; }
  log_line "WARN: could not remove the worktree at $1 — a later tick reaps it; it is named, not silent"
}
_settle_lanes() {
  local f name pid rc rc_file g w
  for f in "$LANES_DIR"/*.pid; do
    [ -f "$f" ] || continue
    name="${f##*/}"; name="${name%.pid}"
    pid="$(tr -dc '0-9' 2>/dev/null <"$f")"
    [ -n "$pid" ] || { rm -f "$f" "$LANES_DIR/$name.slice"; continue; }
    kill -0 "$pid" 2>/dev/null && continue          # still working — not this tick's news
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
    w="$AI/wt-drainer-$name"
    [ -d "$w" ] && _rm_wt "$w"
  done
}
# ⛔ `git worktree prune` IS NOT A LEFTOVER REAPER: it only drops administrative entries whose directory
# is ALREADY GONE, and a leftover from a SIGKILLed tick still has its directory. Reap by the pid the
# tree's own sidecar carries: a `wt-drainer-*` whose sidecar pid is dead is reclaimable; a live one is
# still in use; NO SIDECAR means UNKNOWN, and an unknown tree is left for an operator (a health job
# does not guess).
_reap_leftovers() {
  local w lane n=0
  for w in "$AI"/wt-drainer-*; do
    case "$w" in *.lane-pid) continue ;; esac       # the sidecar is not a worktree
    [ -d "$w" ] || continue
    lane=""
    [ -f "$w.lane-pid" ] && lane="$(tr -dc '0-9' 2>/dev/null <"$w.lane-pid")"
    [ -n "$lane" ] || continue
    kill -0 "$lane" 2>/dev/null && continue
    _rm_wt "$w"
    n=$((n + 1))
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
  local c="$1" t b
  [ -n "$c" ] || return 1
  for t in $c; do
    case "$t" in
      /*) b="${t##*/}"; [ "$b" = "pi" ] && return 0 ;;
      pi) return 0 ;;                        # argv[0] literally `pi` (no shebang rewrite)
    esac
  done
  for b in nonblocking-dispatch.sh bg-dispatch.sh lane.sh fix-one.sh merge-one.sh \
           chain-merge.sh dispatch-merge.sh; do
    case "$c" in *"$b"*) return 0 ;; esac
  done
  return 1
}
_census_dispatcher() { # prints the count of live dispatcher lanes
  local f p c n=0
  for f in "$O"/bg/*.pid; do
    [ -f "$f" ] || continue
    p="$(tr -dc '0-9' 2>/dev/null <"$f")"
    [ -n "$p" ] || continue
    kill -0 "$p" 2>/dev/null || continue          # a dead pidfile is not a lane
    c="$("$PS" -p "$p" -o command= 2>/dev/null | head -1)"
    # ⛔ AN UNREADABLE COMMAND LINE IS ALIVE (the fleet's own liveness polarity: unknown is alive).
    # Counting it as absent was the over-dispatch direction, and the census is now the ONLY thing
    # bounding the lane total (the lock no longer is) — so a `ps` that cannot answer (absent under the
    # unit's PATH, `hidepid`, another uid) must never read as "no lanes".
    if [ -z "$c" ]; then n=$((n + 1)); elif _counts_as_lane "$c"; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
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
_census_launcher() { # prints the count, or nothing when unreadable
  local n
  n="$(wt_count lane- fix- merge- chain- 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$n"
}

# ── WHICH SLICES ARE ALREADY BEING WORKED ────────────────────────────────────────────────────
# ⛔ THE RING CLAMP ALONE DOES NOT PREVENT A DOUBLE-DISPATCH ACROSS TICKS. `n` is capped at the
# number of distinct windows (SLICE_TOTAL/SLICE_WIDTH = 7 at the shipped defaults), but a LIVE lane
# keeps its window for up to LANE_TIMEOUT (3000 s ≈ 2.5 ticks): tick 1 takes offsets 0…60, tick 2
# walks the ring from cursor=7 back to 0 and hands 0/10/20 to NEW lanes while the first lanes are
# still on them — two lanes per window, two reviews per head, two merge attempts per PR. So the
# cursor alone is not enough: the offsets a live lane HOLDS are read from the lane records and
# skipped, and if the ring holds no free window the tick dispatches nothing and says so.
_held_offsets() { # prints " 0 10 30 " — offsets held by lanes whose pid is still alive
  local f name pid off held=" "
  for f in "$LANES_DIR"/*.pid; do
    [ -f "$f" ] || continue
    name="${f##*/}"; name="${name%.pid}"
    pid="$(tr -dc '0-9' 2>/dev/null <"$f")"
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
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
disp_alive="$(_census_dispatcher)"
lau_alive=""; lau_note=""
if [ "$CENSUS_LAUNCHER" = "1" ]; then
  lau_alive="$(_census_launcher)" || lau_alive=""
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
lanes=$((disp_alive + ${lau_alive:-0}))
alive_src="dispatcher=$disp_alive"
[ -n "$lau_alive" ] && alive_src="$alive_src launcher=$lau_alive"
[ -n "$lau_note" ] && alive_src="$alive_src ($lau_note)"

# ⛔ THE HARD GUARDS COME FIRST AND EACH NAMES ITSELF. A guard that refuses without saying which read
# refused sends an operator to fix the wrong resource (`docs/ops/fleet-capacity.md` §5).
if [ "$swap_total" -eq 0 ]; then
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
