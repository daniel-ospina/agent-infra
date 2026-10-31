#!/usr/bin/env bash
# pr-owner-liveness.test.sh — DRIVES pr-owner-liveness.sh against REAL processes and REAL lock files.
#
# agent-infra#2831. Three cases, and each is a NEGATIVE CONTROL for the others:
#   (a) a PR whose lock pid is DEAD is RE-TAKEN: verdict RELEASED, and the stale lock is gone from
#       disk — so the next pass can spawn. (Non-vacuous: the same fixture with a LIVE worker on the
#       same lock reads OWNED, so the test cannot pass by always releasing.)
#   (b) a box with un-owned PRs and ZERO PR spawns for N cycles OPENS the issue path and RECORDS why:
#       the streak advances per measured-zero pass, the escape fires at the bound, the record lands,
#       and the streak resets so it cannot spin. (Non-vacuous: the same loop with one spawn resets to
#       0 and never escapes; an UNMEASURED pass never advances; an unreadable un-owned count never
#       escapes.)
#   (c) a PR whose worker is ALIVE is STILL RESPECTED: verdict OWNED and the lock is NOT removed.
#       (Non-vacuous: the pid is ALIVE in this case, so the dead-pid arm cannot be what answers.)
#
# ⛔ Hermetic: temp dirs, real short-lived processes, no network, no tmux/cmux.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
MOD="$HERE/pr-owner-liveness.sh"
[ -f "$MOD" ] || { echo "❌ module not found: $MOD"; exit 2; }
# shellcheck source=/dev/null
. "$MOD"

