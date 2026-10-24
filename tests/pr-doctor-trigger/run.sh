#!/usr/bin/env bash
# tests/pr-doctor-trigger/run.sh — the EVENT-DRIVEN front end for `pr-doctor`.
#
# THE DEFECT THIS SUITE PINS. The fleet's repair actuator was TIMER-driven: `com.tortoise.pr-doctor`
# ran `StartInterval 1800`, so a PR that turned red one second after a pass waited up to 1800 s
# (mean 900 s) before any worker existed on it. The lead was not the repair — it was the timer.
# `scripts/pr-doctor-trigger.py` watches the PR surface with ONE `gh pr list` per poll and runs the
# EXISTING doctor when the fingerprint changes; the 1800 s timer survives as `--backstop`.
#
# WHAT IS ASSERTED, and why each one can FAIL:
#
#   A. the fingerprint is a FUNCTION OF THE SURFACE (`--dry-run-print` differs on a changed
#      `mergeStateStatus`). Without this every other assertion is vacuous — and the last section
#      proves it: a mutant whose `fingerprint()` returns a constant makes B's "changed surface runs
#      a pass" arm produce ZERO passes, i.e. the suite is falsifiable.
#   B. COLD START runs exactly one pass, and an IDENTICAL second read runs NONE — counted by
#      DOCTOR INVOCATIONS, not by stdout text. A constant fingerprint would still print
#      "no change" and still satisfy a text-only assertion; it cannot fake the counter.
#   C. a CHANGED surface runs ONE pass after the debounce — five rapid `updatedAt`/
#      `mergeStateStatus` moves coalesce into a single pass, not five.
#   D. an UNREADABLE surface is NOT QUIET (#2271: an empty/failed check surface must never read as
#      green). The doctor is not invoked, `PR-SURFACE-UNREADABLE` is logged on EVERY tick (so the
#      next tick retried), the previous fingerprint is KEPT (a surface that comes back unchanged
#      owes no pass), and the word "no change" never appears — those are different states.
#   E. the LOCK: a second instance exits 0 with `ALREADY-RUNNING` and runs no doctor. Concurrency
#      must be visible and exclusive rather than inferred from a plist nobody read.
#   F. `--once` (a supervisor's ExecStart) runs one pass and exits; a no-change `--once` runs none.
#
# HERMETIC: a throwaway HOME-free temp dir, a fake `gh` FIRST on PATH, and a fake `pr-doctor.py`
# BESIDE a copy of the trigger (the trigger resolves its doctor as `dirname($0)/pr-doctor.py`, so
# the copy's sibling IS the stub). It never reads the live account, never runs the real doctor, and
# never touches the real `/tmp/pr-doctor-trigger-*.lock`.
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
DOCTOR_LOG="$TMP/doctor-invocations.log"
: >"$DOCTOR_LOG"; echo ok >"$GH_MODE"

# ── the fake doctor: the ONLY thing that can prove "a pass ran" ────────────────────────────────
cat >"$APP/pr-doctor.py" <<'PY'
import os, sys
with open(os.environ["FAKE_DOCTOR_LOG"], "a") as fh:
    fh.write(" ".join(sys.argv[1:]) + "\n")
sys.exit(int(os.environ.get("FAKE_DOCTOR_RC", "0")))
PY

# ── the fake gh: one call shape only (`pr list --json …`), plus the two failure shapes ─────────
cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
mode="$(cat "$FAKE_GH_MODE" 2>/dev/null || echo ok)"
case "$mode" in
  fail)    echo "HTTP 502: bad gateway" >&2; exit 1 ;;
  garbage) printf 'this is not json\n'; exit 0 ;;
  *)       cat "$FAKE_GH_STATE" ;;
esac
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export FAKE_GH_STATE="$GH_STATE" FAKE_GH_MODE="$GH_MODE" FAKE_DOCTOR_LOG="$DOCTOR_LOG"

