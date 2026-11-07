#!/usr/bin/env bash
# scripts/run-bash-shards.recap.test.sh — #3174: an INTERRUPTED shard run must NAMES its failures
# and say, in the same breath, that its recap is INCOMPLETE.
#
# THE DEFECT (measured, agent-infra#3174). On 2026-10-31 main's `script-validate` job was killed
# mid-run and a KILLED step printed NO recap at all. The set of shards red on `main` is the
# REFERENCE SET every batch verdict subtracts (`batch_failures − main_failures`), so a killed run
# does not merely lose information — it publishes a SMALLER baseline. A shard genuinely red on main
# then drops out, reappears as "a new failure caused by the batch" (a constituent gets dropped or
# reverted on a false signal) and, read as an improvement, HIDES the failures that were real:
#
#     run 41202368455 — completed, full recap, 13 failing shards   ← last trustworthy baseline
#     run 41217287437 — shard step KILLED at 111 min, no recap,    11 failing shards
#     run 41185164653 —                                           10 failing shards
#
# 13 → 11 → 10 while nothing was fixed. The set shrank because the JOB got slower.
#
# ARM 1 — INTERRUPTED. A fixture list of three shards (one fails, one blocks, one never starts) is
#   run and SIGTERM'd as a PROCESS GROUP — what GitHub terminates on a timeout, and required because
#   bash defers a trap while a foreground child runs. Then: (a) the recap line IS printed at all
#   (today's code prints none — this arm is RED before the fix); (b) it NAMES the failed shard (a
#   count is not an attribution, #2643); (c) the `⚠️ RECAP INCOMPLETE (2/3 shards ran)` marker is
#   present WITH HONEST COUNTS, and the never-reached shard is neither named as failing nor counted
#   as reached; (d) the exit status is 1 — an interrupted run must never read green.
# ARM 2 — HAPPY PATH. A COMPLETE run prints the recap WITHOUT the marker. Without this arm the trap
#   could fire on every run and arm 1 would still pass, making the marker noise.
# ARM 3 — THE OUTER JOB'S SLICE MUST NOT REACH THE FIXTURE (#3452). BOTH lanes' jobs now export
#   `BASH_SHARD_SLICE=<i>/<n>` for the WHOLE step — `ci.yml`'s `bash-suites` always did, and since
#   #3174 (landed as PR #3235) `ci-main.yml`'s `script-validate` is the SAME 8-way slice — and this
#   suite's subject is the runner's WHOLE-LIST recap over a THREE-shard fixture list, where a slice of
#   8 over 3 entries has nothing to run and the runner refuses (rc 2).
#   ⛔ BUT THAT SLICE NO LONGER REACHES A SHARD AT ALL, so this is NOT a CI-lane red in either lane
#   today: `shard_exec` — the `env -u` wrapper in `scripts/run-bash-shards.sh`, agent-infra#3415 —
#   strips the runner's whole env contract before every shard it starts, and the paragraph below at
#   the `unset` records the same fact from the other side. What stays exposed is a DIRECT invocation
#   of this file
#   (a repro shell that exports the slice and runs the suite rather than the runner) and a tree where
#   that strip is removed — which is why the `unset` is defence in depth and not the only defence.
#   This arm is the MUTATION control pinning the HAZARD and the runner's refusal contract: the same
#   fixture WITH the slice must still refuse with the runner's own message, so a changed refusal
#   wording, a changed rc, or a weakened runner reds it.
#   The drop above clears the runner's WHOLE env contract (`BASH_SHARD_SLICE`,
#   `BASH_SHARDS_BUDGET_SECS`, `SHARD_BOUND`) because either lane's step-level value would otherwise
#   arrive by a direct invocation — see the block at the `unset`.
#   ⛔ WHAT THIS ARM DOES NOT PIN, stated so nobody reads it as more than it is: it sets its own
#   slice, so it is independent of the `unset` above and CANNOT see the mitigation disappear. That
#   is measured, not assumed — delete the `unset` and an UNSLICED run is still green, while a run
#   that DOES carry a slice reds 9 arms. So the discrimination belongs to a sliced invocation —
#   which is what a DIRECT invocation can be, NOT what CI hands a shard — and a box that only
#   ever runs unsliced cannot see it. Pinning the `unset` itself needs a hermetic-probe
#   mutant — the pattern `tests/run-bash-shards-bound/run.sh` §0 already uses (it strips its own
#   `unset` into a copy and requires the probe to then see the leaked value). That is not built
#   here because it needs a probe mode this suite does not have, and a self-copying mutant without
#   one recurses; it is the follow-up, not a claim of coverage.
#
# THE CONSUMERS of the marker are pinned next door, in `scripts/ci-failure-set.truncated.test.sh`:
# `ci_exemption.py` must answer such a capture with UNPROVEN (no ids), and `ci-failure-set.sh` must
# exclude the run from main's baseline. Split into two files because each is read whole by the
# host's discard guard, which refuses a script whose body exceeds its audit budget.
#
# WHY A FIXTURE: the suite must be cheap and its verdict must depend on NOTHING but the runner. A
# real-list run inherits every other shard's verdict on the machine (the reason
# `tests/ci-lane-parity/run.sh` narrows its fixture too). The fixture rewrites ONE data list
# (`SUITE_GLOBS`, a derivation since #2609) and keeps discovery, the marker parse, sort, slicing,
# sweeps, the sentinels and the #3174 handler byte-identical to the shipped runner.
#
# STYLE: containment tests are here-strings (`grep -q … <<<"$OUT"`), never `printf | grep -q` —
# `set -o pipefail` turns the writer's SIGPIPE into a FALSE FAILURE (scripts/check-no-sigpipe-grep.sh,
# #841). Fixture roots live outside the checkout (mktemp -d).
#
# bash 3.2 compatible (macOS /bin/bash): no `+=` on an empty array, no `mapfile`, no `${x,,}`.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/run-bash-shards.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }

