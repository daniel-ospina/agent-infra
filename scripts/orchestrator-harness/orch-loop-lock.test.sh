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
#   9. structural + DRIFT pins: the block sits above the EXIT trap, that trap's signal list is
#      EXACTLY `EXIT` and it is the only releaser (`acq` keeps `noclobber`), the old liveness-only line
#      is GONE, and both mirror bodies plus the slack are IDENTICAL to the canonical declarations they
#      were copied from (#1178/#1856).
#  10. an exported `COLUMNS` cannot change any answer above (#2926): a width-truncated process read
#      would turn a LIVE loop-shaped owner into "provably NOT the owner" and DELETE its lock, so §11
#      re-drives the refusal arms with `COLUMNS=20` — the witness #2926 requires of every `-ww` fix.
#  12. ⭐ THE PROBE'S THREE UNKNOWN CLOSURES ARE ASSERTED, not merely written (fresh review of #1985,
#      P2): a table that OMITS a signallable pid, an EMPTY table, and a row whose argv column is
#      unreadable must each answer CANNOT-TELL and leave the lock alone. MEASURED on the pre-fix
#      suite: deleting any of the three left `PASS=54 FAIL=0` — the two that close a FAIL-OPEN were
#      invisible to CI, which is the mutant leg being ABSENT rather than the arm being wrong (#3442).
#  13. a ZOMBIE row answers "not the owner" even when its command column still carries the original
#      argv (fresh review of #1985, P2): `kill -0` SUCCEEDS on a zombie, so without this arm a lock
#      whose owner was killed-but-unreaped stops the box forever — the symptom #1985 opened with. On
#      Linux `ps` blank-argvs a zombie (`[bash] <defunct>`), so the SHAPE arm already answers there
#      and this branch is load-bearing on the launchd host; §13 stages the shape with a `PS_BIN`
#      shim, the same idiom §7/7b/7c use, so the arm can actually go red.
#  14. the env slack seam is VALIDATED before arithmetic, and — because a guard whose only witness is a
#      refusal cannot tell "fell back to 5" from "normalised to 8" — §14v observes the RESULTING value
#      for every shape (fresh review of #1985, P3: `08` is stripped to `8`, it does NOT fall back to 5).
#  15. ⭐ A FAULT INSIDE THE VERDICT DOES NOT SKIP THE LOCK DECISION (fresh review of #1985, P3): the
#      verdict is called in a subshell and transports its answer through stdout, so a fault it cannot
#      contain lands in CANNOT-TELL instead of aborting the whole `if ! acq` compound — which is what
#      made the newcomer run with NO lock while the live owner's lock stayed on disk.
#  16. ⭐ AN ARGV WE READ BUT COULD NOT ATTRIBUTE IS CANNOT-TELL (fresh review of PR #3837 at 185e7c5bd,
#      P2): a controller started with a shell OPTION (`bash -x …/orch-loop.sh`) is neither the canonical
#      shape nor provably a non-controller, so it must refuse rather than be reclaimed out from under a
#      live owner. BOTH option polarities count (§16c: `bash +o errexit …`), and `-c` wrappers stay
#      RECLAIMED — #1856 decided they are not controllers (4c, §17, and §17b for the `+c` spelling).
#  17. ⭐ THE TRAP PIN IS AN INVARIANT, NOT A SPELLING, AND IT CANNOT BE ANSWERED BY A COMMENT (§9b):
#      one `^trap` line mentioning the lock, its signal list EXACTLY `EXIT` (matched per WHOLE token, so
#      `SIGEXIT` — which bash REJECTS, installing no trap — reds instead of reading as `EXIT`), and it
#      removes `$LOCKF` on COMMENT-STRIPPED text (so a trailing comment naming the command cannot answer
#      it). Stated false RED: a trailing suffix after the signals. (`SIGEXIT` is NOT in that list and is
#      not a false RED at all — bash REJECTS it and installs no trap, so it must red; a DOUBLE-QUOTED
#      trap including the removal PASSES, which is what §9c row 7 pins. Only the UNQUOTED-variable
#      spelling `rm -f $LOCKF` reds the removal clause, and the subject does not use it.)
#      AND THE RELEASING TRAP MUST BE THE ONLY `EXIT` TRAP: a later `trap … EXIT` REPLACES it, so the
#      lock would never be removed while both traps are spelled correctly.
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
# ⛔ ONLY A REAL `^trap` LINE COUNTS (MEASURED: the previous form used `grep -nF` over the whole file,
# so the COMMENT that documents the #1715 regression — `# Was trap 'rm -f "$LOCKF"' EXIT INT TERM` —
# satisfied it. That is a false PASS on a structural pin, and it is why this arm stayed GREEN when
# main's #3843 extended the trap. Anchored at `^trap`, no comment can answer it.)
TRAP_L="$(grep -nE '^trap .*LOCKF' "$SUBJECT" 2>/dev/null | head -1 | cut -d: -f1)"
[ -n "$TRAP_L" ] && [ "$TRAP_L" -gt "$END_L" ]
ck "the EXIT trap that releases the lock sits BELOW the section (the block runs first)" $?
# ⛔ THE ARM MUST RED ON THE EXACT #1715 REVERT, AND THE FIRST FORM DID NOT (fresh review of #1985,
# P2 — MEASURED: restoring `trap 'rm -f "$LOCKF"' EXIT INT TERM` byte for byte left every arm green,
# because the regex anchored the signal names at the START of the trap while the historical regression
# has them AFTER `EXIT`). So this pins the WHOLE SET: one trap line may mention $LOCKF at all, and it
# is the EXIT-only form.
# ⛔ BUT IT PINS THE INVARIANT, NOT A BYTE-EXACT STRING (MEASURED against main's #3843/#2028, which
# EXTENDED the trap to also run `gh_bound_cleanup`): that extension is legitimate — the lock is still
# released FIRST, and still only on EXIT — while a literal `-qxF` match REDS on it.
#
# trap_pin <the trap text> — 0 when the invariant holds for THAT TEXT. Factored out so §9c can drive the
# pin itself over the spellings that have already defeated it once (a pin nobody tests is how this one
# shipped a false PASS twice).
#   * ONE line may mention $LOCKF,
#   * its signal list is EXACTLY `EXIT`, matched per WHOLE TOKEN,
#   * it removes $LOCKF, checked on COMMENT-STRIPPED text.
# ⛔ WHOLE TOKEN, NOT A SUFFIX (fresh review of #3865 at f8604c74c, P2 — false PASS, MEASURED: a regex
# without a left boundary read `trap 'rm -f "$LOCKF"' SIGEXIT` as `TRAP_SIGS=EXIT` and left the suite
# GREEN, while bash REJECTS `SIGEXIT` (`trap: SIGEXIT: invalid signal specification`) and installs NO
# trap — so the lock is never released, the very invariant this arm asserts).
# ⛔ COMMENT-STRIPPED `rm` CHECK (same review, P3 — false PASS, MEASURED: grepping the RAW line let
# `trap 'true' EXIT  # … rm -f "$LOCKF" there` satisfy it while the trap removes nothing. `^trap`
# anchoring stops a WHOLE-LINE comment, not a trailing one).
# ⚠️ STATED false RED, so it is not found as a bug: a trap line carrying a TRAILING SUFFIX after the
# signals (`trap "rm -f '$tmp'" EXIT 2>/dev/null || true`, the form `scripts/record-review.sh:3753`
# writes) yields no trailing signal run → empty → RED. Fail-closed: a false RED with the #1715
# diagnosis, never a false GREEN. The subject's own trap is single-quoted with no suffix.
# ⛔ AND THE REMOVAL IS MATCHED ON A BACKSLASH-NORMALISED COPY, so a DOUBLE-QUOTED trap (which spells it
# `rm -f \"\$LOCKF\"`) PASSES instead of reding — that was the second half of the quoting blind spot.
trap_pin() {
  local _lt="$1" _cmd _flat _sigs
  _cmd="$(printf '%s' "$_lt" | sed -e 's/[[:space:]]*#.*$//')"
  _flat="$(printf '%s' "$_cmd" | sed -e 's/\\//g')"
  _sigs="$(printf '%s\n' "$_cmd" | awk '
    BEGIN { n = split("EXIT INT TERM HUP QUIT ERR DEBUG RETURN 0", sig, " "); for (i = 1; i <= n; i++) ok[sig[i]] = 1 }
    { out = ""; for (i = NF; i >= 1; i--) { if (!($i in ok)) break; out = $i (out == "" ? "" : " " out) } ; print out }
  ')"
  [ "$(grep -c . <<<"$_lt")" = 1 ] && [ "$_sigs" = "EXIT" ] && grep -qF 'rm -f "$LOCKF"' <<<"$_flat"
}
LOCK_TRAPS="$(grep -E '^trap .*LOCKF' "$SUBJECT" 2>/dev/null)"
trap_pin "$LOCK_TRAPS"
ck "the lock is released by ONE trap and its signal list is EXACTLY 'EXIT' (a returning INT/TERM handler deleted it while the loop lived — #1715)" $?
# ⛔ AND IT MUST BE THE ONLY `EXIT` TRAP, BECAUSE A LATER ONE REPLACES IT (fresh review of #3865 at
# 8c3346680, P2 — false PASS, MEASURED: appending `trap 'true' EXIT` after the releaser left the suite
# at `PASS=118 FAIL=0`, while bash REPLACES the handler — `bash -c 'trap "echo FIRST" EXIT; trap
# "echo SECOND" EXIT'` prints only `SECOND` — so the lock is never removed. The pin above counts only
# traps that MENTION `$LOCKF`, which is exactly the shape a lane adding a second trap line does not
# touch, and this PR's own prose invites extending the EXIT trap.)
EXIT_TRAPS="$(grep -E '^trap .* EXIT' "$SUBJECT" 2>/dev/null)"
[ "$(grep -c . <<<"$EXIT_TRAPS")" = 1 ]
ck "the releasing trap is the ONLY 'EXIT' trap (a second 'trap ... EXIT' REPLACES the first, so the lock is never removed)" $?
# ── 9c) THE PIN ITSELF, DRIVEN OVER THE SPELLINGS THAT DEFEATED IT ────────────────────────────────
# A pin that is never driven against its own near-misses is how this arm shipped a false PASS twice
# (2026-11-09: the comment-match, then the `SIGEXIT` and trailing-comment ones). Each row is a
# hand-written trap text with the verdict the INVARIANT requires; the last two are the false PASSes the
# fresh review of f8604c74c measured on the shipped arms.
echo "── 9c. the trap pin's own verdicts (invariant, not spelling)"
_traprow() { # <expected:0|1> <trap text> <label>
  local _want="$1" _txt="$2" _got=1
  trap_pin "$_txt" && _got=0
  [ "$_got" = "$_want" ]
  ck "9c: $3" $?   # ⛔ `$3`, NOT `$_3`: `_3` is no variable at all, so `set -u` aborted the whole suite here
}
_traprow 0 "trap 'rm -f \"\$LOCKF\"' EXIT" \
  "the shipped form PASSES (one EXIT-only releaser)"
