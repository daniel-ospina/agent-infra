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
# §D  the worker's worktree is REFRESHED on every dispatch, not frozen at the first stall
# §E  the two sinks this script opens are BOUNDED — a brief older than the retention bound is pruned,
#     the escalation ledger rotates at its cap, and a file this script does not own is left alone.
# §F  the age's PROVENANCE (`measured` | `synth` | `unmeasured`) reaches BOTH sinks verbatim — the
#     brief's premise line renders it rather than printing an attempted window as a stall age, and the
#     durable `age_min=/agesrc=` row keeps it un-rewritten (the #3181 P1 regression).
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
# ⛔ A STAMP `N` MINUTES AGO, PORTABLY (BSD `-v-NM` first, GNU `-d` second). A FIXED old date is wrong for
# every leg below that ages a file: the `$O/bg` prune runs BEFORE `wt_in_use`, so a 2020 stamp belongs to
# the PRUNE, not to the liveness pin — a leg built on one measures the wrong mechanism and stays green
# when the thing it claims to pin is deleted.
ago_stamp() { date -v-"$1"M +%Y%m%d%H%M 2>/dev/null || date -d "-$1 min" +%Y%m%d%H%M 2>/dev/null; }
# ⛔ THE AGES THE TWO PIN LEGS USE ARE DERIVED FROM THE SHIPPED `STALL_FIX_PIN_MIN`, NOT RESTATED HERE
# (fresh-context review of #3181, 2026-11-02, P2). A hard-coded 60/20 pair straddles the pin only while
# `DRAIN_STALL_FIX_TIMEOUT` keeps its default; if the bound moves, both legs silently stop straddling it
# and go vacuous while staying green. So the declaration is read out of the shipped script — the same two
# lines the script itself evaluates — and the file ages are placed relative to it.
PINMIN="$(TIMEOUT=1800 bash -c 'eval "$(grep -E "^STALL_FIX_PIN_MIN=" "$1"; grep -F "|| STALL_FIX_PIN_MIN=35" "$1")"; printf %s "$STALL_FIX_PIN_MIN"' _ "$SH" 2>/dev/null || true)"
case "${PINMIN:-}" in ''|*[!0-9]*) PINMIN=0 ;; esac
[ "$PINMIN" -ge 20 ]; ck $? "fixture: the shipped STALL_FIX_PIN_MIN is readable and leaves room to straddle it (got '${PINMIN:-}')"
PIN_YOUNG=$(( PINMIN - 15 ))   # younger than the pin: still a LIVE worker's record
PIN_OLD=$(( PINMIN + 25 ))     # older than the pin: cannot describe a live worker

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

# ── §A2 a dispatcher that cannot be EXECUTED is two different faults (#4003) ────────────────────
# ⛔ THE MEASURED FAILURE: `~/orchestrator/nonblocking-dispatch.sh` was THERE — 36,175 bytes, mode
# `-rw-r--r--`, a deployment that had lost the bit — and the one line the script wrote said
# "no executable $DISP", which reads as a configuration note. Both states produced that same sentence,
# so nothing told an operator whether to redeploy or to `chmod`. These two legs pin the states apart;
# the disjunction is what makes each of them load-bearing (a single message satisfies either one).
D="$(new_o a5)"
rm -f "$D/nonblocking-dispatch.sh"
run_sh "$D" 3 3
has "is ABSENT" && ck 0 "a MISSING dispatcher is named ABSENT" || ck 1 "a MISSING dispatcher is named ABSENT"
has "redeploy the harness" && ck 0 "…and the absent arm names the remedy that fixes it" || ck 1 "…and the absent arm names the remedy that fixes it"
lacks "NOT EXECUTABLE" && ck 0 "…and never claims the present-but-unrunnable state" || ck 1 "…and never claims the present-but-unrunnable state"

D="$(new_o a6)"; stub "$D" "$STUB_OK_TOUCH"; chmod -x "$D/nonblocking-dispatch.sh"
run_sh "$D" 3 3
has "EXISTS but is NOT EXECUTABLE" && ck 0 "a PRESENT-but-chmod-x dispatcher is named as exactly that" || ck 1 "a PRESENT-but-chmod-x dispatcher is named as exactly that"
has "chmod +x" && ck 0 "…and names the remedy, so the operator does not re-deploy to no effect" || ck 1 "…and names the remedy, so the operator does not re-deploy to no effect"
has "-rw-" && ck 0 "…and quotes the mode it actually found" || ck 1 "…and quotes the mode it actually found"
lacks "is ABSENT" && ck 0 "…and never reports it as missing (the pre-#4003 conflation)" || ck 1 "…and never reports it as missing (the pre-#4003 conflation)"
[ ! -f "$D/stub-called" ]; ck $? "…and an unrunnable dispatcher is never reported as dispatched"

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