# ⛔ THE FIXTURE'S LIST IS NOT THE JOB'S LIST (#3452). A slice is a MATRIX concern of the job that
# owns the REAL list — `run-bash-shards.sh`'s own words — and it has no meaning inside a fixture
# whose list is three entries long. Dropped here, PRINTED so a lane reading the job log can see the
# value was dropped on purpose instead of wondering why a slice did nothing.
#
# ⛔ AND IT IS NOT THE ONLY NAME THAT LEAKS — this line clears the runner's WHOLE env contract,
# not just the one that reddened first (review of this change, cycle 2, P1). ⛔ THE TWO-LANE PICTURE
# IS NOT WHAT IT WAS: `ci.yml`'s `bash-suites` and `ci-main.yml`'s `script-validate` both export the
# SAME knob now — `BASH_SHARD_SLICE`, at step level — so exactly ONE of the three is a knob a lane
# really exports today. It is also the one the RUNNER strips before every shard (`shard_exec` — the
# `env -u` wrapper in `scripts/run-bash-shards.sh`, agent-infra#3415), so the leak this defends
# against is NOT CI's own shards: it is a DIRECT invocation of this file, and any tree where that
# strip is removed. The other two are cleared so the suite is hermetic to the CONTRACT, not to
# today's single exported name:
#   * `BASH_SHARDS_BUDGET_SECS` is HISTORY, carried so the unset cannot read as a stale flag: main's
#     lane USED to export it (`BASH_SHARDS_BUDGET_SECS: '7800'` in `script-validate`'s bash-shards
#     step env). It no longer does (#3174, landed as PR #3235), because the runner now REFUSES the
#     BUDGET+SLICE pairing outright (`scripts/run-bash-shards.sh`, `rc 2`) and main became the 8-way
#     slice, so the budget had to go. It still matters here for the same reason the slice does: the
#     runner refuses the pair BY NAME, so an inherited budget makes a sliced ARM 3 meet THAT refusal
#     instead of the slice one it pins. On the pre-fix head (`9b7ed763`, no `env -u` on the child)
#     that reddened ARM 3: `PASS 12 · FAIL 1` with only `BASH_SHARDS_BUDGET_SECS=7800` inherited.
#     Recorded rather than dropped — an unset whose stated pollution source no longer exists reads as
#     a stale flag, and the next reader would delete it.
#   * a SET-but-EMPTY budget is REFUSED by the runner as a missing value, not read as "no deadline".
#     Hence the test below is PRESENCE (`+set`), never non-emptiness — but for the NOTICE's sake,
#     not the runner's: the `unset` is unconditional, so the value is dropped under either spelling
#     and that refusal never happens here whatever the test says. What `:-` would cost is the
#     SIGNAL: a set-but-empty inherited value would be dropped with nothing printed, and this
#     notice is the only evidence a lane has that the drop happened at all.
#   * `SHARD_BOUND` is the third name in the runner's contract. NO lane exports it today — `grep -rn
#     SHARD_BOUND .github/` finds nothing — so this is contract hygiene rather than a leak anyone
#     currently causes, and it is cleared for that reason alone.
# TWO CLEARANCES, ON PURPOSE, and both remove the leaked budget before ARM 3's child starts: this
# `unset`, and the `env -u` on that child. The `env -u` is what makes the arm answer ONE variable;
# it is not the only thing standing between the budget and the arm, and this comment must not be
# read as claiming it is. `tests/run-bash-shards-bound/run.sh` §0 clears the identical set;
# `tests/ci-lane-parity/run.sh` uses this same `env -u BASH_SHARD_SLICE -u BASH_SHARDS_BUDGET_SECS`
# spelling per invocation — two different files, cited separately on purpose. (Formerly cited by two
# line numbers; one of them had already rotted onto an `else`, which is the failure mode the guard
# below names, so both are gone.)
if [ "${BASH_SHARD_SLICE+set}" = set ] || [ "${BASH_SHARDS_BUDGET_SECS+set}" = set ] || [ "${SHARD_BOUND+set}" = set ]; then
  echo "  · inherited runner config dropped for the fixtures — BASH_SHARD_SLICE='${BASH_SHARD_SLICE-<unset>}' BASH_SHARDS_BUDGET_SECS='${BASH_SHARDS_BUDGET_SECS-<unset>}' SHARD_BOUND='${SHARD_BOUND-<unset>}'. They are the OUTER job's, over the REAL list; the fixture's 3-shard list is not that list, so the fixtures run with none of them set (#3452; ARM 3 pins the HAZARD and the runner's refusal, NOT this drop — see the header). A bare dash (not colon-dash) is used in this echo for the same reason the test above is +set: a SET-but-EMPTY value must print as '' and an ABSENT one as <unset>, or the two are indistinguishable in the log this notice exists for."