_traprow 0 "trap 'rm -f \"\$LOCKF\"; command -v x >/dev/null 2>&1 && x' EXIT" \
  "an EXIT trap extended with more cleanup PASSES (the invariant, not a byte match)"
_traprow 1 "trap 'rm -f \"\$LOCKF\"' EXIT INT TERM" \
  "the #1715 revert REDS (a returning INT/TERM handler)"
_traprow 1 "trap 'rm -f \"\$LOCKF\"' SIGEXIT" \
  "a SUFFIX signal name REDS (bash REJECTS SIGEXIT and installs no trap — it must not read as EXIT)"
_traprow 1 "trap 'true' EXIT  # the release now lives in cleanup(): rm -f \"\$LOCKF\" there" \
  "a trailing COMMENT naming the command REDS (a comment cannot answer a structural pin)"
_traprow 1 "trap 'rm -f \"\$LOCKF\"' EXIT
trap 'rm -f \"\$LOCKF\"' EXIT" \
  "TWO trap lines RED (one releaser)"
_traprow 0 'trap "rm -f \"$LOCKF\"; x" EXIT' \
  "a DOUBLE-QUOTED trap PASSES (both halves of the quoting blind spot: signals AND the removal)"
# (the quoting-agnostic extraction and its stated limits live in `trap_pin` above — this arm and §9c
# both drive it, so the pin has exactly one implementation and it is itself under test.)
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
  # ⛔ THE TOKEN-RULES TAIL IS THE PINNED PART, NOT THE WHOLE BODY (fresh review of #1985, P1). The READ
  # arms deliberately differ: in a REPORTING consumer a false "not the owner" degrades a row to
  # STOPPED, while HERE the caller answers it by DELETING a live owner's lock (#1715), so the loop's
  # read is three-valued (`_orch_lock_probe`) and the canonical one is not. What must never drift are
  # the two argv TOKEN rules (#1856: a looser ANY-token match accepts a non-controller).
  # ⛔ AN INCLUDE-FILTERED EXCERPT IS NOT A PIN (fresh review of #1985, round 3, MEASURED): filtering to
  # lines carrying `##*/` or `-ge 2` compared only what the filter kept, so RE-ADDING the #1856 loose arm
  # (`case "$*" in *orch-loop.sh*) return 0 ;; esac`) to the mirror left the pin GREEN. The compared
  # span is therefore everything from the `set --` line to the closing brace — unfiltered, so an added
  # line reds it — with the one deliberate difference (the canonical reads its argv from `$c`, the
  # mirror from its parameters) normalised away.
  tail_from_set() { awk '/set -- /{p=1} p{print}' | sed -e 's/set -- \$\*/set -- ARGV/' -e 's/set -- \$c/set -- ARGV/' -e 's/[[:space:]]\+$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d'; }
  A_LOOP="$(extract_fn "$SUBJECT" _orch_argv_is_loop | tail_from_set)"
  B_LOOP="$(extract_fn "$LIB_REG" registry_pid_is_controller | tail_from_set)"
  [ -n "$A_LOOP" ] && [ "$A_LOOP" = "$B_LOOP" ]
  ck "the argv-shape mirror's TOKEN-RULES TAIL is identical to orchestrator-registry.sh:registry_pid_is_controller" $?
  # ⛔ AND NOTHING MAY SIT ABOVE THE RULES. The tail comparison starts at `set --`, so a line inserted
  # BEFORE it (the #1856 loose arm the predecessor pin missed) is outside the compared span — MEASURED:
  # re-adding `case "$*" in *orch-loop.sh*) return 0 ;; esac` above `set --` left the tail pin green
  # (only driving arm 4c caught it). So the body is pinned by SHAPE as well: exactly the five rule lines.
  A_BODY_N="$(extract_fn "$SUBJECT" _orch_argv_is_loop | sed -e '1d' -e '$d' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  [ "$A_BODY_N" = "5" ]
  ck "the argv-shape mirror is EXACTLY the five rule lines — nothing can hide above the rules (found ${A_BODY_N})" $?
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
mkcase() { # [section-file] — defaults to the pinned extraction from orch-loop.sh
  CASE_N=$((CASE_N+1))
  C="$TMP/c$CASE_N"
  mkdir -p "$C/o/logs" "$C/peer" "$C/bin"
  : > "$C/o/logs/orch-loop.log"
  {
    printf 'set -u\n'
    printf 'O="%s/o"\n' "$C"
    printf 'LOG="%s/o/logs/orch-loop.log"\n' "$C"
    cat "${1:-$SECTION}"
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
  # ⛔ THE STUB IS SELF-BOUNDED (60 s), because it is a process literally named `orch-loop.sh` in a
  # layout this repo's arms read by that shape: if this suite is KILLED between the spawn and its own
  # `kill -9`, an unbounded stub outlives it as an orphan (`ppid 1`) and a LATER arm — in this suite or
  # a sibling's — reads it as a live owner (fresh review of PR #3837 at 185e7c5bd, P3; MEASURED, and
  # two such orphans were already alive on this host from exactly this suite's layouts). `selftest.sh`
  # §20 bounds its own stub for the same reason. 60 s is far longer than the 0.4 s any arm needs.
  printf '#!/bin/bash\ntrap "exit 0" TERM INT\nfor _ in $(seq 1 60); do sleep 1; done\n' > "$1/orch-loop.sh"
  chmod +x "$1/orch-loop.sh"
  bash "$1/orch-loop.sh" >/dev/null 2>&1 &
  printf '%s\n' "$!"
}
spawn_loop_flagged() { # <dir> [shell-option…] — default `-x`; prints the pid
  # The SAME stub, launched through a shell OPTION (`bash -x`, `bash +o errexit`, …), so
  # `_orch_argv_is_loop`'s two-token rule cannot attribute it. This is the shape §16 turns on: a
  # controller we could not PARSE, which is neither an owner we can confirm nor a non-controller we
  # have proved.
  local _d="$1"; shift
  [ "$#" -gt 0 ] || set -- -x
  printf '#!/bin/bash\ntrap "exit 0" TERM INT\nfor _ in $(seq 1 60); do sleep 1; done\n' > "$_d/orch-loop.sh"
  chmod +x "$_d/orch-loop.sh"
  bash "$@" "$_d/orch-loop.sh" >/dev/null 2>&1 &
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
# ⛔ THE `#1831` ARM NEEDS A MUTATED SUBJECT, OR IT CANNOT FAIL (fresh review of #1985, P3;
# mutation-contract rule 3). The non-digit read is guarded TWICE — the caller's `tr -dc '0-9'` and
# `_orch_lock_verdict`'s own `case "$p" in ''|*[!0-9]*` — so replacing the caller's sanitisation with a
# plain `cat` leaves every row green: the verdict guard returns before any numeric test. MEASURED
# (`PASS=46 FAIL=0` for that exact mutant). The row therefore pins the PAIR, and does it by removing the
# verdict's half in the fixture, which is the only way the caller's half becomes individually
# attributable: with the guard gone, a `not-a-pid` lock reaches `[ "$p" -gt 0 ]`, and only the `tr -dc`
# keeps "integer expression expected" off stderr.
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

# ── 4c) an argv that MENTIONS the script is NOT an invocation (#1856) ────────────────────────────
# `bash -c "sleep 300; /abs/orch-loop.sh"` is a non-controller that LOOKS like one to any-token matching.
# The drift pin above catches the loose arm statically; this arm catches it BEHAVIOURALLY, which is what a
# mutation reader trusts. A fresh lock, so only the shape can decide.
echo "── 4c. an argv that merely MENTIONS orch-loop.sh is not an owner (#1856)"
mkcase; CASE_DIR="$C"
# ⛔ THE SLEEP IS BOUNDED AND THE CHILDREN ARE REAPED WITH THE WRAPPER (fresh review at 8eb852d27, P3).
# `kill -9 $MP` kills the `bash -c` WRAPPER only, so an unbounded `sleep 300` inside the command string
# is reparented and outlives the suite by minutes — the same fixture-leak class `spawn_loop` now bounds
# itself for. The bounded form keeps the single-token argv this arm depends on.
bash -c "for _ in \$(seq 1 60); do sleep 1; done; $C/peer/orch-loop.sh" >/dev/null 2>&1 &
MP=$!; KIDS="$KIDS $MP"; sleep 0.4
printf '%s\n' "$MP" > "$C/o/.orch.lock"
run_drv O="$C/o"
ck "4c: a process that only MENTIONS the script does not own the lock (it starts and runs)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
pkill -P "$MP" 2>/dev/null
kill -9 "$MP" 2>/dev/null

# ── 5) ⭐ a PEER controller that began AFTER the lock → reclaim (shape cannot discriminate) ──────
# On this fleet the recycled target is a PEER repo's controller: same basename, same shared harness
# path, so the argv shape matches PERFECTLY. The age fence is the half that answers (#1178/#1856).
echo "── 5. ⭐ a peer orch-loop.sh that began AFTER the lock was written: reclaim and run"
mkcase; CASE_DIR="$C"
PP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $PP"; sleep 0.2
printf '%s\n' "$PP" > "$C/o/.orch.lock"
touch -t 202001010000 "$C/o/.orch.lock" 2>/dev/null || touch -d '2020-01-01 00:00:00' "$C/o/.orch.lock"
run_drv O="$C/o"
ck "5: a shape-matching peer controller that began AFTER the lock does not block a start (the age half discriminates)" \
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
ck "8a: no 'integer expression expected' leaked on the SHIPPED block (defensive; the verdict guard answers first — 8a-noguard is the attributable half)" \
   "$(want "$ERR" "integer expression" && echo 1 || echo 0)"
# ⛔ THE ATTRIBUTABLE HALF (fresh review of #1985, P3). Same lock, with `_orch_lock_verdict`'s own
# non-digit guard STRIPPED from the extracted section — the edit a future reader makes when they
# therefore conclude the caller does not need to sanitise. Red on the named mutant
# (OPID="$(tr -dc '0-9' …)"` -> `OPID="$(cat "$LOCKF" …)"`); green on the shipped code.
mkcase; CASE_DIR="$C"
SECTION_NOGUARD="$C/section-noguard.sh"
# Every non-digit guard in the section (three call sites carry the identical line), removed at once.
grep -vF "''|*[!0-9]*) return 1 ;;" "$SECTION" > "$SECTION_NOGUARD"
GUARDS_REMOVED=$(( $(grep -cF "''|*[!0-9]*) return 1 ;;" "$SECTION") - $(grep -cF "''|*[!0-9]*) return 1 ;;" "$SECTION_NOGUARD") ))
[ "$GUARDS_REMOVED" -ge 1 ]
ck "8a-noguard: the fixture really removes the verdict's non-digit guard (the arm is not a copy of 8a)" $?
mkcase "$SECTION_NOGUARD"; CASE_DIR="$C"
printf 'not-a-pid\n' > "$C/o/.orch.lock"
touch -t 202001010000 "$C/o/.orch.lock" 2>/dev/null || touch -d '2020-01-01 00:00:00' "$C/o/.orch.lock"
run_drv O="$C/o"
ck "8a-noguard: with the verdict guard gone, the CALLER's sanitisation still keeps 'integer expression expected' out" \
   "$(want "$ERR" "integer expression" && echo 1 || echo 0)"
ck "8a-noguard: …and the lock is still reclaimed and the loop runs (the sanitisation does not refuse)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
mkcase; CASE_DIR="$C"
printf '0\n' > "$C/o/.orch.lock"
touch -t 202001010000 "$C/o/.orch.lock" 2>/dev/null || touch -d '2020-01-01 00:00:00' "$C/o/.orch.lock"
run_drv O="$C/o"
ck "8b: pid 0 is not an owner (kill -0 0 hits OUR process group) — the loop runs" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"

# ── 11) AN EXPORTED `COLUMNS` MUST NOT TURN A LIVE OWNER INTO "PROVABLY NOT THE OWNER" (#2926) ────
# ⛔ THE WITNESS #2926 REQUIRES OF EVERY `-ww` FIX: set `COLUMNS` and require the ANSWER to be unchanged.
# `ps(1)` honours `COLUMNS` FIRST even when stdout is a pipe, so without `-ww` the command column is cut
# and the PATH TOKEN — last on the line — is the first casualty. `${2##*/}` then stops equalling
# `orch-loop.sh`, `_orch_lock_verdict` answers 1 = "provably NOT the owner", and the caller answers rc 1 by
# DELETING the lock: a LIVE controller loses it and a second controller sweeps the same queue (#1715).
# MEASURED ON THIS HOST (procps-ng 4.0.4), by deleting `-ww` from a copy of the subject and re-running this
# suite: `PASS=51 FAIL=3` — the three arms below red; with the fix `PASS=54 FAIL=0`. The peer's directory
# name is long on purpose: it reproduces #2926's own live shape, where the truncated tail is the
# `orch-loop.sh` token.
echo "── 11. an exported COLUMNS does not change the answer: a live owner is still refused (#2926)"
mkcase; CASE_DIR="$C"
mkdir -p "$C/a-very-long-directory-name-for-the-COLUMNS-witness/orchestrator-harness"
CP="$(spawn_loop "$C/a-very-long-directory-name-for-the-COLUMNS-witness/orchestrator-harness")"; KIDS="$KIDS $CP"; sleep 0.4
printf '%s\n' "$CP" > "$C/o/.orch.lock"          # AFTER the process started — the real write order
# ⛔ THE ARM'S OWN PRECONDITION, REPORTED NOT ASSUMED: if a width-limited read of that pid ALREADY carries
# the `orch-loop.sh` token, this host's `ps` is ignoring `COLUMNS` and the arm below cannot witness
# anything — say so instead of banking a green that proves nothing (the vacuity class of rule 3).
# ⛔ AND THE PRECONDITION MUST BE ATTRIBUTABLE, NOT A BANKED PASS (fresh review of #1985, P3). This arm
# used to end in `ck "…" 0`, a hardcoded pass in the `*)` branch — so it reported "the plant IS
# width-truncated" also when the read produced NO ROW AT ALL (`ps` failed, or the stub raced away), i.e.
# it asserted a measurement it had not taken. The three cases are now distinct: NO ROW is unattributable
# and SKIPS, a row that still carries the token means this host's `ps` ignores `COLUMNS` and SKIPS, and
# the arm PASSES only for a row that EXISTS and LACKS the token — re-tested here rather than banked, so
# a future edit cannot turn the attribution back into a literal.
# ⛔ NO `grep -q` IN A PIPELINE (#841/#864): the row is CAPTURED and tested in the shell.
_WIDTH_ROW="$(COLUMNS=20 ps -axo pid=,stat=,command= 2>/dev/null | awk -v p="$CP" '$1 == p')"
case "$_WIDTH_ROW" in
  '') skip "11: the width-limited read returned NO row for the plant (ps failed, or the stub exited), so the truncation cannot be observed here" ;;
  *orch-loop.sh*) skip "11: this host's ps ignores COLUMNS, so the truncation the arm exists for cannot be staged here" ;;
  *) ck "11: the plant IS width-truncated without -ww (the arm exercises the hazard, not a simulated one)" \
       "$(want "$_WIDTH_ROW" 'orch-loop.sh' && echo 1 || echo 0)" ;;