# ⛔ THE LOG IS A SHARED CHANNEL (review P2, #3181). `$O/bg/<name>.log` is handed to `run_agent`, so
# it carries the gates' `[<name>] REFUSED` lines AND whatever the worker itself prints — and this worker
# is dispatched to READ the drain's ledger, whose rows say "landing claim REFUSED: held by …". Matching
# the bare word reported a live worker as NOT DISPATCHED and wrote the same claim durably.
D="$(new_o b9)"
stub "$D" 'sleep 30 & printf "%s\n" "$!" > "$O/bg/$1.pid"; printf "%s\n" "$!" >> "$_SLEEPS"; printf "[pr] landing claim REFUSED: held by another box — merge-9812\n" > "$O/bg/$1.log"'
run_sh "$D" 3 3
has "STALL FIX LAUNCH ACCEPTED, AGENT START UNPROVEN" && ck 0 "a worker-log REFUSED that is NOT a gate line leaves a LIVE worker UNPROVEN, not NOT DISPATCHED" || ck 1 "a worker-log REFUSED that is NOT a gate line leaves a LIVE worker UNPROVEN, not NOT DISPATCHED"
lacks "NOT DISPATCHED" && ck 0 "…and never records a gate refusal no gate made" || ck 1 "…and never records a gate refusal no gate made"

# A worker that already ENDED (its `.rc` exists, its log carries the worker's own output, and nothing
# refused) is reported as having run — not as still-dispatching, and not as a failure.
# ⛔ THE LOG BYTE IS PART OF THE FIXTURE ON PURPOSE (fresh-context review, 2026-11-02, P1): a `.rc` with
# ZERO bytes is `nonblocking-dispatch.sh`'s own `NOT STARTED … this is NOT a dispatch` shape, and this
# leg used to assert exactly that shape was "RAN AND ALREADY ENDED" — pinning the false-pass it now
# refuses. The next leg (b5b) drives the zero-byte shape.
D="$(new_o b5)"
stub "$D" 'printf "0\n" > "$O/bg/$1.rc"; printf "[worker] report written\n" > "$O/bg/$1.log"'
run_sh "$D" 3 3
has "RAN AND ALREADY ENDED" && ck 0 "an .rc WITH log bytes and no refusal is reported as RAN AND ALREADY ENDED" || ck 1 "an .rc WITH log bytes and no refusal is reported as RAN AND ALREADY ENDED"
lacks "STALL FIX DISPATCHED" && ck 0 "…and is not called a dispatch" || ck 1 "…and is not called a dispatch"

# ⛔ THE ZERO-BYTE SHAPE IS THE DISPATCHER'S OWN "NOT STARTED", NOT A DISPATCH (fresh-context review,
# 2026-11-02, P1). `nonblocking-dispatch.sh:415-427` writes rc + an EMPTY log and exits 75 saying, in its
# own words, "This is NOT a dispatch: do not record it as one". A verdict reader that treats the `.rc`
# alone as proof reports "it DID start, so its report may exist" and points the operator at a report that
# cannot exist — on the one durable artifact an incident is read from.
D="$(new_o b5b)"
stub "$D" 'printf "0\n" > "$O/bg/$1.rc"; : > "$O/bg/$1.log"; exit 75'
run_sh "$D" 3 3
has "STALL FIX NOT STARTED" && ck 0 "a worker record with ZERO log bytes is NOT STARTED, not a dispatch" || ck 1 "a worker record with ZERO log bytes is NOT STARTED, not a dispatch"
lacks "RAN AND ALREADY ENDED" && ck 0 "…and it does not claim the worker ran" || ck 1 "…and it does not claim the worker ran"
case "$(ledger_of "$D")" in *"NOT STARTED"*) ck 0 "…and the durable row says NOT STARTED too" ;; *) ck 1 "…and the durable row says NOT STARTED too: $(ledger_of "$D")" ;; esac

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

# ⛔ A POST-LAUNCH EXIT 75 IS NOT A PRE-LAUNCH REFUSAL (fresh-context review, 2026-11-02).
# `nonblocking-dispatch.sh:405-443` exits 75 for `NOT STARTED` and `FAILED EARLY` — the launch
# HAPPENED and no lane is running — and the gate's own refusal line sits in the WORKER's log, which
# is the `[land-backlog] REFUSED … rc=74` shape this file's own note records. Classifying every
# non-zero exit as "refused before launching" bypassed the evidence reader and threw that line away.
D="$(new_o b9)"
stub "$D" 'printf "[land-backlog] REFUSED stallfix: landing ratio 0/9 over ceiling — no agent started\n" > "$O/bg/$1.log"; exit 75'
run_sh "$D" 3 3
has "NOT DISPATCHED" && ck 0 "a POST-launch exit 75 with a gate refusal in the worker log is NOT DISPATCHED" || ck 1 "a POST-launch exit 75 with a gate refusal in the worker log is NOT DISPATCHED"
has "[land-backlog] REFUSED" && ck 0 "…and that gate's own line is quoted (it is not discarded on the non-zero path)" || ck 1 "…and that gate's own line is quoted (it is not discarded on the non-zero path)"
lacks "refused before launching" && ck 0 "…and the pre-launch wording is not used for an exit that happened AFTER the launch" || ck 1 "…and the pre-launch wording is not used for an exit that happened AFTER the launch"

# ...and a 75 that DID leave a worker record AND output is "ran and already ended", not "refused".
# The log byte is the discriminator (see b5b): the record alone is the zero-byte `NOT STARTED` shape.
D="$(new_o b10)"
stub "$D" 'printf "0\n" > "$O/bg/$1.rc"; printf "[worker] hi\n" > "$O/bg/$1.log"; exit 75'
run_sh "$D" 3 3
has "RAN AND ALREADY ENDED" && ck 0 "a POST-launch exit 75 with a worker record AND log bytes is RAN AND ALREADY ENDED" || ck 1 "a POST-launch exit 75 with a worker record AND log bytes is RAN AND ALREADY ENDED"
lacks "refused before launching" && ck 0 "…and it does not claim a refusal the record contradicts" || ck 1 "…and it does not claim a refusal the record contradicts"

