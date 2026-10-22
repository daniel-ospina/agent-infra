#!/usr/bin/env bash
# capacity.sh — MEASURED capacity placement: what each box is doing, and which box may take the next
# lane. Sourced by `orch-loop.sh` (one probe + one placement decision per dispatch) and runnable
# STANDALONE (`bash capacity.sh probe`), because the same bytes must answer the question on whichever
# box you are standing on. It never calls `set` — a sourced library must not mutate its caller's
# shell options.
#
# ── WHY THIS EXISTS (measured 2026-10-21 09:45, all three cells) ────────────────────────────────
#   cell-1  load 29.82 on 8 cpu, 105 `pi` processes, 5 sessions   ← SATURATED
#   cell-3  load  8.14 on 4 cpu,  67 `pi`
#   cell-4  load  0.56 on 8 cpu,  23 `pi`, 5 sessions             ← IDLE, twice cell-3's size
# One box was saturated while a box twice its size sat idle, and NOTHING MOVED THE WORK. Every
# placement decision in the fleet was LOCAL: `orch-loop.sh`'s gate chain (`load=$L>=max_load=$MAX_LOAD`,
# `lanes=$LANES>=max_lanes`, `swap_free=…`, `mem_avail=…`) reads only the box it runs on, and the ONE
# cross-box signal was `capacity_yield_live()` — which fires only AFTER a box has already refused an
# item (#1909). A box that is merely busy (half its ceiling) never yields, so the fleet has no notion
# of "the box next door is idle". This file is that notion: MEASURED, not assigned.
#
# ⛔ THERE IS NO FIXED BOX→WORK ASSIGNMENT TO PRESERVE, AND NOTHING ASSIGNED A LANE TO A BOX BEFORE
# THIS FILE. The only cross-box placement that existed was the FIRST-COME CLAIM (`claims.sh`
# `claim_issue_acquire`: an atomic CAS on `refs/claims/issue-<N>`) — i.e. whichever box's controller
# reached a candidate first won it, with no measurement of either box. The single recorded
# box→repo pin is the owner's own sentence in `orchestrator-heartbeat.sh` FA3 ("advance agent-infra
# (cell-2 owns it)"), which is a REPO OWNERSHIP statement about the heartbeat's standing order and
# is NOT touched here: this file chooses a box for a LANE DISPATCH, never re-assigns a repo. (It is
# also why the heartbeat's FA2 — "dispatch locally if the local machine has room, on a cloud VM if
# it is idle" — is an ORDER this file is the missing half of; it is quoted in that file, not here.)
#
# ── WHAT THE PROBE RETURNS, AND WHY EACH FIELD IS THERE ─────────────────────────────────────────
#   host=<name>            the box's own identity (`hostname -s`, or CAP_HOST). The KEY of a record.
#   ncpu=<int>             cores, so load can be compared ACROSS boxes of different sizes.
#   load1=<int>            1-min load average x100 (integer arithmetic: bash 3.2 has no floats).
#   lpc=<int>              LOAD PER CPU x100 — the one capacity number the rule compares. 29.82 on 8
#                          cpu is lpc=372; 8.14 on 4 cpu is lpc=203; 0.56 on 8 cpu is lpc=7.
#   lanes=<int>            lane worktrees live on the box. REPORTED, NEVER A CEILING (see below).
#   disk_free_mb=<int>     free space on the filesystem the repo lives on — the volume that ACTUALLY
#                          fills. A lane's worktree is ~1.1 GB before its venv (#2159), so disk is a
#                          placement bound, not a footnote.
#   mem_free_mb=<int>      available memory (MemAvailable / `free`+`inactive`), the same helper the
#                          controller's own gate uses.
#   at=<epoch>             when it was measured. A record with no age is a stale flag waiting to be
#                          read as current, so the age is part of the record and the TTL is enforced.
#   procs=<int>            live processes on the box (see FORK HEADROOM below). The population the
#                          per-uid/cgroup ceiling applies to, measured in the SAME namespace as the
#                          ceiling -- a count and a ceiling from two populations is not headroom.
#   procs_max=<int>        the ceiling those processes are counted against: the smallest of the
#                          per-uid soft limit (`ulimit -u`, read with a BUILTIN), the per-uid hard
#                          ceiling (`sysctl kern.maxprocperuid`, macOS, when present) and the cgroup
#                          pid ceiling (`pids.max`, Linux) -- all only when actually found.
#                          ⛔ `procs_max=0` MEANS NO CEILING WAS FOUND (unbounded), never "zero
#                          headroom": a box with no ceiling cannot be fork-bound.
#   fork=<1|0>             the TWO-FORK PROBE result: 1 = two concurrent forks completed, 0 = a fork
#                          could not be made. It is separate from the arithmetic on purpose (see the
#                          0.32x-load incident): the count can look fine while the kernel refuses.
#
# ── FORK HEADROOM: THE FIRST READ, BECAUSE IT IS THE ONE THAT KILLS ─────────────────────────────
# MEASURED, agent-infra#2293 (2026-10-21 19:50-20:10 UTC): cloud cell-4 (8 vCPU) could not spawn at
# all (`fork: Resource temporarily unavailable`, EAGAIN, rc 128) at load 2.54/8 = **0.32x** with 11
# lanes and 16 `pi` processes. The Mac hit the same wall minutes later, and there it is provable in
# isolation: `echo ok` (a builtin, no fork) worked while every spawn failed. Load was not the binding
# resource; MEMORY was not; a lane counter was not either (11 lanes is under any sane cap). The binding
# resource was PROCESS/FORK HEADROOM, and it is invisible to all three of the numbers this file used
# to read. A 12th lane placed by a load-only rule lands on a box with no pids left -- and the failure
# is not graceful: the box cannot be probed from inside, so nothing can clean it up locally, and every
# retry by an ALREADY-PLACED lane forks more, which amplifies the exhaustion.
#
# ⛔ WHY THE ORDER IS FORK -> DISK -> LOAD, EVERYWHERE (`cap_bound_hit`, the controller's own gate
# chain, and the spawn gate): the three failures have different remedies and different time scales.
#   fork  -- a box out of pids cannot spawn, cannot be probed, and cannot be cleaned from inside; the
#            remedy is EXTERNAL (restart it, or let it drain). Reporting a load refusal for it sends
#            an operator to wait for an event that cannot arrive.
#   disk  -- never clears by waiting either (a full filesystem stays full); the remedy is a prune.
#   load  -- clears on its own; the remedy is patience. It is LAST because on a box that dies at fork
#            before it ever gets CPU-busy, it is the least informative of the three.
#
# ⛔ A FORK FAILURE IS FATAL TO THE PROCESS THAT ATTEMPTS IT, so the READS are built to survive the
# condition they measure. MEASURED on this tree's bash (5.2.21): `ulimit -u 5; ( exit 0 )` prints
# `bash: fork: retry: Resource temporarily unavailable` four times, then `bash: fork: Resource
# temporarily unavailable`, and THE SCRIPT EXITS 254 -- it is not a per-command error that a loop can
# continue past (verified: a `while` loop died on its first failed fork). That is why:
#   * the COUNT is read without a fork where the platform allows it (a `/proc` glob expansion and the
#     `read`/`ulimit` BUILTINS; only macOS falls back to `ps`), because a `ps` there would be the very
#     fork that fails;
#   * the PROBE's failure is only observable across a process boundary: it runs inside a `( )`/`$( )`
#     child, so a refusal inside it costs THE CHILD (rc 254 = could not fork) and the caller lives;
#   * `bash capacity.sh probe` therefore exits **254** when it could not fork. A caller that must not
#     die (the controller) reads 254 as `fork_exhausted` and forks nothing further that cycle.
#
# ⛔ IT IS STILL NOT A LANE CAP. Nothing here bounds how many lanes a box may run; it bounds whether a
# box that CANNOT SPAWN may be given more work. The refusal names which read refused, so a fleet alarm
# distinguishes "this box needs an external restart" from "this fleet needs another box".
#
# ── THE CEILING: LOAD PER CPU, AND WHAT IT PROTECTS ────────────────────────────────────────────
# `CAP_LPC_CEILING=800` = 8.00 load per cpu. Measured, not derived: the fleet's own incident data
# puts the saturation point at 8-10x cpu load (cell-1 at 3.7x was already collapsing), and the
# controller's local hard gate is ncpu*10 (`MAX_LOAD`), so 8x is the "do not ADD work here" line
# one notch under the "do not start anything at all" line.
#
# Two lines, both load-per-CPU, and both named in the verdict:
#   CAP_LPC_CEILING (8.00)  — DO NOT PLACE HERE. Above it a box is ineligible, full stop.
#   CAP_YIELD_AT_LPC (4.00) — PREFER ELSEWHERE. At or above it, this box stands down for a
#                             materially-less-loaded peer; BELOW it, this box takes the work whoever
#                             else is idle (a box that yields everything it is offered is how a fleet
#                             dispatches nothing while all of it is healthy).
#
# ⛔ IT IS NOT A LANE CAP, AND THERE IS DELIBERATELY NO LANE CEILING TIED TO CPU COUNT HERE. The owner
# ruled on 2026-10-17 that "dispatch should be gated on capacity, not on number of lanes", and a lane
# count cannot see the two things that actually bind:
#   * **gh SERIALISATION PER BOX** — four boxes act as ONE GitHub account and `gh-limit` keeps ONE
#     gh call in flight per box (#1988/#1910), so every lane added to a box lengthens EVERY other
#     lane's gh wait on that box. That is the real bottleneck under concurrency, and it scales with
#     lanes, not with cores — so it is protected by refusing to PILE ON a box whose load-per-cpu says
#     its queue is already deep, and by moving the work to the least-loaded eligible box.
#   * **DISK** — ~1.1 GB per live worktree (#2159): a box can have every core idle and no room.
#   * **MEMORY** — swap pressure is how a box dies rather than slows (#1985/#1961).
# The refusal names WHICH of these bounds it hit (`bound=`), so "no box is eligible" is never a bare
# fact: `bound=load_per_cpu` is a fleet that needs more boxes, `bound=disk` is a box that needs a
# prune, `bound=memory` is a leak, and `bound=probe_unreadable` is an instrument failure.
#
# ── FAIL-CLOSED, IN THE ONE DIRECTION THAT MATTERS ────────────────────────────────────────────
# An UNREADABLE box is NOT eligible. An absent record, an unparseable field, or a record older than
# `CAP_PROBE_TTL` is never read as "probably fine": the whole point is that the fleet must not place
# blind. And if NO box is eligible the dispatch is REFUSED with the measured reason — it is never
# placed on a saturated box just because that box happens to be the one asking.
#
# ── THE TRANSPORT (why records are refs on the shared origin) ─────────────────────────────────
# The fleet's boxes share exactly ONE channel: the queue repo's origin. `claims.sh` already proves it
# (an atomic CAS on `refs/claims/*`, read with `git ls-remote`), so the probe uses the same channel
# and the same read primitive: each box publishes its own record as `refs/boxes/<host>/<record>` and
# every box reads the whole fleet with ONE `git ls-remote --refs refs/boxes/*` — no new daemon, no
# new credential, no per-box RPC. The reading lives in the REF NAME (a ref name is a string the
# transport already carries; fetching a blob per box per cycle would cost a fetch, and claims.sh's
# own encoding — `box:<pid>` — is the precedent). Publishing is best-effort and NEVER fails a
# dispatch: a box that cannot publish is simply INELIGIBLE to its peers, which is the fail-closed
# direction.
#
# USAGE (library)
#   . capacity.sh
#   rec="$(cap_probe_local "$REPO" "$LANES")"      # one record line, or empty (unreadable)
#   cap_publish "$REPO" "$rec"                     # best-effort; rc!=0 => peers cannot see this box
#   fleet="$(cap_read_fleet "$REPO")"              # every box's newest record, one per line; rc!=0 => UNREADABLE
#   cap_place "$(cap_host)" "$fleet" <<<""         # 0 = place=…, 1 = refuse bound=…, 2 = usage
#   cap_fork_bound "$rec"                          # the FORK bound that refuses this record ('' = none)
#   cap_fork_headroom "$rec"                       # spare processes, or `unbounded`
#
# USAGE (CLI)   bash capacity.sh probe|fork|place|fleet|publish [args]
# EXIT          0 decided · 1 refused (a REFUSAL IS NOT A FAILURE, it is the answer) · 2 cannot answer
#               254 the read itself COULD NOT FORK (bash terminates on a failed fork; see FORK HEADROOM)

