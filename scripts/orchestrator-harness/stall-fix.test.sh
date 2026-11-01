#!/usr/bin/env bash
# stall-fix.test.sh — the stall escalation's DISPATCH VERDICT, DRIVEN (agent-infra#2929 / PR #3181).
#
# WHY THIS SUITE EXISTS IN THIS SHAPE. `stall-fix.sh` is executed by the controller on every stalled
# drain pass and its only job is to DISPATCH a worker. Its central claim — "a stall escalation that
# cannot start a worker must not read as one that did" — was FALSE until this suite existed: the
# dispatcher (`nonblocking-dispatch.sh`) backgrounds `run_agent`, and with it every spawn gate, with
# `exec >/dev/null 2>&1`, then returns 0 once it reaches the launch. So a `[load-gate] REFUSED`,
# `[disk-gate] REFUSED` or `[land-backlog] REFUSED` produced a `STALL FIX DISPATCHED` line and a
# `stall-fix dispatched` ledger row — a false success in the one artifact the escalation exists to
# produce (review of #3181, P1). The script now reads the worker's own record (bg log / .rc / .pid,
# plus the spawn point's append-only ledger) instead of the dispatcher's exit status.
#
# §A  the bound and the refusals — no worker is dispatched where the script says it is not
# §B  THE VERDICT — each evidence shape the dispatcher can leave behind maps to the right sentence,
#     and a REFUSAL never prints DISPATCHED (the #3181 P1 regression)
# §C  NON-VACUITY — a mutant that reports `started` without evidence makes §B's central assert FAIL.
#     Without this arm "NOT DISPATCHED" could be green on a tree where nothing is ever dispatched.
#
# Hermetic: every case builds its own `$O`, its own `$HOME` (the spawn-gate ledger lives under it),
# its own fake worktree and its own stub dispatcher. No network, no real runtime, no `pi`.
#
# Run: bash scripts/orchestrator-harness/stall-fix.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$HERE/stall-fix.sh"
PASS=0; FAIL=0
ck() { # ck <rc> <message>
  if [ "$1" -eq 0 ]; then printf '  ✅ %s\n' "$2"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$2"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d)"
_tmp_sleeps="$TMP/sleeps"
: > "$_tmp_sleeps"
export _SLEEPS="$_tmp_sleeps"   # where the b6 stub records the pid it left alive
cleanup() {
  # The one case that proves the "alive pid is not proof of a start" arm leaves a real `sleep`
  # behind on purpose. Reap it, or the suite leaks a process into every later run on this box.
  while IFS= read -r _p; do [ -n "$_p" ] && kill "$_p" 2>/dev/null; done < "$_tmp_sleeps"
  rm -rf "$TMP"
}
trap cleanup EXIT

[ -s "$SH" ] && bash -n "$SH"; ck $? "stall-fix.sh exists and parses"
[ -x "$SH" ]; ck $? "stall-fix.sh is executable (the controller invokes it as a program)"

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
# A minimal runtime tree: `logs/` (the dispatch redirect target), `state/` (the escalation ledger and
# the brief dir), `bg/` (the worker record the verdict is read from) and a worktree carrying `.git`.
# `STALL_FIX_WORKTREE` is what makes that worktree usable, so the `git worktree add` arm is skipped
# and nothing here touches a real repository.
new_o() { # new_o <tag> → prints a fresh runtime dir
  local d="$TMP/o-$1"
  mkdir -p "$d/state/briefs" "$d/logs" "$d/bg" "$d/wt" || return 1
  : > "$d/wt/.git"
  printf '%s' "$d"
}
stub() { # stub <o-dir> <body…> — an executable nonblocking-dispatch.sh running <body>
  local d="$1"; shift
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$d/nonblocking-dispatch.sh"
  chmod +x "$d/nonblocking-dispatch.sh"
}
OUT=""
run_sh() { # run_sh <o-dir> <seen> <every> → runs stall-fix.sh, leaves its combined output in $OUT
  OUT="$(O="$1" STALL_FIX_WORKTREE="$1/wt" DRAIN_STALL_FIX_EVERY="$3" STALL_FIX_VERIFY_SECS=1 \
         bash "$SH" "$2" 90 2>&1)"
}
has()    { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
lacks()  { case "$OUT" in *"$1"*) return 1 ;; *) return 0 ;; esac; }
ledger_of() { cat "$1/state/drain-stall-dispatch.log" 2>/dev/null || true; }

# The `$HOME` this suite hands the script: the spawn point's per-box state dir lives under it.
export HOME="$TMP/home"
mkdir -p "$HOME/.pi/agent/state"
SGL="$HOME/.pi/agent/state/spawn-gate.tsv"
# The number of the worker name a stub was called with, so a stub can write the record the real
# dispatcher would have written for THAT worker.
STUB_OK_TOUCH=': > "$O/stub-called"'

