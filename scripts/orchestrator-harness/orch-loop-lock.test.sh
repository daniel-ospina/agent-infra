#!/usr/bin/env bash
# orch-loop-lock.test.sh — `orch-loop.sh`'s single-instance lock: the WIRING, and the outcomes it
# produces (agent-infra#1985, re-based on agent-infra#2095's module).
#
# ⛔ WHAT THIS SUITE IS FOR. A lock reclaimed on `kill -0 "$OPID"` alone lets a controller killed
# without its EXIT trap (kill -9, OOM, panic) wedge the box: the OS recycles its pid, the next start
# exits `already running (pid N)` over a process that is not a controller, and the box dispatches
# nothing. The OTHER direction is worse — reclaiming on a read the run could not make is how two
# autonomous controllers sweep one PR queue (#1715). So the rule under test is three-valued, and only
# POSITIVE evidence of non-ownership reclaims.
#
# ⛔ #2095 MOVED THE DECISION OUT OF THIS FILE, AND THIS SUITE DID NOT FOLLOW IT BY BEING DELETED.
# The verdict and the acquire/release primitives now live in `controller-state.sh`
# (`orc_singleton_acquire`, `orc_lock_write`, `orc_singleton_release`), the identity is **pid + the
# record's mtime** — a process that BEGAN after the record was written cannot own it — and the refusal
# is loud and non-zero (74 UNJUDGED / 75 HELD). What THIS file pins is the loop's half of that
# contract: the marked section, the trap, the exit codes, the logging, and the five outcomes driven
# from the SHIPPED section. The module's own semantics (§§1–7: state-dir selection, bare-pid format,
# live/dead/recycled/empty records, the pid-identity mirror, provenance) are driven by
# `controller-state.test.sh`, which extracts and runs the shipped module rather than a copy.
#
# ⛔ RETIRED ARMS, NAMED SO NOTHING VANISHES SILENTLY. #1985's identity rule was "the named pid must be
# ALIVE, an `orch-loop.sh` INVOCATION (argv shape, mirrored from
# `orchestrator-registry.sh:registry_pid_is_controller`), and not begun after the record was written".
# #2095 replaces the SHAPE half with the mtime fence, which is the stronger discriminator for the case
# shape cannot see (a PEER repo's controller on the same shared harness path, #2402) and needs no
# process-table read at all. The arms that pinned the retired half are therefore listed here with the
# pin that replaces them — not dropped:
#
#   OLD ARM (deleted with its subject)                        REPLACED BY
#   -------------------------------------------------------   --------------------------------------
#   argv-shape mirror == registry_pid_is_controller's tail     controller-state.test.sh §5 (the
#                                                             pid_began_after / pid_start_epoch mirror
#                                                             is byte-compared to pid-identity.sh)
#   `sleep` (wrong shape) is reclaimed                         this file, arm 4 (a RECYCLED pid is
#                                                             reclaimed on the age fence)
#   a shape-matching PEER that began AFTER the lock            this file, arm 4 — the fence, not the
#                                                             shape, is what discriminates
#   `bash -x …/orch-loop.sh` ⇒ CANNOT-TELL                     this file, arm 5 (an UNREADABLE age is
#                                                             UNJUDGED: refused, never reclaimed)
#   a ZOMBIE row answers "not the owner"                       no subject: nothing reads the process
#                                                             table by shape any more. §5's
#                                                             `ps -o etime=` read is the only one,
#                                                             and it is only ever read for AGE
#   `-o etime=` truncated by COLUMNS (#2926)                   arm 5: a blind `ps` (the seam §2926
#                                                             hardened) is still refused, so the
#                                                             unreadable-age direction stays pinned
#   a fault inside the verdict lands in CANNOT-TELL            `controller-state.sh`'s
#                                                             `orc_began_after` returns 2 on any
#                                                             unreadable/undatable answer and the
#                                                             caller fails closed; arm 5 drives it
#
# ⛔ THE SUBJECT IS THE REAL `orch-loop.sh`, NOT A RE-IMPLEMENTATION. The lock block lives in a marked
# section (`# [orchlock:begin] … # [orchlock:end]`), which this suite EXTRACTS with `sed` and runs as a
# script with `O`/`LOG` supplied — the same sourcing-excerpt contract `repo-target.test.sh` and
# `nochk-resolve.test.sh` already use for this file. Running the whole loop end-to-end is not an
# option (it dispatches), and a hand-copied predicate would pin the copy, not the subject.
#
# Hermetic: every case gets its own temp dir, its own `$O`/`$LOG`, and stub processes only. No network,
# no model, no fleet, no real state dir.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/orch-loop.sh"
MODULE="$HERE/controller-state.sh"
LIB_PID="$HERE/../lib/pid-identity.sh"
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

