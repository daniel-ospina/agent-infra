#!/usr/bin/env bash
# disk-floor.test.sh — the PRE-DISPATCH DISK FLOOR, driven through the shipped gate (agent-infra).
#
# WHAT IT PINS, AND WHY EACH ONE IS A POLARITY RATHER THAN A DETAIL
# ----------------------------------------------------------------
# A floor is only worth shipping if BOTH of its answers are exercised. A gate that only ever refuses
# is a false block; a gate that only ever admits is an inert gate — and an inert gate reads exactly
# like a healthy one in every log. So the three cases here are the three states a box can be in:
#
#   (a) BELOW the floor with a reclaimable uv cache  -> reclaims, RE-MEASURES, and DISPATCHES
#   (b) BELOW the floor with nothing reclaimable     -> SKIPS, names free MB + floor, does NOT dispatch
#   (c) ABOVE the floor                              -> UNCHANGED: no reclaim, dispatch proceeds
#   (e) the two AGE-FLOOR env seams                  -> unset / empty / unusable / literal 0 /
#                                                       leading-zero all resolve to 86400; a usable
#                                                       value moves the floor. Sourced, not driven.
#
# ⛔ NON-VACUITY (case d). (b) passing is only meaningful if it FAILS when the gate is reverted. The
# suite therefore reverts the gate IN A COPY of disk-floor.sh — the shipped file is never edited — and
# asserts that the same fixture that (b) judged correctly is then judged WRONGLY (admitted instead of
# held). Without that, "SKIP happened" could be satisfied by a fixture that was below the floor for a
# reason the gate never looked at.
#
# HOW THE FLOOR IS SIMULATED WITHOUT LYING ABOUT THE DISK
# The floor is an env seam (`DISK_FLOOR_MB`), so "below the floor" is expressed as a floor ABOVE every
# real device rather than by faking `df`. That keeps the measurement real (the same POSIX `df -Pk` the
# controller runs) while making the comparison deterministic — a test that stubbed `df` would prove
# nothing about the shipped probe, which is the half #1765 measured as broken on Linux.
# The RECLAIM is driven through seams an operator would use, never through a bypass: `UV_CACHE_DIR`
# (uv's own knob) points at the fixture cache, `DISK_FLOOR_UV_BIN` at a stand-in `uv` (the same
# explicit-delegate-path rule disk-reaper.sh uses for CACHE_REAPER), and the scratch root at a fixture.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/disk-floor.sh"
[ -f "$GATE" ] || { echo "FATAL: $GATE not found (run from the harness checkout)" >&2; exit 2; }

T="$(mktemp -d 2>/dev/null)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*"; }
ck()  { if eval "$2"; then ok "$1"; else bad "$1"; fi; }   # ck <label> <shell-test>

# A floor above every real device: the measured reading is genuine, the comparison is deterministic.
ABOVE_ALL=999999999
# …and a floor no box is below, for case (c).
BELOW_ALL=1

# ── the fixture: one $O, one uv cache, one scratch root, one stand-in uv ──────────────────────────
mk_fixture() { # <name> -> sets F (fixture dir)
  F="$T/$1"; rm -rf "$F"; mkdir -p "$F/o/state" "$F/cache" "$F/scratch" "$F/bin"
  # 6 MiB of "cache" in 1 MiB files: big enough that a reclaim is measurable in `df` whole MB on a
  # filesystem that reports KiB blocks, small enough to be free.
  local i
  for i in 1 2 3 4 5 6; do dd if=/dev/zero of="$F/cache/blob-$i" bs=1024 count=1024 2>/dev/null; done
  # A stand-in `uv`: the gate only ever asks it to prune/clean the cache it was pointed at, and this
  # records the verbs so the suite can prove WHICH arm ran (the soft prune vs the hard clean).
  cat > "$F/bin/uv" <<'SH'
#!/bin/sh
verb="$1 $2"
printf '%s\n' "$verb" >> "${FAKE_UV_LOG:-/dev/null}"
case "$verb" in
  "cache prune") rm -f "$UV_CACHE_DIR"/blob-1 "$UV_CACHE_DIR"/blob-2 ;;
  "cache clean") rm -f "$UV_CACHE_DIR"/blob-* ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$F/bin/uv"
}

# run_gate <floor-mb> [<reclaim 0|1>] -> sets OUT (the gate's single line) and RC
run_gate() {
  local floor="$1" reclaim="${2:-1}"
  OUT="$(DISK_FLOOR_MB="$floor" DISK_FLOOR_RECLAIM="$reclaim" \
         UV_CACHE_DIR="$F/cache" XDG_CACHE_HOME="$F/nocache" \
         DISK_FLOOR_UV_BIN="$F/bin/uv" FAKE_UV_LOG="$F/uv.log" \
         DISK_FLOOR_SCRATCH_ROOT="$F/scratch" \
         bash -c '. "$1"; disk_floor_gate "$2"; exit $?' _ "$GATE" "$F/o" 2>&1)"
  RC=$?
}