surface() { # <mergeStateStatus> <updatedAt>  — one open PR; the whole observable surface
  printf '[{"number":101,"mergeStateStatus":"%s","updatedAt":"%s","isDraft":false}]\n' "$1" "$2" >"$GH_STATE"
}
n_doctor() { wc -l <"$DOCTOR_LOG" | tr -d ' '; }
reset_doctor() { : >"$DOCTOR_LOG"; }

start_loop() { # <state-dir> <repo> <debounce> <logfile> → pid
  python3 "$APP/pr-doctor-trigger.py" --repo "$2" --repo-dir "$APP" \
      --poll 1 --debounce "$3" --backstop 1000000 --state-dir "$1" >"$4" 2>&1 &
  echo $!
}
wait_for() { # <file> <fixed-string> <tenths>
  local i=0
  while [ "$i" -lt "$3" ]; do
    grep -qF -- "$2" "$1" && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
stop_loop() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

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
echo ok >"$GH_MODE"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── B. cold start runs ONE pass; an identical read runs NONE (counted, not read off stdout)"
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_doctor
S="$TMP/state/b"; mkdir -p "$S"; LOG="$TMP/b.log"
pid="$(start_loop "$S" fake-owner/suite-b 2 "$LOG")"
if wait_for "$LOG" "PASS-BEGIN" 100; then pass "the first read of a cold trigger runs a pass"
else fail "cold start ran no pass"; fi
sleep 1
assert_eq "$(n_doctor)" "1" "exactly one doctor invocation on the cold pass"
reset_doctor
sleep 4                       # ≥4 poll ticks with a byte-identical surface
assert_eq "$(n_doctor)" "0" "an identical surface invokes the doctor ZERO times"
body="$(cat "$LOG")"
assert_contains "$body" "no change" "it says so (a silent trigger is indistinguishable from a dead one)"
n_cold="$(grep -cF 'COLD' "$LOG")"
assert_eq "$n_cold" "1" "cold start is derived EXACTLY once (not re-derived on every tick)"
stop_loop "$pid"

echo "── B2. --once: one pass and exit, then nothing (a supervisor's ExecStart)"
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_doctor
S2="$TMP/state/b2"; mkdir -p "$S2"
python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-b2 --repo-dir "$APP" --once \
  --poll 1 --backstop 1000000 --state-dir "$S2" >"$TMP/b2.log" 2>&1; rc=$?
assert_eq "$rc" "0" "--once on a cold start exits 0"
assert_eq "$(n_doctor)" "1" "--once ran exactly one pass"
reset_doctor
python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-b2 --repo-dir "$APP" --once \
  --poll 1 --backstop 1000000 --state-dir "$S2" >"$TMP/b2b.log" 2>&1
assert_eq "$(n_doctor)" "0" "a second --once with an unchanged surface runs NO pass"
assert_contains "$(cat "$TMP/b2b.log")" "no change" "and it says 'no change'"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── C. a CHANGED surface: one pass after the debounce; five rapid moves → ONE pass"
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_doctor
S="$TMP/state/c"; mkdir -p "$S"; LOG="$TMP/c.log"
pid="$(start_loop "$S" fake-owner/suite-c 3 "$LOG")"
wait_for "$LOG" "PASS-BEGIN" 100 || fail "cold pass never ran (case C cannot start)"
sleep 1; reset_doctor
i=0
while [ "$i" -lt 5 ]; do                       # five RAPID changes, well inside the 3 s debounce
  if [ $((i % 2)) -eq 0 ]; then st=BEHIND; else st=CONFLICTING; fi
  surface "$st" "2026-10-24T18:0$((i + 1)):00Z"
  sleep 0.4; i=$((i + 1))
done
sleep 9                                        # 3 s debounce + pass + several no-change ticks
assert_eq "$(n_doctor)" "1" "five rapid changes produced exactly ONE pass (coalesced)"
assert_contains "$(cat "$LOG")" "CHANGE" "the change was observed"
stop_loop "$pid"

echo "── C2. a pass that FAILED does not buy a backstop window (retry floor, not a 1800 s wait)"
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_doctor
S="$TMP/state/c2"; mkdir -p "$S"; LOG="$TMP/c2.log"
FAKE_DOCTOR_RC=3 python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-c2 --repo-dir "$APP" \
  --once --backstop 1000000 --retry-min 0 --state-dir "$S" >"$LOG" 2>&1; rc=$?
assert_eq "$rc" "1" "a non-{0,2} doctor exit makes --once exit non-zero"
assert_contains "$(cat "$LOG")" "DOCTOR-FAILED rc=3" "it is named DOCTOR-FAILED, not a clean window"
python3 - "$S/pr-doctor-trigger-suite-c2.state.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("last_pass") == 0, "last_pass must be 0 after a failed pass: %r" % d
assert d.get("last_attempt", 0) > 0, "last_attempt must be recorded: %r" % d
PY
assert_eq "$?" "0" "the state records last_pass=0 (backstop NOT consumed) and a real last_attempt"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── D. an UNREADABLE surface is not QUIET (#2271)"
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_doctor
S="$TMP/state/d"; mkdir -p "$S"; LOG="$TMP/d.log"
pid="$(start_loop "$S" fake-owner/suite-d 1 "$LOG")"
wait_for "$LOG" "PASS-BEGIN" 100 || fail "cold pass never ran (case D cannot start)"
sleep 1; reset_doctor
# ⛔ THE BASELINE IS TAKEN HERE, not asserted as an absence: a warm READABLE tick legitimately
# says "no change", so the claim is that the phrase does not GROW while the surface is unreadable.
quiet_before="$(grep -cF 'no change' "$LOG")"
unread_before="$(grep -cF 'PR-SURFACE-UNREADABLE' "$LOG")"
echo fail >"$GH_MODE"
sleep 4                                        # ≥3 poll ticks against a failing gh
quiet_after="$(grep -cF 'no change' "$LOG")"
unread_after="$(grep -cF 'PR-SURFACE-UNREADABLE' "$LOG")"
assert_contains "$(cat "$LOG")" "PR-SURFACE-UNREADABLE" "a failed gh read is logged as PR-SURFACE-UNREADABLE"
[ "$unread_after" -gt "$unread_before" ] && pass "the next tick RETRIED the read ($((unread_after - unread_before)) attempt(s) in 4 s)" \
  || fail "the read was not retried (attempts stayed at $unread_before)"
assert_eq "$quiet_after" "$quiet_before" "no unreadable tick ever logged 'no change' (the #2271 failure)"
assert_eq "$(n_doctor)" "0" "an unreadable surface invoked the doctor ZERO times"
# the surface comes back byte-identical: still no pass (the fingerprint was KEPT, not forgotten)
echo ok >"$GH_MODE"
sleep 3
assert_eq "$(n_doctor)" "0" "the surface returning UNCHANGED owes no pass"
assert_contains "$(cat "$LOG")" "keeping the last fingerprint" "going blind was not treated as a change"
stop_loop "$pid"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── E. the LOCK: a second instance exits 0 and runs no second doctor"
S="$TMP/state/e"; mkdir -p "$S"; LOG="$TMP/e.log"
reset_doctor
pid="$(start_loop "$S" fake-owner/suite-e 1 "$LOG")"
wait_for "$LOG" "PASS-BEGIN" 100 || fail "the holding instance never started"
sleep 1
python3 "$APP/pr-doctor-trigger.py" --repo fake-owner/suite-e --repo-dir "$APP" --once \
  --poll 1 --backstop 1000000 --state-dir "$S" >"$TMP/e2.log" 2>&1; rc=$?
assert_eq "$rc" "0" "the second instance exits 0 (not an error, not a crash loop)"
assert_contains "$(cat "$TMP/e2.log")" "ALREADY-RUNNING" "it SAYS another instance holds the lock"
assert_eq "$(n_doctor)" "1" "no second doctor was started"
stop_loop "$pid"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── F. MUTATION: a constant fingerprint() must turn case C RED (the anti-vacuity arm)"
MUT="$TMP/mutant"; mkdir -p "$MUT"
cp "$APP/pr-doctor.py" "$MUT/pr-doctor.py"
python3 - "$APP/pr-doctor-trigger.py" "$MUT/pr-doctor-trigger.py" <<'PY'
import sys
src = open(sys.argv[1]).read()
needle = '    return ("|".join("%s:%s:%s:%s" % t for t in rows), len(rows))'
assert needle in src, "the fixture cannot find fingerprint()'s return — update the mutation"
open(sys.argv[2], "w").write(src.replace(needle, '    return ("CONSTANT", len(rows))'))
PY
assert_eq "$?" "0" "the mutant was built from the real fingerprint() return"
surface CONFLICTING "2026-10-24T18:00:00Z"
reset_doctor
MS="$TMP/state/f"; mkdir -p "$MS"; MLOG="$TMP/f.log"
python3 "$MUT/pr-doctor-trigger.py" --repo fake-owner/suite-f --repo-dir "$MUT" \
  --poll 1 --debounce 1 --backstop 1000000 --state-dir "$MS" >"$MLOG" 2>&1 &
mpid=$!
wait_for "$MLOG" "PASS-BEGIN" 100 || fail "the mutant never ran its cold pass"
sleep 1; reset_doctor
surface BEHIND "2026-10-24T18:59:00Z"          # a REAL change the mutant cannot see
sleep 4
assert_eq "$(n_doctor)" "0" "the mutant MISSES the change — i.e. case C's assertion is load-bearing"
assert_contains "$(cat "$MLOG")" "no change" "the mutant reports 'no change' over a changed surface"
stop_loop "$mpid"

# ══════════════════════════════════════════════════════════════════════════════════════════════
echo "── G. the SERVICE wiring: ExecStart runs the TRIGGER, Restart=always, backstop 1800"
INSTALLER="$ROOT/scripts/orchestrator-harness/install-repair-service.sh"
[ -f "$INSTALLER" ] && pass "the repair-service installer ships" || fail "no $INSTALLER"
unit="$(ELDATO_PLATFORM=Linux PR_DOCTOR_TRIGGER="$APP/pr-doctor-trigger.py" \
        REPAIR_REPO=fake-owner/suite-g TEMPLATES_DIR="$ROOT/templates/systemd" \
        bash "$INSTALLER" --dry-run 2>&1)"; irc=$?
assert_eq "$irc" "0" "--dry-run renders without touching the service manager"
exec_line="$(grep -m1 '^ExecStart=' <<<"$unit")"
assert_contains "$exec_line" "pr-doctor-trigger.py" "ExecStart runs the TRIGGER"
assert_not_contains "$exec_line" "pr-doctor-loop.sh" "ExecStart is not a shell loop"
assert_contains "$exec_line" "--backstop 1800" "the timer survives ONLY as --backstop 1800"
assert_contains "$unit" "Restart=always" "Restart=always (an ORDERLY exit must come back, #2402)"
assert_not_contains "$unit" "Restart=on-failure" "not on-failure — the measured case is an exit 0"
assert_not_contains "$unit" "{{TRIGGER}}" "the render substitutes every placeholder"
darwin="$(ELDATO_PLATFORM=Darwin bash "$INSTALLER" --dry-run 2>&1)"; drc=$?
[ "$drc" -ne 0 ] && pass "the installer REFUSES a non-systemd platform (rc=$drc)" \
  || fail "the installer 'succeeded' on Darwin — an artifact nothing reads"
assert_contains "$darwin" "install-launchd.sh" "and it names the installer that owns that platform"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# Tripwire for section loss: a whole case was once deleted from a suite of this shape and it still
# reported ALL PASSED. This cannot guard its own deletion; the floor is the honest limit.
assert_eq "$([ "$PASS" -ge 30 ] && echo ok || echo short)" "ok" "assertion floor (≥30 fired, got $PASS)"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "ALL PASSED ($PASS assertions)"
  exit 0
fi
echo "FAILED: $FAIL of $((PASS + FAIL))"
exit 1