# ── 1) the subject exists, parses, and the marked section is extractable ───────────────────────────
[ -s "$SUBJECT" ]; ck "orch-loop.sh exists and is non-empty" $?
# A LITERAL script name after a `cd` (never `bash -n "$SUBJECT"`): the main-worktree-guard cannot
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
# The section names the lock file and asks the MODULE for the decision. Pinning the module's name is
# what makes a revert to an inline verdict redden here (the inline shape is #1985's, retired above).
has_all "$SECTION" 'LOCKF=' 'orc_singleton_acquire'
ck "the section defines the lock file and acquires it through controller-state.sh" $?
okc_not "the section carries NO inline ownership verdict of its own (that decision has one home)" \
  grep -q '^_orch_lock_verdict' "$SECTION"
[ "$(grep -c '^LOCKF=' "$SUBJECT")" = 1 ]
ck "LOCKF is defined ONCE in the whole loop (no split identity of the lock path)" $?
# The module is resolved in TWO homes before the section runs: a flat deploy and a state-dir split.
has_all "$SUBJECT" 'controller-state.sh' 'orc_state_pick'
ck "the loop sources controller-state.sh before the lock section (one home for the decision)" $?
# ⛔ THE rc=2 OPERATOR TEXT IS TWO SHAPES AND MUST STAY TWO (fresh-context review of #3846, cycle 3).
# rc 2 reaches this section two ways: an unreadable record that is still THERE (removing it IS the
# remedy once nothing holds it), and a record that could not be PUT BACK, where `$LOCKF` is absent or
# 0-byte and the displaced record sits at `ORC_RECLAIM_TEMP` — so `rm -f $LOCKF` is a no-op and the copy
# has to be moved BACK. Written as ONE sentence, the second shape sent the operator to that no-op while
# the only copy sat orphaned. Pinned STRUCTURALLY because the second shape needs a hostile state dir to
# reach; a revert to the single echo reddens here.
has_all "$SECTION" 'ORC_RECLAIM_TEMP' 'KEPT at'
ck "the rc=2 refusal has a branch for the KEPT-copy shape (not one sentence for both)" $?
has_all "$SECTION" "mv '\$ORC_RECLAIM_TEMP'"
ck "…and it tells the operator to move the kept copy BACK, not to delete a record that is already gone" $?
has_all "$SECTION" 'could not be judged'
ck "…while the unreadable-record shape keeps its own wording and its own rm -f remedy" $?

# ── 2) STRUCTURAL: the block is ABOVE the EXIT trap, and the trap is the ONLY releaser ────────────
# ⛔ THE ARM MUST RED ON THE EXACT #1715 REVERT. The historical regression is
# `trap 'rm -f "$LOCKF"' EXIT INT TERM` — a returning INT/TERM handler does not terminate bash, so the
# lock was deleted while the controller kept sweeping. This pins the WHOLE SET: one trap line may
# mention $LOCKF at all, and it must be EXIT-only.
LOCK_TRAPS="$(grep -E '^trap .*LOCKF' "$SUBJECT" 2>/dev/null)"
[ "$(printf '%s\n' "$LOCK_TRAPS" | grep -c 'LOCKF')" = 1 ]
ck "exactly ONE trap line mentions \$LOCKF" $?
want "$LOCK_TRAPS" 'EXIT'
ck "the lock's releaser is an EXIT trap (a handler that RETURNS does not terminate the shell — #1715)" $?
okc_not "…and no INT/TERM handler releases it" grep -qE '^trap .*LOCKF.*(INT|TERM)' "$SUBJECT"
TRAP_L="$(grep -nF "$LOCK_TRAPS" "$SUBJECT" | head -1 | cut -d: -f1)"
[ -n "$TRAP_L" ] && [ "$TRAP_L" -gt "$END_L" ]
ck "the EXIT trap that releases the lock sits BELOW the section (the block runs first)" $?
# …and the release is OWNERSHIP-SCOPED (#2095): the trap calls the module's release, not `rm -f`. An
# exiting instance must never delete a NEW holder's record after a reclaim race.
want "$LOCK_TRAPS" 'orc_singleton_release'
ck "the trap releases through orc_singleton_release (never a bare rm -f — an exiting instance must not delete a new holder's record)" $?