fi
unset SHARD_BOUND BASH_SHARDS_BUDGET_SECS BASH_SHARD_SLICE

# ⛔ THE FIXTURE MUST NOT ASK THE HOST'S PROCESS TABLE ANYTHING (#3011): a copy of the runner calls
# `fixture_guard_placement` with the DEFAULT root set, so on a box with a live cell controller the
# copy would exit 78 and this suite's verdict would depend on the machine. An explicit EMPTY value
# is the helper's documented "no roots" seam (no colon: an empty value must survive).
FIXTURE_LIVE_ROOTS=
export FIXTURE_LIVE_ROOTS

TMP="$(mktemp -d "${TMPDIR:-/tmp}/shard-recap.XXXXXX")" || {
  echo "❌ run-bash-shards.recap: cannot create a temp dir — refusing to report on a suite that did not run"
  exit 2
}
trap 'rm -rf "$TMP"' EXIT

# narrow_runner <out> — the SHIPPED runner with its ONE data list narrowed to the fixture's shards.
# SLICE_CONTROL — the value ARM 3 hands the fixture: index 5 of 8 over a 3-shard list, i.e. a slice
# with nothing to run. That is exactly what a real `bash-suites (<n>)` job exports.
SLICE_CONTROL="5/8"

narrow_runner() {
  awk '
    /^SUITE_GLOBS=\($/ { print "SUITE_GLOBS=( \"shards/*.test.sh\" )"; skip = 1; next }
    skip && /^\)$/ { skip = 0; next }
    skip { next }
    { print }
  ' "$RUNNER" >"$1"
}