# ⛔ THE POSITIVE ROW IS PREFERRED, AND IT IS NOT A TIE (fresh-context review of #3181, 2026-11-02, P2).
# `KIND`/`TAG` are EXPORTED into the worker, so a nested `pi` it starts (a `task` sub-agent) records the
# SAME TAG in the same append-only ledger. When a spawn gate refuses that NESTED call, a `refused` row
# lands AFTER this worker's own `allowed` row — and a reader that checks `refused` first reported, and
# durably recorded, a worker that provably started as "NOT DISPATCHED". The positive row is written only
# when an agent was actually spawned, so it cannot coexist with "nothing ran".
D="$(new_o b11)"
stub "$D" 'printf "1\tallowed\t26\t80\t9\t8\tprfix\t%s\t/tmp\tbash\n" "$1" >> "$HOME/.pi/agent/state/spawn-gate.tsv"
printf "1\trefused\t120\t80\t9\t8\ttask\t%s\t/tmp\tbash\n" "$1" >> "$HOME/.pi/agent/state/spawn-gate.tsv"'
run_sh "$D" 3 3
has "STALL FIX DISPATCHED" && ck 0 "an 'allowed' row WINS over a later 'refused' row for the same TAG (a nested pi refusal cannot un-start this worker)" || ck 1 "an 'allowed' row WINS over a later 'refused' row for the same TAG (a nested pi refusal cannot un-start this worker)"
lacks "NOT DISPATCHED" && ck 0 "…and the worker it provably started is never recorded as NOT DISPATCHED" || ck 1 "…and the worker it provably started is never recorded as NOT DISPATCHED"

echo
echo "── §D the worker's tree is REFRESHED, not frozen at the first stall ──────────────────────────"
# ⛔ (fresh-context review, 2026-11-02) The throwaway worktree was created ONCE and then reused for
# every later dispatch, so a box stalled for days would get `file:line` reports resolved against a
# frozen tree — and a repair lane acts on exactly those reports. Driven on a real repository: the
# worktree is created at commit A, the base moves to B, and a SECOND dispatch must report B.
GR="$TMP/grepo"
git init -q -b main "$GR" >/dev/null 2>&1 || true
gc() { git -C "$GR" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m "$1"; }
gc A >/dev/null 2>&1 || true
git -C "$GR" update-ref refs/remotes/origin/main HEAD >/dev/null 2>&1 || true
SHA_A="$(git -C "$GR" rev-parse --short HEAD 2>/dev/null || true)"
D="$(new_o d1)"; stub "$D" 'printf "1\tallowed\t26\t80\t9\t8\tprfix\t%s\t/tmp\tbash\n" "$1" >> "$HOME/.pi/agent/state/spawn-gate.tsv"'
OUT="$(O="$D" STALL_FIX_WORKTREE="$D/wt2" HARNESS_REPO="$GR" DRAIN_STALL_FIX_EVERY=3 \
       STALL_FIX_VERIFY_SECS=1 bash "$SH" 3 90 2>&1)"
