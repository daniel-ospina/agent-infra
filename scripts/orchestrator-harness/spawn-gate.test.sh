#!/usr/bin/env bash
# spawn-gate.test.sh — the load gate and the ONE agent invocation (agent-infra#1720, #8521 port).
#
# HOW THESE CHECKS ARE WRITTEN. The subject is the SHIPPED `spawn-gate.sh`: every check below
# sources that file and drives the real `run_agent`/`can_spawn`/`load1`, then asserts on what they
# DID — whether the stub `pi` was executed, what the walltime ledger received, which exit code came
# back. A check that re-implements the gate passes on the ungated tree too, which is the vacuity
# this suite exists to avoid. `load1` is the one function the test RE-DECLARES after sourcing, and
# that is a seam rather than a stub of the logic under test: run_agent()'s contract is "read load
# IMMEDIATELY before the spawn", and that reading has to be controllable to test the contract at all.
#
# ⛔ `rc=$?` IS CAPTURED ON THE LINE IMMEDIATELY AFTER EVERY TESTED COMMAND, never `ck "… $?"`.
# `$?` inside a `ck` argument is expanded AFTER any `$(…)` in that argument has run, so a message
# that inspects a file silently substitutes the STATUS OF `cat` — the same defect §7.4 records for
# retired/do-merge.sh, and it made three checks here pass on an empty file while writing this port.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
GATE="$HERE/spawn-gate.sh"
mkdir -p "$TMP/bin" "$TMP/O/state"
LOG="$TMP/log"; PROMPT="$TMP/prompt"; PI_LOG="$TMP/pi.log"
printf 'a prompt\n' > "$PROMPT"

echo "==> spawn-gate self-test ($HERE)"

# ── 1) the helper exists, parses, and is SOURCED (never executed) by its callers ─
[ -s "$GATE" ] && bash -n "$GATE"; rc=$?
ck "spawn-gate.sh exists and parses" $rc

# A `run_agent` that a caller never received is worse than none: an unset function is a 127 at the
# SPAWN SITE, not a load-time error, so a caller must FAIL LOUD when the helper is absent rather
# than carry on ungated. Assert the guard, not merely the source line.
for f in lane.sh fix-one.sh; do
  grep -q '\. "\$SELF/spawn-gate.sh" ||' "$HERE/$f"; rc=$?
  ck "$f refuses to run when spawn-gate.sh is missing (fail loud, not 127 at the spawn)" $rc
done

# ⛔ SOURCED AFTER `export PATH`. spawn-gate.sh resolves `_NCPU` at SOURCE time through
# sysctl/nproc/getconf, so a caller that sources it above its PATH export pins _NCPU=4 and
# MAX_LOAD=40 on every cell — the #1702 failure the portable probe exists to prevent.
for f in lane.sh fix-one.sh; do
  src="$(grep -n 'spawn-gate.sh"' "$HERE/$f" | head -1 | cut -d: -f1)"
  pexp="$(grep -n '^export PATH=' "$HERE/$f" | head -1 | cut -d: -f1)"
  if [ -n "$src" ] && [ -n "$pexp" ] && [ "$src" -gt "$pexp" ]; then rc=0; else rc=1; fi
  ck "$f sources the helper AFTER its PATH export (line $src > $pexp)" $rc
done