# ── seams (every one overridable so the suite is hermetic) ──────────────────────────────────────
CAP_LPC_CEILING="${CAP_LPC_CEILING:-800}"      # hundredths of load-per-CPU => 8.00 (REFUSE line)
# ⛔ AND A SECOND, LOWER LINE — because "yield to the least-loaded peer" with no margin is a THRASH
# machine: every box would stand down for any box that happens to be 1% idler, and the fleet would
# dispatch nothing while all of it was healthy. `CAP_YIELD_AT_LPC` is the PREFER-ELSEWHERE line: a box
# at or above it hands a candidate to a materially-less-loaded peer; a box below it TAKES the work,
# whoever else is idler. That keeps throughput (a lightly-loaded box never stands down) while still
# moving work OFF a box that is piling up — and it is a load-per-CPU line, never a lane count.
CAP_YIELD_AT_LPC="${CAP_YIELD_AT_LPC:-400}"    # hundredths of load-per-CPU => 4.00
CAP_MIN_DISK_MB="${CAP_MIN_DISK_MB:-500}"      # same floor spawn-gate.sh enforces before a spawn
CAP_MIN_MEM_MB="${CAP_MIN_MEM_MB:-512}"        # same floor the controller's own mem gate uses
CAP_PROBE_TTL="${CAP_PROBE_TTL:-900}"          # a record older than this is STALE, never eligible
# ⛔ THE FORK MARGIN (agent-infra#2293): spare processes a box must still have before it may take
# another lane. It is a MARGIN, not a cap: the incident's numbers are nowhere near it (cell-1 was
# healthy at 453 procs against a 15641 `ulimit -u`), while an exhausted box has 0. 200 is "a handful
# of lanes' worth of transient forks" -- one `git clone` + `uv sync` burst, plus a cycle's worth of
# git/gh/awk in the controller and its lanes -- and it is deliberately far below any healthy box's
# reading so it cannot become the new Lane Cap Fetish the owner ruled out on 2026-10-17: nothing here
# counts LANES, it asks whether this box can still SPAWN.
CAP_MIN_FORK_HEADROOM="${CAP_MIN_FORK_HEADROOM:-200}"
CAP_NS="${CAP_NS:-refs/boxes}"                 # the namespace peers publish under
CAP_HOST="${CAP_HOST:-}"                       # identity seam (default: hostname -s)
CAP_NOW="${CAP_NOW:-}"                         # clock seam (default: date +%s)

