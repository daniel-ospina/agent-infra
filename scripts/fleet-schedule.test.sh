#!/usr/bin/env bash
# fleet-schedule.test.sh — the regression contract for agent-infra#1864.
#
# The defect: the harness declares every recurring job ONCE, as a launchd plist, and delivers it
# with a launchd-only installer. The cells are Linux, so they received NONE of it — 10 job
# templates, 0 live, no reaping, no liveness, no canary — and nothing announced it. The measured
# table was 24/0/0/0 and every surface a health check looks at said "fine".
#
# This suite drives the SHIPPED scheduler (never a re-implementation of it) against FIXTURE
# plists, so it is hermetic: no launchd, no crontab, no systemd, no network, no real reaper.
#
# What it pins, each of which is a way the gap could come back:
#
#   1. DECLARATIONS ARE READ, NOT COPIED. Every plist in templates/launchd appears as a job, and
#      the parsed count equals the file count — so a job added the Mac way reaches Linux with no
#      further edit, and a silently-dropped plist fails here.
#   2. A PLACEHOLDER THE RUNTIME DOES NOT KNOW IS A LOUD FAILURE, not an empty argv. This is the
#      one class where the second renderer could drift from install-launchd.sh, so it is pinned:
#      adding `{{SOMETHING}}` to a template without teaching fleet-schedule.py fails the suite.
#   3. INSTALL ENDS WITH EVIDENCE, NOT A PID. `--install` runs the due jobs inline; the assertions
#      are a stamp with an rc and a fresh log line — "a unit that loads and never runs" is the
#      exact defect this issue is about.
#   4. `--verify` FAILS on: no loop, a stale pidfile pointing at a LIVE non-loop process (a
#      recycled pid must not read as a running scheduler), a never-run job, a stale tick, an
#      OVERDUE job whose lock is held (the scheduler exists but is not running it), an unknown
#      placeholder, a broken target, and a template with no schedule at all.
#   5. A LEGITIMATE PER-MACHINE ABSENCE IS NAMED, NOT FATAL. A job whose placeholder is unresolved
#      (no swarm root, no tortoise checkout) is reported SKIP with its reason and counted, and
#      `--verify` still passes — the same contract install-launchd.sh has for the Mac.
#   6. NO SECOND DECLARATION TO UPDATE (drift). A plist DROPPED INTO the templates dir while the
#      loop runs is picked up and executed with no reinstall.
#   7. A HUNG JOB CANNOT WEDGE THE LOOP. A job past FLEET_SCHEDULE_JOB_TIMEOUT is killed, stamped
#      rc=124, and logged.
#   8. NON-VACUITY. The passing cases are shown to depend on the fixture actually running (a
#      marker file appears), not on an empty job set: every fixture dir ships at least one job
#      that must be PRESENT and one that must be ABSENT/SKIPPED.
#
# The FRESH-CONTEXT REVIEW of PR #1927 asked for these, each a false PASS or a false FAIL in the
# shipped runtime (every one of them FAILS against the pre-fix scheduler, measured):
#  10. THE DARWIN PATH IS DRIVEN, NOT GREPPED. The module is executed with sys.platform pinched to
#      'darwin' against a fake install-launchd.sh that records its argv and exits 1 with a wording
#      the `--verify` substring scan does not know — so the delegate's EXIT STATUS is pinned, and a
#      neutered delegation (`return 0`) fails here instead of passing a grep over the docstring.
#  11. A Label IS A PATH COMPONENT. `com.test/slash` and `../../escaped` are refused BY NAME (not a
#      traceback), nothing is written outside the state dir, and ONE malformed plist dropped into a
#      running loop does not stop the loop or the other jobs.
#  12. ZERO JOBS IS NOT A PASS. A templates dir that exists but holds no *.plist is refused by
#      --install and --verify, and starts no loop (it used to print "SCHEDULE VERIFIED — 0 job(s)").
#  13. A RECYCLED PID IS NOT THE LOOP. --start replaces a live foreign pid in loop.pid, prints the
#      pid it actually started, and leaves a real loop running (it used to print the foreign pid
#      and exit 0 with no loop at all).
#  14. --install DOES NOT RACE THE FIRST TICK. A job whose interval is 1s and whose body takes 2s
#      makes the loop due again the instant it starts; --install must still exit 0.
#  15. A LONG JOB IS BUSY, NOT A WEDGE — and the exemption EXPIRES: a stale tick with a live busy
#      marker passes, the same tick fails once the marker's deadline has passed.
#  16. AN ANNUAL CALENDAR KEEPS A NEXT OCCURRENCE. A multi-entry StartCalendarInterval with
#      Month/Day is not `next=-` forever, and a calendar that can never match (Feb 31) FAILS.
#  17. --stop WORKS WHERE THE SCHEDULE NEVER RAN: it creates its own OFF switch (no traceback).
#
# Run:  bash scripts/fleet-schedule.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCHED="$HERE/fleet-schedule.py"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
skip() { SKIP=$((SKIP + 1)); echo "  ⏭ SKIPPED — $1"; }
case_() { echo; echo "── $1 ──"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-schedule-1864.XXXXXX")"
cleanup() {
  [ -f "$T/state/loop.pid" ] && kill "$(cat "$T/state/loop.pid" 2>/dev/null)" 2>/dev/null
  [ -f "$T/state2/loop.pid" ] && kill "$(cat "$T/state2/loop.pid" 2>/dev/null)" 2>/dev/null
  [ -f "$T/bare-state/loop.pid" ] && kill "$(cat "$T/bare-state/loop.pid" 2>/dev/null)" 2>/dev/null
  for p in $(cat "$T"/pids 2>/dev/null); do kill "$p" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT

if [ ! -f "$SCHED" ]; then
  echo "❌ missing $SCHED — there is NO portable scheduler; the cells receive no scheduled layer (#1864)"
  exit 1
fi
command -v python3 >/dev/null 2>&1 || { echo "❌ python3 required"; exit 1; }

export CELL_HOME="$T/home"
export HOME="$T/home"
export FLEET_SCHEDULE_STATE="$T/state"
export FLEET_SCHEDULE_TICK=5
export FLEET_SCHEDULE_JOB_TIMEOUT=30
mkdir -p "$T/home" "$T/out"

# ── fixture plists (written with plistlib, the same reader the scheduler uses) ─────────────────
mkplist() { # mkplist <dir> <label> <spec-file>  — spec is pythonplist source for the dict
  python3 - "$1" "$2" "$3" <<'PY'
import os, plistlib, sys
d = {}
exec(open(sys.argv[3]).read(), {}, d)
out = os.path.join(sys.argv[1], sys.argv[2] + ".plist")
os.makedirs(sys.argv[1], exist_ok=True)
with open(out, "wb") as fh:
    plistlib.dump(d["PLIST"], fh)
PY
}

FIX="$T/fixtures"
GOOD="$FIX/good"
BAD_UNKNOWN="$FIX/bad-unknown"
BAD_BROKEN="$FIX/bad-broken"
BAD_NOSCHED="$FIX/bad-noschedule"
BAD_RETIRED="$FIX/bad-retired"
SKIPPY="$FIX/skippy"
DRIFT="$FIX/drift"
mkdir -p "$GOOD" "$BAD_UNKNOWN" "$BAD_BROKEN" "$BAD_NOSCHED" "$BAD_RETIRED" "$SKIPPY" "$DRIFT"
printf '# no retired labels in the fixture\n' > "$GOOD/RETIRED"
cp "$GOOD/RETIRED" "$BAD_UNKNOWN/RETIRED"; cp "$GOOD/RETIRED" "$BAD_BROKEN/RETIRED"
cp "$GOOD/RETIRED" "$BAD_NOSCHED/RETIRED"; cp "$GOOD/RETIRED" "$SKIPPY/RETIRED"
cp "$GOOD/RETIRED" "$DRIFT/RETIRED"
printf 'com.test.retired-both\n' > "$BAD_RETIRED/RETIRED"

# The marker path every fixture job writes; a run is proven by this file appearing, never by the
# fact that a plist exists.
MARK="$T/out/marker.log"

cat > "$T/echo.spec" <<PY
PLIST = {
    "Label": "com.test.echo",
    "ProgramArguments": ["/bin/sh", "-c", "echo ran-\$(date +%s) >> '$MARK'"],
    "StartInterval": 2,
}
PY
cat > "$T/hourly.spec" <<PY
PLIST = {
    "Label": "com.test.hourly",
    "ProgramArguments": ["/bin/sh", "-c", "echo hourly >> '$MARK.hourly'"],
    "EnvironmentVariables": {"FLEET_TEST_ENV": "yes"},
    "StartInterval": 3600,
}
PY
cat > "$T/weekly.spec" <<PY
PLIST = {
    "Label": "com.test.weekly",
    "ProgramArguments": ["/bin/sh", "-c", "echo weekly >> '$MARK.weekly'"],
    "StartCalendarInterval": {"Weekday": 0, "Hour": 6, "Minute": 30},
}
PY
cat > "$T/skipme.spec" <<PY
PLIST = {
    "Label": "com.test.skipme",
    "ProgramArguments": ["{{PYTHON_BIN}}", "{{SWARM_ROOT}}/canary.py"],
    "StartInterval": 60,
}
PY
cat > "$T/unknown.spec" <<PY
PLIST = {
    "Label": "com.test.unknown",
    "ProgramArguments": ["/bin/sh", "-c", "echo {{NOT_A_REAL_PLACEHOLDER}}"],
    "StartInterval": 60,
}
PY
cat > "$T/broken.spec" <<PY
PLIST = {
    "Label": "com.test.broken",
    "ProgramArguments": ["/bin/sh", "{{HOME}}/.pi/agent/scripts/fleet-schedule-fixture-missing.sh"],
    "StartInterval": 60,
}
PY
cat > "$T/thirdparty.spec" <<PY
PLIST = {
    "Label": "com.test.thirdparty",
    "ProgramArguments": ["/bin/sh", "{{TORTOISE_REPO}}/scripts/fixture.sh"],
    "StartInterval": 60,
}
PY
cat > "$T/nosched.spec" <<PY
PLIST = {
    "Label": "com.test.nosched",
    "ProgramArguments": ["/bin/sh", "-c", "true"],
}
PY
cat > "$T/added.spec" <<PY
PLIST = {
    "Label": "com.test.added",
    "ProgramArguments": ["/bin/sh", "-c", "echo added >> '$MARK.added'"],
    "StartInterval": 2,
}
PY
cat > "$T/retired-both.spec" <<PY
PLIST = {
    "Label": "com.test.retired-both",
    "ProgramArguments": ["/bin/sh", "-c", "true"],
    "StartInterval": 60,
}
PY
cat > "$T/slow.spec" <<PY
PLIST = {
    "Label": "com.test.slow",
    "ProgramArguments": ["/bin/sh", "-c", "sleep 20; echo finished >> '$MARK.slow'"],
    "StartInterval": 3600,
}
PY

mkplist "$GOOD"     com.test.echo        "$T/echo.spec"
mkplist "$GOOD"     com.test.hourly      "$T/hourly.spec"
mkplist "$GOOD"     com.test.weekly      "$T/weekly.spec"
mkplist "$SKIPPY"   com.test.skipme      "$T/skipme.spec"
mkplist "$SKIPPY"   com.test.thirdparty  "$T/thirdparty.spec"
mkplist "$SKIPPY"   com.test.echo        "$T/echo.spec"
mkplist "$BAD_UNKNOWN" com.test.unknown  "$T/unknown.spec"
mkplist "$BAD_UNKNOWN" com.test.echo     "$T/echo.spec"
mkplist "$BAD_BROKEN"  com.test.broken   "$T/broken.spec"
mkplist "$BAD_BROKEN"  com.test.echo     "$T/echo.spec"
mkplist "$BAD_NOSCHED" com.test.nosched  "$T/nosched.spec"
mkplist "$BAD_NOSCHED" com.test.echo     "$T/echo.spec"
mkplist "$BAD_RETIRED" com.test.retired-both "$T/retired-both.spec"
mkplist "$DRIFT"    com.test.echo        "$T/echo.spec"

run() { # run <templates-dir> <args...> → prints output, returns the scheduler's rc
  local dir="$1"; shift
  TEMPLATES_DIR="$dir" python3 "$SCHED" "$@" 2>&1
}

state_reset() {
  TEMPLATES_DIR="${1:-$GOOD}" python3 "$SCHED" --stop >/dev/null 2>&1
  rm -rf "$FLEET_SCHEDULE_STATE"
  mkdir -p "$FLEET_SCHEDULE_STATE"
  unset FLEET_SCHEDULE_STATE_BACKUP
  export FLEET_SCHEDULE_STATE="$T/state"
}

# ── 1. the repo's own declarations are read, not re-listed ─────────────────────────────────────
case_ "1. every declared job is read from templates/launchd (no second declaration)"
n_plists="$(ls "$ROOT/templates/launchd"/*.plist 2>/dev/null | grep -c . || true)"
out="$(run "$ROOT/templates/launchd" --status)"; rc=$?
[ "$rc" -eq 0 ] && ok "--status reads the real template set (rc=0)" || bad "--status failed on the repo's own templates: $out"
[ "$n_plists" -ge 10 ] && ok "the repo declares $n_plists job template(s) (floor: 10)" || bad "expected >=10 templates, found $n_plists"
missing=""
while IFS= read -r p; do
  label="$(basename "$p" .plist)"
  grep -q "$label" <<<"$out" || missing="$missing $label"
done < <(ls "$ROOT/templates/launchd"/*.plist)
[ -z "$missing" ] && ok "all $n_plists declared label(s) appear in --status" \
  || bad "--status dropped declared job(s):$missing"
# The runtime must know every placeholder the shipped templates use — a new one is a loud error.
grep -q 'this runtime does not know' <<<"$out" \
  && bad "a shipped template uses a placeholder fleet-schedule.py does not know (would run with an EMPTY argument)" \
  || ok "no shipped template carries an unknown placeholder"

# ── 2. install proves a RUN, not a pid ────────────────────────────────────────────────────────
case_ "2. --install runs the due jobs and ends with a fresh log line + stamp"
state_reset "$GOOD"
out="$(run "$GOOD" --install)"; rc=$?
[ "$rc" -eq 0 ] && ok "--install exited 0" || bad "--install exited $rc: $out"
grep -q 'com.test.echo .*rc=0' <<<"$out" && ok "the first pass ran com.test.echo with rc=0" \
  || bad "the first pass did not report a run of com.test.echo: $out"
[ -s "$MARK" ] && ok "the job's own marker file exists — the job really EXECUTED" \
  || bad "no marker file at $MARK — 'scheduled' was believed, not proven"
log="$FLEET_SCHEDULE_STATE/logs/com.test.echo.log"
grep -q 'fleet-schedule run com.test.echo start' "$log" 2>/dev/null \
  && ok "the run left a fresh log line in the job's log ($log)" \
  || bad "no run header in $log (the acceptance evidence is a log line, not a file's presence)"
stamp="$FLEET_SCHEDULE_STATE/jobs/com.test.echo.json"
[ -s "$stamp" ] && ok "a stamp was written for com.test.echo" || bad "no stamp at $stamp"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("rc")==0 and d.get("started") else 1)' "$stamp" \
  && ok "the stamp records rc=0 and a start time" || bad "stamp content is not a run record: $(cat "$stamp" 2>/dev/null)"
[ -f "$FLEET_SCHEDULE_STATE/jobs/com.test.weekly.json" ] \
  && ok "a CALENDAR job (StartCalendarInterval) also ran its first pass" \
  || bad "the calendar-scheduled job never ran"
grep -q 'loop started' <<<"$out" && ok "the loop was started" || bad "no loop start reported: $out"
grep -q 'SCHEDULE VERIFIED' <<<"$out" && ok "--install finished by VERIFYING the schedule" \
  || bad "--install did not verify: $out"

# ── 3. verify passes right after install, and is non-vacuous ──────────────────────────────────
case_ "3. --verify passes after install and counts the live jobs"
out="$(run "$GOOD" --verify)"; rc=$?
[ "$rc" -eq 0 ] && ok "--verify exited 0 on a live schedule" || bad "--verify exited $rc: $out"
grep -qE 'SCHEDULE VERIFIED — 3 job\(s\) live' <<<"$out" \
  && ok "it counted the 3 runnable jobs (not 0, not the loop alone)" \
  || bad "the verified job count is wrong: $out"

# ── 4. the verify arms ───────────────────────────────────────────────────────────────────────
case_ "4. --verify fails on each way a schedule can be inert"
# 4a: no loop
run "$GOOD" --stop >/dev/null 2>&1
out="$(run "$GOOD" --verify)"; rc=$?
[ "$rc" -eq 1 ] && ok "a stopped loop fails --verify (rc=1)" || bad "expected rc=1 with the loop stopped, got $rc"
grep -q 'NOT RUNNING' <<<"$out" && ok "the failure names the missing loop" || bad "failure does not name the loop: $out"

# 4b: a stale pidfile pointing at a LIVE, unrelated process (recycled pid)
sleep 30 & sleeper=$!; echo "$sleeper" > "$T/pids"
printf '%s\n' "$sleeper" > "$FLEET_SCHEDULE_STATE/loop.pid"
out="$(run "$GOOD" --verify)"; rc=$?
[ "$rc" -eq 1 ] && ok "a pidfile pointing at a live NON-loop process fails --verify" \
  || bad "a recycled pid read as a running scheduler (rc=$rc): $out"
grep -q 'is not fleet-schedule' <<<"$out" && ok "the failure names the pid as not the loop" \
  || bad "failure does not distinguish a recycled pid: $out"
kill "$sleeper" 2>/dev/null; rm -f "$FLEET_SCHEDULE_STATE/loop.pid"

# 4c: a runnable job that has never run
rm -f "$FLEET_SCHEDULE_STATE/jobs/com.test.hourly.json"
out="$(run "$GOOD" --verify)"; rc=$?
[ "$rc" -eq 1 ] && ok "a declared, runnable, never-run job fails --verify" || bad "expected rc=1, got $rc"
grep -q 'com.test.hourly: declared and runnable here, but has NEVER RUN' <<<"$out" \
  && ok "it names the never-run job" || bad "failure does not name the never-run job: $out"

# 4d: a stale tick (the process exists but is not passing)
state_reset "$GOOD"; run "$GOOD" --install >/dev/null 2>&1
python3 - "$FLEET_SCHEDULE_STATE/tick" <<'PY'
import os, sys, time
p = sys.argv[1]
with open(p, "w") as fh:
    fh.write("0\n")
old = time.time() - 7200
os.utime(p, (old, old))
PY
out="$(run "$GOOD" --verify)"; rc=$?
[ "$rc" -eq 1 ] && ok "a stale tick fails --verify" || bad "expected rc=1 on a stale tick, got $rc"
grep -q 'tick is .*old' <<<"$out" && ok "the failure names the stale tick" || bad "failure does not name the tick: $out"

# 4e: OVERDUE — the loop is alive but a locked job is not being run
state_reset "$GOOD"; run "$GOOD" --install >/dev/null 2>&1
sleep 30 & lockpid=$!; echo "$lockpid" >> "$T/pids"
mkdir -p "$FLEET_SCHEDULE_STATE/locks"
printf '%s\n' "$lockpid" > "$FLEET_SCHEDULE_STATE/locks/com.test.echo.lock"
python3 - "$FLEET_SCHEDULE_STATE/jobs/com.test.echo.json" <<'PY'
import json, sys, time
p = sys.argv[1]
d = json.load(open(p))
d["started"] = time.time() - 120
json.dump(d, open(p, "w"))
PY
touched=0
for _ in $(seq 1 40); do
  sleep 1
  # wait for a pass to complete after the backdating (the loop skips the locked job)
  if [ -n "$(stat -c %Y "$FLEET_SCHEDULE_STATE/tick" 2>/dev/null)" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$FLEET_SCHEDULE_STATE/tick") ))
    [ "$age" -le 6 ] && { touched=1; break; }
  fi
done
out="$(run "$GOOD" --verify)"; rc=$?
[ "$touched" -eq 1 ] || skip "could not observe a loop tick before the overdue read"
[ "$rc" -eq 1 ] && ok "an OVERDUE job (lock held by a live run) fails --verify" \
  || bad "an overdue job passed --verify (rc=$rc): $out"
grep -q 'OVERDUE' <<<"$out" && ok "the failure names the overdue job" || bad "failure does not name OVERDUE: $out"
kill "$lockpid" 2>/dev/null; rm -f "$FLEET_SCHEDULE_STATE/locks/com.test.echo.lock"

# ── 5. a broken declaration is refused, loudly, BEFORE anything is scheduled ──────────────────
case_ "5. a declaration the runtime cannot honour is refused"
for spec in "unknown:does not know" "broken:broken target" "noschedule:no StartInterval"; do
  dir="$FIX/bad-${spec%%:*}"; want="${spec#*:}"
  case "$spec" in noschedule:*) dir="$BAD_NOSCHED" ;; esac
  state_reset "$dir"
  out="$(run "$dir" --install)"; rc=$?
  [ "$rc" -eq 1 ] && ok "--install refuses the '${spec%%:*}' fixture (rc=1)" \
    || bad "--install accepted the '${spec%%:*}' fixture (rc=$rc): $out"
  grep -qi -- "$want" <<<"$out" && ok "the refusal names the cause ($want)" || bad "refusal is not diagnosable: $out"
  if [ "${spec%%:*}" = "broken" ]; then
    grep -q 'farm is INCOMPLETE' <<<"$out" \
      && ok "a missing file under {{HOME}}/.pi/agent is diagnosed as an INCOMPLETE FARM" \
      || bad "the broken-target refusal does not name the incomplete farm: $out"
  fi
  [ ! -f "$FLEET_SCHEDULE_STATE/loop.pid" ] && ok "no loop was started over a broken job set" \
    || bad "a loop was started over a job set it could not read in full"
  out="$(run "$dir" --verify)"; rc=$?
  [ "$rc" -eq 1 ] && ok "--verify also fails on the '${spec%%:*}' fixture" || bad "--verify passed a broken set (rc=$rc)"
done
# RETIRED must not also have a template (the same rule install-launchd.sh enforces)
state_reset "$BAD_RETIRED"
out="$(run "$BAD_RETIRED" --install)"; rc=$?
[ "$rc" -eq 1 ] && ok "a RETIRED label that still has a template is refused" || bad "RETIRED conflict accepted (rc=$rc)"
grep -q 'RETIRED but a template still exists' <<<"$out" && ok "the RETIRED refusal names both halves" \
  || bad "RETIRED refusal is not diagnosable: $out"

# ── 6. a per-machine absence is NAMED and does not block certification ───────────────────────
case_ "6. an unresolved placeholder is a named SKIP, counted, not fatal"
state_reset "$SKIPPY"
unset SWARM_ROOT
# A tortoise checkout that EXISTS but has no .venv/scripts: {{TORTOISE_REPO}} resolves, so the
# job is not skipped at the placeholder — it fails at the TARGET, which is the arm being pinned.
mkdir -p "$T/empty-tortoise/.git"
export TORTOISE_REPO="$T/empty-tortoise"
out="$(run "$SKIPPY" --install)"; rc=$?
[ "$rc" -eq 0 ] && ok "--install certifies a machine where one job is legitimately absent" \
  || bad "--install refused over a per-machine absence (rc=$rc): $out"
grep -q 'SKIP.*com.test.skipme.*{{SWARM_ROOT}}' <<<"$out" && ok "the skipped job is NAMED with its reason" \
  || bad "the skipped job is not named: $out"
grep -qE '2 skipped for a named reason' <<<"$out" && ok "--verify counts the skips instead of hiding them" \
  || bad "the skips are not counted in the verdict: $out"
grep -q 'com.test.thirdparty.*target absent on this machine' <<<"$(run "$SKIPPY" --status)" \
  && ok "a missing THIRD-PARTY target is a named SKIP, not a fatal farm error" \
  || bad "a missing third-party target is not reported as a named skip"
unset TORTOISE_REPO
grep -q 'com.test.echo .*rc=0' <<<"$out" && ok "the runnable job still ran" || bad "the runnable job did not run"

# ── 7. NO second declaration: a job added to the templates dir is picked up live ─────────────
case_ "7. a plist dropped in while the loop runs is scheduled with no reinstall (drift)"
state_reset "$DRIFT"
run "$DRIFT" --install >/dev/null 2>&1
[ -f "$MARK.added" ] && bad "the added job ran before it was declared — fixture is wrong" \
  || ok "the added job has not run yet (nothing declares it)"
mkplist "$DRIFT" com.test.added "$T/added.spec"
picked=0
for _ in $(seq 1 30); do
  sleep 1
  [ -f "$MARK.added" ] && { picked=1; break; }
done
[ "$picked" -eq 1 ] && ok "the new plist was picked up and RAN — no second declaration to update" \
  || bad "a newly declared job was never scheduled (the loop is reading a stale set)"
out="$(run "$DRIFT" --verify)"; rc=$?
grep -q 'com.test.added' <<<"$(run "$DRIFT" --status)" && ok "--status lists the new job" \
  || bad "--status does not list the new job"
[ "$rc" -eq 0 ] && ok "--verify passes with the new job in the set" || bad "--verify failed after drift: $out"

# ── 8. a hung job cannot wedge the loop ──────────────────────────────────────────────────────
case_ "8. a job past its ceiling is killed, stamped rc=124 and logged"
SLOWDIR="$FIX/slow"; mkdir -p "$SLOWDIR"; cp "$GOOD/RETIRED" "$SLOWDIR/RETIRED"
mkplist "$SLOWDIR" com.test.slow "$T/slow.spec"
state_reset "$SLOWDIR"
out="$(TEMPLATES_DIR="$SLOWDIR" FLEET_SCHEDULE_JOB_TIMEOUT=1 python3 "$SCHED" --install 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "the pass completed despite a hung job (no wedge)" || bad "a hung job wedged the pass (rc=$rc)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("rc")==124 else 1)' \
  "$FLEET_SCHEDULE_STATE/jobs/com.test.slow.json" 2>/dev/null \
  && ok "the killed job was stamped rc=124" || bad "the timeout was not recorded in the stamp"
grep -q 'KILLED after 1s' "$FLEET_SCHEDULE_STATE/logs/com.test.slow.log" 2>/dev/null \
  && ok "the kill is in the job's log" || bad "the kill is not in the log"

# ── 9. the loop is a real process, and --stop really stops it ────────────────────────────────
case_ "9. the loop is identified by its command line, not a bare pid; --stop stops it"
state_reset "$GOOD"; run "$GOOD" --install >/dev/null 2>&1
pid="$(cat "$FLEET_SCHEDULE_STATE/loop.pid" 2>/dev/null)"
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ok "the loop process is alive (pid $pid)" || bad "no live loop pid"
grep -q -- '--loop' "/proc/$pid/cmdline" 2>/dev/null && ok "the pid runs fleet-schedule.py --loop" \
  || skip "no /proc/<pid>/cmdline on this platform"
out="$(run "$GOOD" --stop)"; rc=$?
[ "$rc" -eq 0 ] && ok "--stop exited 0" || bad "--stop exited $rc: $out"
gone=0; for _ in $(seq 1 20); do sleep 0.2; kill -0 "$pid" 2>/dev/null || { gone=1; break; }; done
[ "$gone" -eq 1 ] && ok "the loop process is gone after --stop" || bad "the loop survived --stop"
[ -f "$FLEET_SCHEDULE_STATE/OFF" ] && ok "the OFF switch is set (a restart cannot silently resume)" \
  || bad "no OFF switch after --stop"
out="$(run "$GOOD" --install)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'switched OFF' <<<"$out" \
  && ok "--install does NOT silently override a deliberate OFF switch (it names it)" \
  || bad "--install ignored the OFF switch (rc=$rc): $out"
out="$(run "$GOOD" --start)"; rc=$?
[ "$rc" -eq 0 ] && [ ! -f "$FLEET_SCHEDULE_STATE/OFF" ] && ok "--start clears OFF and starts the loop" \
  || bad "--start did not resume the schedule (rc=$rc): $out"
run "$GOOD" --stop >/dev/null 2>&1

# ── 9b. a LATER start must find the same declarations (the cell's own restart path) ──────────
case_ "9b. --start resolves the declarations the cell was INSTALLED with"
state_reset "$GOOD"; run "$GOOD" --install >/dev/null 2>&1
run "$GOOD" --stop >/dev/null 2>&1
# The farmed layout: ~/.pi/agent/scripts/fleet-schedule.py, which is NOT a checkout — so without
# the pointer this run has no idea where templates/launchd is, and a `start` from an operator
# shell (the supervisor does exactly this) would either refuse or schedule a DIFFERENT set.
FAKEHOME="$T/fakehome/.pi/agent"
mkdir -p "$FAKEHOME/scripts" && cp "$SCHED" "$FAKEHOME/scripts/fleet-schedule.py"
out="$(cd / && env -u TEMPLATES_DIR -u INFRA_ROOT -u AGENT_INFRA_PATH \
       HOME="$T/fakehome" CELL_HOME="$T/fakehome" FLEET_SCHEDULE_STATE="$FLEET_SCHEDULE_STATE" \
       python3 "$FAKEHOME/scripts/fleet-schedule.py" --start 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "--start works from the farmed layout with no INFRA_ROOT in the environment" \
  || bad "the cell's own restart path cannot find the declarations (rc=$rc): $out"
out="$(cd / && env -u TEMPLATES_DIR -u INFRA_ROOT -u AGENT_INFRA_PATH \
       HOME="$T/fakehome" CELL_HOME="$T/fakehome" FLEET_SCHEDULE_STATE="$FLEET_SCHEDULE_STATE" \
       python3 "$FAKEHOME/scripts/fleet-schedule.py" --status 2>&1)"
grep -q 'com.test.echo' <<<"$out" && ok "--status from the farmed layout reads the same job set" \
  || bad "--status from the farmed layout sees no jobs: $out"
env -u TEMPLATES_DIR -u INFRA_ROOT -u AGENT_INFRA_PATH FLEET_SCHEDULE_STATE="$FLEET_SCHEDULE_STATE" \
  HOME="$T/fakehome" CELL_HOME="$T/fakehome" python3 "$FAKEHOME/scripts/fleet-schedule.py" --stop >/dev/null 2>&1

# ── 9c. a cell with NO declarations warns (rc=3) instead of bricking its start path ───────────
case_ "9c. no declarations is its own exit code (3), not a generic failure"
mkdir -p "$T/barehome"
# Run the FARMED copy (a non-checkout path) with no remembered pointer: that is the shape of a cell
# whose layer exists but whose declarations were never recorded — the supervisor must warn, not die.
out="$(cd / && env -u TEMPLATES_DIR -u INFRA_ROOT -u AGENT_INFRA_PATH \
       HOME="$T/barehome" CELL_HOME="$T/barehome" FLEET_SCHEDULE_STATE="$T/bare-state" \
       python3 "$T/fakehome/.pi/agent/scripts/fleet-schedule.py" --start 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && ok "--start exits 3 when there is nothing to read (the supervisor keys on it)" \
  || bad "expected rc=3 for missing declarations, got $rc: $out"

# ── 10. macOS delegates (never a second scheduler) ──────────────────────────────────────────
case_ "10. the launchd backend is delegated to, driven through the Darwin branch"
# ⛔ BEHAVIOUR, NOT A GREP. The previous version asserted `grep -q 'install-launchd.sh' "$SCHED"`
# and `grep -q 'cmd_darwin' "$SCHED"` — both satisfied by the module DOCSTRING and by
# `def cmd_darwin` alone, so neutering the delegation (`return 0`) left the suite green. Here the
# shipped module is executed with sys.platform pinched to 'darwin' against a FAKE installer that
# records how it was called and fails with a wording the --verify substring scan does NOT know
# (`template dir not found`), which is also the false PASS a delegate's exit status closes.
DARWIN_ROOT="$T/darwin-root"
DELEGATE_RECORD="$T/delegate.record"
mkdir -p "$DARWIN_ROOT/scripts" "$DARWIN_ROOT/templates/launchd"
printf '# fixture\n' > "$DARWIN_ROOT/templates/launchd/RETIRED"
cat > "$DARWIN_ROOT/scripts/install-launchd.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-<no args>}" >> "$DELEGATE_RECORD"
echo "ERROR: template dir not found: /nonexistent" >&2
exit 1
SH
chmod +x "$DARWIN_ROOT/scripts/install-launchd.sh"
# Runs the SHIPPED runtime as macOS would: sys.platform is the only thing faked, and the module's
# own `if __name__ == "__main__"` exit path is taken so the rc is the real one.
darwin_run() { # darwin_run <mode> → prints output, returns the runtime's rc
  : > "$DELEGATE_RECORD"
  DELEGATE_RECORD="$DELEGATE_RECORD" INFRA_ROOT="$DARWIN_ROOT" python3 - "$SCHED" "$1" 2>&1 <<'PY'
import sys
sys.platform = "darwin"
path, mode = sys.argv[1], sys.argv[2]
sys.argv = [path, mode]
exec(compile(open(path).read(), path, "exec"), {"__name__": "__main__", "__file__": path})
PY
}
out="$(darwin_run --verify)"; rc=$?
[ "$rc" -eq 1 ] && ok "--verify FAILS when the delegate it delegates to fails (its rc is read)" \
  || bad "a failing install-launchd.sh --status was certified VERIFIED on macOS (rc=$rc): $out"
grep -q 'SCHEDULE NOT VERIFIED' <<<"$out" && ok "the Darwin failure names the verdict" \
  || bad "no NOT VERIFIED verdict on Darwin: $out"
grep -q '^--status$' "$DELEGATE_RECORD" && ok "--verify asks install-launchd.sh --status (delegated, not reimplemented)" \
  || bad "--verify did not delegate --status: $(cat "$DELEGATE_RECORD" 2>/dev/null)"
out="$(darwin_run --status)"; rc=$?
[ "$rc" -eq 1 ] && grep -q '^--status$' "$DELEGATE_RECORD" \
  && ok "--status delegates to install-launchd.sh and propagates its rc" \
  || bad "--status did not delegate/propagate (rc=$rc): $out"
out="$(darwin_run --install)"; rc=$?
[ "$rc" -eq 1 ] && grep -q '^<no args>$' "$DELEGATE_RECORD" \
  && ok "--install delegates to install-launchd.sh with NO arguments and propagates its rc" \
  || bad "--install did not delegate (rc=$rc): $out ($(cat "$DELEGATE_RECORD" 2>/dev/null))"
out="$(darwin_run --loop)"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'Linux runtime' <<<"$out" \
  && ok "--loop REFUSES on macOS (a second scheduler is what drifting looks like)" \
  || bad "--loop was accepted on macOS (rc=$rc): $out"
out="$(darwin_run --stop)"; rc=$?
[ "$rc" -eq 0 ] && grep -q -- '--uninstall' <<<"$out" \
  && ok "--stop points at install-launchd.sh --uninstall instead of inventing a stop" \
  || bad "--stop did not name the launchd uninstall path (rc=$rc): $out"

# ── 11. a Label is a PATH COMPONENT, so it is validated before it is used as one ─────────────
case_ "11. a Label that is not a safe file name is refused, and cannot escape the state dir"
LABELDIR="$FIX/bad-label"; mkdir -p "$LABELDIR"; cp "$GOOD/RETIRED" "$LABELDIR/RETIRED"
cat > "$T/slashlabel.spec" <<PY
PLIST = {
    "Label": "com.test/slash",
    "ProgramArguments": ["/bin/sh", "-c", "echo slash >> '$MARK.slash'"],
    "StartInterval": 2,
}
PY
cat > "$T/escape-label.spec" <<PY
PLIST = {
    "Label": "../../escaped",
    "ProgramArguments": ["/bin/sh", "-c", "echo escaped >> '$MARK.escaped'"],
    "StartInterval": 2,
}
PY
mkplist "$LABELDIR" com.test.echo "$T/echo.spec"
mkplist "$LABELDIR" com.test.slash "$T/slashlabel.spec"
mkplist "$LABELDIR" com.test.escape "$T/escape-label.spec"
state_reset "$LABELDIR"
out="$(run "$LABELDIR" --install)"; rc=$?
[ "$rc" -eq 1 ] && ok "--install refuses a Label that is not a safe file name (rc=1)" \
  || bad "an unsafe Label was accepted (rc=$rc): $out"
grep -q 'not a safe file name' <<<"$out" && ok "both unsafe Labels are named as such" \
  || bad "the refusal does not name the Label rule: $out"
grep -q 'Traceback' <<<"$out" && bad "the refusal is a traceback, not a diagnosis: $out" \
  || ok "the refusal is a diagnosis, not a traceback"
[ ! -e "$T/escaped.json" ] && [ ! -e "$T/escaped.lock" ] && [ ! -e "$T/escaped.log" ] \
  && ok "nothing was written OUTSIDE the state dir by the traversal Label" \
  || bad "a Label escaped the state dir (stamp/lock/log written under $T)"
[ ! -f "$FLEET_SCHEDULE_STATE/loop.pid" ] && ok "no loop was started over the broken job set" \
  || bad "a loop was started on a set it could not read in full"
# 11b. and ONE bad declaration must not stop a RUNNING loop (dropped in while it runs)
SWAP="$FIX/label-sweep"; mkdir -p "$SWAP"; cp "$GOOD/RETIRED" "$SWAP/RETIRED"
mkplist "$SWAP" com.test.echo "$T/echo.spec"
state_reset "$SWAP"; run "$SWAP" --install >/dev/null 2>&1
loop_pid_11b="$(cat "$FLEET_SCHEDULE_STATE/loop.pid" 2>/dev/null)"
mkplist "$SWAP" com.test.slash "$T/slashlabel.spec"
before="$(grep -c 'ran-' "$MARK" 2>/dev/null || echo 0)"
run_again=0
for _ in $(seq 1 12); do
  sleep 1
  after="$(grep -c 'ran-' "$MARK" 2>/dev/null || echo 0)"
  [ "$after" -gt "$before" ] && { run_again=1; break; }
done
[ "$run_again" -eq 1 ] && ok "the loop kept RUNNING the good job after the bad plist appeared" \
  || bad "a single malformed declaration stopped the whole loop (other jobs no longer run)"
kill -0 "$loop_pid_11b" 2>/dev/null && ok "the loop process survived the malformed declaration" \
  || bad "the loop process died on a malformed declaration"
run "$SWAP" --stop >/dev/null 2>&1

# ── 12. an EMPTY declarations dir is a FALSE PASS, not a clean run ──────────────────────────
case_ "12. a schedule with ZERO jobs is refused instead of certified"
EMPTY="$FIX/empty"; mkdir -p "$EMPTY"; printf '# no retired labels\n' > "$EMPTY/RETIRED"
state_reset "$EMPTY"
out="$(run "$EMPTY" --install)"; rc=$?
[ "$rc" -eq 1 ] && ok "--install refuses an EMPTY job set (rc=1)" \
  || bad "an empty job set was accepted (rc=$rc): $out"
grep -q 'ZERO jobs' <<<"$out" && ok "the refusal says the set is empty (not that everything is fine)" \
  || bad "the refusal is not diagnosable: $out"
grep -q 'SCHEDULE VERIFIED' <<<"$out" && bad "an EMPTY schedule printed SCHEDULE VERIFIED: $out" \
  || ok "nothing was certified over zero jobs"
out="$(run "$EMPTY" --verify)"; rc=$?
[ "$rc" -eq 1 ] && ok "--verify also refuses the empty set" || bad "--verify passed an empty set (rc=$rc)"
[ ! -f "$FLEET_SCHEDULE_STATE/loop.pid" ] && ok "no loop was started over an empty set" \
  || bad "a loop was started over an empty set"

# ── 13. a recycled pid must not fake a running loop (--start used to print one and exit 0) ────
case_ "13. --start replaces a recycled pid in loop.pid instead of reporting it as the loop"
state_reset "$GOOD"
sleep 60 & recycled=$!; echo "$recycled" >> "$T/pids"
printf '%s\n' "$recycled" > "$FLEET_SCHEDULE_STATE/loop.pid"
out="$(run "$GOOD" --start)"; rc=$?
[ "$rc" -eq 0 ] && ok "--start exits 0" || bad "--start failed over a recycled pid (rc=$rc): $out"
newpid="$(cat "$FLEET_SCHEDULE_STATE/loop.pid" 2>/dev/null)"
[ -n "$newpid" ] && [ "$newpid" != "$recycled" ] \
  && ok "loop.pid now names a DIFFERENT pid than the recycled one" \
  || bad "loop.pid still holds the recycled pid ($newpid == $recycled)"
if grep -q -- '--loop' "/proc/$newpid/cmdline" 2>/dev/null; then
  ok "the pid it printed really is fleet-schedule.py --loop"
else
  skip "no /proc/<pid>/cmdline on this platform"
fi
[ -f "$FLEET_SCHEDULE_STATE/tick" ] && ok "a real loop stamped a tick" \
  || bad "no tick: the 'loop started' message was a claim about a foreign pid"
kill -0 "$newpid" 2>/dev/null && ok "the started loop is alive" || bad "the loop it reported is not alive"
run "$GOOD" --stop >/dev/null 2>&1
kill "$recycled" 2>/dev/null

# ── 14. --install must not race the loop's first tick ──────────────────────────────────────
case_ "14. --install verifies a HEALTHY install whose loop is still in its first pass"
RACE="$FIX/race"; mkdir -p "$RACE"; cp "$GOOD/RETIRED" "$RACE/RETIRED"
cat > "$T/race.spec" <<PY
PLIST = {
    "Label": "com.test.race",
    "ProgramArguments": ["/bin/sh", "-c", "sleep 2; echo race >> '$MARK.race'"],
    "StartInterval": 1,
}
PY
mkplist "$RACE" com.test.race "$T/race.spec"
state_reset "$RACE"
out="$(run "$RACE" --install)"; rc=$?
[ "$rc" -eq 0 ] && ok "--install exits 0 (the loop was due again the moment it started)" \
  || bad "--install failed a healthy install because the loop had not ticked yet (rc=$rc): $out"
grep -q 'never ticked' <<<"$out" && bad "verify raced the loop's first tick: $out" \
  || ok "verify did not race the first tick"
[ -f "$MARK.race" ] && ok "the short-interval job actually ran (the fixture is not vacuous)" \
  || bad "the fixture job never ran — the case proves nothing"
run "$RACE" --stop >/dev/null 2>&1

# ── 15. a long job is BUSY, not a wedge — and the exemption EXPIRES ─────────────────────────
case_ "15. a stale tick is explained by a running job, and only until its deadline"
state_reset "$GOOD"; run "$GOOD" --install >/dev/null 2>&1
run "$GOOD" --stop >/dev/null 2>&1
rm -f "$FLEET_SCHEDULE_STATE/OFF"
# A stand-in whose COMMAND LINE is the loop (so the pid arm passes) — the real loop is stopped, so
# nothing can re-stamp the tick and the staleness is deterministic, not a race.
bash -c 'exec -a "fleet-schedule.py --loop" sleep 120' & fakepid=$!; echo "$fakepid" >> "$T/pids"
printf '%s\n' "$fakepid" > "$FLEET_SCHEDULE_STATE/loop.pid"
busy_marker() { # busy_marker <deadline-offset-seconds>
  python3 - "$FLEET_SCHEDULE_STATE" "$1" <<'PY'
import json, os, sys, time
state, offset = sys.argv[1], float(sys.argv[2])
tick = os.path.join(state, "tick")
old = time.time() - 100000
if os.path.exists(tick):
    os.utime(tick, (old, old))
else:
    open(tick, "w").write("0\n")
    os.utime(tick, (old, old))
os.makedirs(os.path.join(state, "busy"), exist_ok=True)
now = time.time()
json.dump(
    {"label": "com.test.echo", "started": now - 900, "pid": os.getpid(),
     "deadline": now + offset},
    open(os.path.join(state, "busy", "com.test.echo.json"), "w"),
)
PY
}
busy_marker +900
out="$(run "$GOOD" --verify)"; rc=$?
[ "$rc" -eq 0 ] && ok "a stale tick WITH a live busy job passes --verify (a long job is not a wedge)" \
  || bad "a long-running job failed --verify as a stale loop (rc=$rc): $out"
grep -q 'BUSY' <<<"$out" && ok "the verdict names the job that is running" \
  || bad "the busy job is not named in the verdict: $out"
busy_marker -60
out="$(run "$GOOD" --verify)"; rc=$?
[ "$rc" -eq 1 ] && ok "once the deadline EXPIRES the same tick fails --verify (the exemption is bounded)" \
  || bad "an expired busy marker still excused a stale tick (rc=$rc): $out"
grep -q 'tick is .*old' <<<"$out" && ok "the expired case names the stale tick" \
  || bad "the expired case does not name the stale tick: $out"
kill "$fakepid" 2>/dev/null

# ── 16. an annual (multi-entry) calendar must keep a NEXT occurrence ───────────────────────
case_ "16. a multi-entry StartCalendarInterval with Month/Day is scheduled, not silently never"
CAL="$FIX/calendar"; mkdir -p "$CAL"; cp "$GOOD/RETIRED" "$CAL/RETIRED"
cat > "$T/annual.spec" <<PY
PLIST = {
    "Label": "com.test.annual",
    "ProgramArguments": ["/bin/sh", "-c", "echo annual >> '$MARK.annual'"],
    "StartCalendarInterval": [
        {"Month": 12, "Day": 25, "Hour": 3, "Minute": 0},
        {"Month": 6, "Day": 1, "Hour": 3, "Minute": 0},
    ],
}
PY
mkplist "$CAL" com.test.annual "$T/annual.spec"
state_reset "$CAL"
run "$CAL" --install >/dev/null 2>&1
out="$(run "$CAL" --status)"
grep -qE 'com.test.annual .*next=-' <<<"$out" && bad "the annual job reads 'next=-': its calendar can never come due again" \
  || ok "the annual job has a NEXT occurrence (the _all entries' keys are read)"
[ -f "$MARK.annual" ] && ok "the annual job ran once (never-run) — the fixture is not vacuous" \
  || bad "the annual fixture never ran"
run "$CAL" --stop >/dev/null 2>&1
# 16b: a calendar that matches NOTHING (Feb 31) must FAIL --verify, not read as healthy
NEVER="$FIX/never-due"; mkdir -p "$NEVER"; cp "$GOOD/RETIRED" "$NEVER/RETIRED"
cat > "$T/never.spec" <<PY
PLIST = {
    "Label": "com.test.neverdue",
    "ProgramArguments": ["/bin/sh", "-c", "echo never >> '$MARK.never'"],
    "StartCalendarInterval": {"Month": 2, "Day": 31, "Hour": 3, "Minute": 0},
}
PY
mkplist "$NEVER" com.test.neverdue "$T/never.spec"
state_reset "$NEVER"
run "$NEVER" --install >/dev/null 2>&1
[ -f "$MARK.never" ] && ok "the never-due job ran once first (never-run shortcut)" \
  || bad "the never-due fixture never ran — the case is vacuous"
out="$(run "$NEVER" --verify)"; rc=$?
[ "$rc" -eq 1 ] && ok "a job whose calendar never matches again FAILS --verify" \
  || bad "a job that can never run again was certified healthy (rc=$rc): $out"
grep -q 'can never run' <<<"$out" && ok "the failure says the job can never run again" \
  || bad "the failure is not diagnosable: $out"
run "$NEVER" --stop >/dev/null 2>&1

# ── 17. --stop must create its own OFF switch on a machine that never ran ───────────────────
case_ "17. --stop works where the schedule never ran (no state dir yet)"
NOSSTATE="$T/never-installed"
rm -rf "$NOSSTATE"
out="$(cd / && env -u TEMPLATES_DIR -u INFRA_ROOT -u AGENT_INFRA_PATH \
       HOME="$T/barehome" CELL_HOME="$T/barehome" FLEET_SCHEDULE_STATE="$NOSSTATE" \
       python3 "$SCHED" --stop 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "--stop exits 0 with no state dir" || bad "--stop failed with no state dir (rc=$rc): $out"
grep -q 'Traceback' <<<"$out" && bad "--stop raised a traceback: $out" || ok "no traceback"
[ -f "$NOSSTATE/OFF" ] && ok "the OFF switch was created (the decision is recorded)" \
  || bad "no OFF switch was written"


echo
echo "───────────────────────────────────────────────────────────────"
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