if [ -n "$SHA_A" ]; then
  has "worktree $SHA_A" && ck 0 "the dispatch line names the commit the worker will actually read" || ck 1 "the dispatch line names the commit the worker will actually read"
  gc B >/dev/null 2>&1 || true
  git -C "$GR" update-ref refs/remotes/origin/main HEAD >/dev/null 2>&1 || true
  SHA_B="$(git -C "$GR" rev-parse --short HEAD 2>/dev/null || true)"
  [ -n "$SHA_B" ] && [ "$SHA_A" != "$SHA_B" ]; ck $? "fixture: the base actually advanced (A != B)"
  OUT="$(O="$D" STALL_FIX_WORKTREE="$D/wt2" HARNESS_REPO="$GR" DRAIN_STALL_FIX_EVERY=3 \
         STALL_FIX_VERIFY_SECS=1 bash "$SH" 3 90 2>&1)"
  has "worktree $SHA_B" && ck 0 "a SECOND dispatch reports the NEW base (the worktree is refreshed, not frozen)" || ck 1 "a SECOND dispatch reports the NEW base (the worktree is refreshed, not frozen)"
  lacks "worktree $SHA_A" && ck 0 "…and no longer reports the stale commit" || ck 1 "…and no longer reports the stale commit"
  [ "$(git -C "$D/wt2" rev-parse HEAD 2>/dev/null || true)" = "$(git -C "$GR" rev-parse HEAD 2>/dev/null || true)" ] \
    && ck 0 "…and the worktree's own HEAD is the refreshed base" || ck 1 "…and the worktree's own HEAD is the refreshed base"

  # ⛔ BUT NOT WHILE A WORKER IS STILL READING IT (fresh-context review, 2026-11-02, P2). The refresh
  # fixed a frozen base; a refresh on EVERY dispatch is that defect inverted, because two or three
  # workers overlap by design (one dispatch per ~12 min, worker timeout 1800 s) and they share ONE
  # tree. The brief makes each worker cite `file:line` AT A NAMED COMMIT, so re-pointing the tree
  # mid-run mixes two commits in one report. A live worker (a pid with no terminal `.rc`, which is
  # exactly what the dispatcher writes) must PIN it. Driven with a real process, not a fake file.
  gc C >/dev/null 2>&1 || true
  git -C "$GR" update-ref refs/remotes/origin/main HEAD >/dev/null 2>&1 || true
  SHA_C="$(git -C "$GR" rev-parse --short HEAD 2>/dev/null || true)"
  [ -n "$SHA_C" ] && [ "$SHA_C" != "$SHA_B" ]; ck $? "fixture: the base advanced again (C differs from B)"
  sleep 60 & _live=$!
  printf '%s' "$_live" > "$D/bg/stallfix-20200101T000000Z.pid"
  OUT="$(O="$D" STALL_FIX_WORKTREE="$D/wt2" HARNESS_REPO="$GR" DRAIN_STALL_FIX_EVERY=3 \
         STALL_FIX_VERIFY_SECS=1 bash "$SH" 3 90 2>&1)"
  has "worktree $SHA_B" && ck 0 "a LIVE worker PINS the tree: the dispatch reports the commit it is reading, not the newest" || ck 1 "a LIVE worker PINS the tree: the dispatch reports the commit it is reading, not the newest"
  lacks "worktree $SHA_C" && ck 0 "…and the base was NOT moved under it (no mid-run re-point)" || ck 1 "…and the base was NOT moved under it (no mid-run re-point)"
  [ "$(git -C "$D/wt2" rev-parse HEAD 2>/dev/null || true)" != "$(git -C "$GR" rev-parse HEAD 2>/dev/null || true)" ] \
    && ck 0 "…and the worktree's HEAD is still the one that worker reads" || ck 1 "…and the worktree's HEAD is still the one that worker reads"
  # A TERMINAL record means that worker is done, so the pin must LIFT — otherwise a leaked pid file
  # freezes the tree forever, which is the very defect the refresh exists to remove.
  : > "$D/bg/stallfix-20200101T000000Z.rc"
  OUT="$(O="$D" STALL_FIX_WORKTREE="$D/wt2" HARNESS_REPO="$GR" DRAIN_STALL_FIX_EVERY=3 \
         STALL_FIX_VERIFY_SECS=1 bash "$SH" 3 90 2>&1)"
  has "worktree $SHA_C" && ck 0 "a FINISHED worker lifts the pin: the next dispatch refreshes to the newest base" || ck 1 "a FINISHED worker lifts the pin: the next dispatch refreshes to the newest base"
  # ⛔ AND A PIDFILE TOO OLD TO DESCRIBE A LIVE WORKER LIFTS IT TOO (fresh-context review of #3181,
  # 2026-11-02, P2). `.rc` is written on the dispatcher's exit path — NOT on SIGKILL/OOM/reboot — and no
  # reaper in this tree deletes a `$O/bg/*.pid`, so a stale pidfile can outlive its worker forever; once
  # the kernel recycles that pid, `kill -0` answers yes on EVERY future dispatch and the tree is frozen
  # again, silently. The age bound (`STALL_FIX_PIN_MIN`, 35 min at the default timeout) is the fix, and
  # until this leg it had none: deleting it restored the freeze-forever defect with every suite green.
  # Aged with `touch -t` (an absolute old stamp) so it parses identically on BSD and GNU.
  gc E >/dev/null 2>&1 || true
  git -C "$GR" update-ref refs/remotes/origin/main HEAD >/dev/null 2>&1 || true
  SHA_E="$(git -C "$GR" rev-parse --short HEAD 2>/dev/null || true)"
  [ -n "$SHA_E" ] && [ "$SHA_E" != "$SHA_C" ]; ck $? "fixture: the base advanced again (E differs from C)"
  sleep 60 & _live2=$!
  printf '%s' "$_live2" > "$D/bg/stallfix-20200102T000000Z.pid"
  # `$PIN_OLD` min: OLDER than the liveness pin so it cannot be a live worker's record, but YOUNGER than
  # the 1440-min retention so the prune keeps it — otherwise this leg would measure the prune instead of
  # the pin's age bound.
  touch -t "$(ago_stamp "$PIN_OLD")" "$D/bg/stallfix-20200102T000000Z.pid"
  OUT="$(O="$D" STALL_FIX_WORKTREE="$D/wt2" HARNESS_REPO="$GR" DRAIN_STALL_FIX_EVERY=3 \
         STALL_FIX_VERIFY_SECS=1 bash "$SH" 3 90 2>&1)"
  has "worktree $SHA_E" && ck 0 "an AGED pidfile lifts the pin (a stale pid the kernel recycled cannot freeze the tree forever)" || ck 1 "an AGED pidfile lifts the pin (a stale pid the kernel recycled cannot freeze the tree forever)"
  kill "$_live2" 2>/dev/null || true
  kill "$_live" 2>/dev/null || true
else
  ck 1 "fixture: a git repository could be initialised (the refresh arm cannot be driven without one)"
