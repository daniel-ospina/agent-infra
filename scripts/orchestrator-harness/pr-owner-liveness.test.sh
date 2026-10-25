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

echo "(a2) a RECYCLED pid is not ownership either"
C="$TMP/c"; mkdir -p "$C"
RP="$(spawn_unrelated)"; sleep 0.2
printf '%s\n' "$RP" > "$(pl_lock_path "$C" 5151)"
check "fixture: the recycled pid IS alive"  "pl_pid_alive '$RP'"
OUT="$(pl_verdict "$C" 5151 1 1)"; RC=$?
check "(a2) verdict is RELEASED despite a live pid" "[ $RC -eq 1 ] && case \"\$OUT\" in RELEASED*) true ;; *) false ;; esac"
check "(a2) the reason names the recycled pid"      "case \"\$OUT\" in *'is ALIVE but is not a merge worker'*) true ;; *) false ;; esac"
check "(a2) the lock was REMOVED"                    "[ ! -e '$(pl_lock_path "$C" 5151)' ]"

# ─────────────────────────────────────────────────────────────────────────────────────────────
echo "(c) a PR whose worker is ALIVE is still respected"
OUT="$(pl_verdict "$B" 4242 1 1)"; RC=$?
check "(c) verdict is OWNED"                 "[ $RC -eq 0 ] && case \"\$OUT\" in OWNED*) true ;; *) false ;; esac"
check "(c) the reason names the live worker" "case \"\$OUT\" in *\"lock pid $WP\"*) true ;; *) false ;; esac"
check "(c) the live worker's lock is KEPT"   "[ -e '$(pl_lock_path "$B" 4242)' ]"
# The external live fact (cwd scan / cross-box lease) and the worker record are each sufficient alone:
OUT="$(pl_verdict "$TMP/c" 5151 0 1)"; RC=$?
check "(c) a live cwd/lease fact alone reads OWNED even with no lock" "[ $RC -eq 0 ]"
OUT="$(pl_verdict "$TMP/c" 5151 1 0)"; RC=$?
check "(c) a live worker RECORD alone reads OWNED"                    "[ $RC -eq 0 ]"
# ⛔ NON-VACUITY for the respect arm: with EVERY proof removed the SAME state is RELEASED.
OUT="$(pl_verdict "$TMP/c" 5151 1 1)"; RC=$?
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
awk '/^  # \[drain-escape:begin\]/{f=1} f{print} /^  # \[drain-escape:end\]/{if(f) exit}' "$LOOP" > "$EXTRACT"
check "(b-wired) the block was found in orch-loop.sh (a marker rename would otherwise skip it)" "[ -s '$EXTRACT' ] && grep -q 'pl_escape_open' '$EXTRACT' && grep -q 'LO_CHOICE=issue' '$EXTRACT'"

drive_escape() { # <state-dir> -> prints "LO_CHOICE=<x>"; log at <state-dir>/log
  local st="$1"
  ( set +e
    # ⛔ `O` MUST BE THE PARENT OF `$st`: the shipped block addresses `$O/state/...`, so a fixture that
    # pointed the two at different directories would drive a block that reads an EMPTY state dir and
    # the test would "pass" by never reaching the escape (this fixture did exactly that on its first
    # run — the assertion that caught it is the one that greps the log).
    O="$(dirname "$st")"; LOG="$st/log"; LO_CHOICE=pr; PL_MOD=1; UPN_WORK=2; PRDISP_SPAWNS=0
    DRAIN_ESCAPE_PASSES=2
    # shellcheck source=/dev/null
    . "$MOD"
    # shellcheck source=/dev/null
    . "$EXTRACT"
    printf 'LO_CHOICE=%s\n' "$LO_CHOICE" ) 2>/dev/null
}
W1="$TMP/w1"; mkdir -p "$W1/state"
pl_note_pass "$W1/state" 0 2 >/dev/null; pl_note_pass "$W1/state" 0 2 >/dev/null
OUT="$(drive_escape "$W1/state")"
check "(b-wired) at the bound the SHIPPED block flips LO_CHOICE to issue" "case \"\$OUT\" in *'LO_CHOICE=issue'*) true ;; *) false ;; esac"
check "(b-wired) it logs ONE auditable line naming the counts/bound/issue" "grep -q 'DRAIN ESCAPE — the PR path started NOTHING for 2 consecutive' '$W1/state/log' && grep -q 'bound 2' '$W1/state/log' && grep -q 'agent-infra#2831' '$W1/state/log'"
check "(b-wired) and it RECORDS the escape" "grep -q '^issue=OPENED-BY-ESCAPE' '$W1/state/drain-escape' && grep -q 'DRAIN ESCAPE RECORDED' '$W1/state/log'"
check "(b-wired) the counter is reset, so the next cycle does NOT re-escape" "[ \"\$(pl_idle_streak '$W1/state')\" = 0 ]"
W2="$TMP/w2"; mkdir -p "$W2/state"
pl_note_pass "$W2/state" 0 2 >/dev/null
OUT="$(drive_escape "$W2/state")"
check "(b-wired) BELOW the bound the same block leaves the issue path CLOSED (contrast half)" "case \"\$OUT\" in *'LO_CHOICE=pr'*) true ;; *) false ;; esac"
check "(b-wired) …and it logs no escape" "! grep -q 'DRAIN ESCAPE' '$W2/state/log' 2>/dev/null"
W3="$TMP/w3"; mkdir -p "$W3/state"
pl_note_pass "$W3/state" 0 2 >/dev/null; pl_note_pass "$W3/state" 0 2 >/dev/null
# A working PR path (spawns > 0) must never escape even at the bound: this is the owner's ruling kept.
( O="$W3"; LOG="$W3/state/log"; LO_CHOICE=pr; PL_MOD=1; UPN_WORK=2; PRDISP_SPAWNS=4; DRAIN_ESCAPE_PASSES=2
  . "$MOD"; pl_note_pass "$W3/state" 1 2 >/dev/null
  . "$EXTRACT"; printf '%s\n' "$LO_CHOICE" ) > "$TMP/w3/out" 2>/dev/null
check "(b-wired) a WORKING PR path (a spawn happened) keeps the issue path closed" "[ \"\$(cat '$TMP/w3/out')\" = pr ]"
# ─────────────────────────────────────────────────────────────────────────────────────────────
printf '\n%s\n' "──────────────────────────────────────────────"
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "✅ pr-owner-liveness: all assertions passed"
