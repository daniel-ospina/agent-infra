#!/usr/bin/env bash
# orch-loop-lock.test.sh — `orch-loop.sh`'s single-instance lock reclaims on IDENTITY, not liveness
# (agent-infra#1985).
#
# ⛔ WHAT THIS SUITE IS FOR. The lock used to reclaim on `kill -0 "$OPID"` alone. A controller killed
# without its EXIT trap (kill -9, OOM, panic) leaves the lock naming a pid the OS will RECYCLE, and
# then the next controller exits `already running (pid N)` over a process that is not a controller at
# all: the box dispatches nothing and cannot start its own recovery. Measured on a live box — the
# watchdog saw the named pid alive, `ps -p <pid> -o command=` showed a foreign process, and the reload
# failed `RECOVERY FAILED` rc 1 on three consecutive passes.
#
# ⛔ AND THE OTHER DIRECTION IS WORSE, so every arm below is paired. Reclaiming on a read the run
# could not make is how two autonomous controllers sweep one PR queue (#1715). So the rule under test
# is three-valued and only POSITIVE evidence of non-ownership reclaims:
#
#   1. no lock                          → acquire, run
#   2. a LIVE owner (real order: lock written after it started) → REFUSE, name it, do not clobber
#   3. a DEAD owner                     → reclaim, run
#   4. ⭐ a RECYCLED pid (`sleep`, absent from the argv shape) → reclaim, run   [the #1985 acceptance]
#   5. ⭐ a PEER controller (argv shape MATCHES — same basename, shared harness path) that began AFTER
#      the lock was written → reclaim, run    [the §M case: shape alone cannot discriminate]
#   6. the same peer controller, lock written AFTER it started → REFUSE  [so 5 cannot pass by refusing
#      everything, and 6 cannot pass by reclaiming everything]
#   7. an UNDATABLE age (`ps` shim without `-o etime=`) on a loop-shaped owner → REFUSE, loudly, with
#      the remedy named — the #1985 defect was that this refusal was one silent line [fail closed]
#   8. a lock carrying no digits, and a lock naming pid 0 → reclaim, run, and NO shell error
#      (`[ abc -gt 0 ]` is an ERRORED test, which is FALSE, which reclaimed — #1831's class)
#   9. structural + DRIFT pins: the block sits above the EXIT trap, the trap is the only releaser,
#      `acq` keeps `noclobber`, the old liveness-only line is GONE, and both mirror bodies plus the
#      slack are IDENTICAL to the canonical declarations they were copied from (#1178/#1856).
#
# ⛔ THE SUBJECT IS THE REAL `orch-loop.sh`, NOT A RE-IMPLEMENTATION. The lock block lives in a marked
# section (`# [orchlock:begin] … # [orchlock:end]`), which this suite EXTRACTS with `sed` and runs as
# a script with `O`/`LOG` supplied — the same sourcing-excerpt contract `repo-target.test.sh` and
# `nochk-resolve.test.sh` already use for this file. Running the whole loop end-to-end is not an
# option (it dispatches), and a hand-copied predicate would pin the copy, not the subject.
#
# Hermetic: every case gets its own temp dir, its own `$O`/`$LOG`, and stub processes only. No network,
# no model, no fleet, no real state dir.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/orch-loop.sh"
LIB_PID="$HERE/../lib/pid-identity.sh"
LIB_REG="$HERE/../lib/orchestrator-registry.sh"
PASS=0; FAIL=0; SKIP=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
skip() { printf '  ⏭ %s\n' "$1"; SKIP=$((SKIP+1)); }
want() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }   # substring membership (no nesting in $( ))