fi

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
echo "── §E the sinks are BOUNDED — prune and rotation, not two files that grow forever ───────────"
# ⛔ review P3, 2026-11-02: `state/briefs/stall-fix-*.md` (~4 KB each, ~120/day on a stalled box) and
# `state/drain-stall-dispatch.log` (one row per dispatch, forever) were the only two unbounded sinks in
# the harness with no pruner and no rotation — on exactly the population this escalation exists for.
# `pi_gate_ledger` bounds its own write with one-generation rotation ("a device that fills silently is
# the defect #1765 exists for"); these two now do the same.
# ⛔ THE THIRD AND FOURTH SINKS GET LEGS BELOW (fresh-context review, 2026-11-02, P2): this section drove
# the brief prune and the ledger rotation only, so mutating the REPORT prune (or the new `$O/bg` prune)
# to `true` left the suite green — while the script's header, README.md and the heartbeat STALL_TERM
# registry all assert those sinks are bounded. A bound with no leg is a claim, not a guarantee.
D="$(new_o e0)"; stub "$D" "$STUB_OK_TOUCH"
# A brief past the retention bound, spelled with an absolute old date (`touch -t`, not `-d '3 days
# ago'`) so it parses identically on BSD and GNU. A file this script does NOT own sits beside it: the
# prune must be scoped to `stall-fix-*.md`, because another writer may legitimately share the dir.
touch -t 202001010000 "$D/state/briefs/stall-fix-20200101T000000Z.md"
touch -t 202001010000 "$D/state/briefs/keep-me.md"
[ -f "$D/state/briefs/stall-fix-20200101T000000Z.md" ]; ck $? "fixture: a stale brief exists before the run"
run_sh "$D" 3 3
[ ! -f "$D/state/briefs/stall-fix-20200101T000000Z.md" ]; ck $? "a brief older than the retention bound is PRUNED"
[ -f "$D/state/briefs/keep-me.md" ]; ck $? "…and a file this script does not own is left alone"
_nb="$(find "$D/state/briefs" -maxdepth 1 -type f -name 'stall-fix-*.md' 2>/dev/null | wc -l | tr -d ' ')"
[ "$_nb" = "1" ]; ck $? "…and exactly the NEW brief remains (pruned before minting, so the run's own brief survives)"

D="$(new_o e1)"; stub "$D" "$STUB_OK_TOUCH"
# The cap is a module constant, and a test must not be able to lift it — so this writes the REAL cap
# rather than injecting a smaller one. 5 MiB of filler is a single fast write and keeps the assert
# honest about the value the script ships.
dd if=/dev/zero bs=1024 count=5120 2>/dev/null | tr '\0' 'x' > "$D/state/drain-stall-dispatch.log"
_sz0="$(wc -c < "$D/state/drain-stall-dispatch.log" | tr -d ' ')"
[ "$_sz0" -ge 5242880 ]; ck $? "fixture: the ledger is at (or past) the cap before the run ($_sz0 bytes)"
run_sh "$D" 3 3
[ -f "$D/state/drain-stall-dispatch.log.1" ]; ck $? "a ledger at the cap is ROTATED to one .1 generation"
_sz1="$(wc -c < "$D/state/drain-stall-dispatch.log" | tr -d ' ')"
[ "$_sz1" -lt 1000 ]; ck $? "…and the live ledger restarts small ($_sz1 bytes), not at the cap"
grep -q 'stall-fix' "$D/state/drain-stall-dispatch.log" 2>/dev/null; ck $? "…and the row that triggered the rotation is IN the live file, not discarded"

# Non-vacuity — and the two ways this clamp can be defeated (fresh-context review, 2026-11-02). The
# first version of this leg asserted only that the run's own brief existed, which is true in BOTH the
# clamped and unclamped case (the prune runs BEFORE the brief is minted, so the run's own file is
# never at risk). It is rewritten around a brief that sits BETWEEN the two bounds, so each clamp is
# pinned by a file that would actually be lost without it:
#   · `0`     → unclamped, `-mmin +0` evicts everything older than a minute ⇒ the MIDDLE-AGED brief dies.
#   · `abc`   → unclamped, `find -mmin +abc` FAILS and (under `|| true`) prunes nothing ⇒ the OLD brief
#               survives, i.e. the unbounded sink comes back silently. The OLD brief is the probe.
D="$(new_o e2)"; stub "$D" "$STUB_OK_TOUCH"
touch -t 202001010000 "$D/state/briefs/stall-fix-20200101T000000Z.md"   # OLD — must be pruned
touch -d '-2 hours' "$D/state/briefs/stall-fix-MIDDLEAGED.md" 2>/dev/null \
  || touch -t "$(date -u -v-2H '+%Y%m%d%H%M' 2>/dev/null || date -u -d '2 hours ago' '+%Y%m%d%H%M')" "$D/state/briefs/stall-fix-MIDDLEAGED.md"
OUT="$(O="$D" STALL_FIX_WORKTREE="$D/wt" DRAIN_STALL_FIX_EVERY=3 STALL_FIX_VERIFY_SECS=1 \
       STALL_FIX_BRIEF_MAX_AGE_MIN=0 bash "$SH" 3 90 2>&1)"
[ -f "$D/state/briefs/stall-fix-MIDDLEAGED.md" ]; ck $? "STALL_FIX_BRIEF_MAX_AGE_MIN=0 is CLAMPED: a 2h-old brief survives (unclamped it is evicted)"
[ ! -f "$D/state/briefs/stall-fix-20200101T000000Z.md" ]; ck $? "…and the clamped default still prunes a genuinely OLD brief (the clamp is not an off-switch)"