# build_fixture <root> <slow|fast> — a minimal checkout the runner can own:
#   shards/a-fail.test.sh   always FAILS (the failure the recap must name)
#   shards/b-slow.test.sh   writes <marker> then sleeps (in `fast` mode it returns immediately)
#   shards/c-later.test.sh  must NEVER be reached in the interrupted arm
#   scripts/sweepable.sh    keeps the syntax-sweep counter non-empty (its sentinel requires it)
#   the #3011 guard helper, without which the runner REFUSES to run (fail-closed).
build_fixture() {
  local root="$1" mode="$2"
  mkdir -p "$root/scripts/orchestrator-harness" "$root/shards" || return 1
  cp "$ROOT/scripts/orchestrator-harness/fixture-hermetic.sh" "$root/scripts/orchestrator-harness/" || return 1
  printf '#!/bin/bash\n:\n' >"$root/scripts/sweepable.sh" || return 1
  printf '#!/bin/bash\nprintf "fixture failure\\n"\nexit 1\n' >"$root/shards/a-fail.test.sh" || return 1
  if [ "$mode" = "slow" ]; then
    printf '#!/bin/bash\n: >"$SLOW_SHARD_MARKER"\nsleep 30\nexit 0\n' >"$root/shards/b-slow.test.sh" || return 1
  else
    printf '#!/bin/bash\nexit 0\n' >"$root/shards/b-slow.test.sh" || return 1
  fi
  printf '#!/bin/bash\nexit 0\n' >"$root/shards/c-later.test.sh" || return 1
  narrow_runner "$root/scripts/runner-narrow.sh" || return 1
}

if [ ! -r "$RUNNER" ]; then
  echo "❌ run-bash-shards.recap: cannot find the runner — refusing to report on a suite that did not run"
  exit 2
fi

echo ""
echo "1. INTERRUPTED — SIGTERM mid-run must print the recap, marked INCOMPLETE"
KILLED="$TMP/killed"
if ! build_fixture "$KILLED" slow; then
  echo "❌ run-bash-shards.recap: cannot build the fixture — refusing to report"
  exit 2
fi
SLOW_SHARD_MARKER="$TMP/slow.started"
export SLOW_SHARD_MARKER
rm -f "$SLOW_SHARD_MARKER"

# ⛔ JOB CONTROL IS LOAD-BEARING: `set -m` puts the background run in its OWN process group, so
# `kill -TERM -<pid>` reaches the RUNNER *and* the shard it waits on. Bash defers a trap until the
# foreground child finishes, so signalling the runner alone would print the recap only after the
# shard returned — an hour later on the real job. GitHub terminates the process GROUP on a timeout.
# ⛔ THE FIXTURE MUST NOT INHERIT THE CALLER'S DISPATCH DECISION — and this `env -u` is the half of
# that contract which sits at the SPAWN SITE. `run-bash-shards.sh` scrubs the identical three names at
# its own `shard_exec`, but that guard protects a shard the RUNNER spawns; it cannot reach the
# runner when a TEST spawns it, and this suite spawns `runner-narrow.sh` DIRECTLY. The narrowed list is
# THREE shards, so a child handed the outer job's slice REFUSES — `❌ BASH_SHARD_SLICE asks for 8
# slice(s) of 3 listed shard(s)` (run-bash-shards.sh:432, rc 2) — and every arm below would then read a
# refusal as if it were a recap. `env -u` (not `unset`) is the contract, and it keeps `$!` equal to the
# runner's pid because `env` execs in place — a wrapper subshell would reintroduce the pid-vs-pgid
# ambiguity :907-925 documents.
#
# ⛔ WHAT THIS GUARD IS **NOT**, stated so the comment is not over-read: it is NOT claiming that CI's
# `bash-suites` lane leaks today — it does not, and it is covered twice over. `bash-suites` exports
# `BASH_SHARD_SLICE=<i>/<n>` for the whole step, as
#   `BASH_SHARD_SLICE: ${{ matrix.shard }}/${{ strategy.job-total }}`
# in its shard step — cited by QUOTE and not by line number, which is ci-main.yml's own rule for its
# citations: "a citation that rots is worse than none". But every SHARD is already scrubbed by
# `shard_exec` before this file runs, and the script-wide `unset` in the notice block above (#3452)
# drops it again for everything below. Both halves are MUTUALLY SUFFICIENT —
# measured on the merged tree with `BASH_SHARD_SLICE=5/8`, the value a real `bash-suites (<n>)` job
# hands its shards:
#   · `unset` KEPT,   `env -u` REMOVED  ->  PASS 13 · FAIL 0   (#3452 alone covers the CI lane)
#   · `unset` REMOVED, `env -u` KEPT    ->  PASS 13 · FAIL 0   (this guard alone is sufficient here)
#   · BOTH removed                      ->  PASS  4 · FAIL 9   (the leak, reproduced — the hazard is real)
# So what this buys is defence in depth at the one seat the runner's guard cannot reach: the leak
# re-opens at these two sites if that `unset` ever moves or is deleted, and a DIRECT invocation (a
# repro shell that exports the slice and runs THIS FILE rather than the runner) relies on this guard
# alone.
set -m
env -u BASH_SHARD_SLICE -u BASH_SHARDS_BUDGET_SECS -u SHARD_BOUND \
  bash "$KILLED/scripts/runner-narrow.sh" >"$TMP/killed.out" 2>&1 &