# ── 3) THE ACQUIRE PRIMITIVE IS ATOMIC, AND IT LIVES IN THE MODULE ───────────────────────────────
A_BODY="$(sed -n '/^orc_lock_write()/,/^}/p' "$MODULE" 2>/dev/null)"
want "$A_BODY" 'set -o noclobber'
ck "the acquire is an atomic noclobber create (orc_lock_write, in controller-state.sh)" $?
# …and the record's FORMAT is unchanged: six shipped tools parse it with `tr -dc '0-9'`.
want "$A_BODY" '$$'
ck "the record is this process's own pid (the bare-pid format six shipped readers parse)" $?

# ── 4) THE REFUSAL IS NON-ZERO, LOUD, AND CARRIES ITS CODE ───────────────────────────────────────
want "$(cat "$SECTION")" 'exit 75'
ck "a HELD refusal exits 75 (not 0 — a silent zero reads as a healthy no-op under KeepAlive)" $?
want "$(cat "$SECTION")" 'exit 74'
ck "an UNJUDGED refusal exits 74 (opposite remedy from HELD: investigate the record, do not leave it)" $?
want "$(cat "$SECTION")" '[singleton]'
ck "the refusal is named '[singleton]' on every surface" $?
want "$(cat "$SECTION")" 'rc=$ORC_SINGLETON_RC'
ck "the refusal line carries rc=, so the wrapper and harness-up can tell 74 from 75" $?
want "$(cat "$SECTION")" '>&2'
ck "the refusal reaches stderr (launchd and a human both read it)" $?
want "$(cat "$SECTION")" '>> "$LOG"'
ck "the refusal is also ON RECORD in the log" $?
want "$(cat "$SECTION")" 'reclaimed'
ck "a RECLAIM is logged, never silent (the other half of the #1715 class)" $?

# ── the fixture ──────────────────────────────────────────────────────────────────────────────────
# mkcase — a fresh `$O`, an empty log, and a driver that sources the module, runs the EXTRACTED section
# and then prints its own pid, which is what proves the section ran PAST the lock instead of exiting.
CASE_N=0
mkcase() {
  CASE_N=$((CASE_N+1))
  C="$TMP/c$CASE_N"
  mkdir -p "$C/o/logs" "$C/bin"
  : > "$C/o/logs/orch-loop.log"
  {
    printf 'set -u\n'
    printf 'O="%s/o"\n' "$C"
    printf 'LOG="%s/o/logs/orch-loop.log"\n' "$C"
    printf 'ORC_INSTANCE=locktest-%s\n' "$$"
    printf 'ORC_STATE_SRC=locktest\nMAX_LOAD=100\nMAX_LOAD_SRC=locktest\n'
    printf '. "%s"\n' "$MODULE"
    cat "$SECTION"
    printf 'echo "STARTED pid=$$"\n'
  } > "$C/drv.sh"
  CASE_DIR="$C"
}
# spawn_loop <dir> — a process whose argv IS an `orch-loop.sh` invocation. Still the realistic shape a
# controller has; what it is used for now is AGE, not shape.
# ⛔ THE CALLER APPENDS TO KIDS, THE HELPER DOES NOT (fresh review of #1985, P2 — MEASURED: every call
# site is `X="$(spawn_loop …)"`, a SUBSHELL, so `KIDS="$KIDS $_pid"` inside it never reached the parent
# and `cleanup()` killed NOTHING). The stub is SELF-BOUNDED (60 s) for the same reason `selftest.sh`
# §20 bounds its own: an orphan named `orch-loop.sh` reads as a live owner to every later arm.
spawn_loop() {
  printf '#!/bin/bash\ntrap "exit 0" TERM INT\nfor _ in $(seq 1 60); do sleep 1; done\n' > "$1/orch-loop.sh"
  chmod +x "$1/orch-loop.sh"
  bash "$1/orch-loop.sh" >/dev/null 2>&1 &
  printf '%s\n' "$!"
}
spawn_sleep() {
  sleep 300 >/dev/null 2>&1 &
  printf '%s\n' "$!"
}
run_drv() { # [env...] -> sets RC, OUT, ERR
  RC=0
  OUT="$(env "$@" bash "$CASE_DIR/drv.sh" 2>"$CASE_DIR/err.txt")" || RC=$?
  ERR="$(cat "$CASE_DIR/err.txt" 2>/dev/null)"
}
ran() { want "$OUT" "STARTED pid="; }
lock_pid() { tr -dc '0-9' 2>/dev/null < "$1"; }
backdate() { touch -t "$(date -v-5M +%Y%m%d%H%M.%S 2>/dev/null || date -d '-5 minutes' +%Y%m%d%H%M.%S)" "$1" 2>/dev/null; }