D="$(new_o e3)"; stub "$D" "$STUB_OK_TOUCH"
touch -t 202001010000 "$D/state/briefs/stall-fix-20200101T000000Z.md"
OUT="$(O="$D" STALL_FIX_WORKTREE="$D/wt" DRAIN_STALL_FIX_EVERY=3 STALL_FIX_VERIFY_SECS=1 \
       STALL_FIX_BRIEF_MAX_AGE_MIN=abc bash "$SH" 3 90 2>&1)"
[ ! -f "$D/state/briefs/stall-fix-20200101T000000Z.md" ]; ck $? "a NON-NUMERIC bound falls back to the default and still prunes (unclamped, find fails and prunes NOTHING)"

# ── §E2 the REPORT sink (the largest of the two `state/` files) is BOUNDED, and scoped ────────────
# ⛔ `state/REPORT-stall-fix-<name>.md` is minted by the brief's own FIRST ACTION on the same cadence as
# the brief, and NOTHING else in the tree reaps it. Deleting its prune left every assertion above green.
D="$(new_o e4)"; stub "$D" "$STUB_OK_TOUCH"
touch -t 202001010000 "$D/state/REPORT-stall-fix-stallfix-20200101T000000Z.md"
touch -t 202001010000 "$D/state/keep-me.txt"
[ -f "$D/state/REPORT-stall-fix-stallfix-20200101T000000Z.md" ]; ck $? "fixture: a stale worker REPORT exists before the run"
run_sh "$D" 3 3
[ ! -f "$D/state/REPORT-stall-fix-stallfix-20200101T000000Z.md" ]; ck $? "a REPORT older than the retention bound is PRUNED (the largest state/ sink is bounded, not merely named)"
[ -f "$D/state/keep-me.txt" ]; ck $? "…and a file this script does not own beside it is left alone"

# ── §E3 the WORKER TRANSCRIPT sink (`$O/bg/stallfix-*`) is BOUNDED, and scoped ────────────────────
# ⛔ The whole `run_agent` transcript plus its record files are minted per dispatch and `$O/bg` has no
# reaper at all (this script's own `wt_in_use` note says so). At ~120 dispatches/day this is the biggest
# artifact this escalation creates, so it is the one that most needs a leg of its own.
D="$(new_o e5)"; stub "$D" "$STUB_OK_TOUCH"; mkdir -p "$D/bg"
touch -t 202001010000 "$D/bg/stallfix-20200101T000000Z.log"
touch -t 202001010000 "$D/bg/lanefix-20200101T000000Z.log"
run_sh "$D" 3 3
[ ! -f "$D/bg/stallfix-20200101T000000Z.log" ]; ck $? "a stale worker transcript THIS script minted is PRUNED (the fourth sink is bounded)"
[ -f "$D/bg/lanefix-20200101T000000Z.log" ]; ck $? "…and ANOTHER lane's transcript is never touched (deleting one would be the defect, not the fix)"

# ── §E4 the RETENTION FLOOR: the prune can never evict a LIVE worker's own records ───────────────
# ⛔ THE PRUNE AND THE LIVENESS PIN (`STALL_FIX_PIN_MIN`) ARE TWO INDEPENDENT BOUNDS, AND THEIR DEFAULT
# ORDER IS ACCIDENTAL
# (fresh-context review of #3181, 2026-11-02, P1). The pin is `(DRAIN_STALL_FIX_TIMEOUT + 300)/60` = 35
# min; the retention knob is accepted down to `1`. Set it below the pin and the `$O/bg` prune deletes the
# LIVE worker's own `.pid` — after which `wt_in_use` finds no pidfile and the `else` arm re-points the
# worktree under a worker that is still reading it, so the report it is writing cites `file:line` at two
# commits. That is the exact defect the pin exists to prevent, reached from the other side. The floor is
# driven here at the only shape that can reach it: a knob BELOW the pin, over a pidfile young enough to
# be live. Delete the floor and this leg reddens.
D="$(new_o e6)"; stub "$D" "$STUB_OK_TOUCH"
sleep 60 & _live3=$!
printf '%s' "$_live3" > "$D/bg/stallfix-live.pid"
# `$PIN_YOUNG` min: OLDER than the `STALL_FIX_BRIEF_MAX_AGE_MIN=5` this leg sets, but YOUNGER than the pin
# the floor raises it to — so with the floor the record survives, and without it the prune takes the
# `.pid` of a worker that is still running.
touch -t "$(ago_stamp "$PIN_YOUNG")" "$D/bg/stallfix-live.pid"
[ -f "$D/bg/stallfix-live.pid" ]; ck $? "fixture: a LIVE worker's pidfile exists before the run"
OUT="$(O="$D" STALL_FIX_WORKTREE="$D/wt" DRAIN_STALL_FIX_EVERY=3 STALL_FIX_VERIFY_SECS=1 \
       STALL_FIX_BRIEF_MAX_AGE_MIN=5 bash "$SH" 3 90 2>&1)"
[ -f "$D/bg/stallfix-live.pid" ]; ck $? "a retention knob BELOW the worker's own wall clock cannot prune a LIVE worker's record (the floor holds)"
# …and the knob still bounds what it is FOR: with the floor in place, a transcript older than the PIN is
# still evicted — the floor raises the bound, it is not an off-switch for the prune.
touch -t 202001010000 "$D/bg/stallfix-old.log"
OUT="$(O="$D" STALL_FIX_WORKTREE="$D/wt" DRAIN_STALL_FIX_EVERY=3 STALL_FIX_VERIFY_SECS=1 \
       STALL_FIX_BRIEF_MAX_AGE_MIN=5 bash "$SH" 3 90 2>&1)"