kpid=$!
set +m

# Wait until the blocking shard has STARTED, so the signal lands with a shard in flight and shard 3
# guaranteed untouched. Bounded: a fixture that never starts is a NAMED failure.
started=0
i=0
while [ "$i" -lt 300 ]; do
  if [ -f "$SLOW_SHARD_MARKER" ]; then started=1; break; fi
  sleep 0.1
  i=$((i + 1))
done
if [ "$started" = "1" ]; then
  ok "the fixture's blocking shard started (so the signal lands with a shard IN FLIGHT)"
else
  bad "the fixture's blocking shard never started — the interrupted arm cannot prove anything"
fi

kill -TERM -"$kpid" 2>/dev/null || kill -TERM "$kpid" 2>/dev/null
wait "$kpid"
KRC=$?
KOUT="$(cat "$TMP/killed.out" 2>/dev/null)"

if [ "$KRC" -eq 1 ]; then
  ok "the interrupted run exits 1 (an interrupted run proves nothing, so it must never read green)"
else
  bad "the interrupted run exited $KRC, expected 1 — a killed run that exits 0 certifies a hole"
fi
if grep -q '❌ failing shard(s):' <<<"$KOUT"; then
  ok "(a) the INTERRUPTED run PRINTED its recap (today's code prints none at all)"
else
  bad "(a) NO RECAP on an interrupted run — this is #3174 exactly: $(tr '\n' '|' <<<"$KOUT" | cut -c1-400)"
fi
if grep -q '^❌ failing shard(s): .*shards/a-fail\.test\.sh' <<<"$KOUT"; then
  ok "(b) the recap NAMES the failing shard (shards/a-fail.test.sh) — a count is not an attribution"
else
  bad "(b) the recap did not name shards/a-fail.test.sh: $(grep -F 'failing shard' <<<"$KOUT" | head -2)"
fi
if grep -q 'RECAP INCOMPLETE (2/3 shards ran)' <<<"$KOUT"; then
  ok "(c) the marker is present with HONEST counts: RECAP INCOMPLETE (2/3 shards ran)"
else
  bad "(c) the incomplete marker is missing or the counts are dishonest (want 'RECAP INCOMPLETE (2/3 shards ran)'): $(grep -F 'RECAP INCOMPLETE' <<<"$KOUT" | head -2)"
fi
if grep -q '1 never reached' <<<"$KOUT"; then
  ok "(c') the recap states that 1 listed shard was NEVER REACHED (the unproven half, said out loud)"
else
  bad "(c') the recap does not say a shard was never reached: $(grep -F 'never reached' <<<"$KOUT" | head -2)"
fi
if grep -q 'failing shard(s): .*shards/c-later\.test\.sh' <<<"$KOUT"; then
  bad "(c'') the shard that NEVER RAN was reported as FAILING — a run that did not happen is not a result"
else
  ok "(c'') the shard that never ran (shards/c-later.test.sh) is NOT reported as a failure"
fi
if grep -q 'NOTHING IS PROVEN' <<<"$KOUT"; then
  bad "the recap claimed nothing was proven while a shard HAD failed — the message must match the counters"
else
  ok "(c''') the recap reported the failure it had counted (not the empty-accumulator message)"
fi

# ⛔ THE COUPLING ARM (review of this change, cycle 2, P2): the marker the RUNNER prints must be the
# marker the PARSER recognises. Without this, the two literals could drift and every fixture would
# still pass — both sides would be self-consistent and jointly wrong. So the interrupted run's ACTUAL
# capture is fed to `scripts/ci_exemption.py` here, not a hand-written copy of the line.
if ! command -v python3 >/dev/null 2>&1; then
  ok "(d) python3 absent — the parser-side coupling arm cannot run here (the parser suite covers it)"
