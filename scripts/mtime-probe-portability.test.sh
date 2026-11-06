#!/usr/bin/env bash
# mtime-probe-portability.test.sh — pins the BSD-first `stat -f` probes
# agent-infra#3434 left behind, so the spelling cannot come back.
#
# Run: bash scripts/mtime-probe-portability.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. Hermetic: every log and
# lock is a fixture in a temp directory, and the scripts are driven with `HOME`
# pointed there, so no real state is read or written. Host facilities used:
# `mktemp`, `mkdir`, `grep`, `sed`, `wc`, `tr`, `cat`, `basename`, `date`, `touch`, and `bash -n`.
#
# ⛔ THREE SCRIPTS, TWO KINDS OF PROBE. `stat -f %m` (mtime) is repaired in
# `monitor-worker.sh` and `lane-scan-fallback.sh`; `stat -f %z` (size) is repaired in
# `unblock-lane.sh`, where the same GNU mis-parse yields a FALSE PASS rather than a wrong
# age — two probes of an unchanged file differ as the box's free blocks churn. All three
# are pinned here, because `check-portability-traps.sh` is blind to all three (below).
#
# WHY THIS SUITE EXISTS — the gate could not see the bug it is about.
# `scripts/check-portability-traps.sh`'s `stat-c-gnu` rule (`:1371`) fires on
# `stat -c` WITHOUT an `-f` counterpart. A ONE-SIDED BSD-first `stat -f %m`
# matches no rule at all (`:1344` blesses the two-sided chain), so the gate
# returns "✅ no NEW cross-platform traps" on the broken code. Measured:
#
#   $ git show origin/main:scripts/monitor-worker.sh > /tmp/pitfall/scripts/monitor-worker.sh
#   $ bash scripts/check-portability-traps.sh --root /tmp/pitfall --targets …
#   …(75 baseline-shrink rows elided)…
#   ✅ no NEW cross-platform traps (0 grandfathered across 0 file/rule pairs)   rc=0
#
# …for a line that aborts on every Linux box. A gate blind in this direction
# cannot pin the fix, so the pin lives here instead. Issue #3434 records the
# gap; the rule to close it is the mirror of `stat-c-gnu`.
#
# ⛔ THE SHAPE: `stat -f %m` is BSD-only. On GNU coreutils `-f` is `--file-system`,
# so `stat -f %m PATH` prints a whole filesystem block to STDOUT and exits 1.
# Inside a SINGLE `$( … || … )` substitution the GNU fallback APPENDS the epoch to
# that block, so the variable is non-numeric and the arithmetic either aborts
# (`File: unbound variable`, under `set -u`) or yields a nonsense age.
#
# ⛔ WHY BOTH ARMS: the two failure modes are opposite. A probe that silently
# yields 0 makes every log look infinitely OLD; a probe that silently yields `now`
# makes every log look fresh for ever. A fresh-only suite therefore passes on a
# probe that hardcodes `now`, so the suite also ages a log and requires STALE.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR="$SCRIPT_DIR/monitor-worker.sh"
LANE_SCAN="$SCRIPT_DIR/lane-scan-fallback.sh"
UNBLOCK="$SCRIPT_DIR/unblock-lane.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_contains()     { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi }
assert_not_contains() { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi }
assert_eq()           { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi }

for f in "$MONITOR" "$LANE_SCAN" "$UNBLOCK"; do
    [ -f "$f" ] || { echo "❌ missing $f"; exit 1; }
done

T="$(mktemp -d "${TMPDIR:-/tmp}/mtime-probe-portability.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# ⛔ THE EXECUTED VIEW DROPS *FULL-LINE AND TRAILING* COMMENTS — never `cat`, and never a
# column-0-only strip. Three ways a comment alone satisfies a positive arm, all measured:
#   * `grep -v '^#'`  — leaves INDENTED comments (the probe in `lane-scan-fallback.sh` sits inside
#     an `if`, so a comment written next to it is indented by construction);
#   * `grep -v '^[[:space:]]*#'` — still leaves a TRAILING comment. `MTIME="$(stat -c %Y "$LOG")"
#     \  # equivalently: date -r "$LOG" +%s` carried `date -r` in its view and passed 16/16 while
#     being GNU-only, i.e. the one defect these arms exist to catch;
#   * `cat` — leaves every comment.
# So: strip trailing comments FIRST, then drop what remains that is a full-line comment.
executed_view() { sed 's/[[:space:]]#.*$//' "$1" | grep -v '^[[:space:]]*#'; }

echo
echo "── executed-view pins (the rationale MAY name the trap; executed code may not) ──"
for f in "$MONITOR" "$LANE_SCAN"; do
    name="$(basename "$f")"
    assert_not_contains "$(executed_view "$f")" 'stat -f %m' \
        "$name reads no mtime with the BSD-only 'stat -f %m'"
    assert_contains "$(executed_view "$f")" 'date -r' \
        "$name reads mtime with a form that works on GNU and BSD"