esac
run_drv O="$C/o" COLUMNS=20
ck "11: a LIVE loop-shaped owner is still REFUSED under COLUMNS=20 (not reclaimed, not started over)" \
   "$(ran && echo 1 || echo 0)"
ck "11: …and the refusal still NAMES the live pid under COLUMNS=20" \
   "$(want "$OUT" "already running (pid $CP)" && echo 0 || echo 1)"
ck "11: …and the owner's lock is UNTOUCHED under COLUMNS=20 (the truncation deletes it without -ww)" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$CP" ] && echo 0 || echo 1 )"
kill -9 "$CP" 2>/dev/null
# The other direction, so the arm cannot be satisfied by refusing everything: the SAME wide read must
# still let the #1985 acceptance case through (a live NON-controller pid, stale lock) under COLUMNS=20.
mkcase; CASE_DIR="$C"
NP="$(spawn_sleep)"; KIDS="$KIDS $NP"; sleep 0.2
printf '%s\n' "$NP" > "$C/o/.orch.lock"
touch -t 202001010000 "$C/o/.orch.lock" 2>/dev/null || touch -d '2020-01-01 00:00:00' "$C/o/.orch.lock"
run_drv O="$C/o" COLUMNS=20
ck "11: a stale lock over a live NON-controller is still RECLAIMED under COLUMNS=20 (the fix is not a blanket refusal)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
kill -9 "$NP" 2>/dev/null