printf '== (a) below the floor WITH a reclaimable uv cache: reclaim, re-measure, DISPATCH\n'
# ⛔ THE FLOOR IS SET JUST ABOVE WHAT THE BOX CAN REACH, NOT ABOVE ALL SPACE: case (a) must be able to
# SUCCEED after the reclaim, or it would only re-test case (b). Read live free space, then set the
# floor to `free + 4 MiB` and put 6 MiB of cache in front of it — the prune frees 2 MiB (not enough),
# so the HARD arm must run and free the rest. That is deliberate: it pins the escalation, which is the
# arm that freed the ~8.5 GB measured on the cell, and it pins that the gate RE-MEASURES in between.
mk_fixture a
FREE_A="$(df -Pk "$F/o" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%d\n", $4 / 1024}')"
if [ -z "$FREE_A" ]; then bad "(a) df could not answer for the fixture — the suite cannot express a floor it can reach"; else
  FLOOR_A=$(( FREE_A + 4 ))
  run_gate "$FLOOR_A" 1
  ck "(a) the gate returns 0 (dispatch proceeds)" '[ "$RC" = 0 ]'
  case "$OUT" in
    *"[disk] RECLAIMED"*) ok "(a) the line says RECLAIMED (the reclaim is what met the floor)" ;;
    *) bad "(a) expected a RECLAIMED line, got: ${OUT:-<empty>}" ;;
  esac
  ck "(a) the line names the free MB, the floor and the reclaimed MB" \
     'case "$OUT" in *"free="*"floor=${FLOOR_A}MB"*"reclaimed="*) true ;; *) false ;; esac'
  ck "(a) it really reclaimed: the prune freed 2 blobs and the hard clean freed the rest" \
     '[ ! -e "$F/cache/blob-6" ]'
  ck "(a) the escalation ran (uv cache clean), not only the prune" \
     'grep -qx "cache clean" "$F/uv.log" 2>/dev/null'
  ck "(a) the reclaim was attributed to the uv class in the line" \
     'case "$OUT" in *"uv-cache="*) true ;; *) false ;; esac'
fi

printf '== (b) below the floor with NOTHING reclaimable: SKIP, name free + floor, do NOT dispatch\n'
mk_fixture b
rm -f "$F/cache"/blob-*                       # nothing in the cache to reclaim
FREE_B="$(df -Pk "$F/o" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%d\n", $4 / 1024}')"
[ -n "$FREE_B" ] || FREE_B=0
FLOOR_B=$(( FREE_B + 100000 ))                # unreachable by any reclaim this fixture allows
run_gate "$FLOOR_B" 1
ck "(b) the gate returns 1 (HOLD — the caller must not dispatch)" '[ "$RC" = 1 ]'
case "$OUT" in
  *"[disk] SKIP"*) ok "(b) the line says SKIP" ;;
  *) bad "(b) expected a SKIP line, got: ${OUT:-<empty>}" ;;
esac
ck "(b) the line names the FREE MB (a real number, not a placeholder)" \
   'case "$OUT" in *"free="*"floor="*) case "$OUT" in *"free=?MB"*) false ;; *) true ;; esac ;; *) false ;; esac'
ck "(b) the line names the FLOOR" 'case "$OUT" in *"floor=${FLOOR_B}MB"*) true ;; *) false ;; esac'
ck "(b) the line names what was reclaimed (0, explicitly)" 'case "$OUT" in *"reclaimed=0MB"*) true ;; *) false ;; esac'
ck "(b) NOTHING was deleted" 'ls "$F/o" >/dev/null 2>&1 && [ -d "$F/cache" ]'
ck "(b) the line does NOT read like a healthy cycle" \
   'case "$OUT" in *"RECLAIMED"*|*"proceeds"*) false ;; *) true ;; esac'

printf '== (c) above the floor: UNCHANGED — no reclaim, dispatch proceeds\n'
mk_fixture c
run_gate "$BELOW_ALL" 1
ck "(c) the gate returns 0" '[ "$RC" = 0 ]'
ck "(c) it printed NOTHING (an unchanged cycle logs what it always logged)" '[ -z "$OUT" ]'
ck "(c) no uv verb ran" '[ ! -s "$F/uv.log" ]'
ck "(c) the cache is untouched" '[ -e "$F/cache/blob-6" ]'
# …and the same answer with the reclaim DISABLED, so the class seam cannot be the reason (c) is quiet.
run_gate "$BELOW_ALL" 0
ck "(c) with DISK_FLOOR_RECLAIM=0 above the floor: still silent, still 0" '[ "$RC" = 0 ] && [ -z "$OUT" ]'

printf '== (d) NON-VACUITY: revert the floor and (b) must FAIL\n'
# The revert is the smallest edit that REMOVES the floor: `disk_floor_gate` opens with `return 0`, i.e.
# the inert gate that admits every box whatever its disk says. If (b) still held under it, (b) was not
# measuring the gate — it was measuring the fixture. (The edit is made in a COPY; the shipped file is
# never touched, and the copy is diffed so a moved anchor reddens instead of silently reverting
# nothing — the vacuity failure mode of a mutation test.)
mk_fixture d
rm -f "$F/cache"/blob-*
awk '{ print } /^disk_floor_gate\(\) \{/ { print "  return 0   # ← THE REVERT: the floor removed" }' \
  "$GATE" > "$T/disk-floor-reverted.sh"
