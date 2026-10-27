#!/bin/bash
# disk-floor.sh — THE PRE-DISPATCH DISK FLOOR, and the cheap always-safe reclaim pass behind it.
#
# WHY THIS EXISTS (the measured defect — two cells, one night, twice)
# -------------------------------------------------------------------
# A cloud cell whose filesystem fills stops DISPATCHING entirely, and it presents as something else:
#
#   pi-lane-1   df: 126G 122G 0 100% /     → the controller and the doctor died; the systemd unit
#                                            stayed `active`, so the box read as healthy (false green)
#   pi-cell-4   df: 126G 120G 872M 100%    → [refresh] FAILED stage=provision sub-step=scout-venv:
#                                            uv sync failed … failed to write
#                                            /tmp/cell-home/.cache/uv/…/libtorch_cuda.so:
#                                            No space left on device
#
# Both were BYTES. Freeing space fixed both instantly: 864MB → 9378MB (the uv cache alone was ~8.5 GB)
# and the pre-flight went from `INCOMPLETE` to `VERDICT: CLEAN (exit 0)`.
#
# ⛔ AND THE CIRCULARITY IS THE POINT: `eldato-disk-reaper.timer` CANNOT free the space, because a full
# disk is exactly what stops work from running — and its hourly pass is not on the dispatch path at
# all. A reaper that runs AFTER the failure cannot prevent it. So the controller measures BEFORE it
# provisions, and reclaims on the spot instead of discovering the shortfall as a `uv sync` error.
#
# WHAT THIS IS NOT
# ----------------
# ⛔ IT IS NOT A SECOND DISK REAPER, AND IT OWNS NO PERMANENT DELETION POLICY. `scripts/disk-reaper.sh`
# remains the owner of the four sink classes (uv / venv / worktree / duplicate-install), each of whose
# delete rule lives in a dedicated delegate. This file implements only the CHEAP, ALWAYS-SAFE subset
# that is defensible to run in the middle of a cycle, and it says so in its own line:
#
#   class                 what is removed                                   why it is always safe
#   --------------------  ------------------------------------------------  ------------------------
#   uv cache              `uv cache prune`, then `uv cache clean` ONLY       content-addressed and
#                         when no live `uv` holds the cache (never while a   rebuildable; hardlinked
#                         lane is resolving)                                 into venvs, so a venv
#                                                                           keeps its blocks
#   stale harness copies  $O/harness.stray-*, $O/harness.preserved-*,        superseded staging copies
#                         $O/.deploy-* — AGE FLOORED (see below)              the live harness never
#                                                                           reads
#   lane scratch          <scratch root>/cloud-cell-<pid>.* — AGE FLOORED     the family's own
#                         and ONLY when <pid> is dead                          `mktemp -d` leftovers;
#                                                                           a killed run never reaches
#                                                                           its trap
#
# ⛔ THE LIST ABOVE IS EXHAUSTIVE, AND THE GUARDS ARE STRUCTURAL, NOT INTENTIONAL:
#   * a WORKTREE can never be a candidate — none of the three name families is a checkout, and every
#     candidate is additionally refused if it carries a `.git` (a directory that IS a checkout) or is
#     a symlink (a link to one). "Never delete a worktree" is therefore not a rule the code has to
#     remember; it is a property of what the code can name.
#   * a VENV IN USE is never a candidate: the only venv-shaped thing touched is the shared uv CACHE,
#     and its destructive arm refuses while a `uv` process is alive on the box.
#   * a runner `_work` is never a candidate — not one of the families, and no `_work` is ever walked.
# Everything else (worktrees, lane venvs, duplicate installs) stays with `scripts/disk-reaper.sh`.
#
# ⛔ AND IT NEVER FAILS SILENTLY. Below the floor the caller gets ONE line it can grep — the free MB,
# the floor, what was reclaimed and why the cycle did not proceed — instead of a `provision` failure
# that names `uv sync`, or a controller that simply stops beating.
#
# USAGE (library — sourced by orch-loop.sh and refresh-candidates.sh, like repo-slug.sh)
#   disk_floor_gate <state-dir>        # 0 = proceed · 1 = HOLD the cycle · 2 = could not measure
#                                      # prints NOTHING when already above the floor (that cycle is
#                                      # unchanged), and exactly one line otherwise.
#   disk_floor_free_mb <path>          # MiB free on the filesystem holding <path>, empty if unreadable
#
# ENV SEAMS (all operator-facing)
#   DISK_FLOOR_MB               floor in MiB (default 3072 = ~3 GB; 1..249999999, anything else is the
#                               default — a 0 floor would be a gate that can never refuse)
#   DISK_FLOOR_RECLAIM          0 disables the reclaim pass (the gate still refuses below the floor)
#   DISK_FLOOR_COPY_MIN_AGE_S   age floor for the stale-copy class (default 86400 = one day)
#   DISK_FLOOR_SCRATCH_MIN_AGE_S  age floor for the lane-scratch class (default 86400)
#   DISK_FLOOR_SCRATCH_ROOT     where lane scratch lives (default ${TMPDIR:-/tmp})
#   DISK_FLOOR_UV_BIN           the uv binary (default: `uv` on PATH). SET-but-not-executable is a
#                               REFUSAL of that class, named in the line — never a silent different
#                               binary (the rule disk-reaper.sh states for its delegates).
#   UV_CACHE_DIR / XDG_CACHE_HOME  the standard uv/cache knobs; the cache class honours both.
#
# POLARITY — DELIBERATELY MIXED, AND IT IS spawn-gate.sh's, NOT THIS FILE'S INVENTION
# ------------------------------------------------------------------------------------
# `spawn-gate.sh` (agent-infra#1765) documents the contract for a floor read in a LIVE dispatch path:
# a READABLE reading below the floor fails CLOSED (no work), and an UNREADABLE `df` fails OPEN with a
# loud line, because a probe that cannot answer must not stop every lane on the box for ever. This
# gate keeps that contract and returns it as rc=2, so the caller can say CANNOT-VERIFY rather than
# "fine". The one place it is STRICTER is the reading taken AFTER a reclaim: a post-reclaim reading we
# cannot take is a HOLD, because the box has just told us it was below the floor and we cannot prove
# it is not any more.