# ── 12) THE PROBE'S UNKNOWN CLOSURES MUST BE ASSERTED, NOT MERELY WRITTEN ────────────────────────
# ⛔ EACH OF THE THREE GUARDS BELOW EARNED ITS OWN ARM BY DISAPPEARING QUIETLY (fresh review of #1985,
# P2; MEASURED: deleting any one of them from a copy at this head left the pre-fix suite at
# `PASS=54 FAIL=0`). They are the closures of the same fail-open the doctrine exists for: `_orch_lock_probe`
# answers rc 1 = ABSENT, and the caller answers ABSENT by DELETING the lock, so a read that merely could
# not see the owner must never be minted into "provably not the owner" (#1715). Each arm is driven
# through the `PS_BIN` shim the §7 family already uses, and each one reds on the named mutant.
echo "── 12. the probe's UNKNOWN closures: an unreadable read never becomes a reclaimed lock"
# 12a) the table READ fine but OMITS a pid that `kill -0` can still signal → UNKNOWN, not ABSENT.
# Mutant that reds this arm: `kill -0 "$p" 2>/dev/null && return 2` deleted from the row-absent branch
# — then an incomplete/hidepid/shimmed table reclaims a LIVE owner's lock.
mkcase; CASE_DIR="$C"
cat > "$C/bin/ps-omits" <<'PSSHIM4'
#!/bin/bash
# A NON-EMPTY table that does not carry the owner's row (an incomplete read, a hidepid table, a shim).
case "$*" in
  *etime*) echo 10:00; exit 0 ;;
  *-axo*)  printf '      1 Ss   bash /tmp/other/orch-loop.sh\n'; exit 0 ;;
