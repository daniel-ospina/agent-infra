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
case_ "10. the launchd backend is delegated to, not reimplemented"
grep -q 'install-launchd.sh' "$SCHED" && ok "the Darwin path delegates to scripts/install-launchd.sh" \
  || bad "the Darwin path does not delegate — a second macOS scheduler would drift"
grep -q 'cmd_darwin' "$SCHED" && ok "the Darwin branch exists behind a platform check" \
  || bad "no Darwin branch"

echo
echo "───────────────────────────────────────────────────────────────"
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