TMP="$(mktemp -d)" || exit 1
KIDS=""
cleanup() {
  for p in $KIDS; do kill -9 "$p" 2>/dev/null; done
  chmod -R u+rwX "$TMP" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> orch-loop single-instance lock self-test ($HERE)"

# ── helpers with UNAMBIGUOUS polarity (ck takes 0 = ok; these take a COMMAND) ─────────────────────
okc() { # okc <desc> <cmd...> — ok when the command SUCCEEDS
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ck "$d" 0; else ck "$d" 1; fi
}
okc_not() { # okc_not <desc> <cmd...> — ok when the command FAILS
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ck "$d" 1; else ck "$d" 0; fi
}
has_all() { # has_all <file> <fixed-string>... — ok when EVERY string is present
  local f="$1"; shift
  local n
  for n in "$@"; do grep -qF -- "$n" "$f" || return 1; done
  return 0
}

# ── 9a) the subject exists, parses, and the marked section is extractable ─────────────────────────
[ -s "$SUBJECT" ]; ck "orch-loop.sh exists and is non-empty" $?
# A literal script name after a `cd` (never `bash -n "$SUBJECT"`): the main-worktree-guard cannot
# statically resolve the variable form and then refuses to run THIS suite (#709) — an unrunnable
# suite protects nothing.
( cd "$HERE" && bash -n orch-loop.sh ); ck "orch-loop.sh parses under bash" $?
[ "$(grep -c '^# \[orchlock:begin\]$' "$SUBJECT")" = 1 ] && [ "$(grep -c '^# \[orchlock:end\]$' "$SUBJECT")" = 1 ]
ck "the lock section is marked by exactly one begin/end pair" $?
BEGIN_L="$(grep -n '^# \[orchlock:begin\]$' "$SUBJECT" | head -1 | cut -d: -f1)"
END_L="$(grep -n '^# \[orchlock:end\]$' "$SUBJECT" | head -1 | cut -d: -f1)"
[ -n "$BEGIN_L" ] && [ -n "$END_L" ] && [ "$BEGIN_L" -lt "$END_L" ]
ck "the section's markers are ordered (begin < end)" $?
SECTION="$TMP/orchlock.section.sh"
sed -n '/^# \[orchlock:begin\]$/,/^# \[orchlock:end\]$/p' "$SUBJECT" | sed '1d;$d' > "$SECTION"
[ -s "$SECTION" ] && ! grep -q 'orchlock:' "$SECTION"
ck "the extracted section is non-empty and carries no marker residue" $?
has_all "$SECTION" 'LOCKF=' 'acq() {' '_orch_lock_verdict() {'
ck "the section defines the lock file, the verdict, and the acquisition" $?
[ "$(grep -c '^LOCKF=' "$SUBJECT")" = 1 ]
ck "LOCKF is defined ONCE in the whole loop (no split identity of the lock path)" $?

# ── 9b) STRUCTURAL: the block is ABOVE the EXIT trap, and the trap is the ONLY releaser ───────────
TRAP_L="$(grep -nF "trap 'rm -f \"\$LOCKF\"' EXIT" "$SUBJECT" | head -1 | cut -d: -f1)"
[ -n "$TRAP_L" ] && [ "$TRAP_L" -gt "$END_L" ]
ck "the EXIT trap that releases the lock sits BELOW the section (the block runs first)" $?
# ⛔ THE ARM MUST RED ON THE EXACT #1715 REVERT, AND THE FIRST FORM DID NOT (fresh review of #1985,
# P2 — MEASURED: restoring `trap 'rm -f "$LOCKF"' EXIT INT TERM` byte for byte left every arm green,
# because the regex anchored the signal names at the START of the trap while the historical regression
# has them AFTER `EXIT`). So this pins the WHOLE SET: one trap line may mention $LOCKF at all, and it
# must be exactly the EXIT-only form.
LOCK_TRAPS="$(grep -E '^trap .*LOCKF' "$SUBJECT" 2>/dev/null)"
# ⛔ `-qxF`, NOT `-qF`: a SUBSTRING match accepts `trap 'rm -f "$LOCKF"' EXIT INT TERM`, which is the
# very regression this arm exists for (MEASURED on the first fix of this arm — the revert stayed green).
[ "$(printf '%s\n' "$LOCK_TRAPS" | grep -c .)" = 1 ] \
  && printf '%s\n' "$LOCK_TRAPS" | grep -qxF "trap 'rm -f \"\$LOCKF\"' EXIT"
ck "the lock is released by ONE trap and it is EXACTLY the EXIT-only form (a returning INT/TERM handler deleted it while the loop lived — #1715)" $?
okc "acq() still takes the lock with set -o noclobber (unchanged primitive)" \
  grep -qF 'acq() { ( set -o noclobber; echo $$ > "$LOCKF" ) 2>/dev/null; }' "$SUBJECT"
okc_not "the OLD liveness-only reclaim is GONE (it must not survive beside the new verdict)" \
  grep -qE 'kill -0 "\$OPID" 2>/dev/null; then echo "\[orch-loop\] already running' "$SUBJECT"
has_all "$SECTION" '_orch_lock_verdict "${OPID:-0}" "$LOCKF"'
ck "the acquisition decision comes from _orch_lock_verdict, not from a bare liveness test" $?
has_all "$SECTION" 'provably NOT the owner'
ck "a reclaim is LOGGED (a silent reclaim is invisible; a silent refusal is the #1985 defect)" $?
has_all "$SECTION" 'CANNOT-TELL' 'rm -f $LOCKF'
ck "an UNKNOWN verdict is logged AND names the remedy" $?

# ── 9c) DRIFT PINS — the mirrors must be the canonical bodies, not remembered ones (#1178/#1856) ──
# Normalised comparison (names + comments + whitespace), the same form install-controller-service.test.sh
# §N and cloud-cell-supervisor.test.sh §(p) apply to their pinned copies.
extract_fn() { awk -v n="$2" 'index($0, n"() {")==1 {p=1} p{print} p && /^}$/{exit}' "$1"; }
norm_fn() {
  sed -e 's/_orch_ps_start_epoch/FN_START/g' -e 's/pid_start_epoch/FN_START/g' \
      -e 's/_orch_pid_is_loop/FN_LOOP/g' -e 's/registry_pid_is_controller/FN_LOOP/g' \
      -e 's/[[:space:]]\+$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d'
}
if [ -f "$LIB_PID" ] && [ -f "$LIB_REG" ]; then
  A_START="$(extract_fn "$SUBJECT" _orch_ps_start_epoch | norm_fn)"
  B_START="$(extract_fn "$LIB_PID" pid_start_epoch | norm_fn)"
  [ -n "$A_START" ] && [ "$A_START" = "$B_START" ]
  ck "the age mirror's CODE is identical to pid-identity.sh:pid_start_epoch" $?
  # ⛔ THE TOKEN RULES ARE THE PINNED PART, NOT THE WHOLE BODY (fresh review of #1985, P1). The READ
  # arms deliberately differ: in a REPORTING consumer a false "not the owner" degrades a row to
  # STOPPED, while HERE the caller answers it by DELETING a live owner's lock (#1715), so the loop's
  # read is three-valued (`_orch_lock_probe`) and the canonical one is not. What must never drift are
  # the two argv TOKEN rules (#1856: a looser ANY-token match accepts a non-controller).
  token_rules() { grep -E "##\*/|-ge 2" | sed -e 's/[[:space:]]\+$//' -e '/^[[:space:]]*#/d'; }
  A_LOOP="$(extract_fn "$SUBJECT" _orch_argv_is_loop | token_rules)"
  B_LOOP="$(extract_fn "$LIB_REG" registry_pid_is_controller | token_rules)"
  [ -n "$A_LOOP" ] && [ "$A_LOOP" = "$B_LOOP" ]
  ck "the argv-shape mirror's TOKEN RULES are identical to orchestrator-registry.sh:registry_pid_is_controller" $?
  _a="$(sed -n 's/^ORCH_LOCK_START_SLACK_SECONDS="\${ORCH_LOCK_START_SLACK_SECONDS:-\([0-9]*\)}"/\1/p' "$SUBJECT" | head -1)"
  _b="$(sed -n 's/^PID_START_SLACK_SECONDS="\${PID_START_SLACK_SECONDS:-\([0-9]*\)}"/\1/p' "$LIB_PID" | head -1)"
  [ -n "${_a:-}" ] && [ "$_a" = "$_b" ]
  ck "the fence slack is the fleet's ONE value (${_a:-<absent>}s, same as pid-identity.sh)" $?
else
  skip "drift pins: $LIB_PID or $LIB_REG is not present in this checkout"
fi

# ── the fixture ──────────────────────────────────────────────────────────────────────────────────
# mkcase <name> — a fresh `$O`, an empty log, and a driver that runs the EXTRACTED section and then
# prints its own pid, which is what proves the section ran past the lock instead of exiting.
CASE_N=0
mkcase() {
  CASE_N=$((CASE_N+1))
  C="$TMP/c$CASE_N"
  mkdir -p "$C/o/logs" "$C/peer" "$C/bin"
  : > "$C/o/logs/orch-loop.log"
  {
    printf 'set -u\n'
    printf 'O="%s/o"\n' "$C"
    printf 'LOG="%s/o/logs/orch-loop.log"\n' "$C"
    cat "$SECTION"
    printf 'echo "STARTED pid=$$"\n'
  } > "$C/drv.sh"
  : > "$C/o/logs/orch-loop.log"
}
# spawn_loop <dir> — a process whose argv IS an orch-loop.sh invocation (`<shell> <dir>/orch-loop.sh`).
# Prints its pid. This is the shape `registry_pid_is_controller` accepts and a `sleep` does not.
# ⛔ THE CALLER APPENDS TO KIDS, THE HELPER DOES NOT (fresh review of #1985, P2 — MEASURED: every call
# site is `X="$(spawn_loop …)"`, which runs the helper in a SUBSHELL, so `KIDS="$KIDS $_pid"` inside it
# never reached the parent and `cleanup()` killed NOTHING — a dead registry that reads as protection).
spawn_loop() {
  printf '#!/bin/bash\ntrap "exit 0" TERM INT\nwhile :; do sleep 1; done\n' > "$1/orch-loop.sh"
  chmod +x "$1/orch-loop.sh"
  bash "$1/orch-loop.sh" >/dev/null 2>&1 &
  printf '%s\n' "$!"
}
spawn_sleep() {
  sleep 300 >/dev/null 2>&1 &
  printf '%s\n' "$!"
}
run_drv() { # <case-dir> [env...] -> sets RC, OUT, ERR
  RC=0
  OUT="$(env "$@" bash "$CASE_DIR/drv.sh" 2>"$CASE_DIR/err.txt")" || RC=$?
  ERR="$(cat "$CASE_DIR/err.txt" 2>/dev/null)"
}
ran() { want "$OUT" "STARTED pid="; }
lock_pid() { tr -dc '0-9' 2>/dev/null < "$1"; }

# ⛔ EVERY SPAWN CALL SITE MUST REGISTER ITS PID IN THE PARENT (fresh review of #1985, P2). Both
# helpers are called through `$( … )`, so the helper's own `KIDS=…` would be lost to a subshell — the
# arm above asserts the trap exists, this one asserts it has something to kill.
UNREG="$(grep -nE '\$\(spawn_(loop|sleep)' "$HERE/orch-loop-lock.test.sh" | grep -v 'KIDS="\$KIDS' | grep -v '^[0-9]*: *#' | wc -l | tr -d ' ')"
[ "$UNREG" = "0" ]
ck "every spawn call site registers its pid in the PARENT shell ($UNREG unregistered)" $?

# ── 1) NO LOCK → acquire and run ─────────────────────────────────────────────────────────────────
echo "── 1. no lock: the controller acquires it and runs"
mkcase; CASE_DIR="$C"
printf '#!/bin/bash\nwhile :; do sleep 1; done\n' > "$C/o/orch-loop.sh"
run_drv O="$C/o"
ck "1: runs (the section does not exit when the lock is free)" "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
OWN="$(printf '%s\n' "$OUT" | sed -n 's/.*STARTED pid=\([0-9]*\).*/\1/p')"
[ -f "$C/o/.orch.lock" ] && [ "$(lock_pid "$C/o/.orch.lock")" = "$OWN" ] && [ -n "$OWN" ]
ck "1: the lock names the process that acquired it ($OWN)" $?

# ── 2) a LIVE owner (real order) → REFUSE, name it, do not clobber ────────────────────────────────
echo "── 2. a live orch-loop.sh owner: refuse, name the pid, leave the lock alone"
mkcase; CASE_DIR="$C"
HP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $HP"; sleep 0.4
printf '%s\n' "$HP" > "$C/o/.orch.lock"          # AFTER the process started — the real write order
run_drv O="$C/o"
ck "2: refuses (does not run a second controller over a live owner)" "$(ran && echo 1 || echo 0)"
ck "2: the refusal NAMES the live pid ($HP)" "$(want "$OUT" "already running (pid $HP)" && echo 0 || echo 1)"
ck "2: the lock still names the owner (a refusal clobbers nothing)" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$HP" ] && echo 0 || echo 1 )"
kill -9 "$HP" 2>/dev/null

# ── 3) a DEAD owner → reclaim and run ────────────────────────────────────────────────────────────
echo "── 3. a dead owner: reclaim and run"
mkcase; CASE_DIR="$C"
DP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $DP"; sleep 0.4
printf '%s\n' "$DP" > "$C/o/.orch.lock"
kill -9 "$DP" 2>/dev/null; sleep 0.3
run_drv O="$C/o"
ck "3: runs after reclaiming a lock whose pid is gone" "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "3: the reclaim is LOGGED (never silent)" "$(want "$(cat "$C/o/logs/orch-loop.log")" "provably NOT the owner" && echo 0 || echo 1)"

# ── 4) ⭐ THE #1985 CASE: a RECYCLED pid (live, not an orch-loop.sh) → reclaim and run ───────────
# The lock outlived its writer (kill -9), the OS recycles the pid onto an unrelated process, and the
# old code refused to start over it forever. The acceptance criterion of #1985, verbatim.
echo "── 4. ⭐ a RECYCLED pid that is not an orch-loop.sh: reclaim and run (the #1985 acceptance)"
mkcase; CASE_DIR="$C"
RP="$(spawn_sleep)"; KIDS="$KIDS $RP"; sleep 0.2
printf '%s\n' "$RP" > "$C/o/.orch.lock"
touch -t 202001010000 "$C/o/.orch.lock" 2>/dev/null || touch -d '2020-01-01 00:00:00' "$C/o/.orch.lock"
run_drv O="$C/o"
ck "4: a live NON-controller pid does not stop the box (it starts and runs)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "4: the stale lock is replaced by the newcomer's own pid" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$(printf '%s\n' "$OUT" | sed -n 's/.*STARTED pid=\([0-9]*\).*/\1/p')" ] && echo 0 || echo 1 )"
kill -9 "$RP" 2>/dev/null

# ── 4b) a live NON-controller pid, lock written AFTER it started → reclaim (SHAPE alone bites) ────
# This is the hand-written/copied-lock shape: the pid is alive and (by mtime) "older than the lock", so
# the AGE arm alone would call it the owner and the box would stay down forever. A process that is not
# an `orch-loop.sh` INVOCATION cannot be the controller that wrote this lock — that is what #1985 asks
# for verbatim ("with $O/.orch.lock naming a live non-controller pid, orch-loop.sh starts and runs").
echo "── 4b. a live NON-controller pid with a FRESH lock: reclaim (the argv-shape arm is load-bearing)"
mkcase; CASE_DIR="$C"
SP="$(spawn_sleep)"; KIDS="$KIDS $SP"; sleep 0.4
printf '%s\n' "$SP" > "$C/o/.orch.lock"          # lock written AFTER the process began
run_drv O="$C/o"
ck "4b: a live pid that is not an orch-loop.sh is not an owner (it starts and runs)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
kill -9 "$SP" 2>/dev/null

# ── 5) ⭐ a PEER controller that began AFTER the lock → reclaim (shape cannot discriminate) ──────
# On this fleet the recycled target is a PEER repo's controller: same basename, same shared harness
# path, so the argv shape matches PERFECTLY. The age fence is the half that answers (#1178/#1856).
echo "── 5. ⭐ a peer orch-loop.sh that began AFTER the lock was written: reclaim and run"
mkcase; CASE_DIR="$C"
PP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $PP"; sleep 0.2
printf '%s\n' "$PP" > "$C/o/.orch.lock"
touch -t 202001010000 "$C/o/.orch.lock" 2>/dev/null || touch -d '2020-01-01 00:00:00' "$C/o/.orch.lock"
run_drv O="$C/o"
ck "5: a shape-matching peer controller from BEFORE… does not block a start (the age half discriminates)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
kill -9 "$PP" 2>/dev/null

# ── 6) the same peer controller, lock written AFTER it started → REFUSE (positive control) ───────
# Without this arm, 5 could pass by reclaiming everything — which is #1715 in the other direction.
echo "── 6. the same live peer controller, lock written AFTER it started: refuse (positive control)"
mkcase; CASE_DIR="$C"
QP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $QP"; sleep 0.4
printf '%s\n' "$QP" > "$C/o/.orch.lock"
run_drv O="$C/o"
ck "6: refuses a genuine owner (the fence is not a blanket reclaim)" \
   "$(want "$OUT" "already running (pid $QP)" && echo 0 || echo 1)"
ck "6: the genuine owner's lock is untouched" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$QP" ] && echo 0 || echo 1 )"
kill -9 "$QP" 2>/dev/null

# ── 7) an UNDATABLE age on a loop-shaped owner → REFUSE, loudly, with the remedy ─────────────────
# "Cannot tell" must not become "provably stale". The shim answers the argv read for real and refuses
# `-o etime=`, like a ps without that format — the same PS_BIN seam the canonical copies carry.
echo "── 7. an UNDATABLE age: refuse loudly (fail closed), never reclaim on an unreadable read"
mkcase; CASE_DIR="$C"
cat > "$C/bin/ps-noetime" <<'PSSHIM'
#!/bin/bash
case "$*" in *etime*) exit 1 ;; esac
exec /bin/ps "$@"
PSSHIM
chmod +x "$C/bin/ps-noetime"
UP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $UP"; sleep 0.4
printf '%s\n' "$UP" > "$C/o/.orch.lock"
run_drv O="$C/o" PS_BIN="$C/bin/ps-noetime"
ck "7: refuses to start a second controller over an owner it cannot date" "$(ran && echo 1 || echo 0)"
ck "7: says CANNOT-TELL on stderr, naming the pid and the lock" \
   "$(want "$ERR" "CANNOT-TELL" && want "$ERR" "$UP" && want "$ERR" ".orch.lock" && echo 0 || echo 1)"