esac
exit 1
PSSHIM4
chmod +x "$C/bin/ps-omits"
OP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $OP"; sleep 0.4
printf '%s\n' "$OP" > "$C/o/.orch.lock"
run_drv O="$C/o" PS_BIN="$C/bin/ps-omits"
ck "12a: a table that omits a pid we CAN signal is UNKNOWN, not absent (it refuses)" "$(ran && echo 1 || echo 0)"
ck "12a: …and says CANNOT-TELL naming the pid" \
   "$(want "$ERR" "CANNOT-TELL" && want "$ERR" "$OP" && echo 0 || echo 1)"
ck "12a: …and the live owner's lock is UNTOUCHED" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$OP" ] && echo 0 || echo 1 )"
kill -9 "$OP" 2>/dev/null
# 12b) the read "succeeded" and printed an EMPTY table → unreadable, never absence (#1178 C3). The
# owner here is genuinely DEAD, which is what makes this arm attributable: with the guard deleted the
# empty table falls through to `kill -0` (fails, the pid is gone) and reclaims. Mutant that reds it:
# `case "$t" in *[![:space:]]*) ;; *) return 2 ;; esac` deleted.
mkcase; CASE_DIR="$C"
cat > "$C/bin/ps-empty" <<'PSSHIM5'
#!/bin/bash
# Answers the AGE read, and "succeeds" on the table read while printing NOTHING.
case "$*" in
  *etime*) echo 10:00; exit 0 ;;
  *-axo*)  exit 0 ;;
esac
exit 1
PSSHIM5
chmod +x "$C/bin/ps-empty"
EP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $EP"; sleep 0.4
printf '%s\n' "$EP" > "$C/o/.orch.lock"
kill -9 "$EP" 2>/dev/null; sleep 0.3               # dead, so only the empty-table guard can refuse
run_drv O="$C/o" PS_BIN="$C/bin/ps-empty"
ck "12b: an EMPTY table is UNREADABLE, not empty — it refuses instead of reclaiming" "$(ran && echo 1 || echo 0)"
ck "12b: …and says CANNOT-TELL" "$(want "$ERR" "CANNOT-TELL" && echo 0 || echo 1)"
ck "12b: …and the lock is left in place for a human" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$EP" ] && echo 0 || echo 1 )"
# 12c) the row is PRESENT but its command column is unreadable → UNKNOWN (never "not an orch-loop.sh").
# Mutant that reds it: `[ -n "$cmd" ] || return 2` deleted — an unreadable argv then reads as a
# non-controller and the lock is deleted.
mkcase; CASE_DIR="$C"
cat > "$C/bin/ps-nocmd" <<'PSSHIM6'
#!/bin/bash
# The row for pid 1 carries a STAT column and no argv at all.
case "$*" in
  *etime*) echo 10:00; exit 0 ;;
  *-axo*)  printf '      1 Ss\n'; exit 0 ;;
esac
exit 1
PSSHIM6
chmod +x "$C/bin/ps-nocmd"
printf '1\n' > "$C/o/.orch.lock"
run_drv O="$C/o" PS_BIN="$C/bin/ps-nocmd"
ck "12c: a row whose argv cannot be read is UNKNOWN, not 'not a controller' (it refuses)" \
   "$(ran && echo 1 || echo 0)"
ck "12c: …and says CANNOT-TELL" "$(want "$ERR" "CANNOT-TELL" && echo 0 || echo 1)"
ck "12c: …and the lock naming that pid is NOT removed" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "1" ] && echo 0 || echo 1 )"

# ── 13) A ZOMBIE CANNOT HOLD A LOCK, EVEN IF ITS ARGV SURVIVES THE READ ──────────────────────────
# ⛔ THE HOST THAT NEEDS THIS IS NOT THIS ONE. Linux's `ps` does not keep a zombie's argv — the row is
# `[bash] <defunct>`, so the SHAPE arm already answers "not the owner" and `Z` changes no outcome here.
# But `kill -0` SUCCEEDS on a zombie, so on any `ps(1)` that hands back the ORIGINAL argv (the macOS/
# launchd host this suite's README calls the loop's production host) the shape and age arms BOTH say
# OWNER and only this branch reclaims — i.e. deleting it restores "a lock owned by a killed-but-unreaped
# controller stops the box forever", the exact symptom #1985 opened with. MEASURED: deleting the `Z*`
# case from a copy at this head left the pre-fix suite at `PASS=54 FAIL=0`, so the arm is staged through
# the `PS_BIN` shim idiom — a zombie row whose command column keeps `bash …/orch-loop.sh`.
echo "── 13. a ZOMBIE row whose argv still reads as a controller: reclaim (a zombie holds no lock)"
mkcase; CASE_DIR="$C"
cat > "$C/bin/ps-zombie" <<'PSSHIM7'
#!/bin/bash
# A zombie whose argv SURVIVED the read: stat Z, command still `<shell> <…/orch-loop.sh>`, and an age
# old enough that the age fence calls it a non-owner only if the Z arm fails to answer first.
case "$*" in
  *etime*) echo 10:00; exit 0 ;;
  *-axo*)  printf '      1 Z    bash /tmp/zombie/orch-loop.sh\n'; exit 0 ;;
esac
exit 1
PSSHIM7
chmod +x "$C/bin/ps-zombie"
printf '1\n' > "$C/o/.orch.lock"                     # written now, so the age fence alone says OWNER
run_drv O="$C/o" PS_BIN="$C/bin/ps-zombie"
ck "13: a ZOMBIE is not an owner even with a loop-shaped argv (the box starts instead of stopping forever)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "13: the reclaim is LOGGED (never silent)" \
   "$(want "$(cat "$C/o/logs/orch-loop.log")" "provably NOT the owner" && echo 0 || echo 1)"
ck "13: the zombie's lock is replaced by the newcomer's own pid" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$(printf '%s\n' "$OUT" | sed -n 's/.*STARTED pid=\([0-9]*\).*/\1/p')" ] && echo 0 || echo 1 )"