echo
echo "── §A the bound and the refusals ───────────────────────────────────────────────────────────"
D="$(new_o a0)"; stub "$D" "$STUB_OK_TOUCH"
run_sh "$D" 0 3
has "skipped (pass counter 0" && ck 0 "pass counter 0 (a healthy pass) is refused" || ck 1 "pass counter 0 (a healthy pass) is refused"
[ ! -f "$D/stub-called" ]; ck $? "…and the dispatcher was NEVER called on a healthy pass"

D="$(new_o a1)"; stub "$D" "$STUB_OK_TOUCH"
run_sh "$D" "not-a-number" 3
has "no pass counter; not a number" && ck 0 "a non-numeric pass counter is skipped, not dispatched" || ck 1 "a non-numeric pass counter is skipped, not dispatched"
[ ! -f "$D/stub-called" ]; ck $? "…and the dispatcher was never called"

D="$(new_o a2)"; stub "$D" "$STUB_OK_TOUCH"
run_sh "$D" 2 3
has "deferred (pass 2, one dispatch per 3)" && ck 0 "an off-bound stalled pass is deferred (2 of 3)" || ck 1 "an off-bound stalled pass is deferred (2 of 3)"
[ ! -f "$D/stub-called" ]; ck $? "…and the dispatcher was never called"

# `DRAIN_STALL_FIX_EVERY=0` must NOT become an unbounded dispatch: a bound of zero is not a bound.
# Coerced to 3, pass 2 is still off-bound — which a zero (or a missing) bound could not produce.
D="$(new_o a3)"; stub "$D" "$STUB_OK_TOUCH"
run_sh "$D" 2 0
has "deferred (pass 2, one dispatch per 3)" && ck 0 "EVERY=0 is coerced to 3 (a bound of zero is not a bound)" || ck 1 "EVERY=0 is coerced to 3 (a bound of zero is not a bound)"
[ ! -f "$D/stub-called" ]; ck $? "…and the off-bound pass did not call the dispatcher"

D="$(new_o a4)"; stub "$D" "$STUB_OK_TOUCH"
run_sh "$D" 3 3
[ -f "$D/stub-called" ]; ck $? "the on-bound stalled pass (3 of 3) DOES call the dispatcher"

echo
echo "── §B the verdict — evidence, not the dispatcher's exit status ─────────────────────────────"
# ⛔ THE #3181 P1 REGRESSION. The real dispatcher exits 0 here (it reached the launch) and the gate
# refusal lands in the WORKER's log. Reading the exit status — the pre-fix shape — records a worker
# that never started.
D="$(new_o b1)"
stub "$D" 'printf "[load-gate] REFUSED stallfix: load=120 >= max_load=80 — no agent started\n" > "$O/bg/$1.log"'
run_sh "$D" 3 3
has "NOT DISPATCHED" && ck 0 "a gate REFUSAL in the worker log is reported as NOT DISPATCHED" || ck 1 "a gate REFUSAL in the worker log is reported as NOT DISPATCHED"
lacks "STALL FIX DISPATCHED" && ck 0 "…and never as STALL FIX DISPATCHED (the #3181 P1 fail-open)" || ck 1 "…and never as STALL FIX DISPATCHED (the #3181 P1 fail-open)"
has "[load-gate] REFUSED" && ck 0 "…and the gate's own line is quoted, so the operator knows WHY" || ck 1 "…and the gate's own line is quoted, so the operator knows WHY"
case "$(ledger_of "$D")" in *"stall-fix NOT DISPATCHED (spawn refused)"*) ck 0 "…and the durable escalation row says NOT DISPATCHED too" ;; *) ck 1 "…and the durable escalation row says NOT DISPATCHED too" ;; esac

# The same refusal seen only through the spawn point's own ledger (a `pi` shim refusal, a log that
# rotated): the positive/negative row is the authoritative answer where it exists.
D="$(new_o b2)"
stub "$D" 'printf "1\trefused\t120\t80\t9\t8\tprfix\t%s\t/tmp\tbash\n" "$1" >> "$HOME/.pi/agent/state/spawn-gate.tsv"'
run_sh "$D" 3 3
has "NOT DISPATCHED" && ck 0 "a spawn-gate ledger 'refused' row alone is NOT DISPATCHED" || ck 1 "a spawn-gate ledger 'refused' row alone is NOT DISPATCHED"

# ...and the one POSITIVE proof: an `allowed` row carrying this worker's TAG.
D="$(new_o b3)"
stub "$D" 'printf "1\tallowed\t26\t80\t9\t8\tprfix\t%s\t/tmp\tbash\n" "$1" >> "$HOME/.pi/agent/state/spawn-gate.tsv"'
run_sh "$D" 3 3
has "STALL FIX DISPATCHED" && ck 0 "a spawn-gate ledger 'allowed' row for this TAG IS a dispatch" || ck 1 "a spawn-gate ledger 'allowed' row for this TAG IS a dispatch"
case "$(ledger_of "$D")" in *"stall-fix dispatched"*) ck 0 "…and the durable escalation row records the dispatch" ;; *) ck 1 "…and the durable escalation row records the dispatch" ;; esac