[ ! -f "$D/bg/stallfix-old.log" ]; ck $? "…and a transcript older than the FLOOR is still pruned (the floor is a floor, not an off-switch)"
kill "$_live3" 2>/dev/null || true


echo
echo "── §F the age's PROVENANCE reaches both sinks this script owns ────────────────────────────"
# ⛔ THE THIRD PROVENANCE (fresh-context review of #3181, 2026-11-02, P1). `orch-loop.sh` passes
# `_AGESRC` beside the age because the age is not always a measurement: `synth` is the WINDOW BOUND an
# empty `mp_recent_land` answer proves, and `unmeasured` is the window that could NOT BE SEARCHED
# (a missing/unreadable `state/`). Both sinks this script owns — the brief's premise line, and the
# `age_min=/agesrc=` ledger row an operator reads after an incident — must say which one they got,
# because a worker quotes the premise back in its report and the ledger is the durable record.
# The pre-fix `case` accepted only `synth|measured` and silently rewrote `unmeasured` to `measured`,
# which asserted a reading this box never took on BOTH surfaces.
#
# ⛔ THIS BLOCK PINS THE CONSUMER ONLY — THE PRODUCER IS PINNED IN `pr-dispatch.test.sh` (fresh-context
# review of #3380, 2026-11-05, P2). `_AGESRC` is supplied by these legs and `f1` relies on the
# `-measured` default, so on its own this block cannot see the OTHER half of the interface: delete
# `_AGESRC="${_agesrc:-measured}"` from `orch-loop.sh`'s call and this suite stays green while every
# real dispatch falls back to `measured` — the #3181 P1, restored, with nothing red. The legs there
# record the provenance the fixer was actually HANDED (`1|measured`, `1|synth`, `1|unmeasured`), so an
# interface is now pinned at both ends. One caveat a maintainer must not have to discover: the
# `unmeasured` producer leg needs an unreadable-but-writable `state/`, so it is reported
# UNPROVEN-ON(root) rather than counted there — on a root host only two of the three are pinned.
#
# ⛔ THIS NOTE CITES CODE BY NAME, NEVER BY LINE NUMBER (review cycles 2 and 3 of #3181, 2026-11-03).
# Two cycles in a row found a pointer here that had silently gone stale: every edit ABOVE a cited line
# shifts it, so a maintainer who follows the number lands on a comment or a blank line, mutates
# nothing, sees every arm stay green, and concludes §F is vacuous when it is not. The §B verdict arms
# (`b1`/`b2`) are NOT involved in any mutation below — a pointer there is what produced that earlier
# false conclusion.
#
# MUTATIONS, MEASURED AT THIS HEAD — each named by the rule it breaks, not by a line to edit. The
# counts are re-measured whenever a leg is ADDED, because they go stale the moment the suite grows: an
# earlier revision of this note still said "81 passed, 3 failed" after `f5` existed (measured at that
# head: 5 failed, not 3), and the pass count happened to stay 81 because it is `86 - failures`.
#   · the `*)` arm of the age-provenance `case` back to `AGESRC=measured`
#       → 81 passed, 5 failed: all three of `f4`'s asserts AND both of `f5`'s;
#   · the `unmeasured)` arm of the brief-text `case` replaced by the bare `$AGEMIN`
#       → 82 passed, 4 failed: `f3`'s premise pair, `f4`'s premise assert AND `f5`'s;
#   · the `synth)` arm of the brief-text `case` replaced by the bare `$AGEMIN`
#       → 85 passed, 1 failed: `f2`'s premise assert.
#
# AND ONE DELIBERATE NO-OP, stated so it is not mistaken for vacuity: deleting the `unmeasured`
# alternative from the ACCEPT LIST alone changes NOTHING (86 passed, 0 failed), because the `*)` arm
# already maps every non-accepted value to `unmeasured`. The accept list NAMES the vocabulary; the
# `*)` arm is the GUARANTEE. Use one of the three mutations above to prove §F discriminates.
brief_of() { cat "$1"/state/briefs/stall-fix-*.md 2>/dev/null || true; }

D="$(new_o f1)"; stub "$D" "$STUB_OK_TOUCH"
run_sh "$D" 3 3
case "$(brief_of "$D")" in *"no PR merged in 90 minutes"*) ck 0 "measured: the brief states the age as a measurement (unchanged)" ;; *) ck 1 "measured: the brief states the age as a measurement (unchanged): $(brief_of "$D" | head -20 | tail -6)" ;; esac
case "$(ledger_of "$D")" in *"age_min=90	agesrc=measured"*) ck 0 "…and the durable row says agesrc=measured" ;; *) ck 1 "…and the durable row says agesrc=measured: $(ledger_of "$D")" ;; esac

D="$(new_o f2)"; stub "$D" "$STUB_OK_TOUCH"
OUT="$(O="$D" STALL_FIX_WORKTREE="$D/wt" DRAIN_STALL_FIX_EVERY=3 STALL_FIX_VERIFY_SECS=1 \
       _AGESRC=synth bash "$SH" 3 90 2>&1)"