# ── 14) THE ENV SLACK SEAM IS VALIDATED BEFORE ARITHMETIC — the one input to the decision that is
# TRUSTED (fresh review of #1985, P1) ───────────────────────────────────────────────────────────
# ⛔ WHY THIS IS A FAIL-OPEN AND NOT A COSMETIC EDGE. `ORCH_LOCK_START_SLACK_SECONDS` reaches
# `$(( lt + … ))` inside a `set -u` shell. MEASURED on the pre-fix block, with a LIVE loop-shaped owner
# in the lock (the exact OWNER case): `1.5` and `08` produce a bash ARITHMETIC ERROR, which ABORTS the
# enclosing `if ! acq` compound — no refusal, no CANNOT-TELL, no reclaim log, no `rm` — so the newcomer
# prints STARTED with NO lock of its own while the live owner's lock stays on disk, and its EXIT trap
# then deletes THAT lock (two controllers, #1715). `abc` kills the controller outright with "unbound
# variable", naming neither the variable nor the remedy. ⛔ `08` IS ALL-DIGITS: a digits-only guard is
# not enough, which is why the shipped fix also strips leading zeros textually.
# The drift pin in §9c compares the slack VALUE; nothing there drives a non-numeric value, so the
# guard could be deleted again with CI silent — this arm is the missing leg.
echo "── 14. the env slack seam: an invalid value falls back to the documented 5 s, never to no lock"
for _BADSLACK in 1.5 08 abc; do
  mkcase; CASE_DIR="$C"
  BADP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $BADP"; sleep 0.4
  printf '%s\n' "$BADP" > "$C/o/.orch.lock"        # AFTER the process started — the real write order
  run_drv O="$C/o" "ORCH_LOCK_START_SLACK_SECONDS=$_BADSLACK"
  ck "14: ORCH_LOCK_START_SLACK_SECONDS='$_BADSLACK' still REFUSES a live owner (it does not skip the lock)" \
     "$(ran && echo 1 || echo 0)"
  ck "14: …'$_BADSLACK' still NAMES the live pid in the refusal" \
     "$(want "$OUT" "already running (pid $BADP)" && echo 0 || echo 1)"
  ck "14: …'$_BADSLACK' leaves the live owner's lock UNTOUCHED" \
     "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$BADP" ] && echo 0 || echo 1 )"
  ck "14: …'$_BADSLACK' does not KILL the controller (rc=0 — the #1985 cryptic-stop class)" \
     "$( [ "$RC" -eq 0 ] && echo 0 || echo 1 )"
  ck "14: …'$_BADSLACK' leaks NO shell fault (no arithmetic/unbound error anywhere in the run)" \
     "$(want "$ERR" "rror" && echo 1 || echo 0)"
  kill -9 "$BADP" 2>/dev/null
done
# An ABSURD value (20 digits) is capped by the length test — reported as DEFENSIVE, not as a witnessed
# arm: MEASURED on the guard-removed mutant, bash's arithmetic WRAPS the overflow silently, so this arm
# stays green there and the length guard has no attributable mutant. It is kept because the value would
# otherwise reach `[ -le ]` as an "integer expression expected" error on stderr.
mkcase; CASE_DIR="$C"
HUGE="$(spawn_loop "$C/peer")"; KIDS="$KIDS $HUGE"; sleep 0.4
printf '%s\n' "$HUGE" > "$C/o/.orch.lock"
run_drv O="$C/o" ORCH_LOCK_START_SLACK_SECONDS=99999999999999999999
ck "14: an ABSURD (20-digit) slack is capped to the default and still refuses a live owner (defensive — no mutant witnesses the length test)" \
   "$(ran && echo 1 || echo 0)"
ck "14: …and leaves the live owner's lock alone" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$HUGE" ] && echo 0 || echo 1 )"
kill -9 "$HUGE" 2>/dev/null
# The other direction, so this cannot be satisfied by a guard that clamps EVERYTHING: a valid widened
# slack must still reach the fence and still reclaim a peer that began after the lock.
mkcase; CASE_DIR="$C"
WSP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $WSP"; sleep 0.2
printf '%s\n' "$WSP" > "$C/o/.orch.lock"
touch -t 202001010000 "$C/o/.orch.lock" 2>/dev/null || touch -d '2020-01-01 00:00:00' "$C/o/.orch.lock"
run_drv O="$C/o" ORCH_LOCK_START_SLACK_SECONDS=30
ck "14: a VALID slack (30) still reclaims a peer that began after the lock (the guard is not a blanket clamp)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
kill -9 "$WSP" 2>/dev/null

# ── 14v) THE RESULTING SLACK VALUE, OBSERVED — NOT JUST THE REFUSAL ─────────────────────────────────
# ⛔ A GUARD WITNESSED ONLY BY ITS REFUSAL CANNOT TELL ITS TWO OUTCOMES APART (fresh review of #1985,
# P3; MEASURED). Every §14 row above asserts that the block REFUSES, which the code does both when the
# seam is "fixed" and when it is merely harmless — so the evidence record could claim `08`
# "falls back to the documented 5 s" while the code STRIPS it to **8** and keeps it (8 is inside the
# bound). It does, and did. What the seam produces is therefore read directly: the same extracted
# block with one probe line appended, driven with no lock so the block runs straight through and the
# value survives to be printed. Each row reds on the guard that owns it — delete the strip and `08` prints
# `08`; delete the digit guard and `1.5` prints `1.5`; delete the bound and `61`/20-digit print as-is.
# The fallback value is the DOCUMENTED 5, so the two shapes are distinguishable in one row each.
echo "── 14v. the slack value the block actually keeps: normalisation vs fallback, observed"
SECTION_SLACK="$TMP/section-slack-value.sh"
{ cat "$SECTION"; printf 'printf "SLACK=%%s\\n" "$ORCH_LOCK_START_SLACK_SECONDS"\n'; } > "$SECTION_SLACK"
grep -qF 'printf "SLACK=%s\n"' "$SECTION_SLACK"
ck "14v: the fixture really appends a probe that prints the RESULTING slack (the row is not a restatement of §14)" $?
slack_row() { # slack_row <raw|UNSET> <expected resulting value>
  mkcase "$SECTION_SLACK"; CASE_DIR="$C"
  if [ "$1" = UNSET ]; then run_drv O="$C/o"; else run_drv O="$C/o" "ORCH_LOCK_START_SLACK_SECONDS=$1"; fi
  ck "14v: ORCH_LOCK_START_SLACK_SECONDS='$1' → slack '$2' (the value kept, not just the refusal)" \
     "$(want "$OUT" "SLACK=$2" && echo 0 || echo 1)"
}
# The normalisation rows: all-digits with leading zeros, KEPT (inside the bound) after a textual strip.
slack_row 08 8
slack_row 007 7
# The fallback rows: not all-digits, empty, or wider than the fence → the documented 5.
slack_row 1.5 5
slack_row abc 5
slack_row "" 5
slack_row UNSET 5
slack_row 61 5
slack_row 99999999999999999999 5
# The other direction: valid values reach the fence UNCHANGED, so this is not a blanket clamp.
slack_row 60 60
slack_row 30 30
slack_row 0 0