cap_now() {
  if [ -n "${CAP_NOW:-}" ]; then printf '%s' "$CAP_NOW"; else date +%s; fi
}

cap_host() {
  if [ -n "${CAP_HOST:-}" ]; then printf '%s' "$CAP_HOST"; return 0; fi
  local h; h="$(hostname -s 2>/dev/null || hostname 2>/dev/null)" || h=""
  case "$h" in ''|*[!A-Za-z0-9._-]*) printf 'box'; return 0 ;; esac
  printf '%s' "$h"
}

cap_ncpu() {
  local n; n="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)" || n=""
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -ge 1 ] || return 1
  printf '%s' "$n"
}

# cap_load1_100 — the 1-min load average as an integer in hundredths. Empty + rc 1 when unreadable:
# a probe that cannot read load must be UNKNOWN, never 0 (0 is a real, very good, reading).
cap_load1_100() {
  local v
  if [ -r /proc/loadavg ]; then
    v="$(awk 'NR==1{print $1; exit}' /proc/loadavg 2>/dev/null)"
  else
    v="$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2; exit}')"
  fi
  case "$v" in ''|*[!0-9.]*|*.*.*) return 1 ;; esac
  printf '%s' "$(awk -v x="$v" 'BEGIN{printf "%d", (x * 100) + 0.5}')"
}

cap_mem_free_mb() {
  # Prefer the controller's own portable helper when it is already loaded (ONE probe, one answer).
  if command -v mem_avail_mb >/dev/null 2>&1; then
    local m; if m="$(mem_avail_mb)" && [ -n "$m" ]; then printf '%s' "$m"; return 0; fi
  fi
  if [ -r /proc/meminfo ]; then
    awk '
      /MemAvailable:/ {a=$2} /MemFree:/ {f=$2} /^Cached:/ {c=$2}
      END { if (a=="") a=f+c; if (a=="") exit 1; printf "%d", a/1024 }' /proc/meminfo 2>/dev/null && return 0
    return 1
  fi
  vm_stat 2>/dev/null | awk '
    /page size of/ {ps=$8}
    /Pages free/ {gsub(/\./,"",$3); f=$3}
    /Pages inactive/ {gsub(/\./,"",$3); i=$3}
    END { if (ps=="") ps=16384; if (f=="") exit 1; printf "%d", ((f+i)*ps)/1048576 }' && return 0
  return 1
}

cap_disk_free_mb() { # <path> — MiB free on the filesystem <path> lives on (df -Pk is POSIX)
  local p="${1:-.}" mb
  mb="$(df -Pk "$p" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%d", int($4/1024); exit}')"
  case "$mb" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$mb"
}

# ── FORK HEADROOM (agent-infra#2293) — read FIRST, and read so that it survives what it measures ──
# cap_ulimit_u -> this shell's per-uid process soft limit, or empty when there is none/ unreadable.
# `ulimit -u` is a bash BUILTIN: it costs no fork, which is what makes it usable on a box that cannot
# fork. "unlimited" (root on Linux) is NOT a number and is reported as empty = no ceiling.
cap_ulimit_u() {
  local v; v="$(ulimit -u 2>/dev/null)" || v=""
  case "$v" in ''|unlimited|*[!0-9]*) return 1 ;; esac
  [ "$v" -ge 1 ] || return 1
  printf '%s' "$v"
}