UNREG="$(grep -nE '\$\(spawn_(loop|sleep)' "$HERE/orch-loop-lock.test.sh" | grep -v 'KIDS="\$KIDS' | grep -v '^[0-9]*: *#' | wc -l | tr -d ' ')"
[ "$UNREG" = "0" ]
ck "every spawn call site registers its pid in the PARENT shell ($UNREG unregistered)" $?

# ── 4a) NO LOCK → acquire and run ─────────────────────────────────────────────────────────────────
echo "── 4a. no lock: the controller acquires it and runs"
mkcase
run_drv O="$C/o"
ck "4a: runs (the section does not exit when the lock is free)" "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
OWN="$(printf '%s\n' "$OUT" | sed -n 's/.*STARTED pid=\([0-9]*\).*/\1/p')"
[ -f "$C/o/.orch.lock" ] && [ "$(lock_pid "$C/o/.orch.lock")" = "$OWN" ] && [ -n "$OWN" ]
ck "4a: the lock names the process that acquired it ($OWN)" $?
okc_not "4a: a clean acquire writes no [singleton] refusal line" \
  grep -q '\[singleton\]' "$C/o/logs/orch-loop.log"

# ── 4b) A LIVE OWNER (real order) → REFUSE, name it, do not clobber ───────────────────────────────
echo "── 4b. a live owner (the record is written AFTER it started): refuse"
mkcase
HP="$(spawn_loop "$C")"; KIDS="$KIDS $HP"
sleep 0.4                                   # the record is written AFTER the owner exists (real order)
printf '%s\n' "$HP" > "$C/o/.orch.lock"
run_drv O="$C/o"
ck "4b: refuses (does not run a second controller over a live owner)" "$(ran && echo 1 || echo 0)"
[ "$RC" = "75" ]
ck "4b: the refusal exits 75 (rc=$RC)" $?
want "$ERR" "[singleton] rc=1"
ck "4b: the refusal carries rc=1 (HELD) on stderr" $?
want "$ERR" "$HP"
ck "4b: the refusal NAMES the holder pid ($HP)" $?
[ "$(lock_pid "$C/o/.orch.lock")" = "$HP" ]
ck "4b: the lock still names the owner (a refusal clobbers nothing)" $?
kill -9 "$HP" 2>/dev/null

# ── 4c) A DEAD OWNER → reclaim, log it, run ──────────────────────────────────────────────────────
echo "── 4c. a DEAD owner (SIGKILL/OOM/reboot): reclaim and run"
mkcase
printf '999999\n' > "$C/o/.orch.lock"
run_drv O="$C/o"
ck "4c: runs after reclaiming a lock whose pid is gone" "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
want "$(cat "$C/o/logs/orch-loop.log" 2>/dev/null)" "DEAD"
ck "4c: the reclaim is LOGGED and names what it displaced (never silent)" $?
[ "$(lock_pid "$C/o/.orch.lock")" = "$(printf '%s\n' "$OUT" | sed -n 's/.*STARTED pid=\([0-9]*\).*/\1/p')" ]
ck "4c: the stale record is replaced by the newcomer's own pid" $?

# ── 4d) ⭐ A RECYCLED pid → reclaim on the AGE FENCE, not on shape ───────────────────────────────
echo "── 4d. a RECYCLED pid (alive, but it began AFTER the record was written): reclaim and run"
mkcase
SP="$(spawn_sleep)"; KIDS="$KIDS $SP"
printf '%s\n' "$SP" > "$C/o/.orch.lock"
backdate "$C/o/.orch.lock"
run_drv O="$C/o"
ck "4d: a live pid that cannot own the record does not stop the box (it starts and runs)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
want "$(cat "$C/o/logs/orch-loop.log" 2>/dev/null)" "RECYCLED"
ck "4d: the reclaim says WHY (a recycled pid, not a dead one)" $?
[ "$(lock_pid "$C/o/.orch.lock")" = "$(printf '%s\n' "$OUT" | sed -n 's/.*STARTED pid=\([0-9]*\).*/\1/p')" ]
ck "4d: the record now names the newcomer" $?
kill -0 "$SP" 2>/dev/null
ck "4d: the displaced process was NOT signalled (reclaim moves a RECORD, never a process)" $?
kill -9 "$SP" 2>/dev/null