done
# unblock-lane.sh is the SIZE probe, not the mtime one: `stat -f %z` is the same GNU mis-parse
# (`-f` = --file-system), and its positive replacement is `wc -c`, not `date -r`.
assert_not_contains "$(executed_view "$UNBLOCK")" 'stat -f' \
    "unblock-lane.sh reads no size with the BSD-only 'stat -f'"
assert_contains "$(executed_view "$UNBLOCK")" 'wc -c' \
    "unblock-lane.sh reads size with a form that works on GNU and BSD"

echo
echo "── the shipped probe actually dates a real file (no non-numeric value) ──"
FRESH="$T/fresh.log"
printf 'stage: working\n[task-heartbeat] tick\n' > "$FRESH"
probe="$(date -r "$FRESH" +%s 2>/dev/null || echo 0)"
case "${probe:-}" in
    ''|*[!0-9]*) bad "date -r <path> +%s yielded a NON-NUMERIC value on this host: [$probe]";;
    *)           ok "date -r <path> +%s yields a numeric epoch ($probe)";;
esac
if [ "${probe:-0}" -gt 0 ] 2>/dev/null; then ok "the epoch is a real timestamp, not the 0 fallback"; else bad "the epoch fell back to 0 — the probe failed"; fi

echo
echo "── monitor-worker.sh: a FRESH log must read ALIVE (the pre-fix script aborted) ──"
out="$(bash "$MONITOR" "$FRESH" 60 2>&1)"; rc=$?
assert_eq "$rc" 0 "a fresh log exits 0"
assert_contains "$out" 'worker is ALIVE' "a fresh log is reported ALIVE"
assert_not_contains "$out" 'unbound variable' "the arithmetic did not die on a non-numeric operand"

echo
echo "── monitor-worker.sh: an AGED log must read STALE (a probe hardcoding now cannot pass both) ──"
OLD="$T/old.log"
printf 'stage: sleeping\n' > "$OLD"
# Backdate the mtime well past the bound. ⛔ `touch -d <relative>` is GNU-ONLY:
# BSD `touch -d` goes to `stime_darg`, which strptime()s an ABSOLUTE
# `%Y-%m-%d[ T]%H:%M:%S` and errors on anything else (Apple file_cmds
# touch/touch.c:103-106, :345-352; FreeBSD usr.bin/touch/touch.c:305-345). So the
# portable spelling is the ABSOLUTE `-t` form, with each host computing it.
touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)" "$OLD" 2>/dev/null \
  || touch -d '2 hours ago' "$OLD" 2>/dev/null || true
out="$(bash "$MONITOR" "$OLD" 60 2>&1)"; rc=$?
assert_eq "$rc" 1 "an aged log exits 1 (STALE)"
assert_contains "$out" 'appears STALE' "an aged log is reported STALE"

echo
echo "── lane-scan-fallback.sh: the LOCK AGE is computed (behavioural, not textual) ──"
# ⛔ THIS ARM EXISTS BECAUSE THE TEXT PINS ARE NOT ENOUGH (agent-infra#3509 review).
# Dropping the `+%s` from the shipped probe keeps every textual pin green while
# reintroducing the exact `File: unbound variable` abort this branch fixes — measured.
# A FRESH lock makes the script take its fast `already running` branch, so the
# probe runs end-to-end and nothing heavy is reached.
LH="$T/lane-home"
mkdir -p "$LH/.pi/agent/state/lane-scan-fallback.lock"
# ⛔ CAPTURE STDERR, DO NOT DISCARD IT (#3509 review round 5). `File: unbound variable` is printed
# by the SHELL, and `log()` is the only writer of $LLOG — so on the pre-fix script the arithmetic at
# `:58` aborts BEFORE any `log()` call, $LLOG is never even created, and an arm that greps $LLOG for
# `unbound variable` is a check that CANNOT FAIL: measured on `origin/main`'s script, the abort is on
# stderr (`line 53: File: unbound variable`, rc=1) while the state dir holds only the lock, so
# `cat $LLOG 2>/dev/null` yields the empty string and the arm printed ✅. `2>&1 >/dev/null` takes
# stderr to the capture and only then sends stdout to /dev/null — the order is load-bearing.
err="$(HOME="$LH" bash "$LANE_SCAN" 2>&1 >/dev/null)"; rc=$?
LLOG="$LH/.pi/agent/state/orchestrator-heartbeat.log"
assert_eq "$rc" 0 "a FRESH lock exits 0 (the age was computable)"
# ⛔ BOUNDED, not exact. The lock is created immediately before this call, so the true age is 0s —
# but a runner whose bash startup crosses a second boundary legitimately reports 1s (STALE_LOCK_S is
# 900, so 1s is still "fresh"). Pinning the literal `0s` reds intermittently on a loaded box —
# measured 2/200 direct runs, deterministic under `sleep 1.2` — which is a flaky pin, not a stricter
# one. What must be pinned is that the age is a COMPUTED SMALL NUMBER and not a filesystem block.
if grep -Eq 'already running \(lock [0-9]{1,2}s old\)' "$LLOG" 2>/dev/null; then
    ok "the lock age is a computed number (0-99s), not a filesystem block"