# cap_maxprocperuid -> macOS's per-uid HARD ceiling (`kern.maxprocperuid`), or empty when absent.
# It is read BESIDE `ulimit -u` rather than instead of it: the soft limit is what the kernel enforces,
# but a box whose soft limit is `unlimited` still has a hard per-uid wall, and that wall is the one
# cell-4 hit. Absent on Linux (no such sysctl), where the cgroup arm covers the same ground.
cap_maxprocperuid() {
  local v; v="$(sysctl -n kern.maxprocperuid 2>/dev/null)" || v=""
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  [ "$v" -ge 1 ] || return 1
  printf '%s' "$v"
}

# cap_procs_live -> live process count.
# ⛔ FORK-FREE WHERE THE PLATFORM ALLOWS IT, AND THAT IS THE POINT (see the FORK HEADROOM header): a
# `ps` here would be the very fork that fails on the box we are trying to measure. A `/proc` glob is
# the shell's own readdir (no spawn), so Linux cells cost nothing; only macOS falls back to `ps`.
# A reading of 0 is IMPOSSIBLE (this shell is a process), so 0 is UNREADABLE, never "an idle box".
cap_procs_live() {
  local n=""
  if [ -d /proc/1 ]; then
    # `set --` in a function touches THIS function's positional parameters only.
    set -- /proc/[0-9]*
    case "${1:-}" in
      ''|'/proc/[0-9]*') : ;;   # no match: the pattern came back literally, so /proc was not readable
      *) n="$#" ;;
    esac
  fi
  if [ -z "$n" ]; then
    n="$(ps -e 2>/dev/null | wc -l 2>/dev/null | tr -d ' \t')" || return 1
  fi
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -ge 1 ] || return 1
  printf '%s' "$n"
}

# cap_h_for <procs> <max> -> headroom. `max` 0 means NO CEILING WAS FOUND and prints `unbounded`.
# cap_h_for_vars is the SAME arithmetic written to a variable, so an in-process caller (the controller,
# on the starved path) can read it with NO command substitution — a `$( )` is a fork, and a fork is the
# one thing that box cannot do. ONE implementation, two adapters.
cap_h_for_vars() {
  local p="${1:-}" m="${2:-}" __out=""
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$m" -eq 0 ]; then __out=unbounded
  else __out=$(( m - p )); [ "$__out" -lt 0 ] && __out=0; fi
  printf -v "$3" '%s' "$__out"
}
cap_h_for() {
  local o=""
  cap_h_for_vars "${1:-}" "${2:-}" o || return 1
  printf '%s' "$o"
}

# cap_procs_pair -> "<procs> <procs_max> <src>" — ONE population with ITS ceiling (src = uid|cgroup),
# choosing the pair with the SMALLEST headroom because the most binding ceiling is the one that fails.
# ⛔ THE PAIR IS ATOMIC ON PURPOSE. `pids.current` counts TASKS (threads) while `ps -e` counts
# PROCESSES, so a cgroup ceiling paired with a process count would SUBTRACT TWO DIFFERENT POPULATIONS
# and report headroom that does not exist — a fail-OPEN, the one direction that must not happen. So the
# cgroup arm reads pids.current beside pids.max, and the uid arm reads the process count beside
# `ulimit -u`; they are never mixed. rc 1 when no pair could be read at all.
cap_procs_pair() {
  local _cpp_p="" _cpp_m="" _cpp_s=""
  cap_procs_pair_vars _cpp_p _cpp_m _cpp_s || return 1
  printf '%s %s %s' "$_cpp_p" "$_cpp_m" "$_cpp_s"
}

# cap_procs_pair_vars <procsVar> <maxVar> <srcVar> — the SAME pair, written to variables instead of
# stdout, so a caller that must not spend a `$( )` per reading still gets an atomic pair. (It is NOT
# claimed to be fork-free: bash cannot capture a builtin's output — `ulimit -u` — without a subshell.
# What IS fork-free is the /proc COUNT, and that is the read the starved box most needs.)
# ⛔ EVERY WORKING LOCAL HERE IS PREFIXED `_cpv_`, AND THAT IS A CORRECTNESS RULE, NOT STYLE
# (verification gate, P0, agent-infra#2293). bash `local` is DYNAMIC: a variable a function declares is
# visible to the functions it calls, and `printf -v "$outvar"` writes to the nearest binding of that
# NAME. This function writes the CALLER's chosen variables, so working locals named `p`/`m`/`src`
# silently CAPTURED the write whenever the caller passed those names — the caller then read empty
# strings, the headroom arithmetic was skipped, and the spawn gate's fork arm answered `ok` on a box
# with 10 pids of headroom (fail-OPEN, driven: `run_agent` started the agent instead of refusing 74).
# A prefix makes the collision unreachable instead of improbable, and `spawn-gate.test.sh` now DRIVES
# this function with exactly the names the fail-open case used. `capacity-placement.test.sh` drives the
# SHIPPED caller (`cap_procs_pair`) too: the second round of this bug was THAT caller's `_cp_p`/`_cp_m`
# out-vars colliding with this function's working locals, which emptied every published record.
cap_procs_pair_vars() {
  local _pv="${1:-}" _mv="${2:-}" _sv="${3:-}" _cpv_best="" _cpv_besth="" _cpv_p _cpv_m _cpv_src _cpv_h _cpv_f _cpv_cur _cpv_max _cpv_hard
  for _cpv_f in /sys/fs/cgroup/pids.max /sys/fs/cgroup/pids/pids.max; do
    [ -r "$_cpv_f" ] || continue
    _cpv_max=""; read -r _cpv_max < "$_cpv_f" 2>/dev/null || _cpv_max=""
    case "$_cpv_max" in ''|max|*[!0-9]*) continue ;; esac
    [ "$_cpv_max" -ge 1 ] || continue
    _cpv_cur=""; read -r _cpv_cur < "${_cpv_f%/*}/pids.current" 2>/dev/null || _cpv_cur=""
    case "$_cpv_cur" in ''|*[!0-9]*) continue ;; esac
    _cpv_best="$_cpv_cur $_cpv_max cgroup"; _cpv_besth="$(cap_h_for "$_cpv_cur" "$_cpv_max")" || _cpv_besth=0
    break
  done
  if _cpv_p="$(cap_procs_live)"; then
    _cpv_m="$(cap_ulimit_u)" || _cpv_m=0
    _cpv_hard="$(cap_maxprocperuid)" || _cpv_hard=""
    if [ -n "$_cpv_hard" ] && { [ "$_cpv_m" -eq 0 ] || [ "$_cpv_hard" -lt "$_cpv_m" ]; }; then _cpv_m="$_cpv_hard"; fi
    _cpv_src=uid
    _cpv_h="$(cap_h_for "$_cpv_p" "$_cpv_m")" || _cpv_h=0
    [ "$_cpv_h" = "unbounded" ] && _cpv_h=999999999
    if [ -z "$_cpv_best" ] || [ "$_cpv_h" -lt "$_cpv_besth" ]; then _cpv_best="$_cpv_p $_cpv_m $_cpv_src"; _cpv_besth="$_cpv_h"; fi
  fi
  [ -n "$_cpv_best" ] || return 1
  _cpv_p="${_cpv_best%% *}"; _cpv_h="${_cpv_best#* }"; _cpv_m="${_cpv_h%% *}"; _cpv_src="${_cpv_h#* }"
  printf -v "$_pv" '%s' "$_cpv_p"
  printf -v "$_mv" '%s' "$_cpv_m"
  printf -v "$_sv" '%s' "$_cpv_src"
  return 0
}