# ── 15) ⭐ A FAULT INSIDE THE VERDICT MUST NOT SKIP THE LOCK DECISION ──────────────────────────────
# ⛔ MEASURED ON THE PRE-FIX BLOCK WITH THIS EXACT FIXTURE: an arithmetic-expansion fault inside
# `_orch_lock_verdict` prints its error, then — because `v; _OV=$?` and `v`⏎`_OV=$?` are the SAME
# AND-OR list — the whole `if ! acq` body is ABORTED. No refusal, no CANNOT-TELL, no reclaim log, no
# `rm`; execution continues PAST the compound and the driver prints `STARTED` with NO lock of its own
# while the live owner's lock stays on disk (its EXIT trap then deletes THAT lock — #1715). The
# statement split the earlier comment praised could not contain anything, and a plain
# `( verdict ); _OV=$?` would mint rc 1 = RECLAIM, the destructive direction. The fix transports the
# verdict's rc AND reason through stdout and maps "produced nothing" to 2 = CANNOT-TELL. The fault is
# INJECTED into the extracted copy (the mutant the contract asks for), never into the subject.
echo "── 15. ⭐ a fault INSIDE the verdict lands in CANNOT-TELL instead of skipping the lock decision"
mkcase; CASE_DIR="$C"
SECTION_FAULT="$C/section-verdict-fault.sh"
awk '/^_orch_lock_verdict\(\) \{/{print; print "  _INJECTED_FAULT=$(( 1 + 1.5 ))"; next} {print}' "$SECTION" > "$SECTION_FAULT"
grep -qF '_INJECTED_FAULT=$((' "$SECTION_FAULT"
ck "15: the fixture really injects an arithmetic fault INSIDE the verdict (the arm is not a copy of 7)" $?
mkcase "$SECTION_FAULT"; CASE_DIR="$C"
FTP="$(spawn_loop "$C/peer")"; KIDS="$KIDS $FTP"; sleep 0.4
printf '%s\n' "$FTP" > "$C/o/.orch.lock"        # AFTER the process started — the real write order
run_drv O="$C/o"
ck "15: a fault in the verdict does not let the newcomer run with NO lock (the lock decision is not skipped)" \
   "$(ran && echo 1 || echo 0)"
ck "15: …it lands in CANNOT-TELL, naming the pid and the lock (a refusal a human can act on)" \
   "$(want "$ERR" "CANNOT-TELL" && want "$ERR" "$FTP" && want "$ERR" ".orch.lock" && echo 0 || echo 1)"
ck "15: …the live owner's lock is UNTOUCHED (the half that #1715 turns on)" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$FTP" ] && echo 0 || echo 1)"
ck "15: …and it does not KILL the controller (rc=0 — the #1985 cryptic-stop class)" \
   "$( [ "$RC" -eq 0 ] && echo 0 || echo 1)"
kill -9 "$FTP" 2>/dev/null

# ── 16) AN ARGV WE READ BUT COULD NOT ATTRIBUTE IS CANNOT-TELL, NOT "PROVABLY NOT THE OWNER" ──────
# (fresh review of PR #3837 at 185e7c5bd, P2; MEASURED on the pre-fix block: a controller started with a
# shell OPTION between the shell and the script — `bash -x …/orch-loop.sh` — failed `_orch_argv_is_loop`'s
# two-token rule and was therefore minted into rc 1 = PROVABLY NOT the owner. The next start printed
# `STARTED`, logged `[lock] reclaiming … pid N is provably NOT the owner …`, and `kill -0 N` was STILL
# TRUE: a second controller sweeping one PR queue, which is #1715.)
# ⛔ THE RULE IS "ONLY POSITIVE EVIDENCE OF NON-OWNERSHIP RECLAIMS", AND "I COULD NOT PARSE IT" IS NOT
# EVIDENCE. An argv that was READ and could not be ATTRIBUTED is the third outcome the verdict already
# has for every unreadable read: refuse, loudly, and leave the owner's lock alone.
# ⛔ WHY `-c` IS EXEMPT, SAID HERE SO NOBODY "FIXES" IT LATER: #1856 decided `bash -c "sleep 300;
# /abs/orch-loop.sh"` is a WRAPPER's argv, not a controller, and arm 4c above asserts such a pid is
# RECLAIMED. That recorded decision stands — the exemption is deliberate, not an oversight — and only the
# option forms no decision reaches are deferred to a human as ambiguous.
echo "── 16. ⭐ an unparseable-but-loop-shaped argv REFUSES (CANNOT-TELL); it is not 'provably NOT the owner'"
mkcase; CASE_DIR="$C"
GP="$(spawn_loop_flagged "$C/peer")"; KIDS="$KIDS $GP"; sleep 0.4
printf '%s\n' "$GP" > "$C/o/.orch.lock"        # AFTER the process started — the real write order
run_drv O="$C/o"
ck "16: a live owner whose argv carries a shell OPTION is not reclaimed (it refuses instead)" \
   "$(ran && echo 1 || echo 0)"
ck "16: …the refusal says CANNOT-TELL and names the pid and the lock" \
   "$(want "$ERR" "CANNOT-TELL" && want "$ERR" "$GP" && want "$ERR" ".orch.lock" && echo 0 || echo 1)"
ck "16: …and names the unparsed argv, not a read that failed (the human must know WHICH ambiguity)" \
   "$(want "$ERR" "cannot attribute" && echo 0 || echo 1)"
ck "16: …the live owner's lock is UNTOUCHED (a refusal clobbers nothing)" \
   "$( [ "$(lock_pid "$C/o/.orch.lock")" = "$GP" ] && echo 0 || echo 1)"
# ⛔ THE SAME INERT ROW WAS DELETED HERE TOO ("…and the owner is still ALIVE", `kill -0 "$GP"`). The
# review of PR #3865 at 49fda057a scoped this one OUT as a follow-up because it predates the diff, and
# this lane MEASURED it before deciding rather than inheriting the assumption: under the mutant that
# removes the unparsed-argv refusal (`if false` in place of the `_orch_argv_is_loop_flagged` call) the
# FOUR rows above go RED and this row stayed GREEN — no branch of the lock decision signals the named
# pid, so the row cannot vary and is not coverage (#3442 rule 3). Deleting it rather than leaving a
# follow-up debt beside its identical twin above; the four rows above carry the whole behaviour.
kill -9 "$GP" 2>/dev/null
# The positive control, so §16 cannot pass by refusing every shell-option argv it cannot parse: the
# SAME option form with a NON-loop script must still be RECLAIMED (rc 1), which is what keeps this arm
# from being a blanket refusal.
mkcase; CASE_DIR="$C"
printf '#!/bin/bash\nfor _ in $(seq 1 60); do sleep 1; done\n' > "$C/peer/notalock.sh"
chmod +x "$C/peer/notalock.sh"
bash -x "$C/peer/notalock.sh" >/dev/null 2>&1 &
XP=$!; KIDS="$KIDS $XP"; sleep 0.4
printf '%s\n' "$XP" > "$C/o/.orch.lock"
run_drv O="$C/o"
ck "16b: the same OPTION form over a NON-loop script is still RECLAIMED (§16 is not a blanket refusal)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
kill -9 "$XP" 2>/dev/null