# ── the floor, guarded at source time ────────────────────────────────────────────────────────────
# `disk_floor_num` is `is_num`-shaped but local to this file: it is sourced by two scripts with two
# different helper sets, and a floor that depends on the caller's `is_num` is a floor that silently
# changes meaning with its caller. A leading-zero value is rejected here for the same reason #2293's
# `10#` note gives (`08` is an invalid octal in `$(( ))`), and a 0 floor is rejected because
# `[ "$mb" -ge 0 ]` is true for every reading — the no-op gate this file is written against.
disk_floor_num() { # <value> <default>
  local v="${1:-}"
  case "$v" in ''|*[!0-9]*) printf '%s' "$2"; return 0 ;; esac
  case "$v" in 0*) printf '%s' "$2"; return 0 ;; esac
  printf '%s' "$v"
}
DISK_FLOOR_MB="${DISK_FLOOR_MB:-3072}"
DISK_FLOOR_MB="$(disk_floor_num "$DISK_FLOOR_MB" 3072)"
[ "${DISK_FLOOR_MB:-0}" -ge 1 ] || DISK_FLOOR_MB=3072
# The upper bound is the same one spawn-gate.sh uses for its floor: `is_limit` accepts 9 digits, so
# without this a typo'd `999999999` would put the floor above every real device and turn the gate into
# a permanent, ignorable HOLD — an inert gate wearing a strict one.
[ "${DISK_FLOOR_MB:-0}" -le 249999999 ] || DISK_FLOOR_MB=3072
DISK_FLOOR_COPY_MIN_AGE_S="$(disk_floor_num "${DISK_FLOOR_COPY_MIN_AGE_S:-}" 86400)"
DISK_FLOOR_SCRATCH_MIN_AGE_S="$(disk_floor_num "${DISK_FLOOR_SCRATCH_MIN_AGE_S:-}" 86400)"