# cap_fork_probe — TWO concurrent forks that must each complete. This is the only read that answers the
# question the incident actually asked ("can this box spawn AT ALL"), and it is the cheapest possible
# one: two subshells that `exit 0` — no exec, no binary, no PATH.
# ⛔ THE CALLER MUST NOT SHARE FATE WITH IT. A fork failure does not return an error to bash; it
# TERMINATES the shell that attempted the fork (measured: rc 254, the rest of the script never ran).
# So this MUST be called from a `$( )` substitution or a child, and the caller must read rc 254 as
# "this box could not fork". Called in the foreground of a long-lived process, its refusal kills it.
cap_fork_probe() {
  local a b
  ( exit 0 ) & a=$!
  ( exit 0 ) & b=$!
  [ -n "${a:-}" ] && [ -n "${b:-}" ] || return 1
  wait "$a" 2>/dev/null || return 1
  wait "$b" 2>/dev/null || return 1
  return 0
}

# cap_fork_read -> "procs=<n> procs_max=<n> fork=<1|0>"; rc 1 when neither the pair nor the probe could
# be read. `fork=0` (probe refused) is a READABLE record: it says the box cannot spawn, which is a
# measurement peers must see, not a reason to publish nothing.
cap_fork_read() {
  local pair p m src f=0
  pair="$(cap_procs_pair)" || return 1
  p="${pair%% *}"; m="${pair#* }"; m="${m%% *}"; src="${pair##* }"
  cap_fork_probe && f=1 || f=0
  printf 'procs=%s procs_max=%s fork=%s src=%s' "$p" "$m" "$f" "$src"
}

# cap_fork_headroom <record> -> spare processes, or `unbounded`, or rc 1 when unreadable.
cap_fork_headroom() {
  local r="${1:-}"
  cap_h_for "$(cap_kv "$r" procs)" "$(cap_kv "$r" procs_max)"
}

# cap_fork_bound <record> -> the FIRST fork bound that makes it ineligible, or empty. This is the
# headroom read in the PLACEMENT rule; `cap_bound_hit` calls it BEFORE disk and load.
#   fork_unknown    the record carries no fork reading (a legacy publisher). Fail-closed: a box whose
#                   headroom was never measured is not a box we may add work to.
#   fork_probe      the two-fork probe refused: the box could not spawn when it published.
#   fork_headroom   a ceiling WAS found and the spare processes are below CAP_MIN_FORK_HEADROOM.
cap_fork_bound() {
  local r="${1:-}" p m f h
  p="$(cap_kv "$r" procs)"; m="$(cap_kv "$r" procs_max)"; f="$(cap_kv "$r" fork)"
  case "$p" in ''|*[!0-9]*) printf 'fork_unknown'; return 0 ;; esac
  case "$m" in ''|*[!0-9]*) printf 'fork_unknown'; return 0 ;; esac
  case "$f" in
    '') printf 'fork_unknown'; return 0 ;;
    '1') : ;;
    *)  printf 'fork_probe'; return 0 ;;
  esac
  h="$(cap_h_for "$p" "$m")" || { printf 'fork_unknown'; return 0; }
  [ "$h" = "unbounded" ] && return 0
  [ "$h" -lt "$CAP_MIN_FORK_HEADROOM" ] && { printf 'fork_headroom'; return 0; }
  return 0
}