# ── 16c) THE `+` POLARITY IS AN OPTION TOO (fresh review at 8eb852d27, P2) ──────────────────────
# `bash` accepts the `+` form of every `set`-style option, and this repo's OWN classifier decision treats
# such an argv as an INVOCATION: `check-deployed-drift.test.sh` §10a-3e drives `bash -o pipefail`,
# `bash -O extglob`, `bash +o noexec`, `bash +o errexit`, `bash --rcfile noexec`, `bash -euo pipefail` …
# over `<abs>/orch-loop.sh` and asserts each one IS an invocation. A `-`-only option
# test RECLAIMED over a live owner — which `main` also does (MEASURED: its own predicate is the `-`-only
# form), so this CLOSES a fail-open band rather than restoring one; the pre-#1985 loop refused any live
# pid, and #1985's shape rule opened the band this arm closes. MEASURED before the fix, same fixture:
# `STARTED` + `[lock] reclaiming … provably NOT the owner` with the owner still alive.
# ⛔ AND NO BACKTICKS IN A DOUBLE-QUOTED LABEL (found by this round's test run, P2; MEASURED: the labels
# printed with a HOLE — "a live owner behind  is not reclaimed" — and the option words were EXECUTED at
# label-construction time, because a backtick pair inside a double-quoted string IS a command
# substitution. Every label below therefore quotes the option form with SINGLE quotes, or spells it out.
# This is the same hazard the fleet's commit-message rule names; a label is not a safe place for one.
echo "── 16c. a '+'-form option in front of the script REFUSES too (both polarities are options)"
mkcase; CASE_DIR="$C"
PL="$(spawn_loop_flagged "$C/peer" +o errexit)"; KIDS="$KIDS $PL"; sleep 0.4
printf '%s\n' "$PL" > "$C/o/.orch.lock"
run_drv O="$C/o"
ck "16c: a live owner behind 'bash +o errexit …' is not reclaimed (it refuses instead)" \
   "$(ran && echo 1 || echo 0)"
ck "16c: …the refusal says CANNOT-TELL and the owner's lock is UNTOUCHED" \
   "$(want "$ERR" "CANNOT-TELL" && [ "$(lock_pid "$C/o/.orch.lock")" = "$PL" ] && echo 0 || echo 1)"
# ⛔ A THIRD ROW STOOD HERE — "…and the owner is still ALIVE" (`kill -0 "$PL"`) — AND IT WAS DELETED, NOT
# KEPT AS A DISCLOSED GREEN (#3442 rule 3; review of PR #3865 at 49fda057a, P3). It could not VARY: the
# only thing the mutant changes is the predicate's ANSWER, which selects the refusal branch or the reclaim
# branch, and NEITHER signals the named pid (the reclaim path is `rm -f "$LOCKF"` then `acq`). MEASURED
# under the `-`-only revert on a staged copy: the two rows above go RED and that row stayed GREEN.
# ⛔ DO NOT RE-ADD IT. The behaviour it appears to guard is already carried above — a wrong reclaim is
# witnessed by "it refuses instead" (row 1) and by "the lock is UNTOUCHED" (row 2), which is the
# observable a reclaim actually changes. An assertion that cannot go red is a false guard, not coverage.
kill -9 "$PL" 2>/dev/null
# and the `+`-form positive control, so accepting `+` cannot become a blanket refusal
mkcase; CASE_DIR="$C"
printf '#!/bin/bash\nfor _ in $(seq 1 60); do sleep 1; done\n' > "$C/peer/notalock.sh"
chmod +x "$C/peer/notalock.sh"
bash +o errexit "$C/peer/notalock.sh" >/dev/null 2>&1 &
YP=$!; KIDS="$KIDS $YP"; sleep 0.4
printf '%s\n' "$YP" > "$C/o/.orch.lock"
run_drv O="$C/o"
ck "16d: the same '+'-form option over a NON-loop script is still RECLAIMED (§16c is not a blanket refusal)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
kill -9 "$YP" 2>/dev/null

# ── 17) A `-c` WRAPPER STAYS RECLAIMED EVEN WITH AN OPTION IN FRONT OF IT (#1856, made ORDERED) ───
# The `-c` exemption used to fire only when `-c` was argv[2], so the SAME command string answered two
# OPPOSITE ways once an `-x` was added: `bash -c "…; /abs/orch-loop.sh"` reclaimed (4c) while
# `bash -x -c "…; /abs/orch-loop.sh"` refused as ambiguous — although #1856's evidence (a `-c` token,
# i.e. a COMMAND STRING rather than a script argument) is present in both. The scan is now ORDERED: a
# `-c`-family option seen BEFORE the loop-shaped token means the shell was handed a command string, so
# it is a wrapper and not a controller. (fresh review at 8eb852d27, P3)
echo "── 17. a '-c' wrapper is a non-controller even with another option in front of it (#1856)"
mkcase; CASE_DIR="$C"
bash -x -c "for _ in \$(seq 1 60); do sleep 1; done; $C/peer/orch-loop.sh" >/dev/null 2>&1 &
WP=$!; KIDS="$KIDS $WP"; sleep 0.4
printf '%s\n' "$WP" > "$C/o/.orch.lock"
run_drv O="$C/o"
ck "17: a '-c' wrapper with an OPTION in front of it is still RECLAIMED (not refused as ambiguous)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
pkill -P "$WP" 2>/dev/null
kill -9 "$WP" 2>/dev/null
# and the `+c` SPELLING of the same token (fresh review of #3865 at f8604c74c, P3: the exemption was
# `-`-only, so `bash +c "…; <loop>"` — which MEASURABLY executes the string — was refused as ambiguous
# while its `-c` twin reclaimed, contradicting the rule this PR states for both polarities)
mkcase; CASE_DIR="$C"
bash +c "for _ in \$(seq 1 60); do sleep 1; done; $C/peer/orch-loop.sh" >/dev/null 2>&1 &
ZP=$!; KIDS="$KIDS $ZP"; sleep 0.4
printf '%s\n' "$ZP" > "$C/o/.orch.lock"
run_drv O="$C/o"
ck "17b: a '+c' wrapper is RECLAIMED too (the exemption holds for BOTH polarities)" \
   "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
pkill -P "$ZP" 2>/dev/null
kill -9 "$ZP" 2>/dev/null
# ⛔ AND `c` INSIDE A SHORT-OPTION CLUSTER IS STILL THE SAME FAMILY (fresh review of #3865 at 8c3346680,
# P3 — MEASURED: `bash +cx 'echo FROM_PLUS_CX'` and `bash -ce …` BOTH execute the string, while a
# whole-token match missed both, so those spellings were refused as ambiguous even though they execute.
# Two rows, one per polarity, so the cluster rule is witnessed and not merely written.)
for _cf in '+cx' '-ce'; do
  mkcase; CASE_DIR="$C"
  bash "$_cf" "for _ in \$(seq 1 60); do sleep 1; done; $C/peer/orch-loop.sh" >/dev/null 2>&1 &
  TP=$!; KIDS="$KIDS $TP"; sleep 0.4
  printf '%s\n' "$TP" > "$C/o/.orch.lock"
  run_drv O="$C/o"
  ck "17c: a '$_cf' cluster wrapper is RECLAIMED (c inside a short-option cluster is the -c family)" \
     "$(ran && [ "$RC" -eq 0 ] && echo 0 || echo 1)"
  pkill -P "$TP" 2>/dev/null
  kill -9 "$TP" 2>/dev/null
done

# ── recap ───────────────────────────────────────────────────────────────────────────────────────
echo
printf 'PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