ck "7: names the remedy (a human-recoverable refusal, not a silent stop)" \
   "$(want "$ERR" "rm -f" && echo 0 || echo 1)"
ck "7: records it in the log too (a stderr-only line is invisible under launchd)" \
   "$(want "$(cat "$C/o/logs/orch-loop.log")" "CANNOT-TELL" && echo 0 || echo 1)"
ck "7: the undatable owner's lock is NOT removed (a refusal clobbers nothing)" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$UP" ] && echo 0 || echo 1 )"
kill -9 "$UP" 2>/dev/null

# ── 7b) an UNREADABLE PROCESS TABLE over a genuine loop-shaped owner → REFUSE (the P1 the fresh
# review of #1985 reproduced). The shape read is the OTHER half of the same doctrine: "cannot read"
# must never become "provably not the owner", because the caller answers that by DELETING the lock.
# This arm is the mirror of 7 for the table read; before it existed, a `ps` that refused the table
# turned a live owner into a reclaimed lock (MEASURED: OUT=STARTED, lock re-pointed at the newcomer).
echo "── 7b. an UNREADABLE process table over a live loop-shaped owner: refuse, never reclaim"
mkcase; CASE_DIR="$C"
cat > "$C/bin/ps-notable" <<'PSSHIM2'
#!/bin/bash
# Answers the AGE read, refuses the process TABLE — the shape read's failure mode.
case "$*" in *etime*) echo 00:42; exit 0 ;; esac
exit 1
PSSHIM2
chmod +x "$C/bin/ps-notable"
VP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $VP"; sleep 0.4
printf '%s\n' "$VP" > "$C/o/.orch.lock"
run_drv O="$C/o" PS_BIN="$C/bin/ps-notable"
ck "7b: an unreadable TABLE does not become a reclaimed lock (it refuses)" "$(ran && echo 1 || echo 0)"
ck "7b: the refusal says CANNOT-TELL and names the read that failed" \
   "$(want "$ERR" "CANNOT-TELL" && want "$ERR" "process table" && echo 0 || echo 1)"