# cap_probe_local <repo-path> [lanes] -> one record line; rc 1 (and NO output) if a core field is
# unreadable. Lanes is passed IN by the controller (it already counts them by evidence); standalone
# callers get a worktree count.
cap_probe_local() {
  local repo="${1:-.}" lanes="${2:-}" ncpu load1 disk mem host at lpc fr
  ncpu="$(cap_ncpu)"      || return 1
  load1="$(cap_load1_100)" || return 1
  disk="$(cap_disk_free_mb "$repo")" || return 1
  mem="$(cap_mem_free_mb)" || return 1
  # ── FORK HEADROOM FIRST (agent-infra#2293). It is read before the fields above are USED and it is
  # the one read whose own failure is meaningful: a fork failure inside this substitution kills THIS
  # probe process with rc 254, which the controller reads as `fork_exhausted`.
  fr="$(cap_fork_read 2>/dev/null)" || fr=""
  case "$fr" in
    *procs=*procs_max=*fork=*) : ;;
    # ⛔ THE READ THAT DID NOT HAPPEN IS NOT HEADROOM. `fork=0` makes every reader treat this box as
    # INELIGIBLE (fork_probe) instead of publishing a record that reads as unmeasured-but-fine.
    *) fr="procs=0 procs_max=0 fork=0 src=unreadable" ;;
  esac
  if [ -z "$lanes" ]; then
    lanes="$(git -C "$repo" worktree list --porcelain 2>/dev/null | grep -c '^worktree .*lane-')" || lanes=0
  fi
  case "$lanes" in ''|*[!0-9]*) lanes=0 ;; esac
  host="$(cap_host)"; at="$(cap_now)"
  lpc="$(awk -v l="$load1" -v n="$ncpu" 'BEGIN{printf "%d", l/n}')"
  # The fork fields are APPENDED: existing consumers (`scripts/harness-up`, peers on an older tree)
  # parse the leading fields by key and ignore what follows, so this is additive, not a new grammar.
  printf 'host=%s ncpu=%s load1=%s lpc=%s lanes=%s disk_free_mb=%s mem_free_mb=%s at=%s %s' \
    "$host" "$ncpu" "$load1" "$lpc" "$lanes" "$disk" "$mem" "$at" "$fr"
}

# ── record parsing ─────────────────────────────────────────────────────────────
cap_kv() { # cap_kv <record> <key> -> value or empty
  local _kv_rec="${1:-}" _kv_key="${2:-}" _kv_out
  case "$_kv_key" in ''|*[!A-Za-z0-9_]*) return 0 ;; esac
  _kv_out="$(printf '%s\n' "$_kv_rec" | awk -v k="$_kv_key" '
    { n=split($0, f, " "); for (i=1;i<=n;i++) { if (index(f[i], k "=") == 1) { print substr(f[i], length(k)+2); exit } } }')"
  printf '%s' "${_kv_out:-}"
}

# cap_valid_base_record <record> — 0 iff every field the LOAD/DISK/MEMORY rule reads is present and
# numeric. Split out of cap_valid_record so a record that lacks ONLY the fork reading can be NAMED
# `fork_unknown` rather than lumped in with `probe_unreadable` (a named cause, not a blanket one).
cap_valid_base_record() {
  local r="${1:-}" k v
  for k in ncpu load1 lpc lanes disk_free_mb mem_free_mb at; do
    v="$(cap_kv "$r" "$k")"
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
  done
  case "$(cap_kv "$r" host)" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# cap_valid_record <record> — 0 iff every field the rule reads is present and numeric.
# ⛔ A MISSING FIELD IS NOT A ZERO. `lpc` absent must make the box INELIGIBLE, never "least loaded".
# ⛔ AND THAT INCLUDES THE FORK FIELDS: a record published before agent-infra#2293 (6-slot refs) has
# no fork reading, and is refused as `fork_unknown` — the fail-closed direction. This cannot strand a
# fleet: every box republishes every cycle and the reader keeps the NEWEST record per host, so a box
# on the new code is visible with a full record immediately, and only a DEAD box can still hold a
# fresh legacy ref (and a dead box is ineligible on every other axis anyway).
cap_valid_record() {
  local r="${1:-}" k v
  cap_valid_base_record "$r" || return 1
  for k in procs procs_max fork; do
    v="$(cap_kv "$r" "$k")"
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
  done
  return 0
}

cap_lpc_human() { awk -v x="${1:-0}" 'BEGIN{printf "%.2f", x/100}'; }

# cap_bound_hit <record> <now> -> the FIRST bound that makes it ineligible, or empty.
# The order is fixed so a refusal names a STABLE reason for a given fleet state, and it is
# FORK -> DISK -> LOAD -> MEMORY (see the FORK HEADROOM header for why this order and not another).
cap_bound_hit() {
  local r="${1:-}" now="${2:-}" at age lpc disk mem forkb
  cap_valid_base_record "$r" || { printf 'probe_unreadable'; return 0; }
  at="$(cap_kv "$r" at)"; age=$(( now - at ))
  [ "$age" -lt 0 ] && age=0
  if [ "$age" -gt "$CAP_PROBE_TTL" ]; then printf 'probe_stale'; return 0; fi
  # 1. FORK HEADROOM — a box that cannot spawn is refused even if every other number is lovely.
  forkb="$(cap_fork_bound "$r")"
  [ -n "$forkb" ] && { printf '%s' "$forkb"; return 0; }
  # 2. DISK — never clears by waiting; the remedy is a prune.
  disk="$(cap_kv "$r" disk_free_mb)"; [ "$disk" -lt "$CAP_MIN_DISK_MB" ] && { printf 'disk'; return 0; }
  # 3. LOAD — clears on its own; the least informative on a box that dies at fork.
  lpc="$(cap_kv "$r" lpc)";  [ "$lpc"  -ge "$CAP_LPC_CEILING" ] && { printf 'load_per_cpu'; return 0; }
  # 4. MEMORY.
  mem="$(cap_kv "$r" mem_free_mb)";   [ "$mem"  -lt "$CAP_MIN_MEM_MB" ]  && { printf 'memory'; return 0; }
  return 0
}

# ── the placement rule ────────────────────────────────────────────────────────
# cap_place <self-host> [records...]   (with no record args, they arrive on stdin, one per line)
#   0  -> `place=<host> lpc=<x100> evaluated=<n> eligible=<n> why=none`
#   1  -> `refuse bound=<bound> detail=<host>:<bound>@<reading>,… evaluated=<n> eligible=0`
#   2  -> usage error (no self host, unreadable clock)
# The LEAST-LOADED ELIGIBLE box wins; ties break on more free disk, then on host name so the answer
# is deterministic (two boxes at the same lpc must not flip the decision every cycle).
cap_place() {
  local self="${1:-}"; shift 2>/dev/null || true
  [ -n "$self" ] || { printf 'refuse bound=usage detail=no-self-host\n'; return 2; }
  local now; now="$(cap_now)"
  case "$now" in ''|*[!0-9]*) printf 'refuse bound=usage detail=clock-unreadable\n'; return 2 ;; esac
  local rec n=0 elig=0 bound hits="" hit lpc disk host detail="" winner_lpc="" winner_disk="" winner="" best_hits=""
  # Records arrive either as arguments or, when there are none, on stdin (one record per line).
  # stdin is the CONTROLLER's shape: a record contains spaces, so `cap_place h $fleet` would word-split
  # every record into fragments — a bug that reads as "no eligible box" instead of "bad call".
  local src
  if [ "$#" -gt 0 ]; then src="$(printf '%s\n' "$@" | grep -v '^$')"; else src="$(cat)"; fi
  while IFS= read -r rec; do
    [ -n "${rec:-}" ] || continue
    n=$((n + 1))
    hit="$(cap_bound_hit "$rec" "$now")"
    host="$(cap_kv "$rec" host)"
    [ -n "$host" ] || host="?"
    if [ -n "$hit" ]; then
      detail="${detail}${detail:+, }${host}:${hit}"
      hits="${hits}${hit}\n"
      continue
    fi
    elig=$((elig + 1))
    lpc="$(cap_kv "$rec" lpc)"; disk="$(cap_kv "$rec" disk_free_mb)"
    if [ -z "$winner" ]; then winner="$host"; winner_lpc="$lpc"; winner_disk="$disk"; continue; fi
    # shellcheck disable=SC2055
    if [ "$lpc" -lt "$winner_lpc" ] \
       || { [ "$lpc" -eq "$winner_lpc" ] && [ "$disk" -gt "$winner_disk" ]; } \
       || { [ "$lpc" -eq "$winner_lpc" ] && [ "$disk" -eq "$winner_disk" ] && [ "$host" \< "$winner" ]; }; then
      winner="$host"; winner_lpc="$lpc"; winner_disk="$disk"
    fi
  done <<EOF
$src
EOF
  if [ -z "$winner" ]; then
    # ⛔ NAME THE BOUND, MEASURED. The DOMINANT bound is the one that excluded the most boxes; with
    # no boxes at all the honest answer is `no_probe` (nothing to measure), never "no capacity".
    local dominant="no_probe"
    if [ "$n" -gt 0 ]; then
      dominant="$(printf '%b' "$hits" | grep -v '^$' | sort | uniq -c | sort -rn | head -1 | sed 's/^ *[0-9][0-9]* *//')"
      [ -n "$dominant" ] || dominant="no_probe"
    fi
    printf 'refuse bound=%s detail=%s evaluated=%s eligible=0 ceiling_lpc=%s disk_min_mb=%s mem_min_mb=%s\n' \
      "$dominant" "${detail:-none}" "$n" "$CAP_LPC_CEILING" "$CAP_MIN_DISK_MB" "$CAP_MIN_MEM_MB"
    return 1
  fi
  printf 'place=%s lpc=%s evaluated=%s eligible=%s why=none%s\n' \
    "$winner" "$winner_lpc" "$n" "$elig" "${detail:+ ineligible=[$detail]}"
  return 0
}

