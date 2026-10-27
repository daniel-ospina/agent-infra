#!/usr/bin/env bash
# tests/pr-doctor-trigger/run.sh — the EVENT-DRIVEN front end for the repair PASS.
#
# THE DEFECT THIS SUITE PINS. The fleet's repair actuator was TIMER-driven: `com.tortoise.pr-doctor`
# ran `StartInterval 1800`, so a PR that turned red one second after a pass waited up to 1800 s
# (mean 900 s) before any worker existed on it. The lead was not the repair — it was the timer.
# `scripts/pr-doctor-trigger.py` watches the PR surface with ONE `gh pr list` per poll and runs ONE
# PASS of `scripts/pr-repair-loop.sh` when the fingerprint changes; the timer survives as `--backstop`.
#
# ⛔ THE CHILD IS THE PASS, NOT `pr-doctor.py`, AND THAT IS THE POINT OF THIS SUITE. Calling the doctor
# directly would skip the derived cap, the disk floor and the load ceiling (#2721), the reap, the
# `keys.env` credential source (#1852/#2716) and the status row — a front end that bypasses its own
# gate. The stub below is therefore named `pr-repair-loop.sh`, so EVERY count in this file would go to
# zero if the trigger went back to calling `pr-doctor.py`.
#
# WHAT IS ASSERTED, and why each one can FAIL:
#
#   A. the fingerprint is a FUNCTION OF THE SURFACE (`--dry-run-print` differs on a changed
#      `mergeStateStatus`). Without this every other assertion is vacuous — and the last section
#      proves it: a mutant whose `fingerprint()` returns a constant makes B's "changed surface runs
#      a pass" arm produce ZERO passes, i.e. the suite is falsifiable.
#   B. COLD START runs exactly one pass, and an IDENTICAL second read runs NONE — counted by
#      PASS INVOCATIONS, not by stdout text. A constant fingerprint would still print
#      "no change" and still satisfy a text-only assertion; it cannot fake the counter.
#   C. a CHANGED surface runs ONE pass after the debounce — five rapid `updatedAt`/
#      `mergeStateStatus` moves coalesce into a single pass, not five. C5 pins that a DEFERRED pass
#      (rc 6 — the MACHINE saying not-now) is a VERDICT like 0/2, not a failure that would re-measure
#      a box that just said no on every poll.
#   D. an UNREADABLE surface is NOT QUIET (#2271: an empty/failed check surface must never read as
#      green). The pass is not invoked, `PR-SURFACE-UNREADABLE` is logged on EVERY tick (so the
#      next tick retried), the previous fingerprint is KEPT (a surface that comes back unchanged
#      owes no pass), and the word "no change" never appears — those are different states.
#   E. the LOCK: a second instance exits 0 with `ALREADY-RUNNING` and runs no pass. Concurrency
#      must be visible and exclusive rather than inferred from a plist nobody read.
#   F. `--once` (a supervisor's ExecStart) runs one pass and exits; a no-change `--once` runs none.
#   G. THE WIRING: `pr-repair-loop.sh --trigger` execs this trigger (one entry point for the unit),
#      and the pass is invoked with NO arguments — the cap is the machine's, never a scheduler's.
#
# HERMETIC: a throwaway HOME-free temp dir, a fake `gh` FIRST on PATH, and a fake `pr-repair-loop.sh`
# BESIDE a copy of the trigger (the trigger resolves its pass as `dirname($0)/pr-repair-loop.sh`, so
# the copy's sibling IS the stub). It never reads the live account, never runs the real pass, and
# never touches the real `$STATE_DIR/pr-doctor-trigger-*.lock`.
#
# Run: bash tests/pr-doctor-trigger/run.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$ROOT/scripts/pr-doctor-trigger.py"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '   ✅ %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '   ❌ %s\n' "$*"; }
assert_eq() { # <actual> <expected> <label>
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got: '$1', want '$2')"; fi
}
# ⛔ HERE-STRINGS, NOT `printf … | grep -q` (#841): under `pipefail` the quiet grep exits on its
# first match, the writer takes SIGPIPE, and the PIPELINE's status becomes 141 — `$?` then records
# a SIGPIPE instead of the match. Checked by `scripts/check-no-sigpipe-grep.sh`.
assert_contains() { # <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then pass "$3"; else fail "$3 (missing: $2)"; fi
}
assert_not_contains() {
  if grep -qF -- "$2" <<<"$1"; then fail "$3 (unexpected: $2)"; else pass "$3"; fi
}

