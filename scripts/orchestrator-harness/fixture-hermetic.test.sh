#!/usr/bin/env bash
# fixture-hermetic.test.sh — the contract for agent-infra#3011.
#
# THE DEFECT. `harness-refresh.test.sh`'s ONLY teardown was `trap 'rm -rf "$T"' EXIT`. A deleted cwd
# does not end a process: every run left its REAL controllers resident, parked on a fifo `read` at
# 0 CPU and reparented to 1. MEASURED 2026-10-28 on `pi-cell-4`: 145 leaked controllers, load 33–39
# on 8 cores — the box's entire headroom, read by the fleet as "the cell is busy", plus a FALSE PASS
# from the suite that leaked them.
#
# HOW THESE CHECKS ARE WRITTEN. Each one drives the SHIPPED helper (`fixture-hermetic.sh`) — never a
# re-implementation, which would pass on the broken copy too. The leak arm starts a REAL fifo-blocked
# controller in its own process group, exactly as `start_ctrl` does, and asserts on the PROCESS TABLE
# after the teardown, so it fails if the reaper signals the wrong id, skips a ledger entry, or does
# not signal at all. The detector has its own non-vacuity arm (H5): the very read that decides the
# verdict is driven against a group left alive, and then against the same group after a real reap, so
# neither "never signals" nor "always red" can pass.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/fixture-hermetic.sh"
SHARDS="$HERE/../run-bash-shards.sh"
REFRESH_TEST="$HERE/harness-refresh.test.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

echo "==> fixture-hermetic contract ($HERE)"
[ -f "$HELPER" ] || { echo "  ❌ missing $HELPER"; exit 1; }
# shellcheck source=/dev/null
. "$HELPER"

T="$(mktemp -d "${TMPDIR:-/tmp}/fixture-hermetic.XXXXXX")" || { echo "  ❌ mktemp failed"; exit 1; }
fixture_hermetic_init "$T/.pgids" "$T"

# A controller-shaped process: the exact argv a suite's `start_ctrl` produces, parked on a fifo read
# so it neither exits nor burns CPU — the measured shape of all 145 leaked instances.
plant() { # plant <dir> -> prints pid
  local d="$1" f
  mkdir -p "$d/scripts/orchestrator-harness"
  # ⛔ THE FIFO LIVES INSIDE $T, NOT IN /tmp (agent-infra#3011 residue). `mktemp -u` never creates a
  # file, so a /tmp path here leaves one junk fifo per plant (4+ per run) — the same residue the
  # sibling fix in harness-refresh.test.sh moved inside its own temp dir. AND `mkfifo` MUST SUCCEED:
  # a failing one leaves a plant whose `read` exits immediately, which turns H8 into a full recursive
  # shard run, with the guard under test as its only bound.
  f="$(mktemp -u "$T/fixture-hermetic-fifo.XXXXXX")"
  mkfifo "$f" || { echo "  ❌ plant: mkfifo failed at $f"; exit 1; }
  printf 'read -r _ < %s\n' "$f" > "$d/scripts/orchestrator-harness/orch-loop.sh"
  fixture_start_group bash "$d/scripts/orchestrator-harness/orch-loop.sh"
}
alive() { kill -0 "$1" 2>/dev/null; }

# ── H1–H3: the placement guard ─────────────────────────────────────────────────────────────────
# ⛔ THE GUARD KEYS ON "A CONTROLLER EXECUTES FROM A LIVE ROOT", NOT "THE DIRECTORY EXISTS". A bare
# directory is a stale flag (/tmp/cell-home survives on a laptop with no controller behind it), and
# refusing on it is a false block on a healthy machine.
echo "=== H1: no controller on a live root -> the suite runs (a stale directory is not a live cell) ==="
ROOT1="$T/root1"; mkdir -p "$ROOT1"
OUT="$(FIXTURE_LIVE_ROOTS="$ROOT1" bash -c '. "$1"; fixture_guard_placement "x.test.sh"' _ "$HELPER" 2>&1)"; rc=$?
ck "an empty cell root does not refuse the run (rc=$rc)" "$rc"
case "$OUT" in *REFUSES*) bad "it refused on directory presence alone" ;; *) ok "…and it printed no refusal" ;; esac

echo "=== H2: a controller executing from a live root -> REFUSES (rc 78), naming pid and root ==="
ROOT2="$T/root2"; P2="$(plant "$ROOT2" | tail -1)"
OUT="$(FIXTURE_LIVE_ROOTS="$ROOT2" bash -c '. "$1"; fixture_guard_placement "x.test.sh"' _ "$HELPER" 2>&1)"; rc=$?
ck "it refuses to run a suite on a live cell (rc=$rc, want 78)" "$([ "$rc" -eq 78 ] && echo 0 || echo 1)"
case "$OUT" in *"pid $P2"*) ok "the refusal names the offending controller (pid $P2), so it is actionable" ;;
              *) bad "the refusal does not name pid $P2: $OUT" ;; esac
case "$OUT" in *"$ROOT2"*) ok "…and the live root it read" ;; *) bad "the root is not named: $OUT" ;; esac

