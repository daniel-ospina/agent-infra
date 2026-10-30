#!/usr/bin/env bash
# scripts/lib/lane-ceiling.sh — the fleet's ONE lane-ceiling derivation, portable across macOS,
# Linux and therefore a cmux cloud cell.
#
# THE RULING IS NOT BEING CHANGED HERE (contradiction test, agent-infra#3171). `MAX_LANES` is
# **DERIVED, not configured**: `floor(ncpu × 5/2)`, the fleet's 2026-10-17 lane ruling
# (`docs/ops/ai-drainer.md` §"the target is a measurement", `docs/ops/fleet-harness-baseline.md`
# §2's "MAX_LANES is derived, not configured — do not 'fix' a per-box MAX_LANES").
#   OVERRIDES: the hardware-scheduler default of sizing a worker pool from BOTH cpu and memory
#   requests (Kubernetes requests/limits, Nomad `memory`+`cpu`, cgroup v2 `memory.max`) — the
#   fleet's lane ceiling is CPU-derived by owner ruling, and memory is the drainer's SEPARATE
#   second ceiling (`target = min(cpu_ceiling, mem_ceiling)`), reported here and never applied
#   here. Adopting a memory-based MAX_LANES would be a REOPEN of that ruling, not a fix.
#
# WHAT THIS FILE IS FOR: the ruling is one rule; the DERIVATION was written out four times
# (`install.sh:46,87`, `orch-loop.sh:197,243`, `ai-drainer.sh:256`, `spawn-gate.sh:91`) and the
# cell path derived it ZERO times — a cell's `keys.env` carried a hand-pushed `MAX_LANES` and
# nothing compared it to the derivation, so cell-3 pinned 20 against a derived 10 with a memory
# ceiling of 3 and thrashed (#3171). Portability is the part that has to be shared.
#
# Usage:
#   . scripts/lib/lane-ceiling.sh          # then call lc_* functions
#   bash scripts/lib/lane-ceiling.sh --selftest
#
# ⛔ STANDALONE CONSTRAINT. `orch-loop.sh`, `ai-drainer.sh`, `spawn-gate.sh` and
# `cloud-cell-supervisor.sh` are all farmed into a runtime dir and copied outside any checkout, so
# they CANNOT source this file (cloud-cell-supervisor.sh says so above its `_proc_start_epoch`).
# They carry a PINNED MIRROR of `lc_cpu_probe` and the drift arms in their suites pin the copies
# together — the `pin_dirty` pattern this repo already uses for exactly this constraint. A mirror
# that may drift is the #1178 defect ("two contracts for one safety rule"); a mirror pinned by a
# drift arm is one contract with two carriers, and a divergence reddens CI instead of becoming a
# silent lane-cap.

# ── validation: a DIGIT STRING is not a MAGNITUDE ─────────────────────────────────────────────
# Same predicates as install.sh:53-63 and orch-loop.sh. `is_limit` bounds the WIDTH, because a
# 19-digit probe WRAPS instead of erroring (`9223372036854775808 * 5 / 2` is 0, which every downstream
# guard accepts as a legal lane count and which dispatches nothing, silently and indefinitely).
# Leading zeros are rejected because DOWNSTREAM consumers read these values with a plain `$(( ))`,
# where `08` IS an octal error — not because `10#` cannot parse it (`$(( 10#08 ))` is 8, fine; the
# guard exists for the reader that does not write `10#`).
lc_is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
lc_is_limit() { lc_is_num "${1:-}" && [ "${#1}" -le 9 ]; }