ck "7b: the live owner's lock is UNTOUCHED (a failed read clobbers nothing)" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$VP" ] && echo 0 || echo 1 )"
kill -9 "$VP" 2>/dev/null

# ── 7c) PID 1 IS DECIDED BY THE SHAPE, NOT BY A NUMERIC SHORTCUT (fresh review of #1985, P2).
# A lock naming pid 1 is a normal answer in a container whose entrypoint IS the loop, so `1` may not be
# turned into "provably not the owner" by a comparison: that is a third reclaim reason the design does
# not sanction, and the caller answers rc 1 by DELETING the lock. Driven with a `ps` shim whose table
# row for pid 1 IS a loop invocation — the numeric shortcut reds this arm, the shape arm passes it.
echo "── 7c. pid 1 flows through the SHAPE arm (a numeric shortcut must not reclaim it)"
mkcase; CASE_DIR="$C"
cat > "$C/bin/ps-pid1" <<'PSSHIM3'
#!/bin/bash
case "$*" in
  *etime*) echo 10:00; exit 0 ;;
  *-axo*)  printf '      1 Ss   bash /tmp/x/orch-loop.sh\n'; exit 0 ;;
esac
exit 1
PSSHIM3
chmod +x "$C/bin/ps-pid1"
printf '1\n' > "$C/o/.orch.lock"
run_drv O="$C/o" PS_BIN="$C/bin/ps-pid1"
ck "7c: a lock naming a LOOP-SHAPED pid 1 is deferred to, not reclaimed on the number" \
   "$(want "$OUT" "already running (pid 1)" && echo 0 || echo 1)"