# A stale row from an EARLIER worker (same TAG, written before this launch) must not answer for this
# one: the offset is taken before the call, and a failed launch writes nothing after it.
D="$(new_o b4)"
printf '1\tallowed\t26\t80\t1\t0\tprfix\t%s\t/tmp\tbash\n' "stallfix-000000" >> "$SGL"
stub "$D" 'printf "[fork-gate] REFUSED stallfix: box out of processes\n" > "$O/bg/$1.log"'
run_sh "$D" 3 3
has "NOT DISPATCHED" && ck 0 "an 'allowed' row from an earlier worker cannot mask a refusal here" || ck 1 "an 'allowed' row from an earlier worker cannot mask a refusal here"

# A worker that already ENDED (its `.rc` exists and nothing refused) is reported as having run —
# not as still-dispatching, and not as a failure.
D="$(new_o b5)"
stub "$D" 'printf "0\n" > "$O/bg/$1.rc"'
run_sh "$D" 3 3
has "RAN AND ALREADY ENDED" && ck 0 "an .rc with no refusal is reported as RAN AND ALREADY ENDED" || ck 1 "an .rc with no refusal is reported as RAN AND ALREADY ENDED"
lacks "STALL FIX DISPATCHED" && ck 0 "…and is not called a dispatch" || ck 1 "…and is not called a dispatch"

# A live pid with NO ledger row and no refusal is the honest middle: the launcher accepted it, but
# nothing yet proves an agent started. (A box without the shipped `pi` shim looks exactly like this.)
D="$(new_o b6)"
stub "$D" 'sleep 30 & printf "%s\n" "$!" > "$O/bg/$1.pid"; printf "%s\n" "$!" >> "$_SLEEPS"'
run_sh "$D" 3 3
has "STALL FIX LAUNCH ACCEPTED, AGENT START UNPROVEN" && ck 0 "a live pid with no positive evidence says UNPROVEN, not DISPATCHED" || ck 1 "a live pid with no positive evidence says UNPROVEN, not DISPATCHED"
lacks "STALL FIX DISPATCHED" && ck 0 "…and does not claim a dispatch it cannot prove" || ck 1 "…and does not claim a dispatch it cannot prove"

# Nothing at all: no pid, no rc, no refusal, no row.
D="$(new_o b7)"
stub "$D" 'exit 0'
run_sh "$D" 3 3
has "DISPATCH UNPROVEN" && ck 0 "an empty record is reported as DISPATCH UNPROVEN" || ck 1 "an empty record is reported as DISPATCH UNPROVEN"
lacks "STALL FIX DISPATCHED" && ck 0 "…and never as a dispatch" || ck 1 "…and never as a dispatch"

# A FOREGROUND refusal (the dispatcher exits non-zero: usage, brief gate, missing helper).
D="$(new_o b8)"
stub "$D" 'echo "nonblocking-dispatch.sh: REFUSED — brief-gate judged the brief and refused it" >&2; exit 80'
run_sh "$D" 3 3
has "DISPATCH FAILED" && ck 0 "a non-zero dispatcher exit is reported as DISPATCH FAILED" || ck 1 "a non-zero dispatcher exit is reported as DISPATCH FAILED"
case "$(ledger_of "$D")" in *"stall-fix DISPATCH FAILED (exit 80)"*) ck 0 "…and the durable row carries the exit status" ;; *) ck 1 "…and the durable row carries the exit status" ;; esac

echo
echo "── §C non-vacuity — a mutant that reports DISPATCHED without evidence must redden §B ───────"
# The mutation removes the EVIDENCE requirement from the positive arm (an unconditional `started`),
# which is precisely the pre-fix shape ("the launcher returned, so a worker started"). If §B's central
# assert cannot tell the two apart, §B is a decoration.
MUT="$TMP/stall-fix.mutant.sh"
sed 's/if spawn_row allowed; then _verdict=started; break; fi/if true; then _verdict=started; break; fi/' \
  "$SH" > "$MUT" 2>/dev/null
if [ -s "$MUT" ] && grep -qF 'if true; then _verdict=started' "$MUT"; then
  ck 0 "the mutant was actually produced (a mutation that never applied proves nothing)"
  D="$(new_o c1)"
  stub "$D" 'printf "[load-gate] REFUSED stallfix: load=120 >= max_load=80 — no agent started\n" > "$O/bg/$1.log"'
  OUT="$(O="$D" STALL_FIX_WORKTREE="$D/wt" DRAIN_STALL_FIX_EVERY=3 STALL_FIX_VERIFY_SECS=1 bash "$MUT" 3 90 2>&1)"
  has "STALL FIX DISPATCHED" && ck 0 "the mutant reports DISPATCHED on a refusal — so §B's assert is discriminating" || ck 1 "the mutant reports DISPATCHED on a refusal — so §B's assert is discriminating"
else
  ck 1 "the mutant was actually produced (a mutation that never applied proves nothing)"
fi

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