# ── 4e) ⭐ AN UNDATABLE age → UNJUDGED: refuse, name the remedy, clobber nothing ─────────────────
echo "── 4e. an owner whose AGE CANNOT BE READ: refuse (74), loudly, and touch nothing"
mkcase
printf '#!/bin/sh\nexit 1\n' > "$C/bin/ps"; chmod +x "$C/bin/ps"
HP2="$(spawn_loop "$C")"; KIDS="$KIDS $HP2"
sleep 0.4
printf '%s\n' "$HP2" > "$C/o/.orch.lock"
run_drv O="$C/o" PS_BIN="$C/bin/ps"
ck "4e: refuses to start a second controller over an owner it cannot date" "$(ran && echo 1 || echo 0)"
[ "$RC" = "74" ]
ck "4e: the refusal exits 74 (UNJUDGED — the opposite remedy from HELD; rc=$RC)" $?
want "$ERR" "[singleton] rc=2"
ck "4e: the refusal carries rc=2 and names the state that could not be judged" $?
want "$ERR" "rm -f"
ck "4e: it names the remedy a human can act on (removing the record IS the fix when nothing holds it)" $?
want "$(cat "$C/o/logs/orch-loop.log" 2>/dev/null)" "[singleton] rc=2"
ck "4e: it is on record in the log as well (a stderr-only line is invisible under launchd)" $?
[ "$(lock_pid "$C/o/.orch.lock")" = "$HP2" ]
ck "4e: the undatable owner's record is NOT removed (a refusal clobbers nothing)" $?
kill -9 "$HP2" 2>/dev/null

# ── 4f) the OLD liveness-only test must not survive ───────────────────────────────────────────────
echo "── 4f. the retired liveness-only reclaim is GONE"
# ⛔ THE SECTION'S OWN PROSE NAMES THE RETIRED SHAPES (that is how a reader learns what it replaced),
# so these two arms read CODE LINES ONLY. Pinning the sentence instead of the code would make the
# explanation itself the defect, and delete the evidence with it.
CODE_ONLY="$(mktemp)"
grep -vE '^[[:space:]]*#' "$SECTION" > "$CODE_ONLY"
okc_not "4f: no kill -0-only holder test remains in the section" \
  grep -qE 'kill -0 "\$OPID"|OPID=' "$CODE_ONLY"
okc_not "4f: the loop no longer prints 'already running' and exits 0" \
  grep -q 'already running' "$CODE_ONLY"
rm -f "$CODE_ONLY"

# ── 5) DRIFT PIN: the age fence is the fleet's ONE rule, not a remembered copy ───────────────────
echo "── 5. the age mirror has not drifted from scripts/lib/pid-identity.sh (#1178)"
if [ -f "$LIB_PID" ]; then
  # Same normalisation `controller-state.test.sh` §5 uses: only the NAME line changes, comments go.
  norm5() { sed -n "/^$2()/,/^}/p" "$1" | sed "1s/^$2()/FN()/" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'; }
  norm5 "$LIB_PID" pid_start_epoch > "$TMP/lib5.body"
  norm5 "$MODULE" _orc_proc_start_epoch > "$TMP/mod5.body"
  [ -s "$TMP/lib5.body" ] && [ -s "$TMP/mod5.body" ] && diff -q "$TMP/lib5.body" "$TMP/mod5.body" >/dev/null 2>&1
  ck "5: the shipped age mirror is byte-identical to pid-identity.sh:pid_start_epoch" $?
else
  skip "5: $LIB_PID is absent (a flat deploy) — the drift pin cannot run here"
fi
want "$(sed -n '/^orc_began_after()/,/^}/p' "$MODULE")" 'ORC_LOCK_START_SLACK_SECONDS:-5'
ck "5: the age fence uses the fleet's ONE slack value (5s, override named)" $?

# ── verdict ──────────────────────────────────────────────────────────────────────────────────────
echo
if [ "$FAIL" -eq 0 ]; then
  echo "==> ALL PASS ($PASS assertions, $SKIP skipped)"
  exit 0
fi
echo "==> $FAIL FAILURE(S); $PASS passed, $SKIP skipped"
exit 1