# ── 2) exactly ONE shipped file invokes the model ────────────────────────────────
# The defect was three copy-pasted spawn sites plus a fourth launch path nobody routed. A grep for
# "run_agent" would pass on a file that defines it and never calls it, so this counts the actual
# INVOCATION and asserts the SET rather than a total: a new launch path fails here until it is
# routed through the helper, and porting the remaining caller is an explicit, visible edit.
# The test suites are excluded — they are not launch paths, and this file's own grep pattern would
# otherwise match itself.
PI_FILES=""
for f in "$HERE"/*.sh; do
  b="$(basename "$f")"
  case "$b" in selftest.sh|*.test.sh) continue ;; esac
  grep -q 'pi -p ' "$f" && PI_FILES="$PI_FILES $b"
done
PI_FILES="${PI_FILES# }"
# merge-one.sh is NOT ported here: it is owned by a concurrent lane (PR #1769/#1730). The assertion
# is deliberately an EQUALITY, so the residual is asserted rather than left silent, and a THIRD
# pi-invoker — or a regression in either of these two — fails it.
EXPECTED_PI="merge-one.sh spawn-gate.sh"
[ "$PI_FILES" = "$EXPECTED_PI" ]; rc=$?
[ "$rc" -eq 0 ] || echo "      pi-invokers found: [${PI_FILES:-<none>}]"
ck "the shipped pi-invokers are exactly [$EXPECTED_PI]" $rc

# ... and the ported callers must have no spawn logic of their own left behind.
for f in lane.sh fix-one.sh; do
  if grep -qE '^run_agent\(\)' "$HERE/$f"; then rc=1; else rc=0; fi
  ck "$f no longer defines its own run_agent() (one copy, in the helper)" $rc
done

# ── 3) load1 reads the 1-min load on BOTH platforms ─────────────────────────────
# /proc field 1 IS the 1-min load; macOS `sysctl vm.loadavg` prints `{ 1m 5m 15m }`, where awk sees
# the brace as $1 so the 1-min load is $2. One shared awk reads the wrong thing on one of the two.
got="$(. "$GATE" 2>/dev/null; printf '4.50 1.00 2.00\n' > "$TMP/loadavg"; load1 "$TMP/loadavg" 2>/dev/null)"
[ "$got" = "4" ]; rc=$?
ck "load1 reads field 1 from a /proc/loadavg file (got '${got:-<none>}', want 4)" $rc

if [ -r /proc/loadavg ]; then
  echo "  ⏭  skip: this host has /proc/loadavg, so load1's sysctl branch is unreachable here"
else
  # macOS. A fake `sysctl` is the only way to drive the real branch. The three values DIFFER
  # (3.10 / 7.90 / 2.00) so the check discriminates: the 1-min load is 3, a shared awk reading $1
  # gives 0 (the brace), and a 5-min read gives 7.
  printf '#!/bin/sh\n[ "$1" = "-n" ] && [ "$2" = "vm.loadavg" ] && { echo "{ 3.10 7.90 2.00 }"; exit 0; }\nexit 1\n' > "$TMP/bin/sysctl"
  chmod +x "$TMP/bin/sysctl"
  got="$(PATH="$TMP/bin:$PATH" bash -c '. "$1"; load1' _ "$GATE" 2>/dev/null)"
  [ "$got" = "3" ]; rc=$?
  ck "load1 reads the 1-min load from sysctl vm.loadavg on macOS (got '${got:-<none>}', want 3)" $rc
fi

# ── 4) MAX_LOAD coercion: a bad plist value must CLOSE the gate, not open it ─────
# `[ -ge ]` on a non-number is FALSE, and a false test in the gate chain ALLOWS dispatch — so a
# typo in the plist would remove the back-pressure. Leading zeros are the subtle half: `$(( ))`
# parses base 0, so `08` reaches `[ "$L" -ge "08" ]`, which ERRORS (also false => OPEN). The
# magnitude is the third: a 19-digit MAX_LOAD passes a digits-only test and errors every `[ -ge ]`.
for bad in "08" "abc" "" "9223372036854775807" " 5"; do
  got="$(MAX_LOAD="$bad" bash -c '. "$1"; printf "%s" "$MAX_LOAD"' _ "$GATE" 2>/dev/null)"
  case "$got" in 0|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]|[1-9][0-9][0-9][0-9][0-9]) rc=0 ;; *) rc=1 ;; esac
  ck "MAX_LOAD='$bad' is coerced to a usable integer (got '${got:-<empty>}')" $rc
done
# ... and the derived default uses the PORTABLE probe, not `|| echo 4` (which pinned every Linux
# cell to 4 cores / MAX_LOAD=40, #1702).
want_ncpu="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
got="$(env -u MAX_LOAD bash -c '. "$1"; printf "%s" "$MAX_LOAD"' _ "$GATE" 2>/dev/null)"
[ "$got" = "$(( 10#$want_ncpu * 10 ))" ]; rc=$?
ck "the derived MAX_LOAD is 10 x the PORTABLE core count (got '${got:-<none>}', want $(( 10#$want_ncpu * 10 )))" $rc

# ── 5) can_spawn is a strict `<` on the reading it is GIVEN ─────────────────────
# The argument (never a global) is the point: merge-one.sh uses `L` for a LOG PATH, so a gate that
# read a global `$L` would compare "/…/logs/merge-42" against MAX_LOAD.
got="$(. "$GATE" 2>/dev/null; MAX_LOAD=10; r=""
       can_spawn 9  && r="${r}9+" || r="${r}9-"
       can_spawn 10 && r="${r}10+" || r="${r}10-"
       can_spawn 0  && r="${r}0+" || r="${r}0-"
       printf '%s' "$r")"
[ "$got" = "9+10-0+" ]; rc=$?
ck "can_spawn accepts <MAX_LOAD and refuses >=MAX_LOAD (got '${got:-<none>}')" $rc

# ── 6) run_agent REFUSES above the ceiling — and the agent is really not started ─
cat > "$TMP/bin/pi" <<'PI'
#!/bin/sh
echo "PI_RAN" >> "$PI_LOG"
exit 0
PI
chmod +x "$TMP/bin/pi"

# drive <load> <label> [<max-load>] — runs the SHIPPED run_agent under a controlled reading. `load1`
# is re-declared AFTER sourcing, which is the seam described at the top. `pi` is a stub; every
# assertion is on WHETHER IT RAN and on the ledger, never on a model.
drive() { # drive <load> <label> <max-load>
  local load="$1" label="${2:-test agent}" max="${3:-10}"
  : > "$PI_LOG"
  PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" bash -c '
    . "$1"
    LOAD="$2"; MAX_LOAD="$3"; LOG="$4"; PROMPT="$5"; LABEL="$6"
    load1() { printf "%s" "$LOAD"; }
    run_agent 5 "$LOG" "$PROMPT" "$LABEL" >/dev/null 2>&1
    rc=$?
    printf "rc=%s started=%s" "$rc" "$AGENT_STARTED"
  ' _ "$GATE" "$load" "$max" "$LOG" "$PROMPT" "$label"
}

rm -f "$TMP/O/state/walltime.tsv"; : > "$LOG"
res="$(drive 40)"
[ "$res" = "rc=75 started=0" ]; rc=$?
ck "run_agent above MAX_LOAD returns AGENT_LOAD_REFUSED and sets AGENT_STARTED=0 ($res)" $rc
[ ! -s "$PI_LOG" ]; rc=$?
ck "the model was NOT invoked on a refusal (a refusal must not spawn)" $rc
# The refusal is EXPLICIT and NAMES the load: an operator reading the log must be able to tell it
# apart from a failed agent, because the two demand opposite responses (wait vs fix).
grep -q 'load-gate.*REFUSED.*load=40 >= max_load=10' "$LOG"; rc=$?
ck "the refusal line names the gate, the load and the ceiling" $rc
# A refused spawn must write NO walltime row: no agent ran, so a row would fabricate a zero-duration
# sample into the very series #1709 reads to size the fleet.
[ ! -s "$TMP/O/state/walltime.tsv" ]; rc=$?
ck "a refusal writes no walltime row (the #1709 series stays honest)" $rc

# ── 7) ... and it STARTS below the ceiling, recording the measurement ────────────
: > "$LOG"
res="$(drive 3)"
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "run_agent below MAX_LOAD starts the agent ($res)" $rc
grep -q 'PI_RAN' "$PI_LOG"; rc=$?
ck "the model was actually invoked when the gate allowed it" $rc
grep -q 'elapsed=' "$LOG"; rc=$?
ck "the run records the measured elapsed wall-time (#1709 item 3)" $rc
# 6 tab-separated fields: epoch, kind, tag, wall limit, elapsed, rc — the append-only series.
row="$(tail -1 "$TMP/O/state/walltime.tsv" 2>/dev/null)"
nf="$(printf '%s' "$row" | awk -F'\t' '{print NF}')"
f4="$(printf '%s' "$row" | cut -f4)"
[ "$nf" = "6" ] && [ "$f4" = "5" ]; rc=$?
ck "a started run appends one 6-field row to walltime.tsv (got: ${row:-<none>})" $rc

# ── 8) the gate RE-READS at the spawn, and a refusal is not a `pi` exit status ───
# This is the whole point of the port: a chain-<N> worker dispatched on a quiet box may open its PR
# 90 minutes later, and the reading that governs is the one taken at the spawn.
got="$(PATH="$TMP/bin:$PATH" O="$TMP/O" bash -c '
  . "$1"
  MAX_LOAD=10
  load1() { printf "2"; }                   # the controller-time reading: quiet
  can_spawn "$(load1)" || exit 9            # would have allowed the session
  load1() { printf "99"; }                  # load has since spiked
  run_agent 5 "$2" "$3" "late chain worker" >/dev/null 2>&1
  printf "rc=%s" "$?"
' _ "$GATE" "$TMP/log2" "$PROMPT" 2>/dev/null)"
[ "$got" = "rc=75" ]; rc=$?
ck "a spawn re-reads load (quiet dispatch, spiked spawn -> refused: '${got:-<none>}')" $rc
# ... and pi's 0-255 namespace cannot be mistaken for a refusal, so AGENT_STARTED (not the exit
# code) is what the callers act on.
got="$(PATH="$TMP/bin:$PATH" O="$TMP/O" bash -c '
  . "$1"
  load1() { printf "0"; }
  MAX_LOAD=10
  run_agent 5 "$2" "$3" "agent that itself exits 75" >/dev/null 2>&1
  printf "started=%s" "$AGENT_STARTED"
' _ "$GATE" "$TMP/log3" "$PROMPT" 2>/dev/null)"
[ "$got" = "started=1" ]; rc=$?
ck "AGENT_STARTED distinguishes a real refusal from a pi that exits 75 itself ('${got:-<none>}')" $rc

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