# ── the CPU probe: ONE line, portability is the whole point ───────────────────────────────────
# `sysctl -n hw.ncpu` is macOS-only AND sysctl is absent from a minimal Linux userland (debian:
# stable-slim ships no procps) — reading it as the sole source silently pinned _NCPU=4 on every
# cell and MAX_LOAD=40 with it (#1702). `nproc` is GNU/Linux-only and absent on macOS. `getconf
# _NPROCESSORS_ONLN` is in POSIX and present on both. So: try all three IN THIS ORDER, fall back to
# a constant only when every probe has failed — and SAY SO when that happens, because a silent
# constant is indistinguishable from a measurement (the defect this file exists for).
# Sets LC_CPU_N / LC_CPU_MECH in the CALLER's shell (no subshell), so the mechanism that answered
# is reportable rather than lost. `lc_cpu_probe` is the printing wrapper for call sites that only
# want the number.
_lc_probe_raw() {
  local n
  LC_CPU_MECH=""; LC_CPU_N=""
  n="$(sysctl -n hw.ncpu 2>/dev/null)" && [ -n "$n" ] && lc_is_limit "$n" && { LC_CPU_MECH=sysctl; LC_CPU_N="$((10#$n))"; }
  if [ -z "$LC_CPU_MECH" ]; then
    n="$(nproc 2>/dev/null)" && [ -n "$n" ] && lc_is_limit "$n" && { LC_CPU_MECH=nproc; LC_CPU_N="$((10#$n))"; }
  fi
  if [ -z "$LC_CPU_MECH" ]; then
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null)" && [ -n "$n" ] && lc_is_limit "$n" && { LC_CPU_MECH=getconf; LC_CPU_N="$((10#$n))"; }
  fi
  if [ -z "$LC_CPU_MECH" ]; then
    # ⛔ LOUD FALLBACK. 4 is the documented constant; it is never reported as a probe result.
    printf '%s\n' "WARN: the CPU count could not be read — sysctl hw.ncpu, nproc and getconf _NPROCESSORS_ONLN all failed (or answered a non-magnitude). Falling back to 4 cores, so MAX_LANES derives to 10. This is a CONSTANT, not a measurement." >&2
    LC_CPU_MECH=fallback; LC_CPU_N=4; return 0
  fi
  if [ "$LC_CPU_N" -lt 1 ]; then
    # A 0-valued probe is a FAILED probe, not "no cores": a 0 propagates into every divisor
    # downstream and turns "unknown" into "the box has no capacity", which reads as a full fleet.
    printf '%s\n' "WARN: the CPU probe ($LC_CPU_MECH) answered 0 — a 0-valued probe is a FAILED probe, not 'no cores'. Falling back to 4 cores." >&2
    LC_CPU_MECH=fallback; LC_CPU_N=4
  fi
  return 0
}

lc_cpu_probe() { _lc_probe_raw; printf '%s\n' "$LC_CPU_N"; }

# ── the derivation: floor(ncpu × 5/2) — the 2026-10-17 ruling, byte-for-byte ──────────────────
# Integer division FLOORS: 10 cores → 25, 8 → 20, 4 → 10, 3 → 7. The fallback of 10 applies to a
# FAILED or ABSURD derivation only — never to a pin, which is the operator's and is reported (see
# lc_drift), never overwritten.
lc_derive_max_lanes() { # $1 = ncpu
  local n="${1:-}" d
  lc_is_limit "${n:-}" || return 1
  d=$(( 10#$n * 5 / 2 ))
  [ "$d" -ge 1 ] && [ "$d" -le 999999999 ] || d=10
  printf '%s\n' "$d"
}

# ── memory: a REPORTED second ceiling, not a new constant ─────────────────────────────────────
# `mem_ceiling = floor( (available − floor_mb) × budget_pct/100 ÷ lane_mb )` — the drainer's own
# formula (`ai-drainer.sh:44`), with the same defaults and the same env names, so a pin on one box
# is honoured by both. It is REPORTED here precisely because the drainer owns APPLICATION: this
# file must never quietly narrow a lane count from memory, or the ruling above is reversed by a
# side effect. #3171's cell-3 is why it must still be visible: 10 lanes running against a memory
# ceiling of 3 is a thrash, and it should be one printed line, not an inference from the wreckage.
lc_mem_avail_mb() {
  local p="${LC_PROC_MEMINFO:-/proc/meminfo}" mb
  if [ -n "${MEM_AVAIL_MB:-}" ]; then
    case "$MEM_AVAIL_MB" in ''|*[!0-9]*) ;; *) printf '%s\n' "$((10#$MEM_AVAIL_MB))"; return 0 ;; esac
  fi
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

lc_mem_ceiling() { # $1 = mem_avail_mb → prints the lane ceiling memory would allow, or "?"
  local avail="${1:-}" floor_mb budget lane_mb usable
  lc_is_num "${avail:-}" || { printf '?\n'; return 1; }
  floor_mb="${MIN_MEM_FREE_MB:-512}"; budget="${MEM_BUDGET_PCT:-75}"; lane_mb="${LANE_MEM_MB:-512}"
  lc_is_num "$floor_mb" || floor_mb=512
  lc_is_num "$budget"   || budget=75
  lc_is_num "$lane_mb"  || lane_mb=512
  # ⛔ THE DRAINER'S OWN CLAMPS, not just non-numeric coercion (review P2): `ai-drainer.sh:229-231`
  # clamps MEM_BUDGET_PCT into [1,100] and LANE_MEM_MB to >= 1 BEFORE its `_capacity_target`. Without
  # the same clamps a `keys.env` carrying MEM_BUDGET_PCT=500 would make this report print 5x the
  # ceiling the drainer actually enforces — a second contract for the one number the change exists to
  # unify. This file REPORTS that number; it must report the drainer's, not an unclamped reading.
  [ "$budget" -ge 1 ]   || budget=1
  [ "$budget" -le 100 ] || budget=100
  [ "$lane_mb" -ge 1 ]  || lane_mb=512
  usable=$(( (10#$avail - 10#$floor_mb) * 10#$budget / 100 ))
  [ "$usable" -ge 0 ] || usable=0
  printf '%s\n' "$(( usable / 10#$lane_mb ))"
}

# ── the ONE report line ───────────────────────────────────────────────────────────────────────
# `cpus=N MAX_LANES=M mem_ceiling=K` on every box start, so a box whose lane count exceeds its
# memory ceiling is visible in one line rather than inferred from a thrash (item 4, #3171).
# `pinned=` appears only when a pin exists; `drift=1` means the pin disagrees with the derivation.
lc_report() { # $1 = optional pinned MAX_LANES (env / keys.env)
  local pin="${1:-}" ncpu derived avail memceiling
  _lc_probe_raw; ncpu="$LC_CPU_N"
  derived="$(lc_derive_max_lanes "$ncpu")" || derived=10
  avail="$(lc_mem_avail_mb 2>/dev/null)" || avail=""
  memceiling="$(lc_mem_ceiling "$avail" 2>/dev/null)" || memceiling="?"
  if [ -z "$pin" ]; then
    printf 'cpus=%s MAX_LANES=%s mem_ceiling=%s cpu_probe=%s\n' "$ncpu" "$derived" "$memceiling" "${LC_CPU_MECH:-?}"
  else
    printf 'cpus=%s MAX_LANES=%s mem_ceiling=%s cpu_probe=%s pinned=%s drift=%s\n' \
      "$ncpu" "$derived" "$memceiling" "${LC_CPU_MECH:-?}" "$pin" "$(lc_drift "$pin" "$ncpu" >/dev/null 2>&1 && echo 0 || echo 1)"
  fi
}

# ── the drift check: a pin that disagrees is a REPORTED DEFECT, never silently overwritten ────
# rc 0 = the pin agrees with the derivation (or there is no pin), rc 1 = DRIFT, rc 2 = the pin is
# not a usable magnitude. The pin stays in force either way: it is the operator's, and a tool that
# rewrites it converts a visible disagreement into a silent one.
lc_drift() { # $1 = pinned MAX_LANES, $2 = ncpu (optional)
  local pin="${1:-}" ncpu derived
  [ -n "$pin" ] || return 0
  lc_is_limit "${pin:-}" || return 2
  ncpu="${2:-$(lc_cpu_probe)}"
  derived="$(lc_derive_max_lanes "$ncpu")" || return 2
  [ "$((10#$pin))" = "$derived" ] && return 0
  return 1
}

# ── selftest: the four portability arms, executable ───────────────────────────────────────────
# Each arm stubs the probes ahead of the real PATH so the fall-through order is provable rather
# than asserted: sysctl absent → nproc; sysctl+nproc absent → getconf; all three absent → the LOUD
# fallback; and a garbage answer from an earlier probe must pass through to the next.
lc_selftest() {
  local tmp rc=0 out
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/lc-selftest.XXXXXX")" || exit 1
  trap 'rm -rf "$tmp"' EXIT

  # One arm = one PATH. The arm's PATH is MINIMAL (`$tmp/bin` and nothing else), so a probe this
  # arm did not stub is genuinely ABSENT rather than inherited from the host — otherwise "sysctl
  # absent" would quietly re-find the host's nproc and the arm would prove nothing.
  stub() { mkdir -p "$tmp/bin"; printf '#!/bin/sh\n%s\n' "$2" >"$tmp/bin/$1"; chmod +x "$tmp/bin/$1"; }
  run_arm() { # $1 = PATH to expose to the probe
    bash -c 'PATH="$2"; . "$1"; _lc_probe_raw
             printf "cpus=%s mech=%s derived=%s\n" "$LC_CPU_N" "$LC_CPU_MECH" "$(lc_derive_max_lanes "$LC_CPU_N")"' \
      lane-ceiling-lib "$0" "$1" 2>&1
  }

  printf '=== arm 1: all three probes present — sysctl answers FIRST (macOS shape) ===\n'
  rm -rf "$tmp/bin"; stub sysctl 'printf "8\n"'; stub nproc 'printf "4\n"'; stub getconf 'printf "2\n"'
  out="$(run_arm "$tmp/bin")"; printf '%s\n' "$out"
  case "$out" in *cpus=8*mech=sysctl*derived=20*) ;; *) printf 'ARM 1 FAILED\n'; rc=1 ;; esac

  printf '=== arm 2: sysctl ABSENT — falls through to nproc (Linux cell shape) ===\n'
  rm -rf "$tmp/bin"; stub nproc 'printf "4\n"'; stub getconf 'printf "2\n"'
  out="$(run_arm "$tmp/bin")"; printf '%s\n' "$out"
  case "$out" in *cpus=4*mech=nproc*derived=10*) ;; *) printf 'ARM 2 FAILED\n'; rc=1 ;; esac

  printf '=== arm 3: sysctl + nproc ABSENT — falls through to getconf (POSIX) ===\n'
  rm -rf "$tmp/bin"; stub getconf 'printf "6\n"'
  out="$(run_arm "$tmp/bin")"; printf '%s\n' "$out"
  case "$out" in *cpus=6*mech=getconf*derived=15*) ;; *) printf 'ARM 3 FAILED\n'; rc=1 ;; esac

  printf '=== arm 4: ALL probes ABSENT — the LOUD fallback, never a silent constant ===\n'
  rm -rf "$tmp/bin"; mkdir -p "$tmp/bin"
  out="$(run_arm "$tmp/bin")"; printf '%s\n' "$out"
  case "$out" in *WARN:*could\ not\ be\ read*) ;; *) printf 'ARM 4 FAILED: the fallback was SILENT\n'; rc=1 ;; esac
  case "$out" in *cpus=4*mech=fallback*derived=10*) ;; *) printf 'ARM 4 FAILED: wrong value\n'; rc=1 ;; esac

  printf '=== arm 5: a non-magnitude answer passes THROUGH to the next probe ===\n'
  rm -rf "$tmp/bin"; stub sysctl 'printf "08\n"'; stub nproc 'printf "4\n"'
  out="$(run_arm "$tmp/bin")"; printf '%s\n' "$out"
  case "$out" in *cpus=4*mech=nproc*) ;; *) printf 'ARM 5 FAILED (a leading-zero probe was accepted, or the fall-through broke)\n'; rc=1 ;; esac

  printf '=== arm 6: a 19-digit probe is refused (it would WRAP, not error) ===\n'
  rm -rf "$tmp/bin"; stub sysctl 'printf "9223372036854775808\n"'; stub nproc 'printf "4\n"'
  out="$(run_arm "$tmp/bin")"; printf '%s\n' "$out"
  case "$out" in *cpus=4*mech=nproc*derived=10*) ;; *) printf 'ARM 6 FAILED\n'; rc=1 ;; esac

  printf '=== the derivation (the 2026-10-17 ruling, floored) ===\n'
  for c in 3 4 8 10; do printf '  ncpu=%s -> MAX_LANES=%s\n' "$c" "$(lc_derive_max_lanes "$c")"; done

  printf '=== drift: a pin that disagrees is REPORTED (rc 1), and is NEVER rewritten here ===\n'
  # cell-3's measured shape: keys.env pinned 20 on a 4-core box whose derivation is 10.
  lc_drift 20 4 >/dev/null 2>&1; [ "$?" = 1 ] || { printf 'DRIFT ARM FAILED: 20 pinned vs 4 cores (derives 10) must be rc 1\n'; rc=1; }
  lc_drift 20 8 >/dev/null 2>&1; [ "$?" = 0 ] || { printf 'DRIFT ARM FAILED: 20 pinned vs 8 cores (derives 20) AGREES\n'; rc=1; }
  lc_drift "" 4 >/dev/null 2>&1;  [ "$?" = 0 ] || { printf 'DRIFT ARM FAILED: no pin is not drift\n'; rc=1; }
  lc_drift "abc" 4 >/dev/null 2>&1; [ "$?" = 2 ] || { printf 'DRIFT ARM FAILED: a non-magnitude pin is rc 2\n'; rc=1; }
  printf '  lc_drift 20 4 -> rc 1 (drift) ; lc_drift 20 8 -> rc 0 (agrees) ; lc_drift "" -> rc 0 ; lc_drift abc -> rc 2\n'

  printf '=== the ONE report line ===\n'
  printf '  %s\n' "$(lc_report)"
  printf '  %s\n' "$(MEM_AVAIL_MB=9000 lc_report 20)"
  case "$(MEM_AVAIL_MB=9000 lc_report 20)" in
    *'mem_ceiling=12'*'pinned=20'*) ;;   # (9000-512)*75/100/512 = 12
    *) printf 'MEM CEILING ARM FAILED: (9000-512)*75%%/100/512 must be 12\n'; rc=1 ;;
  esac

  if [ "$rc" = 0 ]; then printf 'SELFTEST PASS\n'; else printf 'SELFTEST FAIL\n'; fi
  return "$rc"
}

# Sourced normally (a caller does `. lane-ceiling.sh`); executed directly, it selftests.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --selftest) lc_selftest ;;
    '') printf 'usage: %s --selftest\n' "$0" >&2; exit 2 ;;
    *)  printf 'lane-ceiling.sh: unknown argument %s (try --selftest)\n' "$1" >&2; exit 2 ;;
  esac
fi