echo "=== H3: the same box with explicit opt-in -> runs, and says so ==="
OUT="$(FIXTURE_LIVE_ROOTS="$ROOT2" HARNESS_SUITE_ALLOW_LIVE_CELL=1 bash -c '. "$1"; fixture_guard_placement "x.test.sh"' _ "$HELPER" 2>&1)"; rc=$?
ck "HARNESS_SUITE_ALLOW_LIVE_CELL=1 overrides the refusal (rc=$rc)" "$rc"
case "$OUT" in *"LIVE cell"*) ok "…and the override is DISCLOSED, not silent" ;; *) bad "the override was silent: $OUT" ;; esac
alive "$P2" || bad "the guard killed the plant — it must only refuse, never signal"
fixture_reap_all >/dev/null 2>&1

# ── H4: the leak test (this is the arm that goes RED if the reaper is reverted) ────────────────
echo "=== H4: a fixture controller started by a suite does not survive the teardown ==="
P4="$(plant "$T/h4" | tail -1)"
sleep 0.3
ck "the plant is ALIVE before the teardown (pid $P4) — otherwise this case passes vacuously" "$(alive "$P4" && echo 0 || echo 1)"
ck "…and its group is recorded in the ledger" "$(grep -qx "$P4" "$FIXTURE_PGID_FILE" && echo 0 || echo 1)"
# ⛔ AND ASSERT THE GROUP ITSELF, NOT JUST THAT THE PID DIES (review, cycle 3). `fixture_terminate`
# falls back to the PID when no group exists, so a plant that is NOT in its own group is still
# killed — which means reverting the `setpgrp`-before-`exec` idiom (or `fixture_start_group` itself)
# leaves every OTHER arm green while the GROUP guarantee, and every descendant of a fixture,
# silently disappears. That is the false PASS #3011 exists to close, one layer up. This is the
# mechanism's only discriminator, so it is paired with a control that must answer the other way —
# otherwise "pgid == pid" would be satisfied by any process that happens to lead its own group.
ck "…and it LEADS its own process group (pgid == pid), so a reap ends its descendants too" \
   "$([ "$(ps -o pgid= -p "$P4" 2>/dev/null | tr -d ' ')" = "$P4" ] && echo 0 || echo 1)"
bash -c 'sleep 20' & UNGROUPED=$!
sleep 0.3
ck "…and the same read says the OPPOSITE for a plain 'bash … &' start (pgid pid), so it is not vacuous" \
   "$([ "$(ps -o pgid= -p "$UNGROUPED" 2>/dev/null | tr -d ' ')" != "$UNGROUPED" ] && echo 0 || echo 1)"
kill "$UNGROUPED" 2>/dev/null; wait "$UNGROUPED" 2>/dev/null
fixture_reap_all; rc=$?
ck "fixture_reap_all reports every group gone (rc=$rc)" "$rc"
sleep 0.2
ck "…and the controller is GONE from the process table, not merely signalled" "$(alive "$P4" && echo 1 || echo 0)"

# ── H5: the detector is not vacuous ───────────────────────────────────────────────────────────
# ⛔ A REAPER THAT NEVER SIGNALS AND ONE THAT SIGNALS CORRECTLY BOTH EXIT 0 unless the check CAN
# fail. `fixture_survivors` is the read that decides the verdict, so drive IT with a group that is
# deliberately still alive: it must come back nonzero and name the group. (A group missing from the
# ledger is invisible BY DESIGN — that is the ledger's contract, not the detector's — so the arm the
# reaper's verdict actually depends on is this one, exercised directly.)
echo "=== H5: a live group is reported as a survivor (non-vacuity of the reaper's verdict) ==="
P5="$(plant "$T/h5" | tail -1)"
sleep 0.3
OUT="$(fixture_survivors "$P5" 2>&1)"; rc=$?
ck "a group that is still alive is caught (rc=$rc, want nonzero)" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
case "$OUT" in *"FIXTURE LEAK"*) ok "…and it is named as a LEAK with its argv, not swallowed" ;;
              *) bad "the survivor was not reported: $OUT" ;; esac