ck "7c: …and its lock is left in place" "$( [ "$(lock_pid "$C/o/.orch.lock")" = "1" ] && echo 0 || echo 1 )"

# ── 8) a lock carrying NO digits, and a lock naming pid 0 ────────────────────────────────────────
# `[ abc -gt 0 ]` is an ERRORED test, which is FALSE, which reclaimed — the #1831 class. pid 0 is the
# caller's own PROCESS GROUP (`kill -0 0` succeeds!), so it must never be treated as a live owner.
echo "── 8. a lock with no digits, and a lock naming pid 0: reclaim, run, no shell error"
mkcase; CASE_DIR="$C"
printf 'not-a-pid\n' > "$C/o/.orch.lock"
touch -t 202001010000 "$C/o/.orch.lock" 2>/dev/null || touch -d '2020-01-01 00:00:00' "$C/o/.orch.lock"
run_drv O="$C/o"
ck "8a: a lock with no digits is reclaimed and the loop runs" "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "8a: no 'integer expression expected' leaked (the read is sanitised before any test)" \
   "$(want "$ERR" "integer expression" && echo 1 || echo 0)"
mkcase; CASE_DIR="$C"
printf '0\n' > "$C/o/.orch.lock"
touch -t 202001010000 "$C/o/.orch.lock" 2>/dev/null || touch -d '2020-01-01 00:00:00' "$C/o/.orch.lock"
run_drv O="$C/o"
ck "8b: pid 0 is not an owner (kill -0 0 hits OUR process group) — the loop runs" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"

# ── recap ───────────────────────────────────────────────────────────────────────────────────────
echo
printf 'PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
