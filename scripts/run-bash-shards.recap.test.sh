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
set -m
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

echo ""
printf 'PASS %d · FAIL %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