FAIL=0
PASS=0
ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [assert: $2]"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pl.XXXXXX")" || exit 2
PIDS=""
cleanup() {
  local p
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

# A worker that IS a live merge worker for <pr>, in the exact two shipped spawn forms.
spawn_worker() { # <pr> -> pid on stdout
  local pr="$1" p
  # ⛔ NO `exec`, AND A TRAILING `; :` (both load-bearing): bash EXECS a `-c` body that is a single
  # command, so the cmdline became `sleep 300` and the matcher (correctly) refused it. The real spawn
  # keeps `merge-one.sh --argv state/argv-<PR>` in the cmdline, which is one of the two shipped forms.
  bash -c 'sleep 300; :' merge-one.sh --argv "state/argv-$pr" >/dev/null 2>&1 &
  p=$!
  PIDS="$PIDS $p"
  printf '%s\n' "$p"
}
# A live process that is NOT a merge worker for this PR (pid recycling: the record outlives the worker).
spawn_unrelated() {
  local p
  bash -c 'sleep 300' some-unrelated-daemon 999 >/dev/null 2>&1 &
  p=$!
  PIDS="$PIDS $p"
  printf '%s\n' "$p"
}
dead_pid() {
  local p
  bash -c 'exit 0' & p=$!
  wait "$p" 2>/dev/null || true
  printf '%s\n' "$p"
}
wait_pid_gone() { local p="$1" i=0; while pl_pid_alive "$p" && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done; }

echo "pr-owner-liveness.test.sh — agent-infra#2831"

# ─────────────────────────────────────────────────────────────────────────────────────────────
echo "(a) a PR owned by a DEAD pid is re-taken"
A="$TMP/a"; mkdir -p "$A"
DP="$(dead_pid)"; wait_pid_gone "$DP"
printf '%s\n' "$DP" > "$(pl_lock_path "$A" 4242)"
check "fixture: the recorded pid is really gone" "! pl_pid_alive '$DP'"
OUT="$(pl_verdict "$A" 4242 1 1)"; RC=$?
check "(a) verdict is RELEASED"            "[ $RC -eq 1 ] && case \"\$OUT\" in RELEASED*) true ;; *) false ;; esac"
check "(a) the reason names the dead pid"  "case \"\$OUT\" in *\"pid $DP is GONE\"*) true ;; *) false ;; esac"
check "(a) the stale lock was REMOVED"     "[ ! -e '$(pl_lock_path "$A" 4242)' ]"
# ⛔ NON-VACUITY: the same fixture with an ALIVE worker on the same lock must read OWNED — otherwise
# this arm would pass by releasing everything.
B="$TMP/b"; mkdir -p "$B"
WP="$(spawn_worker 4242)"; sleep 0.2
printf '%s\n' "$WP" > "$(pl_lock_path "$B" 4242)"
check "fixture: the worker pid is alive"   "pl_pid_alive '$WP'"
OUT="$(pl_verdict "$B" 4242 1 1)"; RC=$?
check "(a-control) the same lock with a LIVE worker reads OWNED (so (a) is not vacuous)" "[ $RC -eq 0 ] && [ -e '$(pl_lock_path "$B" 4242)' ]"

echo "(a2) a LIVE pid is never reaped — even an unrelated one (#1985 residue, the safe direction)"
# ⛔ THIS ARM WAS INVERTED BY REVIEW (P0, 2026-10-25) AND THE INVERSION WAS THE HARD-RULE BREACH. Three
# roles write `mergeclaim-<PR>.lock` (`merge-one.sh`, `fix-one.sh` — held for a fixer's whole run — and
# `cloud-cell-doctor.sh`), so "the pid is not a merge-one.sh" is NOT evidence of a recycled pid: keying
# on it reaped LIVE fixers and let a second worker push to the same branch. Whatever is alive stays.
C="$TMP/c"; mkdir -p "$C"
RP="$(spawn_unrelated)"; sleep 0.2
printf '%s\n' "$RP" > "$(pl_lock_path "$C" 5151)"
check "fixture: the unrelated pid IS alive"  "pl_pid_alive '$RP'"
OUT="$(pl_verdict "$C" 5151 1 1)"; RC=$?
check "(a2) a LIVE pid reads OWNED (never reaped)"    "[ $RC -eq 0 ] && case \"\$OUT\" in OWNED*) true ;; *) false ;; esac"
check "(a2) the reason says WHY it is not judged"    "case \"\$OUT\" in *'#1985'*) true ;; *) false ;; esac"
check "(a2) the live lock is KEPT"                   "[ -e '$(pl_lock_path "$C" 5151)' ]"
# ⛔ AND THE CREATION WINDOW: `merge-one.sh` claims with `noclobber; echo $$ > LOCK`, so the file exists
# EMPTY for an instant. An empty lock is a claim IN PROGRESS, not a dead owner (fix-one.sh documents the
# same hole). Reaping it deletes a live lander's claim.
D="$TMP/d"; mkdir -p "$D"
: > "$(pl_lock_path "$D" 6161)"
OUT="$(pl_verdict "$D" 6161 1 1)"; RC=$?
check "(a3) an EMPTY lock (claim mid-creation) reads OWNED" "[ $RC -eq 0 ] && case \"\$OUT\" in *'mid-creation'*) true ;; *) false ;; esac"
check "(a3) …and the mid-create lock is NOT removed"       "[ -e '$(pl_lock_path "$D" 6161)' ]"

# ⛔ (a4) AN ORPHANED RECORD — one that names NO owner and has OUTLIVED any possible create window — is
# ABANDONED, not mid-creation (agent-infra#3096, review P1-1). `merge-one.sh` creates the record and
# writes its pid in two steps, so an EMPTY record is a claim IN PROGRESS for as long as that window can
# last, which is microseconds. Past it the state is a MEASUREMENT, and it must not read OWNED for ever:
# the controller asks this verdict BEFORE each of its five fixer/rail spawn arms (`pr_owner_live`,
# `orch-loop.sh:3150`), so answering OWNED for a 21-hour-old 0-byte record spawns NOTHING — while
# `pr_owned`, which needs a pid > 0, counts the same PR UN-owned and holds the issue path shut. One
# state, two opposite verdicts, zero lanes: measured on three cells, records 1278-2314 minutes old, and
# the fixer arm that reclaims them could never be reached (review of #3096, P1-1).
# The alternative that must never happen is reclaiming on EMPTINESS ALONE, which deletes a live
# lander's claim. (a3) and (a4) use the SAME BYTES and the SAME CALL and differ only in the record's
# age, so the pair pins that AGE is what is measured — and that the content alone never decides.
O="$TMP/orphan"; mkdir -p "$O"
OLK="$(pl_lock_path "$O" 7171)"
: > "$OLK"; touch -t 202001010000 "$OLK" 2>/dev/null
[ -n "$(find "$OLK" -maxdepth 0 -mmin +2 2>/dev/null)" ]; rc=$?
check "(a4) the fixture really is an OLD record (mtime aged past the grace, or the arm below is vacuous)" "[ $rc -eq 0 ]"
OUT="$(pl_verdict "$O" 7171 1 1)"; RC=$?
check "(a4) an empty record PAST the create window is ABANDONED — RELEASED, not 'never reaped'" \
  "[ $RC -eq 1 ] && case \"\$OUT\" in RELEASED*'named NO owner'*ABANDONED*) true ;; *) false ;; esac"
check "(a4) …and the abandoned record is REMOVED, so the PR is genuinely spawnable" "[ ! -e '$OLK' ]"
# The deliberate NARROWING, and the arm that would otherwise be a fail-open: a body that is NOT empty is a
# claim with real content in it, and "nothing was ever written here" is not provable from it. It stays LIVE.
: > "$OLK"; printf 'not-a-pid\n' > "$OLK"; touch -t 202001010000 "$OLK" 2>/dev/null
OUT="$(pl_verdict "$O" 7171 1 1)"; RC=$?
check "(a4b) a NON-empty unparseable record stays LIVE (content alone never proves abandonment)" \
  "[ $RC -eq 0 ] && case \"\$OUT\" in OWNED*) true ;; *) false ;; esac"
check "(a4b) …and it is KEPT" "[ -e '$OLK' ]"
# A peer's LIVE claim is never displaced, however the age reads: the pid arm runs first and returns OWNED.
printf '%s\n' "$$" > "$OLK"; touch -t 202001010000 "$OLK" 2>/dev/null
OUT="$(pl_verdict "$O" 7171 1 1)"; RC=$?
check "(a4c) an OLD record naming a LIVE pid is OWNED and kept (age never overrides a measured owner)" \
  "[ $RC -eq 0 ] && [ -e '$OLK' ]"
rm -f "$OLK"
# ⛔ (a4d) THE WORKER RECORD OUTRANKS THE LOCK, AND THIS ARM DELETES FILES (review of #3096, P2-1). A lock
# is the WEAKEST proof this module accepts; the dead-pid arm deliberately declines to answer and falls
# through to the worker-record step for exactly that reason. An arm that REMOVES the record must not run
# ahead of it, or it deletes the lock a live worker's census row still proves is held.
: > "$OLK"; touch -t 202001010000 "$OLK" 2>/dev/null
OUT="$(pl_verdict "$O" 7171 1 0)"; RC=$?
check "(a4d) a LIVE worker record keeps an aged empty lock OWNED (the reap never outranks a measured worker)" \
  "[ $RC -eq 0 ] && case \"\$OUT\" in *'live worker record'*) true ;; *) false ;; esac"
check "(a4d) …and the lock is KEPT — deleting a live worker's lock is the one outcome this module bans" \
  "[ -e '$OLK' ]"
rm -f "$OLK"
# ⛔ (a4e/a4f) THE RACE OUTCOMES HAVE THEIR OWN SENTENCES, AND EACH MUST BE REACHABLE (review P2-4: 18
# lines that no shard could see go red). `pl_reap_no_owner` calls `mv` and `ln` UNQUALIFIED on purpose, so
# a function of that name drives the exact instant: `mv` still detaches (the race is real, not simulated)
# and the detached record then carries a PEER's pid.
: > "$OLK"; touch -t 202001010000 "$OLK" 2>/dev/null
OUT="$( mv() { command mv "$@"; printf '%s\n' "$$" > "$OLK.reclaim.$$"; }; pl_verdict "$O" 7171 1 1 )"; RC=$?
check "(a4e) a peer that claims during the reclaim is PUT BACK and reported as OWNED (rc=$RC)" \
  "[ $RC -eq 0 ] && case \"\$OUT\" in *'PEER claimed it in the instant'*) true ;; *) false ;; esac"
check "(a4e) …and the restored claim is readable AT THE PATH again, not merely ln-succeeded" \
  "[ -f '$OLK' ] && [ -n \"\$(cat '$OLK' 2>/dev/null)\" ]"
: > "$OLK"; touch -t 202001010000 "$OLK" 2>/dev/null
OUT="$( mv() { command mv "$@"; printf '%s\n' "$$" > "$OLK.reclaim.$$"; }; ln() { return 1; }; pl_verdict "$O" 7171 1 1 )"; RC=$?
check "(a4f) a claim that could NOT be put back is reported as LOST, not as 'nothing was deleted' (rc=$RC)" \
  "[ $RC -eq 0 ] && case \"\$OUT\" in *'could NOT be put back'*) true ;; *) false ;; esac"
check "(a4f) …and it does NOT claim the peer still holds it" \
  "case \"\$OUT\" in *'peer holds it'*) false ;; *) true ;; esac"
# The detach itself failing must NOT invent a peer: a `mv` that fails leaves the record on disk, unchanged.
: > "$OLK"; touch -t 202001010000 "$OLK" 2>/dev/null
OUT="$( mv() { return 1; }; pl_verdict "$O" 7171 1 1 )"; RC=$?
check "(a4g) a reclaim that could not detach says so, and does NOT assert a cause it never measured (rc=$RC)" \
  "[ $RC -eq 0 ] && case \"\$OUT\" in *'could NOT be detached'*) true ;; *) false ;; esac && case \"\$OUT\" in *'unwritable'*) false ;; *) true ;; esac"
check "(a4g) …and the abandoned record is still on disk, unchanged" "[ -e '$OLK' ]"
rm -f "$OLK"
# ⛔ THE GUARDS THAT MAKE A `rm`-BEARING ARM SAFE (review of #3096, P3-4). Each of these was measured as
# UNDISCRIMINATED: deleting the guard left both suites green. They fail closed, so the risk is not worse
# behaviour, it is a silent regression in the arm that deletes files.
# 1. A SYMLINK is not a record: `[ -f ]` follows it, so a `rm` would delete the TARGET.
: > "$OLK"; touch -t 202001010000 "$OLK" 2>/dev/null
OLLINK="$TMP/orphan-link.lock"; rm -f "$OLLINK"; ln -s "$OLK" "$OLLINK" 2>/dev/null
check "(a4h) a symlinked record is NOT admitted (content alone is not the record's own — `rm` would hit the target)" \
  "! pl_record_no_owner '$OLLINK' >/dev/null"
OUT="$( pl_reap_no_owner "$TMP" orphan-link >/dev/null 2>&1; printf '%s' ok )"
check "(a4h) …and the reap refuses it, leaving the target intact" "[ -e '$OLK' ]"
rm -f "$OLLINK" "$OLK"
# 2. a WHITESPACE-ONLY body is no owner, and is admitted (the module side of the fix-one '   \n' fixture).
: > "$OLK"; printf '   \n' > "$OLK"; touch -t 202001010000 "$OLK" 2>/dev/null
OUT="$(pl_verdict "$O" 7171 1 1)"; RC=$?
check "(a4i) an AGED whitespace-only record is RELEASED (the module half of the shape fix-one reclaims)" \
  "[ $RC -eq 1 ] && case \"\$OUT\" in RELEASED*) true ;; *) false ;; esac"
check "(a4i) …and it is REMOVED" "[ ! -e '$OLK' ]"
# 3. an UNREADABLE record is not evidence of anything — no `|| echo 0` shortcut, and never reaped.
: > "$OLK"; printf '\n' > "$OLK"; touch -t 202001010000 "$OLK" 2>/dev/null; chmod 000 "$OLK" 2>/dev/null
if [ ! -r "$OLK" ]; then
  OUT="$(pl_verdict "$O" 7171 1 1)"; RC=$?
  check "(a4j) an UNREADABLE aged record is not reclaimed — what cannot be read is not evidence (rc=$RC)" \
    "[ $RC -eq 0 ] && [ -e '$OLK' ]"
  chmod 600 "$OLK" 2>/dev/null
else
  printf '  (skipped) cannot make a file unreadable here — chmod 000 had no effect (root?)\n'
fi
rm -f "$OLK"

# ─────────────────────────────────────────────────────────────────────────────────────────────
echo "(c) a PR whose worker is ALIVE is still respected"
OUT="$(pl_verdict "$B" 4242 1 1)"; RC=$?
check "(c) verdict is OWNED"                 "[ $RC -eq 0 ] && case \"\$OUT\" in OWNED*) true ;; *) false ;; esac"
check "(c) the reason names the live worker pid" "case \"\$OUT\" in *\"lock pid $WP\"*) true ;; *) false ;; esac"
check "(c) the live worker's lock is KEPT"   "[ -e '$(pl_lock_path "$B" 4242)' ]"
# The external live fact (cwd scan / cross-box lease) and the worker record are each sufficient alone:
OUT="$(pl_verdict "$TMP/c" 5151 0 1)"; RC=$?
check "(c) a live cwd/lease fact alone reads OWNED even with no lock" "[ $RC -eq 0 ]"
OUT="$(pl_verdict "$TMP/c" 5151 1 0)"; RC=$?
check "(c) a live worker RECORD alone reads OWNED"                    "[ $RC -eq 0 ]"
# ⛔ NON-VACUITY for the respect arm: with EVERY proof removed (a fresh state dir: no lock, no cwd
# fact, no worker record) the verdict is RELEASED. The SAME call shape as above, so the only difference
# is the evidence — not the arguments.
Z="$TMP/c-control"; mkdir -p "$Z"
OUT="$(pl_verdict "$Z" 5151 1 1)"; RC=$?
check "(c-control) with no proof at all it is RELEASED (so (c) is not vacuous)" "[ $RC -eq 1 ]"

# ─────────────────────────────────────────────────────────────────────────────────────────────
echo "(b) un-owned PRs + ZERO PR spawns for N cycles OPENS the issue path and records why"
E="$TMP/e"; mkdir -p "$E"
BOUND=3
check "(b) at pass 0 the escape is closed"  "! pl_escape_open '$E' 3 '$BOUND'"
S1="$(pl_note_pass "$E" 0 3)"
S2="$(pl_note_pass "$E" 0 3)"
check "(b) a measured zero advances the streak" "[ '$S1' = 1 ] && [ '$S2' = 2 ]"
check "(b) at the bound-1 the escape is still closed" "! pl_escape_open '$E' 3 '$BOUND'"
S3="$(pl_note_pass "$E" 0 3)"
check "(b) the third inert pass reaches the bound" "[ '$S3' = 3 ]"
check "(b) the escape OPENS the issue path at the bound" "pl_escape_open '$E' 3 '$BOUND'"
LINE="$(pl_escape_line "$E" 3 "$BOUND")"
check "(b) the line names the counts"        "case \"\$LINE\" in *'3 consecutive'*'3 un-owned'*) true ;; *) false ;; esac"
check "(b) the line names the bound"         "case \"\$LINE\" in *'bound 3'*) true ;; *) false ;; esac"
check "(b) the line names the issue"         "case \"\$LINE\" in *'agent-infra#2831'*) true ;; *) false ;; esac"
check "(b) the record LANDS"                 "pl_escape_record '$E' 3 0"
check "(b) the record says WHY"              "grep -q '^issue=OPENED-BY-ESCAPE' '$E/drain-escape' && grep -q '^streak=3' '$E/drain-escape' && grep -q '^bound=3' '$E/drain-escape'"
check "(b) the streak RESETS after the escape (bounded, cannot spin)" "! pl_escape_open '$E' 3 '$BOUND' && [ \"\$(pl_idle_streak '$E')\" = 0 ]"
# ⛔ NON-VACUITY: the same loop with only ONE spawn never escapes, and a spawn resets the streak.
F="$TMP/f"; mkdir -p "$F"
pl_note_pass "$F" 0 3 >/dev/null; pl_note_pass "$F" 0 3 >/dev/null
check "fixture: the second box reached streak 2" "[ \"\$(pl_idle_streak '$F')\" = 2 ]"
check "(b-control) one spawned worker RESETS the streak" "[ \"\$(pl_note_pass '$F' 1 3)\" = 0 ] && [ \"\$(pl_idle_streak '$F')\" = 0 ]"
pl_note_pass "$F" 0 3 >/dev/null; pl_note_pass "$F" 0 3 >/dev/null
check "(b-control) a working PR path never reaches the bound" "! pl_escape_open '$F' 3 5"
G="$TMP/g"; mkdir -p "$G"
for _ in 1 2 3 4 5; do pl_note_pass "$G" '' 3 >/dev/null; done
check "(b-control) an UNMEASURED spawn count never advances (nor invents) the streak" "[ \"\$(pl_idle_streak '$G')\" = 0 ] && ! pl_escape_open '$G' 3 '$BOUND'"
H="$TMP/h"; mkdir -p "$H"
for _ in 1 2 3 4 5; do pl_note_pass "$H" 0 '' >/dev/null; done
check "(b-control) an UNREADABLE un-owned count never opens the issue path" "! pl_escape_open '$H' '' '$BOUND'"
check "(b-control) the bound cannot be zero (a zero bound would fire on a healthy box)" "[ \"\$(pl_escape_bound 0)\" = 3 ]"


# ─────────────────────────────────────────────────────────────────────────────────────────────
# (b-WIRED) the SHIPPED escape block, driven VERBATIM out of orch-loop.sh. The module decisions above
# are worth nothing if the loop never reaches them or never applies the verdict: this drives the real
# `[drain-escape:begin/end]` text in a subshell with `LO_CHOICE=pr`, so a wiring that computes the
# escape and then leaves the issue path shut goes RED here (and a block that opens it on a healthy
# box — streak below the bound — goes RED on the contrast half).
echo "(b-wired) the shipped [drain-escape] block, extracted and DRIVEN"
LOOP="$HERE/orch-loop.sh"
EXTRACT="$TMP/escape-block.sh"
# The block, PLUS the two gate lines it must un-block (the `LO_CHOICE != issue` reason, and the
# `[ -z "$GATE_WHY" ]` body entry). The body's first statement is replaced by a sentinel write so the
# assertion is "dispatch was ENTERED", not "a line was printed".
awk '/^  # \[drain-escape:begin\]/{f=1} f{print} /^  # \[drain-escape:end\]/{if(f) exit}' "$LOOP" > "$EXTRACT"
# ⛔ `\$O` MUST BE ESCAPED FOR AWK, AND THE `if` MUST BE CLOSED. Inside an awk string `$O` is awk's
# FIELD reference (unset -> `$0`, the whole line), so the first version emitted the matched line as the
# sentinel; and an extracted `if … then` with no `fi` is a SYNTAX ERROR at EOF, which aborted the source
# midway (the escape's own log lines still landed, which is exactly how a "wired" test reads green while
# nothing dispatches — the same failure the real block had).
awk '/^  if \[ "\$\{LO_CHOICE:-none\}" != "issue" \] && \[ -z "\$GATE_WHY" \]/{f=1} f&&/^  if \[ -z "\$GATE_WHY" \]; then/{print; print "    : > \"\$O/state/dispatched\""; print "  fi"; exit}' "$LOOP" >> "$EXTRACT"
bash -n "$EXTRACT" || bad "(b-wired) the extracted block is not valid shell — the drive would abort midway"
check "(b-wired) the block was found in orch-loop.sh (a marker rename would otherwise skip it)" "[ -s '$EXTRACT' ] && grep -q 'pl_escape_open' '$EXTRACT' && grep -q 'LO_CHOICE=issue' '$EXTRACT'"

drive_escape() { # <state-dir> [<gate-why>] -> prints "LO_CHOICE=<x> DISPATCH=<yes|no>"
  local st="$1" gw="${2-}"
  ( set +e
    # ⛔ `O` MUST BE THE PARENT OF `$st`: the shipped block addresses `$O/state/...`, so a fixture that
    # pointed the two at different directories would drive a block that reads an EMPTY state dir and
    # the test would "pass" by never reaching the escape.
    O="$(dirname "$st")"; LOG="$st/log"; LO_CHOICE=pr; PL_MOD=1; UPN_WORK=2; PRDISP_SPAWNS=0
    DRAIN_ESCAPE_PASSES=2
    # ⛔ `GATE_WHY` IS THE WHOLE POINT (review P0, 2026-10-25). The escape fires only on a pass where
    # the merge-priority gate is SET — that is the state `mp_reason` produces whenever un-owned > 0 —
    # and the ONE line that opens dispatch is `[ -z "$GATE_WHY" ]`. An earlier version of this fixture
    # left GATE_WHY unset, so it proved the escape "opens the issue path" while the real loop could
    # dispatch nothing. The gate lines are extracted and driven too, and a sentinel records that the
    # dispatch branch was actually ENTERED.
    GATE_WHY="$gw"
    # shellcheck source=/dev/null
    . "$MOD"
    # shellcheck source=/dev/null
    . "$EXTRACT"
    printf 'LO_CHOICE=%s DISPATCH=%s\n' "$LO_CHOICE" "$( [ -e "$st/dispatched" ] && echo yes || echo no )" ) 2>/dev/null
}

W1="$TMP/w1"; mkdir -p "$W1/state"
pl_note_pass "$W1/state" 0 2 >/dev/null; pl_note_pass "$W1/state" 0 2 >/dev/null
OUT="$(drive_escape "$W1/state" "GW_SENTINEL")"
check "(b-wired) at the bound the SHIPPED block flips LO_CHOICE to issue" "case \"\$OUT\" in *'LO_CHOICE=issue'*) true ;; *) false ;; esac"
# ⛔ THE ASSERTION THE FIRST VERSION OF THIS SUITE COULD NOT MAKE. With GATE_WHY set (the real state on
# any pass with un-owned PRs) and LO_CHOICE flipped, the dispatch branch must actually be REACHED —
# otherwise the escape records an action that did not happen: a false PASS, not a harmless no-op.
check "(b-wired) …and the dispatch branch is actually ENTERED (the gate was lifted, not just printed)" "case \"\$OUT\" in *'DISPATCH=yes'*) true ;; *) false ;; esac"
check "(b-wired) it logs the lift, naming what it overrode" "grep -q 'DRAIN ESCAPE lifted the issue-path gate (was: GW_SENTINEL)' '$W1/state/log'"
check "(b-wired) it logs ONE auditable line naming the counts/bound/issue" "grep -q 'DRAIN ESCAPE — the PR path started NOTHING for 2 consecutive' '$W1/state/log' && grep -q 'bound 2' '$W1/state/log' && grep -q 'agent-infra#2831' '$W1/state/log'"
check "(b-wired) and it RECORDS the escape" "grep -q '^issue=OPENED-BY-ESCAPE' '$W1/state/drain-escape' && grep -q 'DRAIN ESCAPE RECORDED' '$W1/state/log'"
check "(b-wired) the counter is reset, so the next cycle does NOT re-escape" "[ \"\$(pl_idle_streak '$W1/state')\" = 0 ]"
W2="$TMP/w2"; mkdir -p "$W2/state"
pl_note_pass "$W2/state" 0 2 >/dev/null
OUT="$(drive_escape "$W2/state" "GW_SENTINEL")"
check "(b-wired) BELOW the bound the same block leaves the issue path CLOSED (contrast half)" "case \"\$OUT\" in *'LO_CHOICE=pr'*) true ;; *) false ;; esac"
check "(b-wired) …and it dispatches NOTHING and logs no escape" "case \"\$OUT\" in *'DISPATCH=no'*) true ;; *) false ;; esac"; ! grep -q 'DRAIN ESCAPE' "$W2/state/log" 2>/dev/null || bad "(b-wired) an escape was logged below the bound"
W3="$TMP/w3"; mkdir -p "$W3/state"
pl_note_pass "$W3/state" 0 2 >/dev/null; pl_note_pass "$W3/state" 0 2 >/dev/null
# A WORKING PR path (a spawn happened) must never escape even at a stale streak: the owner's ruling kept.
( O="$W3"; LOG="$W3/state/log"; LO_CHOICE=pr; PL_MOD=1; UPN_WORK=2; PRDISP_SPAWNS=4; DRAIN_ESCAPE_PASSES=2
  GATE_WHY="merge-priority (2 un-owned)"
  . "$MOD"; pl_note_pass "$W3/state" 1 2 >/dev/null
  . "$EXTRACT"; printf '%s %s\n' "$LO_CHOICE" "$( [ -e "$W3/state/dispatched" ] && echo yes || echo no )" ) > "$TMP/w3/out" 2>/dev/null
check "(b-wired) a WORKING PR path keeps the issue path closed AND dispatches nothing" "[ \"\$(cat '$TMP/w3/out')\" = 'pr no' ]"

# ─────────────────────────────────────────────────────────────────────────────────────────────
printf '\n%s\n' "──────────────────────────────────────────────"
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "✅ pr-owner-liveness: all assertions passed"