else
    bad "the lock age is a computed number (0-99s), not a filesystem block (missing: already running (lock <N>s old))"
fi
assert_not_contains "$err" 'unbound variable' \
    "the lock age arithmetic did not die (read from STDERR — $LLOG only exists IF the arithmetic worked)"

echo
# ⛔ THIS ARM EXISTS BECAUSE THE TEXT PINS ALONE WERE NOT ENOUGH (agent-infra#3509 review round 4).
# The executed-view arms above prove the file no longer SPELLS `stat -f`; they do not prove the
# value reaching the comparison is a BYTE COUNT. `stat -f %z` on GNU coreutils writes the whole
# filesystem block to stdout and exits 1, so two probes of an UNCHANGED file DIFFER as the box's
# free blocks/inodes churn — and `unblock-lane.sh` then prints PARENT RESUMED about a parent that
# never resumed. That is a false PASS on the one thing the tool exists to prove, and it is invisible
# to a text pin. So the tool is driven end-to-end against a fixture session file that grows exactly
# once, and the sizes it REPORTS must be the file's exact byte lengths — never a block (4096+).
echo "── unblock-lane.sh: the size probe sees a REAL write, and only a real write (behavioural) ──"
UH="$T/unblock-home"
SESSDIR="$UH/.pi/agent/sessions/aaaabbbb-cccc-dddd-eeee-ffff00001111"
mkdir -p "$SESSDIR"
SESS="$SESSDIR/sess-fix3509.jsonl"
printf '{"type":"user"}\n' > "$SESS"            # 16 bytes
BEFORE_BYTES="$(wc -c <"$SESS" | tr -d '[:space:]')"
AFTER_LINE='{"type":"assistant"}'
AFTER_BYTES=$((BEFORE_BYTES + ${#AFTER_LINE} + 1))
# A "parent" that resumes exactly once, AFTER the tool has taken its `before_size` reading (the
# tool kills the child and sleeps 3 s before its first re-read, so a 1 s delay lands inside the gap).
( sleep 1; printf '%s\n' "$AFTER_LINE" >>"$SESS" ) &
WRITER=$!
bash -c 'sleep 60' &                                # the parked child the tool kills
CHILD=$!
out="$(HOME="$UH" bash "$UNBLOCK" "$CHILD" fix3509 2>&1)"; rc=$?
kill "$WRITER" "$CHILD" 2>/dev/null
wait "$WRITER" "$CHILD" 2>/dev/null
assert_eq "$rc" 0 "the tool exited 0 when the parent resumed"
assert_contains "$out" 'PARENT RESUMED' "the resumed parent is reported as resumed"
# The two sizes in that line must be the exact byte lengths. `session 16 -> 37 bytes`.
assert_contains "$out" "session $BEFORE_BYTES -> $AFTER_BYTES bytes" \
    "the reported sizes are the file's exact byte counts ($BEFORE_BYTES -> $AFTER_BYTES), not a filesystem block"
# ⛔ NOT an arm: "no `No such file or directory` in the report" was DELETED here (#3509 review round 5).
# The fixture above guarantees `$F` resolves, so no input redirection can fail in that run and the
# assertion could never fire — measured: the leaking-order mutant scored PASS=23 FAIL=1, red only on
# the textual arm below. An arm that cannot fail is a false PASS inside the very suite that exists to
# stop false PASSes, so the leak is pinned where it can actually be seen — on the executable text.
# …and the same redirection-order trap, pinned on the executable text rather than by driving the
# 90 s not-resumed path: a command's redirections are applied LEFT TO RIGHT, and a failing `<"$F"`
# is reported by the SHELL before `2>/dev/null` takes effect — so `wc -c <"$F" 2>/dev/null` prints
# "No such file or directory" on EVERY probe (up to 32 of them) into the report. `$F` is empty
# whenever no session file matches, so this is the common case, not an edge one.
# ⛔ MUTANT NAMED: restoring `wc -c <"$F" 2>/dev/null` (or `<"$F"` with the redirection last) reds
# this arm. It accepts BOTH correct spellings — `wc -c 2>/dev/null <"$F"` and
# `{ wc -c <"$F"; } 2>/dev/null` — so it pins the DEFECT, not one of its fixes.
leaky="$(executed_view "$UNBLOCK" | grep 'wc -c' | grep -F '<"$F" 2>/dev/null' || true)"
assert_eq "$leaky" "" \
    "no wc -c probe puts 2>/dev/null after the input redirection (the error would leak into the report)"

echo
echo "── the three scripts still parse ──"
for f in "$MONITOR" "$LANE_SCAN" "$UNBLOCK"; do
    if bash -n "$f" 2>/dev/null; then ok "$(basename "$f") parses"; else bad "$(basename "$f") does not parse"; fi
done

echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  ✅ all checks passed"; exit 0; fi
echo "  ❌ $FAIL check(s) failed"; exit 1