else
  python3 "$ROOT/scripts/ci_exemption.py" ids --log "$TMP/killed.out" >"$TMP/k-ids.out" 2>"$TMP/k-ids.err"
  KIRC=$?
  KIERR="$(cat "$TMP/k-ids.err" 2>/dev/null)"
  if [ "$KIRC" -eq 4 ] && [ ! -s "$TMP/k-ids.out" ] && grep -q 'UNPROVEN' <<<"$KIERR"; then
    ok "(d) the runner's ACTUAL interrupted capture is recognised by the parser (rc 4, no ids, UNPROVEN)"
  else
    bad "(d) the parser did not recognise the runner's own marker (rc $KIRC, ids=[$(sed -n '1,2p' "$TMP/k-ids.out" | tr '\n' ' ')]): the marker and the parser have DRIFTED"
  fi
fi

echo ""
echo "2. HAPPY PATH — a COMPLETE run recaps WITHOUT the incomplete marker"
COMPLETE="$TMP/complete"
if ! build_fixture "$COMPLETE" fast; then
  echo "❌ run-bash-shards.recap: cannot build the fixture — refusing to report"
  exit 2
fi
# The same spawn-site contract as ARM 1's child above — see the ⛔ note in the ARM 1 section for what
# it is and is not. (Deliberately NOT a line number, here or in that note: a same-file pin drifts on
# every edit above it, and this comment's own first draft carried one that had already gone stale.)
# Kept inline for the same reason: `env` execs in place, so `$?` is the runner's own status.
env -u BASH_SHARD_SLICE -u BASH_SHARDS_BUDGET_SECS -u SHARD_BOUND \
  bash "$COMPLETE/scripts/runner-narrow.sh" >"$TMP/complete.out" 2>&1
CRC=$?
COUT="$(cat "$TMP/complete.out" 2>/dev/null)"

if [ "$CRC" -eq 1 ]; then
  ok "the complete run with one failing shard exits 1 (the failure arm still works)"
else
  bad "the complete run exited $CRC, expected 1"
fi
if grep -q '^❌ failing shard(s): .*shards/a-fail\.test\.sh' <<<"$COUT"; then
  ok "a COMPLETE run still prints the recap and names the failing shard"
else
  bad "a COMPLETE run did not print the recap: $(tr '\n' '|' <<<"$COUT" | cut -c1-400)"
fi
if grep -q 'RECAP INCOMPLETE' <<<"$COUT"; then
  bad "the incomplete marker FIRED ON THE HAPPY PATH — a marker that is always present is not a signal"
else
  ok "the incomplete marker does NOT fire on the happy path (so its presence MEANS something)"
fi

# ARM 3 — THE MUTATION CONTROL (#3452). Hand the SAME fixture the outer job's slice and the runner
# must refuse: that is the red this suite shipped in the sharded lane, and this arm is what keeps
# the mitigation above from being deleted as unexplained noise. ⛔ ONE VARIABLE IS ISOLATED ON
# PURPOSE: the other two runner knobs are `env -u`n out of the child, because `BASH_SHARDS_BUDGET_SECS`
# plus a slice is a DIFFERENT refusal (a positive budget and a slice do not compose) and would satisfy
# this arm's `rc 2` for the wrong reason, or fail it for a reason that is not the one asserted.
BASH_SHARD_SLICE="$SLICE_CONTROL" env -u BASH_SHARDS_BUDGET_SECS -u SHARD_BOUND bash "$COMPLETE/scripts/runner-narrow.sh" >"$TMP/sliced.out" 2>&1
SRC=$?
SOUT="$(cat "$TMP/sliced.out" 2>/dev/null)"
# The refusal's count is DERIVED from SLICE_CONTROL, never re-typed: a literal here would let the
# control drift away from the value it claims to describe and still pass.
SLICE_COUNT="${SLICE_CONTROL##*/}"
if [ "$SRC" -eq 2 ] && grep -q "asks for $SLICE_COUNT slice(s) of 3 listed shard(s)" <<<"$SOUT"; then
  ok "(mutation) the SAME fixture WITH BASH_SHARD_SLICE=$SLICE_CONTROL REFUSES (rc 2) — the hazard the fixtures are protected from is real"
else
  bad "(mutation) a sliced fixture run exited $SRC and did not name the slice refusal — the fixtures' isolation would then be described by nothing: $(tr '\n' '|' <<<"$SOUT" | cut -c1-300)"
fi

echo ""
printf 'PASS %d · FAIL %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