[ -f "$SRC" ] || { echo "no pr-doctor-trigger.py at $SRC"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
APP="$TMP/app"; mkdir -p "$APP" "$TMP/bin" "$TMP/state"
cp "$SRC" "$APP/pr-doctor-trigger.py"
GH_STATE="$TMP/gh-surface.json"
GH_MODE="$TMP/gh-mode"
PASS_LOG="$TMP/pass-invocations.log"
: >"$PASS_LOG"; echo ok >"$GH_MODE"

# ── the fake PASS (`pr-repair-loop.sh`): the ONLY thing that can prove "a pass ran" ─────────────
# ⛔ THE STUB IS THE LOOP, NOT THE DOCTOR. The trigger's child is `dirname($0)/pr-repair-loop.sh`, and
# this stub occupies that exact path — so every invocation count below is evidence that the front end
# drives the PASS (with its cap, gates, reap, credential source and status row) instead of reaching
# past it into `pr-doctor.py`.
cat >"$APP/pr-repair-loop.sh" <<'SH'
#!/usr/bin/env bash
# argv is recorded so the suite can assert the scheduler supplies NOTHING (no `--max`: the cap is the
# machine's — half the cores, the disk floor and the owner's load ceiling decide it).
printf '%s\n' "$*" >>"$FAKE_PASS_LOG"
exit "${FAKE_PASS_RC:-0}"
SH
chmod +x "$APP/pr-repair-loop.sh"

# ── the fake gh: one call shape only (`pr list --json …`), plus the two failure shapes ─────────
cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
# ONE invocation log, so "one `gh pr list` per read" is COUNTED rather than asserted in prose: a
# per-PR call added inside a pass would show up here as N+1 lines for N PRs (review cycle 5).
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
mode="$(cat "$FAKE_GH_MODE" 2>/dev/null || echo ok)"
case "$mode" in
  fail)    echo "HTTP 502: bad gateway" >&2; exit 1 ;;
  # ⛔ EVERY ONE OF THESE IS RC=0 AND IS NOT A PR LIST (review cycle 1). Two of them were read as
  # "zero open PRs" by the shipped code — the #2271 conflation — and three of them killed the
  # trigger with a traceback. The suite drives all of them now; `garbage` existed unexercised.
  garbage) printf 'this is not json\n'; exit 0 ;;
  empty)   printf ''; exit 0 ;;
  object)  printf '{}\n'; exit 0 ;;
  null)    printf 'null\n' ;;
  wrapped) printf '{"data":[]}\n' ;;
  scalars) printf '[1,2]\n' ;;
  *)       cat "$FAKE_GH_STATE" ;;
esac
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export FAKE_GH_STATE="$GH_STATE" FAKE_GH_MODE="$GH_MODE" FAKE_PASS_LOG="$PASS_LOG"
GH_LOG="$TMP/gh-calls.log"; : >"$GH_LOG"; export FAKE_GH_LOG="$GH_LOG"

surface() { # <mergeStateStatus> <updatedAt>  — one open PR; the whole observable surface
  printf '[{"number":101,"mergeStateStatus":"%s","updatedAt":"%s","isDraft":false}]\n' "$1" "$2" >"$GH_STATE"
}
surface3() { # three PRs — the shape that catches a PER-PR `gh` call
  printf '[{"number":101,"mergeStateStatus":"CONFLICTING","updatedAt":"2026-10-24T18:00:00Z","isDraft":false},{"number":102,"mergeStateStatus":"BEHIND","updatedAt":"2026-10-24T18:01:00Z","isDraft":false},{"number":103,"mergeStateStatus":"BLOCKED","updatedAt":"2026-10-24T18:02:00Z","isDraft":true}]\n' >"$GH_STATE"
}
n_pass() { [ -f "$PASS_LOG" ] && wc -l <"$PASS_LOG" | tr -d ' ' || printf '0'; }
reset_pass() { : >"$PASS_LOG"; }