case "$OUT" in *"$P5"*) ok "…naming the group id ($P5)" ;; *) bad "the group id is missing from the report" ;; esac
alive "$P5" && ok "…and it really is still running, so the report is a measurement" || bad "the plant died; H5 measured nothing"
# …and the same read after a REAL reap must answer 0, or "always red" would satisfy the arm above.
fixture_reap_all >/dev/null 2>&1
fixture_survivors "$P5" 2>/dev/null; rc=$?
ck "…and once reaped the same read answers 0, so the check is not a constant (rc=$rc)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# ── H6–H7: wiring — "fixed but nothing calls it" is the repo's measured review failure ─────────
echo "=== H6: the leaker's teardown actually goes through the helper ==="
grep -q 'fixture_hermetic_init' "$REFRESH_TEST"; ck "harness-refresh.test.sh installs the hermetic teardown" $?
# ⛔ ABSENCE MUST BE ASSERTED WITH A NEGATION, AND SCOPED AWAY FROM COMMENTS. The first version of
# this arm was `grep -q "trap 'rm -rf …' EXIT"; ck … $?` — which passes when the string is FOUND,
# i.e. exactly when the defect is PRESENT. It was green only because the explanation in that file's
# own comment quotes the old line, so it could never have caught a regression (found by a VGATE
# reviewer, and it is the same false-PASS class this whole change exists to close). A real code
# `trap` starts a line (after optional whitespace) with `trap`; a comment starts with `#`, so
# anchoring to `^[[:space:]]*trap` discriminates the two.
grep -qE "^[[:space:]]*trap 'rm -rf" "$REFRESH_TEST"; rc=$?
ck "…and no bare 'rm -rf'-only trap remains in CODE (it reaped nothing)" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
grep -q 'fixture_guard_placement' "$REFRESH_TEST"; ck "…and it refuses to run on a live cell" $?
# ⛔ AND PIN THE START ITSELF, NOT JUST THE TRAP (review, cycle 2). With the arms above satisfied, a
# revert of `start_ctrl` to the old `bash … &` leaves EVERY arm green: the trap still exists, the
# guard still exists, the ledger merely stays empty because nothing records a group — and the suite
# passes while leaking again. That is precisely the false PASS this change exists to close, one
# layer up. Anchored to `^[[:space:]]*` so the explanation in that file's own comment cannot satisfy
# it (the same trap the bare-`rm -rf` arm above was already fixed for).
grep -qE '^[[:space:]]*fixture_start_group bash ' "$REFRESH_TEST"; ck "…and start_ctrl starts the controller in its OWN group" $?
grep -qE '^[[:space:]]*bash "\$1/scripts/orchestrator-harness/orch-loop\.sh"' "$REFRESH_TEST"; rc=$?
ck "…and no bare background 'bash …' start remains in CODE (it is not its own group)" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

echo "=== H7: the single shard seam guards every suite it runs ==="
grep -q 'fixture_guard_placement' "$SHARDS"; ck "run-bash-shards.sh calls the placement guard" $?
# ⛔ AND IT CANNOT BE AN INERT GUARD: an unloadable helper must REFUSE the run, not exit 127 once and
# then run every suite unguarded — "an enforcer that cannot fire" is the class #3011 belongs to, and
# `bash -n` cannot see it.
grep -q 'command -v fixture_guard_placement' "$SHARDS"; ck "…and fails CLOSED if the helper cannot be loaded" $?

# ── H8: end-to-end — the REAL seam refuses on a live cell ─────────────────────────────────────
# The unit arms above drive the function; this drives the shipped driver, so the wiring under review
# is the thing that refuses. `--list` is checked too: it runs nothing, so it must NOT be blocked
echo "=== H8: driving the shipped run-bash-shards.sh: --list still reads, a live cell is refused ==="
LIST_OUT="$(bash "$SHARDS" --list 2>&1)"; rc=$?
ck "--list still works on an ordinary box (rc=$rc)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
case "$LIST_OUT" in *fixture-hermetic.test.sh*) ok "…and it derives this new suite into the shard list (wired by the file, not by an edit)" ;;
                              *) bad "the new suite is not in the derived list" ;; esac
ROOT8="$T/root8"; P8="$(plant "$ROOT8" | tail -1)"
# ⛔ WITHOUT THIS PRECONDITION H8 MEASURES NOTHING: a dead plant means the guard correctly finds no
# controller, rc is 0, and the assertion fails for a reason that is about the FIXTURE, not the guard —
# or, worse, the full shard list executes (H4 already carries the same precondition; H8 lacked it).
sleep 0.3
ck "…and the plant is ALIVE before driving the driver (pid $P8) — otherwise the refusal is vacuous" "$(alive "$P8" && echo 0 || echo 1)"
# ⛔ AND THE PRECONDITION MUST GATE THE INVOCATION, not merely be reported (review, cycle 3). `ck` only
# increments the failure counter, so a dead plant still fell through to the driver: with no controller
# present the guard passes, the driver runs the WHOLE derived shard list (minutes), and the inner
# fixture-hermetic.test.sh recurses the same way. The failure direction was safe — rc≠78 reds the arm —
# but a broken `plant` turned the cheapest shard into an unbounded recursive full-population run.
if alive "$P8"; then
  OUT="$(FIXTURE_LIVE_ROOTS="$ROOT8" bash "$SHARDS" 2>&1)"; rc=$?
  ck "the shipped driver REFUSES to run shards on a live cell (rc=$rc, want 78)" "$([ "$rc" -eq 78 ] && echo 0 || echo 1)"
  case "$OUT" in *"REFUSES TO RUN ON A LIVE CELL"*) ok "…with its own refusal, not a shard failure" ;;
                                  *) bad "the refusal text is missing: $OUT" ;; esac
  case "$OUT" in *"SHARD FAILED"*) bad "it ran shards anyway after refusing" ;; *) ok "…and no shard was executed" ;; esac
else
  bad "H8 skipped the driver — the plant died, so a passing guard could not be attributed to it"
fi
fixture_reap_all >/dev/null 2>&1

echo "───────────────────────────────────────────────"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