# Free MEBIBYTES on the filesystem holding <path>, or EMPTY when the probe cannot answer.
# The SAME POSIX probe `res_line` in orch-loop.sh and `disk_free_mb` in spawn-gate.sh use: `df -Pk`'s
# 4th column is 1KiB blocks on both platforms, the column is VALIDATED rather than trusted (a
# column-shifted `df` would hand `[ -lt ]` a string that errors, and an errored comparison is not a
# measurement), and `printf "%d"` — never `int()` — because mawk renders large integers in scientific
# notation, which `[ -lt ]` also errors on.
# ⛔ A PATH THAT DOES NOT EXIST YET IS MEASURED ON ITS NEAREST EXISTING ANCESTOR, not reported
# unreadable: `$O` is created a few lines AFTER this gate in the refresh (and may not exist at all on a
# first run), so a bare `df "$O"` would answer CANNOT-VERIFY on exactly the fresh box that has the
# most to provision. The ancestor walk keeps the answer a real measurement of the volume the state dir
# will live on; only when nothing in the chain exists does the probe return empty (unreadable).
disk_floor_free_mb() { # <path>
  local p="${1:-.}" mb
  while :; do
    mb="$(df -Pk "$p" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%d\n", $4 / 1024}')"
    [ -n "$mb" ] && { printf '%s\n' "$mb"; return 0; }
    case "$p" in
      ''|.|/) return 0 ;;
    esac
    case "$p" in
      */*) p="${p%/*}" ;;
      *)   p="." ;;
    esac
    [ -n "$p" ] || p=.
  done
}

# ── the reclaim classes ────────────────────────────────────────────────────────────────────────
# Each class prints ONE token per action/candidate it considered, so the caller's single line can say
# what was done AND what was deliberately not done. Bytes are never self-reported by `du` (a uv cache
# entry is hardlinked into every venv built from it, so `du` over-states); the gate reports the `df`
# delta across the whole pass, which is what the filesystem actually gave back.
disk_floor_uv_live() { # 0 = a live uv process may be holding the cache
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x uv >/dev/null 2>&1
    return $?
  fi
  # No `pgrep`: assume LIVE. The conservative direction is expensive (the destructive arm is skipped
  # and the class falls back to the prune the tool itself says is safe); the permissive one can pull
  # entries out from under a running resolve.
  return 0
}

disk_floor_reclaim_uv() { # <soft|hard>
  local mode="${1:-soft}" cache uv
  cache="${UV_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/uv}"
  [ -d "$cache" ] || return 0
  if [ -n "${DISK_FLOOR_UV_BIN:-}" ]; then
    uv="$DISK_FLOOR_UV_BIN"
    if [ ! -x "$uv" ]; then
      printf 'uv-cache=REFUSED(%s is not executable — DISK_FLOOR_UV_BIN names a binary this box does not have; the class did not run)\n' "$uv"
      return 0
    fi
  else
    uv="$(command -v uv 2>/dev/null || true)"
    if [ -z "$uv" ]; then
      printf 'uv-cache=SKIPPED(no uv on PATH — nothing could reclaim the cache; set DISK_FLOOR_UV_BIN or PATH)\n'
      return 0
    fi
  fi
  if [ "$mode" = "soft" ]; then
    # `uv cache prune` removes UNUSED entries and is documented safe while lanes work; UV_LOCK_TIMEOUT
    # bounds the wait for uv's own lock so a busy box cannot park the controller here.
    UV_CACHE_DIR="$cache" UV_LOCK_TIMEOUT=20 "$uv" cache prune >/dev/null 2>&1
    printf 'uv-cache=prune\n'
    return 0
  fi
  # HARD: the whole cache. ⛔ ONLY when nothing is resolving — this is the pass that freed ~8.5 GB on
  # the measured cell, and it is also the one that would hurt a lane mid-`uv sync` if it ran blind.
  if disk_floor_uv_live; then
    printf 'uv-cache=clean-DEFERRED(a live uv process holds the cache — prune only)\n'
    return 0
  fi
  UV_CACHE_DIR="$cache" UV_LOCK_TIMEOUT=20 "$uv" cache clean >/dev/null 2>&1
  printf 'uv-cache=clean\n'
}

# Age floor, in whole minutes, for `find -mmin +N`. One minute is the smallest expressible bound and a
# zero/absent setting would make every candidate instantly eligible.
disk_floor_age_min() { # <seconds>
  local s; s="$(disk_floor_num "${1:-}" 0)"
  [ "$s" -ge 60 ] || s=60
  printf '%s' "$(( s / 60 ))"
}

disk_floor_reclaim_copies() { # <state-dir>
  local o="${1:-.}" p base n=0 mins
  mins="$(disk_floor_age_min "$DISK_FLOOR_COPY_MIN_AGE_S")"
  [ -d "$o" ] || return 0
  for p in "$o"/harness.stray-* "$o"/harness.preserved-* "$o"/.deploy-*; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    base="$(basename "$p")"
    # ⛔ THE TWO STRUCTURAL REFUSALS. A symlink is not followed (`rm -rf` on a link removes the link,
    # but a link is also how a candidate name points somewhere it does not own), and a directory that
    # carries `.git` IS a checkout — whatever it is called, this pass does not delete worktrees.
    if [ -L "$p" ]; then printf 'stale-copy=SKIPPED(%s is a symlink)\n' "$base"; continue; fi
    if [ -e "$p/.git" ]; then printf 'stale-copy=SKIPPED(%s is a checkout)\n' "$base"; continue; fi
    if [ -z "$(find "$p" -maxdepth 0 -mmin +"$mins" 2>/dev/null)" ]; then
      continue   # too fresh to be stale: age is the only thing that separates a copy from a live one
    fi
    if rm -rf -- "$p" 2>/dev/null; then n=$(( n + 1 )); fi
  done
  printf 'stale-copies=%s\n' "$n"
}

disk_floor_reclaim_scratch() {
  local root="${DISK_FLOOR_SCRATCH_ROOT:-${TMPDIR:-/tmp}}" p base tok n=0 mins
  mins="$(disk_floor_age_min "$DISK_FLOOR_SCRATCH_MIN_AGE_S")"
  [ -d "$root" ] || return 0
  # `cloud-cell-<pid>.<rand>` is what this family's `mktemp -d` leaves under $TMPDIR on a cell. A run
  # killed by ENOSPC never reaches its trap, so they accumulate for the life of the box — MEASURED
  # 2026-10-21: removing ONE stale `/tmp/cloud-cell-1718.SmGtAK` took cell-3 from 2,506 MB to
  # 27,134 MB free. `cloud-cell-doctor.sh` owns the FULL hygiene policy for this family; this is the
  # emergency subset, with a STRICTER age floor and the same liveness proof.
  for p in "$root"/cloud-cell-*; do
    [ -d "$p" ] || continue
    base="$(basename "$p")"
    if [ -L "$p" ]; then printf 'lane-scratch=SKIPPED(%s is a symlink)\n' "$base"; continue; fi
    if [ -e "$p/.git" ]; then printf 'lane-scratch=SKIPPED(%s is a checkout)\n' "$base"; continue; fi
    # ⛔ THE PID IN THE NAME IS THE LIVENESS PROOF, AND A NAME WITHOUT A NUMBER HAS NONE. The token
    # before the first `.` is a pid for `mktemp -d …/cloud-cell-<pid>.XXXXXX`, so `kill -0` answers it
    # exactly; the same spelling also comes from `…/cloud-cell-<issue>.XXXXXX` and `…/cloud-cell-test.`,
    # where it is NOT a pid — which is why the age floor is required INDEPENDENTLY, and why a name with
    # no numeric token is REPORTED and never reaped (never "reaped by assumption").
    tok="${base#cloud-cell-}"; tok="${tok%%.*}"
    case "${tok:-}" in
      ''|*[!0-9]*) printf 'lane-scratch=SKIPPED(%s carries no pid token, so it has no liveness proof)\n' "$base"; continue ;;
    esac
    if kill -0 "$tok" 2>/dev/null; then
      printf 'lane-scratch=SKIPPED(%s: pid %s is LIVE)\n' "$base" "$tok"; continue
    fi
    if [ -z "$(find "$p" -maxdepth 0 -mmin +"$mins" 2>/dev/null)" ]; then continue; fi
    if rm -rf -- "$p" 2>/dev/null; then n=$(( n + 1 )); fi
  done
  printf 'lane-scratch=%s\n' "$n"
}

# disk_floor_reclaim <state-dir> -> one token per line on stdout (the caller flattens them).
disk_floor_reclaim() { # <state-dir>
  local o="${1:-.}" mid
  disk_floor_reclaim_uv soft
  # Re-measure between the soft and hard uv arms: the whole point of the hard arm is a cache that the
  # prune could not shrink enough, and paying `uv cache clean` when the prune already met the floor
  # would throw away cache hits for nothing.
  mid="$(disk_floor_free_mb "$o")"
  if [ -z "$mid" ] || [ "$mid" -lt "$DISK_FLOOR_MB" ]; then disk_floor_reclaim_uv hard; fi
  disk_floor_reclaim_copies "$o"
  disk_floor_reclaim_scratch
}

# ── the gate ────────────────────────────────────────────────────────────────────────────────────
# disk_floor_gate <state-dir>
#   rc 0  the floor is met — dispatch may proceed. SILENT when it was already met at entry, so an
#         unchanged cycle logs exactly what it logged before this change; ONE line when the reclaim
#         pass is what met it.
#   rc 1  HOLD — still below the floor after the reclaim pass. ONE line names free MB, floor, what was
#         reclaimed, and what was deliberately left alone. The caller must not provision or dispatch.
#   rc 2  CANNOT-VERIFY — `df` did not answer. ONE line; the caller proceeds (the live-dispatch
#         polarity above) but says so, so this is not silent.
disk_floor_gate() { # <state-dir>
  local o="${1:-.}" before after reclaimed why acts
  before="$(disk_floor_free_mb "$o")"
  if [ -z "$before" ]; then
    printf '[disk] CANNOT-VERIFY: df -Pk %s did not answer, so the pre-dispatch floor (DISK_FLOOR_MB=%s) could not be measured — proceeding unguarded this cycle (a probe that cannot answer must not stop every lane on the box; spawn-gate.sh documents the same polarity)\n' \
      "$o" "$DISK_FLOOR_MB"
    return 2
  fi
  [ "$before" -ge "$DISK_FLOOR_MB" ] && return 0
  if [ "${DISK_FLOOR_RECLAIM:-1}" = "0" ]; then
    printf '[disk] SKIP free=%sMB floor=%sMB reclaimed=0MB (the reclaim pass is DISABLED: DISK_FLOOR_RECLAIM=0) — no refresh and no dispatch this cycle\n' \
      "$before" "$DISK_FLOOR_MB"
    return 1
  fi
  acts="$(disk_floor_reclaim "$o" 2>/dev/null | tr '\n' ' ')"
  acts="${acts% }"
  after="$(disk_floor_free_mb "$o")"
  if [ -z "$after" ]; then
    printf '[disk] SKIP free=%sMB floor=%sMB reclaimed=?MB (%s) — the post-reclaim df could not be read, so the floor cannot be proven met; no refresh and no dispatch this cycle\n' \
      "$before" "$DISK_FLOOR_MB" "${acts:-no action taken}"
    return 1
  fi
  reclaimed=$(( after - before )); [ "$reclaimed" -ge 0 ] || reclaimed=0
  if [ "$after" -ge "$DISK_FLOOR_MB" ]; then
    printf '[disk] RECLAIMED free=%sMB->%sMB floor=%sMB reclaimed=%sMB (%s) — the floor is met after the safe reclaim pass, so this cycle dispatches\n' \
      "$before" "$after" "$DISK_FLOOR_MB" "$reclaimed" "${acts:-no action taken}"
    return 0
  fi
  why="still below the floor after the safe reclaim pass"
  printf '[disk] SKIP free=%sMB floor=%sMB reclaimed=%sMB (%s) — %s, so NO refresh, NO dispatch and no PR sweep this cycle. The remaining classes (lane worktrees, lane venvs, duplicate installs) are disk-reaper.sh'"'"'s and are NOT touched here; if this repeats, free space or lower DISK_FLOOR_MB deliberately\n' \
    "$before" "$DISK_FLOOR_MB" "$reclaimed" "${acts:-no action taken}" "$why"
  return 1
}