start_loop() { # <state-dir> <repo> <debounce> <logfile> → pid
  python3 "$APP/pr-doctor-trigger.py" --repo "$2" --repo-dir "$APP" \
      --poll 1 --debounce "$3" --backstop 1000000 --state-dir "$1" >"$4" 2>&1 &
  echo $!
}
wait_for() { # <file> <fixed-string> <tenths>
  local i=0
  while [ "$i" -lt "$3" ]; do
    # the file may not exist yet on the very first probe — a `grep` on a missing path would print a
    # spurious error into the CI log
    [ -f "$1" ] && grep -qF -- "$2" "$1" && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
stop_loop() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
# ⛔ POLL FOR AN ARRIVAL, SLEEP ONLY FOR AN ABSENCE (review cycle 1). `wait_for PASS-BEGIN` returns
# before the pass is spawned (the trigger logs it first), so `sleep 1; assert count==1` asked a
# saturated runner to fork python inside one second. Every other sleep in this file asserts that
# something did NOT happen, which cannot flake. This helper is the arrival half.
wait_dir() { # <want-count> <tenths>
  local i=0
  while [ "$i" -lt "$2" ]; do
    [ "$(n_pass)" -ge "$1" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── A. the fingerprint is a function of the SURFACE"
surface CONFLICTING "2026-10-24T18:00:00Z"
fp_a="$(python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-a --repo-dir "$APP" --dry-run-print 2>/dev/null)"
surface MERGEABLE "2026-10-24T18:00:00Z"
fp_b="$(python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-a --repo-dir "$APP" --dry-run-print 2>/dev/null)"
surface MERGEABLE "2026-10-24T18:00:00Z"
fp_c="$(python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-a --repo-dir "$APP" --dry-run-print 2>/dev/null)"
[ -n "$fp_a" ] && pass "a readable surface prints a fingerprint" || fail "empty fingerprint"
[ "$fp_a" != "$fp_b" ] && pass "mergeStateStatus CONFLICTING→MERGEABLE changes it" || fail "fingerprint is CONSTANT under a mergeStateStatus change"
assert_eq "$fp_b" "$fp_c" "an unchanged surface is byte-identical (no spurious events)"
assert_contains "$fp_a" "101:CONFLICTING" "the fingerprint names the PR and its status"

# a 5-PR surface must differ from a 1-PR one (a PR appearing/disappearing is an event)
printf '[{"number":101,"mergeStateStatus":"MERGEABLE","updatedAt":"2026-10-24T18:00:00Z","isDraft":false},{"number":102,"mergeStateStatus":"MERGEABLE","updatedAt":"2026-10-24T18:00:00Z","isDraft":false}]\n' >"$GH_STATE"
fp_two="$(python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-a --repo-dir "$APP" --dry-run-print 2>/dev/null)"
[ "$fp_b" != "$fp_two" ] && pass "a PR appearing changes it" || fail "fingerprint ignores an OPENED PR"

echo "── A2. an unreadable surface is UNREADABLE, not an empty fingerprint"
echo fail >"$GH_MODE"
out="$(python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-a --repo-dir "$APP" --dry-run-print 2>&1)"; rc=$?
assert_eq "$rc" "2" "--dry-run-print on an unreadable surface exits 2 (never 0 with an empty value)"
assert_not_contains "$out" "prs=0" "unreadable is not reported as zero PRs"
assert_contains "$out" "PR-SURFACE-UNREADABLE" "it names the failure"

echo "── A3. rc=0 is not the same as a READABLE surface (#2271), and [] is not the same as unusable"
for mode in garbage empty object null wrapped scalars; do
  echo "$mode" >"$GH_MODE"
  out="$(python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-a --repo-dir "$APP" --dry-run-print 2>&1)"; rc=$?
  assert_eq "$rc" "2" "gh output '$mode' (rc=0, not a PR list) is UNREADABLE, not an empty surface"
  assert_not_contains "$out" "prs=0" "'$mode' is never reported as zero open PRs"
done
# ⛔ THE MODE MUST BE RESET FIRST: the loop above leaves the fake gh on its LAST mode (`scalars`),
# and the positive control below has to run against a READABLE gh or it proves nothing.
echo ok >"$GH_MODE"
# the POSITIVE control: a genuinely empty surface is the JSON list `[]`, and it must NOT be refused
printf '[]\n' >"$GH_STATE"
out="$(python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-a --repo-dir "$APP" --dry-run-print 2>&1)"; rc=$?
assert_eq "$rc" "0" "a genuinely empty surface ([]) is READABLE — over-refusing it would be the opposite bug"
assert_contains "$out" "prs=0" "and it reports zero PRs"
echo ok >"$GH_MODE"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── A4. ONE gh call per read — the cost claim, counted"
# "One `gh pr list` per poll (no per-PR calls)" is what makes this cheap enough to poll; prose cannot
# pin it. Three PRs, one read: exactly one `gh` invocation, or the arm fails.
: >"$GH_LOG"
surface3
reset_pass
python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-a4 --repo-dir "$APP" \
  --once --dry-run-print --state-dir "$TMP/state/a4" >"$TMP/a4.log" 2>&1
assert_eq "$(wc -l <"$GH_LOG" | tr -d ' ')" "1" "three PRs cost exactly ONE gh call (not one per PR)"
assert_contains "$(cat "$TMP/a4.log")" "103" "and the read still saw every PR"
surface CONFLICTING "2026-10-24T18:00:00Z"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── B. cold start runs ONE pass; an identical read runs NONE (counted, not read off stdout)"
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_pass
S="$TMP/state/b"; mkdir -p "$S"; LOG="$TMP/b.log"
pid="$(start_loop "$S" fake-owner/suite-b 2 "$LOG")"
if wait_for "$LOG" "PASS-BEGIN" 100; then pass "the first read of a cold trigger runs a pass"
else fail "cold start ran no pass"; fi
wait_dir 1 100 || true
assert_eq "$(n_pass)" "1" "exactly one pass invocation on the cold pass"
reset_pass
sleep 4                       # ≥4 poll ticks with a byte-identical surface
assert_eq "$(n_pass)" "0" "an identical surface invokes the pass ZERO times"
body="$(cat "$LOG")"
assert_contains "$body" "no change" "it says so (a silent trigger is indistinguishable from a dead one)"
n_cold="$(grep -cF 'COLD' "$LOG")"
assert_eq "$n_cold" "1" "cold start is derived EXACTLY once (not re-derived on every tick)"
stop_loop "$pid"

echo "── B2. --once: one pass and exit, then nothing (a supervisor's ExecStart)"
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_pass
S2="$TMP/state/b2"; mkdir -p "$S2"
python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-b2 --repo-dir "$APP" --once \
  --poll 1 --backstop 1000000 --state-dir "$S2" >"$TMP/b2.log" 2>&1; rc=$?
assert_eq "$rc" "0" "--once on a cold start exits 0"
assert_eq "$(n_pass)" "1" "--once ran exactly one pass"
reset_pass
python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-b2 --repo-dir "$APP" --once \
  --poll 1 --backstop 1000000 --state-dir "$S2" >"$TMP/b2b.log" 2>&1
assert_eq "$(n_pass)" "0" "a second --once with an unchanged surface runs NO pass"
assert_contains "$(cat "$TMP/b2b.log")" "no change" "and it says 'no change'"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── C. a CHANGED surface: one pass after the debounce; five rapid moves → ONE pass"
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_pass
S="$TMP/state/c"; mkdir -p "$S"; LOG="$TMP/c.log"
pid="$(start_loop "$S" fake-owner/suite-c 3 "$LOG")"
wait_for "$LOG" "PASS-BEGIN" 100 || fail "cold pass never ran (case C cannot start)"
wait_dir 1 100 || true
reset_pass
i=0
while [ "$i" -lt 5 ]; do                       # five RAPID changes, well inside the 3 s debounce
  if [ $((i % 2)) -eq 0 ]; then st=BEHIND; else st=CONFLICTING; fi
  surface "$st" "2026-10-24T18:0$((i + 1)):00Z"
  sleep 0.4; i=$((i + 1))
done
sleep 9                                        # 3 s debounce + pass + several no-change ticks
assert_eq "$(n_pass)" "1" "five rapid changes produced exactly ONE pass (coalesced)"
assert_contains "$(cat "$LOG")" "CHANGE" "the change was observed"
stop_loop "$pid"

echo "── C2. a pass that FAILED does not buy a backstop window (retry floor, not a 1800 s wait)"
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_pass
S="$TMP/state/c2"; mkdir -p "$S"; LOG="$TMP/c2.log"
FAKE_PASS_RC=3 python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-c2 --repo-dir "$APP" \
  --once --backstop 1000000 --retry-min 0 --state-dir "$S" >"$LOG" 2>&1; rc=$?
assert_eq "$rc" "1" "a non-{0,2} doctor exit makes --once exit non-zero"
assert_contains "$(cat "$LOG")" "PASS-FAILED rc=3" "it is named PASS-FAILED, not a clean window"
python3 - "$S/pr-doctor-trigger-suite-c2.state.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("last_pass") == 0, "last_pass must be 0 after a failed pass: %r" % d
assert d.get("last_attempt", 0) > 0, "last_attempt must be recorded: %r" % d
PY
assert_eq "$?" "0" "the state records last_pass=0 (backstop NOT consumed) and a real last_attempt"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── C3. --retry-min BOUNDS a repeated failure (one pass per floor, not one per poll)"
# ⛔ THE KNOB ADDED BEYOND THE BRIEF NEEDED A TEST (review cycle 5). `--retry-min` exists because
# `pr-doctor` has a non-crash non-clean exit (`EXIT_UNDELIVERED = 3`, which is what the box reports
# right now) and treating it as a crash retried a FULL pass every poll. Only C2 touched the floor and
# it ran `--retry-min 0`, which cannot tell the floor from its absence — deleting the clause left the
# suite green. Here the backstop is always due (`--backstop 0`) and the pass keeps failing: with the
# floor there is ONE attempt in four polls without it there are four.
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_pass; S="$TMP/state/c3"; mkdir -p "$S"; LOG="$TMP/c3.log"
FAKE_PASS_RC=3 python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-c3 --repo-dir "$APP" \
  --poll 1 --debounce 0 --backstop 0 --retry-min 600 --state-dir "$S" >"$LOG" 2>&1 &
c3pid=$!
wait_dir 1 100
sleep 4
stop_loop "$c3pid"
assert_eq "$(n_pass)" "1" "a failing pass is retried ONCE per --retry-min, not once per poll"
assert_contains "$(cat "$LOG")" "PASS-FAILED rc=3" "and the failure is named"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── C4. the debounce is a DEADLINE: the pass lands at it, not at the next poll tick"
# ⛔ THE OTHER HALF OF THE MEASURED QUANTISATION DEFECT (review cycle 5). With `--poll 60
# --debounce 90` the settling window used to sleep a whole poll and wake at
# `poll + ceil(debounce/poll)*poll` = 180 s instead of 150 s. Every loop arm ran `--poll 1`, where
# "sleep to the next tick" and "sleep to the deadline" are the SAME 1 s, so reverting the deadline
# sleep left the suite green. `--poll 6 --debounce 7` separates them: the deadline sleep wakes at
# ~7 s, a per-tick sleep at 12 s (6, then 6 more for the last 1 s).
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_pass; S="$TMP/state/c4"; mkdir -p "$S"; LOG="$TMP/c4.log"; : >"$LOG"
python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-c4 --repo-dir "$APP" \
  --poll 6 --debounce 7 --backstop 1000000 --state-dir "$S" >"$LOG" 2>&1 &
c4pid=$!
if wait_dir 1 200; then pass "cold pass first (poll=6)"; else fail "no cold pass at poll=6"; fi
reset_pass
surface BEHIND "2026-10-24T18:30:00Z"
t_det=""
wait_for "$LOG" "CHANGE settling" 200 && t_det="$(date +%s)"
wait_dir 1 200; t_run="$(date +%s)"
stop_loop "$c4pid"
assert_eq "$(n_pass)" "1" "poll=6 debounce=7 runs exactly one pass"
if [ -n "$t_det" ]; then
  el=$(( t_run - t_det ))
  # shipped: ~7 s after the change is observed. A per-tick sleep: 12 s. The threshold sits between
  # them with >1.5x headroom on both sides of the gap; the arm measures a DEADLINE, not an instant.
  [ "$el" -le 9 ] && pass "it woke at the DEADLINE (${el}s after the change was observed, not +12s)" \
                  || fail "the settling window slept to the next tick (${el}s)"
else
  fail "the settling window never logged CHANGE"
fi

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── D. an UNREADABLE surface is not QUIET (#2271)"
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_pass
S="$TMP/state/d"; mkdir -p "$S"; LOG="$TMP/d.log"
pid="$(start_loop "$S" fake-owner/suite-d 1 "$LOG")"
wait_for "$LOG" "PASS-BEGIN" 100 || fail "cold pass never ran (case D cannot start)"
wait_dir 1 100 || true
reset_pass
# ⛔ THE BASELINE IS TAKEN **AFTER** THE FLIP HAS PRODUCED ≥2 UNREADABLE TICKS, not before it.
# Taking it before made this assertion RACY and it flaked: the trigger can be mid-tick when the mode
# flips, so a tick that read the surface while it was still readable logs its legitimate "no change"
# a moment later and lands in the "after" bucket. Waiting for two unreadable ticks first means every
# tick counted below is provably a failing-read tick.
echo fail >"$GH_MODE"
i=0
while [ "$i" -lt 120 ]; do
  [ "$(grep -cF 'PR-SURFACE-UNREADABLE' "$LOG")" -ge 2 ] && break
  sleep 0.1; i=$((i + 1))
done
unread_before="$(grep -cF 'PR-SURFACE-UNREADABLE' "$LOG")"
quiet_before="$(grep -cF 'no change' "$LOG")"
assert_contains "$(cat "$LOG")" "PR-SURFACE-UNREADABLE" "a failed gh read is logged as PR-SURFACE-UNREADABLE"
[ "$unread_before" -ge 2 ] && pass "the next tick RETRIED the read ($unread_before attempts so far)" \
  || fail "the read was not retried (${unread_before} attempt(s))"
sleep 3                                        # more unreadable ticks, all of them after the baseline
quiet_after="$(grep -cF 'no change' "$LOG")"
unread_after="$(grep -cF 'PR-SURFACE-UNREADABLE' "$LOG")"
assert_eq "$quiet_after" "$quiet_before" "no unreadable tick ever logged 'no change' (the #2271 failure)"
[ "$unread_after" -gt "$unread_before" ] && pass "and it kept retrying ($((unread_after - unread_before)) more attempt(s))" \
  || fail "retrying stopped after the first two attempts"
assert_eq "$(n_pass)" "0" "an unreadable surface invoked the pass ZERO times"
# the surface comes back byte-identical: still no pass (the fingerprint was KEPT, not forgotten)
echo ok >"$GH_MODE"
sleep 3
assert_eq "$(n_pass)" "0" "the surface returning UNCHANGED owes no pass"
assert_contains "$(cat "$LOG")" "keeping the last fingerprint" "going blind was not treated as a change"
stop_loop "$pid"

echo "── D2. --once over an UNREADABLE surface exits non-zero and never says 'no change'"
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_pass
S="$TMP/state/d2"; mkdir -p "$S"
python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-d2 --repo-dir "$APP" --once \
  --poll 1 --backstop 1000000 --state-dir "$S" >"$TMP/d2a.log" 2>&1   # seed a fingerprint
echo fail >"$GH_MODE"
python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-d2 --repo-dir "$APP" --once \
  --poll 1 --backstop 1000000 --state-dir "$S" >"$TMP/d2.log" 2>&1; rc=$?
echo ok >"$GH_MODE"
assert_eq "$rc" "2" "--once on an unreadable surface exits 2 (a READS-I-COULD-NOT-DO verdict)"
assert_contains "$(cat "$TMP/d2.log")" "SURFACE-DEGRADED" "it names the degraded surface"
assert_not_contains "$(cat "$TMP/d2.log")" "no change" "and never reports the unreadable surface as quiet"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── E. the LOCK: a second instance exits 0 and runs no second pass"
S="$TMP/state/e"; mkdir -p "$S"; LOG="$TMP/e.log"
reset_pass
pid="$(start_loop "$S" fake-owner/suite-e 1 "$LOG")"
wait_for "$LOG" "PASS-BEGIN" 100 || fail "the holding instance never started"
wait_dir 1 100 || true
python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-e --repo-dir "$APP" --once \
  --poll 1 --backstop 1000000 --state-dir "$S" >"$TMP/e2.log" 2>&1; rc=$?
assert_eq "$rc" "0" "the second instance exits 0 (not an error, not a crash loop)"
assert_contains "$(cat "$TMP/e2.log")" "ALREADY-RUNNING" "it SAYS another instance holds the lock"
assert_eq "$(n_pass)" "1" "no second pass was started"
stop_loop "$pid"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── F. MUTATION: a constant fingerprint() must turn case C RED (the anti-vacuity arm)"
MUT="$TMP/mutant"; mkdir -p "$MUT"
cp "$APP/pr-repair-loop.sh" "$MUT/pr-repair-loop.sh"
python3 - "$APP/pr-doctor-trigger.py" "$MUT/pr-doctor-trigger.py" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = '    return ("|".join("%s:%s:%s:%s" % t for t in rows), len(rows))'
assert needle in src, "the fixture cannot find fingerprint()'s return — update the mutation"
open(sys.argv[2], "w").write(src.replace(needle, '    return ("CONSTANT", len(rows))'))
PY
assert_eq "$?" "0" "the mutant was built from the real fingerprint() return"
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_pass
MS="$TMP/state/f"; mkdir -p "$MS"; MLOG="$TMP/f.log"
python3 "$MUT/pr-doctor-trigger.py" --repo fake-owner/suite-f --repo-dir "$MUT" \
  --poll 1 --debounce 1 --backstop 1000000 --state-dir "$MS" >"$MLOG" 2>&1 &
mpid=$!
wait_for "$MLOG" "PASS-BEGIN" 100 || fail "the mutant never ran its cold pass"
wait_dir 1 100 || true                       # an ARRIVAL: poll, never sleep (review cycle 2, F3)
reset_pass
surface BEHIND "2026-10-24T18:59:00Z"          # a REAL change the mutant cannot see
sleep 4
assert_eq "$(n_pass)" "0" "the mutant MISSES the change — i.e. case C's assertion is load-bearing"
assert_contains "$(cat "$MLOG")" "no change" "the mutant reports 'no change' over a changed surface"
stop_loop "$mpid"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── G. the WIRING: the unit's ONE entry point execs this trigger, and the pass gets no arguments"
# ⛔ THE MODE IS THE UNIT'S CLOCK CHOICE, NOT A SECOND UNIT: `pr-repair-loop.sh --trigger` execs the
# trigger, whose child is the SAME loop's one-pass mode. So a box has ONE repair unit, ONE installer
# and ONE queue, and the front end cannot bypass the cap, the two machine gates, the reap, the
# credential source or the status row.
LOOP="$ROOT/scripts/pr-repair-loop.sh"
[ -f "$LOOP" ] && pass "the repair loop ships (the trigger's child)" || fail "no $LOOP"
WIRE="$TMP/wire"; mkdir -p "$WIRE" "$TMP/state/g"
cp "$LOOP" "$WIRE/pr-repair-loop.sh"
EVID="$TMP/wire-trigger-argv.log"
# a stub FRONT END beside the real loop: it records the argv the loop hands it and exits 0.
cat >"$WIRE/pr-doctor-trigger.py" <<'PY'
import os, sys
open(os.environ["WIRE_EVID"], "w").write(" ".join(sys.argv[1:]))
raise SystemExit(0)
PY
# ⛔ `PR_REPAIR_SCRIPTS` IS THE LOOP'S OWN SEAM FOR ITS SIBLINGS (it execs the FARMED copy's neighbours
# — `pr-doctor.py`, `pi-reap-worktrees.sh` — by the same variable), so the stub directory is pointed at
# the same way the farm would be. Passing it here is the shipped path, not a test-only shortcut.
WIRE_EVID="$EVID" REPAIR_TRIGGER_BACKSTOP_S=4242 PR_DOCTOR_REPO=fake-repo/one \
  PR_DOCTOR_REPO_DIR=/tmp PR_REPAIR_SCRIPTS="$WIRE" \
  bash "$WIRE/pr-repair-loop.sh" --trigger >"$TMP/g-trigger.out" 2>&1; wrc=$?
[ "$wrc" = 0 ] || sed 's/^/      /' "$TMP/g-trigger.out"
assert_eq "$wrc" "0" "--trigger execs the front end and exits with its status"
if [ -f "$EVID" ]; then
  wire_argv="$(cat "$EVID")"
  assert_contains "$wire_argv" "--repo fake-repo/one" "--trigger passes the RESOLVED repo (not a default)"
  assert_contains "$wire_argv" "--repo-dir /tmp" "and the checkout the pass may create worktrees in"
  assert_contains "$wire_argv" "--backstop 4242" "and the demoted timer, from the loop's own env seam"
  assert_not_contains "$wire_argv" "--max" "the scheduler never sets the cap (it is the machine's)"
else
  fail "--trigger never reached the front end (no argv recorded)"
fi
# ⛔ A MISSING FRONT END IS A NAMED REFUSAL, NOT A START-LIMIT LOOP. A unit whose ExecStart cannot
# resolve its own front end fails every start, systemd exhausts StartLimitBurst, and the only trace is
# a journal — so `--trigger` refuses with a diagnosis AND records the verdict where a reader looks.
NOPASS="$TMP/nopass"; mkdir -p "$NOPASS" "$TMP/state/g2"
cp "$LOOP" "$NOPASS/pr-repair-loop.sh"
# `PR_REPAIR_SCRIPTS` points at the stub dir, which holds ONLY the loop — so this arm is hermetic
# against whatever happens to be farmed on the box running the suite.
O="$TMP/state/g2" PR_DOCTOR_REPO=fake-repo/one PR_DOCTOR_REPO_DIR="$TMP" \
  PR_REPAIR_SCRIPTS="$NOPASS" bash "$NOPASS/pr-repair-loop.sh" --trigger >"$TMP/g-missing.out" 2>&1; mrc=$?
assert_eq "$mrc" "2" "--trigger with NO front-end artifact REFUSES (rc 2, the loop's refusing code)"
assert_contains "$(cat "$TMP/g-missing.out")" "pr-doctor-trigger.py" "and the refusal names the missing file"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── H. a trigger with NO pass is PASS-MISSING, never a clean pass"
NODOC="$TMP/nodoctor"; mkdir -p "$NODOC" "$TMP/state/h"
cp "$SRC" "$NODOC/pr-doctor-trigger.py"          # the trigger WITHOUT its sibling pr-repair-loop.sh
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_pass
python3 "$NODOC/pr-doctor-trigger.py" --repo fake-owner/suite-h --repo-dir "$NODOC" --once \
  --poll 1 --backstop 1000000 --state-dir "$TMP/state/h" >"$TMP/h.log" 2>&1; rc=$?
# ⛔ CPython exits 2 for "can't open file", and 2 is a code this trigger treats as a VERDICT — so
# without this arm a trigger whose PASS was never farmed reported a clean window, consumed the whole
# backstop and exited 0 under the unit's ExecStart. That is the exact state the farm ORDER in
# pi-bootstrap/setup.sh exists to prevent, and the farm cannot prevent it off-farm.
assert_eq "$rc" "1" "--once with no pass exits non-zero (not a clean 0)"
assert_contains "$(cat "$TMP/h.log")" "PASS-MISSING" "it is named PASS-MISSING"
assert_not_contains "$(cat "$TMP/h.log")" "PASS-END rc=2" "a missing pass never reports a pass's rc"
python3 - "$TMP/state/h/pr-doctor-trigger-suite-h.state.json" <<'PYH'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("last_pass") == 0, "a missing pass must NOT consume the backstop window: %r" % d
PYH
assert_eq "$?" "0" "the backstop window is NOT consumed by a missing pass"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── H2. the pass is invoked with NO arguments — the cap is the machine's, never the scheduler's"
# ⛔ THE STUB LOGS ITS ARGV, SO THIS IS A COUNTED CLAIM. The pass derives its cap from `nproc`, the
# disk floor and the load ceiling (#2409); a scheduler that could pass `--max` would be the "16 workers
# on a box at load 57" defect. An EMPTY line in the log is the evidence of no argv.
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_pass
S="$TMP/state/h2"; mkdir -p "$S"
python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-h2 --repo-dir "$APP" --once \
  --poll 1 --backstop 1000000 --state-dir "$S" >"$TMP/h2.log" 2>&1
assert_eq "$(n_pass)" "1" "one pass was invoked"
assert_eq "$(tr -d '[:space:]' <"$PASS_LOG")" "" "and its argv was EMPTY (no --max, no knobs)"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── C5. rc=6 (DEFERRED) is a VERDICT like 0/2: the backstop window IS consumed"
# ⛔ 6 IS THE PASS SAYING "THE MACHINE SAID NOT NOW" (below the disk floor / above the load ceiling /
# cap 0 — #2721). Treating it as a failure would re-measure a box that just refused on EVERY poll,
# which is the opposite of the discipline the deferral exists to enforce. This arm separates 6 from 3
# (C2/C3), where the retry floor deliberately DOES retry.
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_pass
S="$TMP/state/c5"; mkdir -p "$S"
FAKE_PASS_RC=6 python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-c5 --repo-dir "$APP" \
  --once --backstop 1000000 --retry-min 0 --state-dir "$S" >"$TMP/c5.log" 2>&1; rc=$?
assert_eq "$rc" "0" "a DEFERRED pass makes --once exit 0 (a verdict, not a failure)"
assert_contains "$(cat "$TMP/c5.log")" "PASS-END rc=6" "it is logged as the pass's own rc"
assert_not_contains "$(cat "$TMP/c5.log")" "PASS-FAILED" "and NOT as a failure"
python3 - "$S/pr-doctor-trigger-suite-c5.state.json" <<'PYH5'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("last_pass", 0) > 0, "a DEFERRED pass must consume the backstop window: %r" % d
PYH5
assert_eq "$?" "0" "the state records last_pass (the window was consumed by the deferral)"

echo "── I. a PENDING change survives a RESTART inside the debounce window"
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_pass
S="$TMP/state/i"; mkdir -p "$S"; LOG="$TMP/i.log"
pid="$(start_loop "$S" fake-owner/suite-i 20 "$LOG")"   # a long debounce: the window is wide on purpose
wait_for "$LOG" "PASS-BEGIN" 100 || fail "cold pass never ran (case I cannot start)"
wait_dir 1 100 || true
reset_pass
surface BEHIND "2026-10-24T19:00:00Z"                    # a REAL change, then kill inside the window
wait_for "$LOG" "CHANGE" 100 || fail "the change was never observed"
stop_loop "$pid"                                        # killed BEFORE the 20 s debounce elapses
assert_eq "$(n_pass)" "0" "nothing ran yet (the change is still in its coalescing window)"
assert_contains "$(cat "$S"/pr-doctor-trigger-suite-i.state.json)" '"pending_since"' \
  "the pending change was PERSISTED, not just remembered"
LOG="$TMP/i2.log"
pid="$(start_loop "$S" fake-owner/suite-i 20 "$LOG")"
wait_dir 1 300 || true
assert_eq "$(n_pass)" "1" "after the restart the change still runs exactly ONE pass (not lost, not doubled)"
assert_contains "$(cat "$LOG")" "RESUMING a pending change" "and the restart says it is resuming one"
stop_loop "$pid"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# Tripwire for section loss: a whole case was once deleted from a suite of this shape and it still
# reported ALL PASSED. ⛔ THE FLOOR IS PINNED JUST BELOW THE CURRENT POPULATION (review cycle 4): at
# `-ge 30` this guard tolerated losing 55 assertions, and EVERY single section is smaller than that
# (section A3 alone is 12), so any one case could be deleted while the floor printed `ok` — a
# tripwire blind to the exact event it names. Deleting the smallest arm now trips it. Bump it when
# you add arms; never lower it to make a failing run pass.
assert_eq "$([ "$PASS" -ge 81 ] && echo ok || echo short)" "ok" "assertion floor (≥81 fired, got $PASS)"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "ALL PASSED ($PASS assertions)"
  exit 0
fi
echo "FAILED: $FAIL of $((PASS + FAIL))"
exit 1