# ── the fleet's records, over the ONE shared channel ──────────────────────────────────────────
# cap_ref_for <record> -> refs/boxes/<host>/<at>-<ncpu>-<load1>-<lanes>-<disk>-<mem>-<procs>-<max>-<fork>
# ⛔ THE GRAMMAR IS APPEND-ONLY, AND THE DECODERS ACCEPT THE OLD SIX-SLOT FORM AS `fork_unknown`. A ref
# name is a string the transport already carries (see the header), so adding slots costs no fetch --
# but a peer on an older tree must be REFUSED for a named reason, not silently read as healthy.
cap_ref_for() {
  local r="${1:-}" h at ncpu load1 lanes disk mem procs pmax fork
  cap_valid_record "$r" || return 1
  h="$(cap_kv "$r" host)"; at="$(cap_kv "$r" at)"; ncpu="$(cap_kv "$r" ncpu)"
  load1="$(cap_kv "$r" load1)"; lanes="$(cap_kv "$r" lanes)"
  disk="$(cap_kv "$r" disk_free_mb)"; mem="$(cap_kv "$r" mem_free_mb)"
  procs="$(cap_kv "$r" procs)"; pmax="$(cap_kv "$r" procs_max)"; fork="$(cap_kv "$r" fork)"
  printf '%s/%s/%s-%s-%s-%s-%s-%s-%s-%s-%s' "$CAP_NS" "$h" "$at" "$ncpu" "$load1" "$lanes" \
    "$disk" "$mem" "$procs" "$pmax" "$fork"
}

# cap_record_from_ref <refname or path> -> record line (rc 1 if the ref is not one of ours)
# Six numeric slots = a pre-#2293 record: it decodes WITHOUT fork fields, so `cap_fork_bound` calls it
# `fork_unknown` (ineligible, named) instead of the whole ref being dropped as unparseable.
cap_record_from_ref() {
  local ref="${1:-}" path base h rest
  case "$ref" in
    *"$CAP_NS"/*) path="${ref#*"$CAP_NS"/}" ;;
    *) return 1 ;;
  esac
  h="${path%%/*}"; rest="${path#*/}"
  case "$h" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s' "$rest" | awk -v h="$h" '
    { n=split($0, f, "-") }
    END{
      if (n != 6 && n != 9) exit 1
      for (i=1;i<=n;i++) if (f[i] == "" || f[i] ~ /[^0-9]/) exit 1
      lpc = int(f[3] / f[2])
      printf "host=%s ncpu=%s load1=%s lpc=%d lanes=%s disk_free_mb=%s mem_free_mb=%s at=%s", \
        h, f[2], f[3], lpc, f[4], f[5], f[6], f[1]
      if (n == 9) printf " procs=%s procs_max=%s fork=%s", f[7], f[8], f[9]
    }'
}