if cmp -s "$GATE" "$T/disk-floor-reverted.sh"; then
  bad "(d) the revert did not change the source — the non-vacuity check is itself vacuous (the anchor line moved)"
else
  FREE_D="$(df -Pk "$F/o" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%d\n", $4 / 1024}')"
  [ -n "$FREE_D" ] || FREE_D=0
  FLOOR_D=$(( FREE_D + 100000 ))
  OUT="$(DISK_FLOOR_MB="$FLOOR_D" DISK_FLOOR_RECLAIM=1 UV_CACHE_DIR="$F/cache" \
         DISK_FLOOR_UV_BIN="$F/bin/uv" FAKE_UV_LOG="$F/uv.log" DISK_FLOOR_SCRATCH_ROOT="$F/scratch" \
         bash -c '. "$1"; disk_floor_gate "$2"; exit $?' _ "$T/disk-floor-reverted.sh" "$F/o" 2>&1)"; RC=$?
  ck "(d) with the floor REVERTED, the SAME fixture case (b) holds is ADMITTED (rc 0)" '[ "$RC" = 0 ]'
  ck "(d) …and prints nothing, i.e. (b)'s SKIP line was produced by the gate and not by the fixture" '[ -z "$OUT" ]'
  # …and the shipped gate on the same fixture still holds: one fixture, two gates, opposite verdicts.
  run_gate "$FLOOR_D" 1
  ck "(d) the SHIPPED gate on the same fixture still returns 1 (the difference is the gate)" '[ "$RC" = 1 ]'
fi

# ── the two AGE-FLOOR env seams ───────────────────────────────────────────────────────────────────
# The declarations registry (`extensions/shared/heartbeat-progress-edges.ts`,
# STALL_TERM_REGISTRY) registers DISK_FLOOR_COPY_MIN_AGE_S and DISK_FLOOR_SCRATCH_MIN_AGE_S, and its
# reverse scan went RED on main for the weeks they were unregistered. Registering a term that nothing
# asserts would be a claim nobody checks, so the polarities live here, against the SHIPPED script
# (sourced, exactly as cases (a)-(d) above source it).
#
# HONEST SCOPE — what this pins and what it does not. `disk_floor_num()`'s documented contract is
# "an unusable value is the DEFAULT, never 0", and the direction that matters is the LOW end: a 0 age
# floor makes every stale copy and every scratch directory instantly eligible, i.e. a deletion rather
# than a floor. So "" and a literal 0 must BOTH resolve to 86400, only a genuinely usable value may
# move the floor, and a leading-zero value (the `08`-is-invalid-octal hazard the shipped comment
# cites from #2293) must fall back too. These assertions pin the RESOLUTION of the seam. They do NOT
# pin that the sweeps USE the resolved value, and they do NOT pin an upper bound — `disk_floor_num`
# has none (unlike DISK_FLOOR_MB, which clamps at 249999999), so a 20-digit typo overflows `find`'s
# minute arithmetic into a ~1-minute floor. Both gaps are follow-ups, not claims made here.
age_seam() { # <VAR> <value> -> the value the shipped script resolves when VAR is SET to <value>
  # 2>&1 rather than 2>/dev/null and NO `| tail -1`: both existed to hide noise, which would also
  # hide a sourcing error. The comparison is an exact `=`, so any stray byte is a loud failure.
  env "$1=$2" bash -c '. "$1"; printf %s "${!2-}"' _ "$GATE" "$1" 2>&1
}
age_seam_unset() { # <VAR> -> the value when VAR is genuinely ABSENT from the environment
  env -u "$1" bash -c '. "$1"; printf %s "${!2-}"' _ "$GATE" "$1" 2>&1
}
for AGE_SEAM in DISK_FLOOR_COPY_MIN_AGE_S DISK_FLOOR_SCRATCH_MIN_AGE_S; do
  ck "$AGE_SEAM defaults to 86400 (one day) when genuinely UNSET" \
     '[ "$(age_seam_unset "$AGE_SEAM")" = 86400 ]'
  ck "$AGE_SEAM: set-but-EMPTY also resolves to 86400" \
     '[ "$(age_seam "$AGE_SEAM" "")" = 86400 ]'
  ck "$AGE_SEAM: an unusable value falls back to 86400, never 0" \
     '[ "$(age_seam "$AGE_SEAM" abc)" = 86400 ]'
  ck "$AGE_SEAM: a literal 0 falls back to 86400 (a zero age floor is a deletion, not a floor)" \
     '[ "$(age_seam "$AGE_SEAM" 0)" = 86400 ]'
  ck "$AGE_SEAM: a leading-zero value falls back to 86400 (the 08-octal hazard, #2293)" \
     '[ "$(age_seam "$AGE_SEAM" 0400)" = 86400 ]'
  ck "$AGE_SEAM: a usable override is honoured (the seam is real, not decorative)" \
     '[ "$(age_seam "$AGE_SEAM" 120)" = 120 ]'
done

printf '\n== %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