case "$(brief_of "$D")" in *"no PR merged in >=90 minutes"*) ck 0 "synth: the brief renders the age as a BOUND, not a measurement" ;; *) ck 1 "synth: the brief renders the age as a BOUND, not a measurement: $(brief_of "$D" | head -20 | tail -6)" ;; esac
case "$(ledger_of "$D")" in *"age_min=90	agesrc=synth"*) ck 0 "…and the durable row says agesrc=synth" ;; *) ck 1 "…and the durable row says agesrc=synth: $(ledger_of "$D")" ;; esac

D="$(new_o f3)"; stub "$D" "$STUB_OK_TOUCH"
OUT="$(O="$D" STALL_FIX_WORKTREE="$D/wt" DRAIN_STALL_FIX_EVERY=3 STALL_FIX_VERIFY_SECS=1 \
       _AGESRC=unmeasured bash "$SH" 3 90 2>&1)"
case "$(brief_of "$D")" in *"no PR merged in an UNMEASURED number of minutes"*) ck 0 "unmeasured: the brief says the age was NOT taken" ;; *) ck 1 "unmeasured: the brief says the age was NOT taken: $(brief_of "$D" | head -20 | tail -6)" ;; esac
case "$(brief_of "$D")" in *"no PR merged in 90 minutes"*) ck 1 "…and it never presents the window that could not be searched as the stall age" ;; *) ck 0 "…and it never presents the window that could not be searched as the stall age" ;; esac
case "$(ledger_of "$D")" in *"age_min=90	agesrc=unmeasured"*) ck 0 "…and the durable row keeps agesrc=unmeasured verbatim (the P1 fix)" ;; *) ck 1 "…and the durable row keeps agesrc=unmeasured verbatim (the P1 fix): $(ledger_of "$D")" ;; esac
case "$(ledger_of "$D")" in *"agesrc=measured"*) ck 1 "…and it is NOT rewritten to agesrc=measured (the pre-fix shape)" ;; *) ck 0 "…and it is NOT rewritten to agesrc=measured (the pre-fix shape)" ;; esac

# ⛔ AN UNRECOGNISED PROVENANCE IS NOT `measured` (review cycle 2, 2026-11-03, P2). Unset is handled by
# the `-measured` default, so only a value the caller SUPPLIED can reach the `*)` arm. Before the fix
# that arm wrote `measured`, so `_AGESRC=<anything unknown>` put "no PR merged in 90 minutes" in the
# worker's premise and `agesrc=measured` in the ledger — the same false measurement, reachable by a
# fourth provenance. Set the `*)` arm back to `measured` and all FIVE asserts below redden
# (measured: 81 passed, 5 failed — these three AND `f5`'s two).
D="$(new_o f4)"; stub "$D" "$STUB_OK_TOUCH"
OUT="$(O="$D" STALL_FIX_WORKTREE="$D/wt" DRAIN_STALL_FIX_EVERY=3 STALL_FIX_VERIFY_SECS=1 \
       _AGESRC=banana bash "$SH" 3 90 2>&1)"
case "$(brief_of "$D")" in *"no PR merged in an UNMEASURED number of minutes"*) ck 0 "unrecognised: the brief does NOT claim a measurement it was never given" ;; *) ck 1 "unrecognised: the brief does NOT claim a measurement it was never given: $(brief_of "$D" | head -20 | tail -6)" ;; esac
case "$(ledger_of "$D")" in *"agesrc=measured"*) ck 1 "…and the durable row does not assert agesrc=measured for a value it did not understand: $(ledger_of "$D")" ;; *) ck 0 "…and the durable row does not assert agesrc=measured for a value it did not understand" ;; esac
case "$(ledger_of "$D")" in *"agesrc=unmeasured"*) ck 0 "…it degrades to agesrc=unmeasured (the value that says no reading was taken)" ;; *) ck 1 "…it degrades to agesrc=unmeasured (the value that says no reading was taken): $(ledger_of "$D")" ;; esac

# ⛔ A PRESENT-BUT-**EMPTY** VALUE IS NOT AN ABSENT ONE (review cycle 3 of #3380, 2026-11-05, P3).
# `:-measured` substitutes on empty as well as unset, so `_AGESRC=` — the "typo'd caller" shape the
# `*)` arm exists for — was read as `measured` and put "no PR merged in 90 minutes" in the premise and
# `agesrc=measured` in the ledger, byte-identical to an unset variable. The default is `-measured`, so
# only an ABSENT variable keeps its old shape; a caller that supplied an empty value is a caller this
# script did not understand, and that degrades like any other unrecognised value. Set the default back
# to `:-measured` and this leg reddens.
D="$(new_o f5)"; stub "$D" "$STUB_OK_TOUCH"
OUT="$(O="$D" STALL_FIX_WORKTREE="$D/wt" DRAIN_STALL_FIX_EVERY=3 STALL_FIX_VERIFY_SECS=1 \
       _AGESRC= bash "$SH" 3 90 2>&1)"
case "$(brief_of "$D")" in *"no PR merged in an UNMEASURED number of minutes"*) ck 0 "empty: a PRESENT-BUT-EMPTY provenance is NOT read as the default measurement" ;; *) ck 1 "empty: a PRESENT-BUT-EMPTY provenance is NOT read as the default measurement: $(brief_of "$D" | head -20 | tail -6)" ;; esac
case "$(ledger_of "$D")" in *"agesrc=measured"*) ck 1 "…and the ledger row does not claim a measurement for an empty value: $(ledger_of "$D")" ;; *) ck 0 "…and the ledger row does not claim a measurement for an empty value" ;; esac


echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