# cap_parse_lsremote — pure: `<sha>\t<ref>` lines on stdin -> ONE record per host (the newest `at`).
# Kept separate from the git call so the suite can drive it with fixture text.
cap_parse_lsremote() {
  awk -v ns="$CAP_NS" '
    function rec_for(ref,   p, h, rest, n, f, i, lpc) {
      p = ref; sub("^" ns "/", "", p)
      if (p == ref) return ""                       # not in our namespace
      i = index(p, "/"); if (i <= 1) return ""
      h = substr(p, 1, i - 1); rest = substr(p, i + 1)
      n = split(rest, f, "-")
      if (n != 6 && n != 9) return ""
      for (i = 1; i <= n; i++) if (f[i] == "" || f[i] ~ /[^0-9]/) return ""
      lpc = int(f[3] / f[2])
      r = sprintf("host=%s ncpu=%s load1=%s lpc=%d lanes=%s disk_free_mb=%s mem_free_mb=%s at=%s", \
                     h, f[2], f[3], lpc, f[4], f[5], f[6], f[1])
      if (n == 9) r = r sprintf(" procs=%s procs_max=%s fork=%s", f[7], f[8], f[9])
      return r
    }
    {
      ref = $2
      if (ref == "") { split($0, t, "\t"); ref = t[2] }
      r = rec_for(ref, 1)
      if (r == "") next
      split(r, g, " "); at = g[8]; sub("^at=", "", at)
      if (!(g[1] in best) || at + 0 > atv[g[1]] + 0) { best[g[1]] = r; atv[g[1]] = at + 0 }
    }
    END { for (k in best) print best[k] }
  ' | sort
}

# cap_read_fleet <repo> -> every box's newest record, one per line. rc 2 when the channel cannot be
# read (no repo, no origin, git failure) — the CALLER must then refuse to place, never place blind.
cap_read_fleet() {
  local repo="${1:-.}" out rc
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { printf 'CAPACITY: not a git checkout: %s\n' "$repo" >&2; return 2; }
  git -C "$repo" remote get-url origin >/dev/null 2>&1 || { printf 'CAPACITY: %s has no origin — the fleet channel is unreadable\n' "$repo" >&2; return 2; }
  out="$(git -C "$repo" ls-remote --refs origin "$CAP_NS/*" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { printf 'CAPACITY: git ls-remote %s/* failed (rc=%s) — the fleet channel is UNREADABLE\n' "$CAP_NS" "$rc" >&2; return 2; }
  printf '%s\n' "$out" | cap_parse_lsremote
}

# cap_publish <repo> <record> — publish this box's reading; prune this box's PREVIOUS refs only.
# Best-effort by design: a publish failure must never fail a dispatch (this box becomes ineligible to
# its peers, which is the fail-closed direction). rc 0 published · 1 refused/failed (reason on stdout)
cap_publish() {
  local repo="${1:-.}" rec="${2:-}" ref sha old
  cap_valid_record "$rec" || { printf 'publish=refused why=invalid-record\n'; return 1; }
  ref="$(cap_ref_for "$rec")" || { printf 'publish=refused why=invalid-record\n'; return 1; }
  sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || { printf 'publish=refused why=no-head\n'; return 1; }
  git -C "$repo" push -q origin "$sha:$ref" >/dev/null 2>&1 || { printf 'publish=failed why=push-refused ref=%s\n' "$ref"; return 1; }
  # Prune THIS host's older refs. A peer's ref is never named here (the pattern is host-scoped), so a
  # delete can only ever remove a record this box published.
  for old in $(git -C "$repo" ls-remote --refs origin "$CAP_NS/$(cap_kv "$rec" host)/*" 2>/dev/null | awk '{print $2}'); do
    [ "$old" = "$ref" ] && continue
    git -C "$repo" push -q origin ":$old" >/dev/null 2>&1 || true  # a stuck old ref is harmless: the
    #    reader keeps the NEWEST record per host, so a superseded ref cannot win a placement decision
  done
  printf 'publish=ok ref=%s\n' "$ref"
  return 0
}

# ── CLI ───────────────────────────────────────────────────────────────────────
cap_cli() {
  local v="${1:-}"; shift 2>/dev/null || true
  case "$v" in
    probe)
      local rec _rc
      rec="$(cap_probe_local "${1:-.}" "${2:-}")"; _rc=$?
      # ⛔ 254 IS A NAMED ANSWER, NOT A CRASH. A fork failure terminates the shell that attempted it
      # (measured), so the probe's own child killing itself with 254 IS the reading: this box cannot
      # spawn. Saying so is the point; a caller (the controller) keys on it and forks nothing further
      # this cycle instead of dying on its next fork. Any other non-zero is unreadable.
      if [ "$_rc" -eq 254 ]; then
        printf 'probe=fork_exhausted why=the_probe_could_not_fork(fork_EAGAIN,_rc_254) reads=procs,procs_max,fork\n' >&2
        return 254
      fi
      { [ "$_rc" -eq 0 ] && [ -n "$rec" ]; } || { printf 'probe=unreadable why=a core field could not be measured\n' >&2; return 2; }
      printf '%s\n' "$rec" ;;
    fork)
      # The fork reading ALONE: the verb an operator runs on a box that looks idle and cannot spawn.
      local fr _frc
      fr="$(cap_fork_read 2>/dev/null)"; _frc=$?
      [ "$_frc" -eq 254 ] && { printf 'fork_exhausted procs=? procs_max=? fork=0 why=the_read_could_not_fork\n'; return 254; }
      [ -n "$fr" ] || { printf 'fork=unreadable why=neither_the_process_count_nor_a_ceiling_could_be_read\n' >&2; return 2; }
      printf '%s headroom=%s min_fork_headroom=%s\n' \
        "$fr" "$(cap_fork_headroom "$fr")" "$CAP_MIN_FORK_HEADROOM" ;;
    fleet)   cap_read_fleet "${1:-.}" ;;
    publish) cap_publish "${1:-.}" "${2:-}" ;;
    place)   cap_place "${1:-}" ;;
    ''|-h|--help|help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) printf 'capacity: unknown command %s (try: probe|fork|place|fleet|publish)\n' "$v" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then cap_cli "$@"; fi
