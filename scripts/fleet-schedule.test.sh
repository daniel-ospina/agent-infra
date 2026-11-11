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
#   2. A PLACEHOLDER THE RUNTIME DOES NOT KNOW IS A LOUD FAILURE, not an empty argv. ⛔ THIS WAS THE
#      ONE RULE THAT DID NOT HOLD, and it cost a whole cell (agent-infra#2908, #2804): the assertion was a
#      grep over `--status`, which on macOS DELEGATES to launchd and can never emit the wording, and
#      the suite was not even in the shard list when #2639 introduced the drift. It is now graded by
#      `--check` (platform-independent, parses the declarations with this runtime's loader) AND by a
#      three-way comparison of the placeholder lists — installer array, runtime tuple, and the
#      {{NAME}} tokens in the shipped templates — with a MUTATION arm that requires the comparison to
#      REDDEN when a name is removed. Cases 1a-1e; both arms of the identity SKIP are pinned there too
#      (unset → named SKIP, set → the value is rendered into the job).
#   2b. A STAGED COPY THAT IS NOT THE CHECKOUT IS VISIBLE (case 1f). A cell executes
#      $CELL_HOME/.pi/agent/scripts/fleet-schedule.py, so a checkout fix is invisible until the farm
#      is refreshed; `--check` reports it as DRIFT (non-fatal) and `--verify` FAILS on it.
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
#  18. RESIDENCY IS A DECLARED PROPERTY OF THE BODY, READ IN EVERY FORM launchd DOCUMENTS — and a
#      resident job is REFUSED BY NAME, never scheduled into a kill at JOB_TIMEOUT. A fresh review
#      left two P2s on PR #2954 here, one failure class apart and the same class as #2908: (a)
#      `KeepAlive` as a DICT (`{"SuccessfulExit": false}`) is launchd's documented form, was read
#      by IDENTITY, and so a valid declaration was refused as absent — the whole layer with it;
#      (b) the daemon skip lived INSIDE the no-schedule branch, so a resident body carrying a
#      `StartInterval` (ai-multi-repo's shape, the moment an operator sets its identity on a cell)
#      was "scheduled" and killed at FLEET_SCHEDULE_JOB_TIMEOUT, every ceiling. Case 18 proves the
#      accepted forms, the named refusal, that the resident body NEVER RUNS, and — by mutation —
#      that the accepted forms are what makes it pass.
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
  # §19's per-arm state dirs: a loop left behind here keeps ticking at a deleted directory.
  for _s in "$T"/s19*/loop.pid; do [ -f "$_s" ] && kill "$(cat "$_s" 2>/dev/null)" 2>/dev/null; done
  # §20 (the build stamp) keeps its own state dir so it can never contend with §19's box lock.
  for _s in "$T"/st20*/loop.pid; do [ -f "$_s" ] && kill "$(cat "$_s" 2>/dev/null)" 2>/dev/null; done
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
# ⛔ THE BOX LOCK IS PINNED INTO THE FIXTURE (#2890). One scheduler loop per BOX is the invariant, so
# without this seam every case that starts a loop would CONTEND WITH THIS HOST'S OWN PRODUCTION
# SCHEDULER — or, on a box with none, with the previous case's loop, since the mutex is deliberately
# not scoped to the state dir. A per-run root keeps the suite hermetic AND keeps its cases independent.
export FLEET_SCHEDULE_LOCK_ROOT="$T/box-lock"
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
# The live job is what makes the assertion below non-vacuous: the fixture must be a set the layer
# CAN run, so `--install` passing is a statement about the retired job alone and not about an
# empty/inert set (which is refused for its own reason).
mkplist "$BAD_RETIRED" com.test.echo     "$T/echo.spec"
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

code_stamp() { # code_stamp <state-dir> <pid> <path-the-loop-loaded> — a SIMULATED live loop's stamp
  # ⛔ A HAND-BUILT loop.pid MODELS A LIVE LOOP, AND A LIVE LOOP FROM THIS BUILD ALSO RECORDS WHAT IT
  # LOADED (#2961). A fixture that writes only the pidfile models the PRE-STAMP build instead — a
  # state `--verify` now refuses by design, and case 20 pins that it does. So the simulation is made
  # FAITHFUL here rather than the runtime made lenient there: this helper writes the stamp the real
  # loop writes, with the digest of the file the fake loop claims to run.
  python3 - "$1" "$2" "$3" <<'PY'
import hashlib, json, os, sys, time
state, pid, path = sys.argv[1], int(sys.argv[2]), os.path.abspath(sys.argv[3])
with open(path, "rb") as fh:
    digest = hashlib.sha256(fh.read()).hexdigest()[:16]
with open(os.path.join(state, "loop.code"), "w") as fh:
    json.dump({"digest": digest, "pid": pid, "path": path, "started": time.time()}, fh)
PY
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

# ── 1a. the shipped set is RUNNABLE by this runtime — graded by the platform-independent verb ─────
# ⛔ THE OLD ASSERTION HERE WAS A GREP FOR A MESSAGE THE COMMAND COULD NOT EMIT. It ran `--status`
# and hoped to find "this runtime does not know" in the output; on macOS `--status` DELEGATES to
# install-launchd.sh (which has no notion of this runtime's placeholder set), so it was structurally
# vacuous on the machine where templates are written. And nothing compared the two placeholder lists
# at all. `--check` parses the declarations with THIS runtime's loader on EVERY platform, needs no
# loop, and is what `cases 1b/1c` grade — so a template this runtime cannot run can no longer reach
# a cell, which is exactly what happened on 2026-10-27 (cell4: MainPID=0, no reaper canary).
case_ "1a. every shipped declaration is runnable by this runtime (--check, every platform)"
out="$(run "$ROOT/templates/launchd" --check)"; rc=$?
[ "$rc" -eq 0 ] && ok "--check exits 0 on the shipped template set" \
  || bad "the shipped template set is not runnable by this runtime: $out"
grep -qE '^  (ERROR|FAIL) ' <<<"$out" \
  && bad "a shipped template is refused by this runtime (cell4's outage — it refuses the WHOLE layer): $out" \
  || ok "no shipped template is refused (0 ERROR rows)"
grep -q 'DECLARATIONS OK' <<<"$out" \
  && ok "--check printed its verdict, so the pass is a read and not an empty output" \
  || bad "--check printed no verdict line: $out"
# --check must NOT grade target EXISTENCE: whether ~/.pi/agent/scripts is farmed on THIS host is a
# fact about the host. Grading it here would redden CI (where no farm exists) over a good template.
out="$(env HOME="$T/nofarm" CELL_HOME="$T/nofarm" TEMPLATES_DIR="$ROOT/templates/launchd" \
       python3 "$SCHED" --check 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "--check passes with no farm installed (declarations, not this host's layer)" \
  || bad "--check graded the host's missing farm instead of the declarations: $out"

# ── 1b. THE TWO PLACEHOLDER LISTS CANNOT DRIFT ───────────────────────────────────────────────
# #2639 added AI_DRAINER_* / AI_MULTI_REPO_* to install-launchd.sh and not to fleet-schedule.py.
# The same shipped plist was then a designed SKIP on macOS and a hard ERROR on every cell. One list
# would be better than a test; two self-contained renderers (the .py is FARMED to cells alone, so it
# cannot read a sibling manifest) is the shape we have — so the lists are COMPARED, three ways:
# the installer's array, the runtime's tuple, and the {{NAME}} tokens actually present in the shipped
# templates. The check is self-proving: it is run a second time against a MUTATED copy (see below),
# because a guard that cannot fail is the defect this repo keeps re-finding.
DRIFT_PY="$T/placeholder-drift.py"
cat > "$DRIFT_PY" <<'PY'
import ast, os, re, sys
sched, installer, tdir = sys.argv[1], sys.argv[2], sys.argv[3]
# ⛔ FLOORS, so a parse that silently reads NOTHING cannot pass as "no differences". They are set
# BELOW the shipped count on purpose (today: 15) so that a MUTATION removing a name is graded as
# DRIFT — the membership and set-difference checks below — instead of being masked as "truncated".
FLOOR = {"runtime": 10, "installer": 10, "templates": 5}
KNOWN = ("AI_DRAINER_O", "AI_DRAINER_STATE", "AI_MULTI_REPO_SLUG", "AI_MULTI_REPO_REPO",
         "AI_MULTI_REPO_STATE")

def die(kind, msg):
    print("%s: %s" % (kind, msg))
    raise SystemExit(1 if kind == "DRIFT" else 2)

def runtime_list(path):
    tree = ast.parse(open(path).read())
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == "PLACEHOLDERS"
                                                for t in node.targets):
            return list(ast.literal_eval(node.value))
    return None

def installer_list(path):
    body = open(path).read()
    m = re.search(r'^PLIST_PLACEHOLDERS=\((.*?)^\)', body, re.S | re.M)
    if not m:
        return None
    return [ln.strip() for ln in m.group(1).splitlines()
            if ln.strip() and not ln.strip().startswith("#")]

def template_tokens(path):
    toks = set()
    for name in sorted(os.listdir(path)):
        if name.endswith(".plist"):
            with open(os.path.join(path, name), errors="replace") as fh:
                toks |= set(re.findall(r"\{\{([A-Z_][A-Z0-9_]*)\}\}", fh.read()))
    return toks

rt = runtime_list(sched)
sh = installer_list(installer)
tpl = template_tokens(tdir)
if rt is None:
    die("VACUOUS", "no PLACEHOLDERS tuple found in %s — the runtime's list moved and this compare is blind" % sched)
if sh is None:
    die("VACUOUS", "no PLIST_PLACEHOLDERS array found in %s" % installer)
for name, got in (("runtime", rt), ("installer", sh), ("templates", tpl)):
    if len(got) < FLOOR[name]:
        die("VACUOUS", "parsed only %d %s name(s) (floor %d) — a truncated parse would read as agreement"
            % (len(got), name, FLOOR[name]))
unknown = sorted(tpl - set(rt))
if unknown:
    die("DRIFT", "a shipped template carries %s, which the runtime does not know — it would run "
        "with an EMPTY argument" % ", ".join("{{%s}}" % u for u in unknown))
only_rt = sorted(set(rt) - set(sh))
only_sh = sorted(set(sh) - set(rt))
if only_rt or only_sh:
    die("DRIFT", "the two lists disagree — only in the runtime: %s; only in the installer: %s "
        "(a name the cell runtime does not know is a HARD ERROR on every cell)"
        % (only_rt or "none", only_sh or "none"))
for name in KNOWN:
    for where, have in (("fleet-schedule.py PLACEHOLDERS", rt), ("install-launchd.sh PLIST_PLACEHOLDERS", sh),
                        ("templates/launchd", tpl)):
        if name not in have:
            die("DRIFT", "{{%s}} is missing from %s" % (name, where))
if len(rt) != len(set(rt)) or len(sh) != len(set(sh)):
    die("DRIFT", "a duplicate name in %s — the two lists would agree on a set the renderer repeats"
        % ("runtime" if len(rt) != len(set(rt)) else "installer"))
print("counts: runtime=%d installer=%d templates=%d" % (len(rt), len(sh), len(tpl)))
print("checked: %s" % " ".join(KNOWN))
print("clean")
PY

case_ "1b. the two backends' placeholder lists cannot drift (compared, not trusted)"
out="$(python3 "$DRIFT_PY" "$SCHED" "$ROOT/scripts/install-launchd.sh" "$ROOT/templates/launchd" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "runtime tuple, installer array and shipped templates agree" \
  || bad "PLACEHOLDER CONTRACT DRIFT (rc=$rc): $out"
grep -q '^counts: runtime=' <<<"$out" && ok "the comparison counted what it read: $(grep '^counts:' <<<"$out")" \
  || bad "the comparison printed no counts — it may have compared nothing: $out"
grep -q '^checked: .*AI_DRAINER_O' <<<"$out" \
  && ok "the five identity names #2639 broke are all present in all three lists" \
  || bad "the identity names were not verified: $out"

# ⛔ THE MUTATION. Put the drift back — delete AI_DRAINER_O from the runtime's tuple, exactly the
# state #2639 shippped — and the check above must REDDEN, naming the name and the direction. A
# comparison that stays green on the defect it was written for is not a guard.
MUTANT="$T/fleet-schedule.mutated.py"
python3 - "$SCHED" "$MUTANT" <<'PY'
import sys
src = open(sys.argv[1]).read()
out = src.replace('    "AI_DRAINER_O",\n', "", 1)
assert out != src, "the mutation did not apply — the tuple no longer holds AI_DRAINER_O"
open(sys.argv[2], "w").write(out)
PY
out="$(python3 "$DRIFT_PY" "$MUTANT" "$ROOT/scripts/install-launchd.sh" "$ROOT/templates/launchd" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "MUTATION (AI_DRAINER_O removed from the runtime tuple) REDDENS the drift check" \
  || bad "the drift check stayed GREEN/other on the very defect it exists for (rc=$rc): $out"
grep -qE 'DRIFT: .*(missing from fleet-schedule.py PLACEHOLDERS|the two lists disagree|which the runtime does not know)' <<<"$out" \
  && ok "the mutation fails on the CONTRACT, not on a vacuous parse: $(head -1 <<<"$out")" \
  || bad "the mutation's failure does not name the drift: $out"

# ⛔ A SECOND MUTATION, FOR THE OTHER TWO ARMS. The mutant above is caught by the TEMPLATE-vs-runtime
# arm (`unknown`), so it proves ONE of the three pairwise comparisons: the installer⇄runtime SET
# DIFFERENCE (`only_rt` / `only_sh`) could rot away with this suite fully green — and that is the
# direction #2639 travelled (install-launchd.sh learned the AI_* names, the runtime did not, and the
# two backends then disagreed about the SAME template). The name to remove is one NO template uses,
# so the `unknown` arm cannot fire first and mask which arm actually caught it.
MUT_SH="$T/install-launchd.mutated.sh"
python3 - "$ROOT/scripts/install-launchd.sh" "$MUT_SH" <<'PY'
import sys
src = open(sys.argv[1]).read()
out = src.replace("    SWARM_ENV_FILE\n", "", 1)
assert out != src, "the mutation did not apply — PLIST_PLACEHOLDERS no longer lists SWARM_ENV_FILE"
open(sys.argv[2], "w").write(out)
PY
out="$(python3 "$DRIFT_PY" "$SCHED" "$MUT_SH" "$ROOT/templates/launchd" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "MUTATION (SWARM_ENV_FILE removed from the INSTALLER array) REDDENS the drift check" \
  || bad "the installer⇄runtime comparison stayed GREEN on a one-sided removal (rc=$rc): $out"
grep -q 'the two lists disagree' <<<"$out" \
  && ok "it fails on the SET-DIFFERENCE arm, so that direction is proven to fire: $(head -1 <<<"$out")" \
  || bad "the second mutation did not exercise the set-difference arm: $out"

# ── 1c. BOTH ARMS of the identity-placeholder skip ──────────────────────────────────────────
# The designed behaviour is SKIP-with-a-loud-warning when unset and a RENDERED VALUE when set.
# Both arms are pinned here, because either one alone is satisfiable by an accident: "always
# error" passes arm 2, and "always skip" passes arm 1.
DRAINER="$FIX/drainer"; mkdir -p "$DRAINER"; printf '# no retired labels\n' > "$DRAINER/RETIRED"
DRMARK="$T/out/drainer.log"
cat > "$T/drainer.spec" <<PY
PLIST = {
    "Label": "com.test.drainer",
    "ProgramArguments": ["/bin/sh", "-c", "echo \"\$O|\$AI\" >> '$DRMARK'"],
    "EnvironmentVariables": {"O": "{{AI_DRAINER_O}}", "AI": "{{AI_DRAINER_STATE}}"},
    "StartInterval": 1,
}
PY
mkplist "$DRAINER" com.test.drainer "$T/drainer.spec"
mkplist "$DRAINER" com.test.echo    "$T/echo.spec"   # so the set is never zero-live

case_ "1c. identity placeholder UNSET → named SKIP (not an error, not silently empty)"
out="$(env -u AI_DRAINER_O -u AI_DRAINER_STATE TEMPLATES_DIR="$DRAINER" python3 "$SCHED" --check 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "--check still certifies the set (a skip is not a failure)" \
  || bad "an unset identity placeholder made the set uncertifiable (rc=$rc): $out"
grep -q 'SKIP .*com.test.drainer.*{{AI_DRAINER_O}}, {{AI_DRAINER_STATE}}' <<<"$out" \
  && ok "the skip is NAMED with both placeholders (loud, and never a silent empty argv)" \
  || bad "the unset arm is not named as a SKIP: $out"
grep -qE '^  (ERROR|FAIL) .*com.test.drainer' <<<"$out" \
  && bad "an unset identity placeholder is an ERROR again — this is what took cell4's scheduler down: $out" \
  || ok "it is a SKIP, not an error (the designed arm)"
# ⛔ THE ABSENT-PHRASE IS PINNED POSITIVELY **HERE**, because case 1g asserts it NEGATIVELY (an
# unresolvable name must NOT be filed as this machine's absence). A negative-only assertion on prose
# that nothing pins positively is a check that cannot fail: reword `fleet-schedule.py:589` and 1g
# keeps printing ✅ while testing nothing. One case produces the string, the other forbids it.
grep -q 'unresolved placeholder(s) {{AI_DRAINER_O}}, {{AI_DRAINER_STATE}} — absent on this machine' <<<"$out" \
  && ok "a genuinely unset placeholder SAYS 'absent on this machine' (the phrase 1g forbids elsewhere is pinned here)" \
  || bad "the unset arm no longer uses the absence phrase, so 1g's negative assertion is now vacuous: $out"
state_reset "$DRAINER"
out="$(env -u AI_DRAINER_O -u AI_DRAINER_STATE TEMPLATES_DIR="$DRAINER" python3 "$SCHED" --install 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "--install exits 0 with the job skipped" || bad "--install failed (rc=$rc): $out"
[ ! -s "$DRMARK" ] && ok "the skipped job did NOT run with empty values (the run is what would be silent)" \
  || bad "the skipped job executed anyway: $(cat "$DRMARK" 2>/dev/null)"
run "$DRAINER" --stop >/dev/null 2>&1

case_ "1d. identity placeholder SET → the job renders with that value"
out="$(AI_DRAINER_O=/fixture/o AI_DRAINER_STATE=/fixture/ai TEMPLATES_DIR="$DRAINER" \
       python3 "$SCHED" --check 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "--check exits 0" || bad "--check failed with the identity set (rc=$rc): $out"
grep -qE '^  ok .*com.test.drainer' <<<"$out" && ok "the job is RUNNABLE, not skipped" \
  || bad "the job is still skipped with its identity set: $out"
state_reset "$DRAINER"
out="$(AI_DRAINER_O=/fixture/o AI_DRAINER_STATE=/fixture/ai TEMPLATES_DIR="$DRAINER" python3 "$SCHED" --install 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "--install exits 0" || bad "--install failed (rc=$rc): $out"
grep -qx '/fixture/o|/fixture/ai' "$DRMARK" 2>/dev/null \
  && ok "the rendered env reached the job as the VALUE (not empty, not the literal placeholder)" \
  || bad "the job ran with '$(cat "$DRMARK" 2>/dev/null)' — the placeholder was not rendered to its value"
run "$DRAINER" --stop >/dev/null 2>&1

# ── 1e. the SHIPPED template pair, both arms — the exact file that broke the cell ─────────────
case_ "1e. the shipped ai-drainer template: SKIP when unset, runnable when set"
out="$(env -u AI_DRAINER_O -u AI_DRAINER_STATE TEMPLATES_DIR="$ROOT/templates/launchd" \
       python3 "$SCHED" --check 2>&1)"
grep -qE '^  SKIP .*com.eldato.ai-drainer.*AI_DRAINER_O' <<<"$out" \
  && ok "unset → the SHIPPED drainer is skipped by name" \
  || bad "the shipped drainer is not skipped when its identity is unset: $out"
grep -qE '^  (ERROR|FAIL) .*com.eldato.ai-drainer' <<<"$out" \
  && bad "the shipped drainer is an ERROR with its identity unset (cell4's outage): $out" \
  || ok "unset → not an error"
out="$(AI_DRAINER_O=/fixture/o AI_DRAINER_STATE=/fixture/ai TEMPLATES_DIR="$ROOT/templates/launchd" \
       python3 "$SCHED" --check 2>&1)"
grep -qE '^  ok .*com.eldato.ai-drainer' <<<"$out" \
  && ok "set → the SHIPPED drainer is runnable" \
  || bad "the shipped drainer is not runnable with its identity set: $out"


# ── 1f. a STAGED copy that differs from the checkout is visible ───────────────────────────────
# A cell does not run this file from the checkout: the supervisor stages it at
# $CELL_HOME/.pi/agent/scripts/fleet-schedule.py and the loop executes THAT. A fix landed in the
# checkout therefore changes nothing on a running cell until the farm is refreshed — measured
# 2026-10-27, when a "hotfix" for the placeholder drift did not take. The signal must exist and it
# must be non-vacuous in both directions.
case_ "1f. the STAGED scheduler is compared with the checkout (--check notes it, --verify fails)"
STAGED="$T/staged-home/.pi/agent/scripts"; mkdir -p "$STAGED"
cp "$SCHED" "$STAGED/fleet-schedule.py"
out="$(INFRA_ROOT="$ROOT" TEMPLATES_DIR="$ROOT/templates/launchd" python3 "$STAGED/fleet-schedule.py" --check 2>&1)"
grep -q 'DRIFT' <<<"$out" \
  && bad "a byte-identical staged copy was reported as drift (a false alarm trains operators to ignore it): $out" \
  || ok "an identical staged copy is not drift"
printf '\n# hand-edited / stale\n' >> "$STAGED/fleet-schedule.py"
out="$(INFRA_ROOT="$ROOT" TEMPLATES_DIR="$ROOT/templates/launchd" python3 "$STAGED/fleet-schedule.py" --check 2>&1)"; rc=$?
grep -q 'DRIFT .*STAGED scheduler differs from the checkout' <<<"$out" \
  && ok "--check names the staged copy as differing from the checkout" \
  || bad "a stale staged copy was not reported: $out"
[ "$rc" -eq 0 ] && ok "--check does NOT fail on it (a Mac's farmed copy legitimately lags a worktree)" \
  || bad "--check failed on a lagging farmed copy (rc=$rc): $out"
if [ "$(uname -s)" = "Darwin" ]; then
  skip "--verify delegates to launchd on macOS, so the staged-copy FAIL can only be driven on linux"
else
  out="$(INFRA_ROOT="$ROOT" TEMPLATES_DIR="$ROOT/templates/launchd" python3 "$STAGED/fleet-schedule.py" --verify 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && ok "--verify FAILS on a cell whose staged scheduler is not the checkout's" \
    || bad "--verify certified a cell running a copy that is not the checkout's (rc=$rc): $out"
  grep -q 'STAGED scheduler differs from the checkout' <<<"$out" \
    && ok "the failure says why a checkout fix did not take, and how to refresh it" \
    || bad "the failure does not name the staged copy: $out"
fi
# ⛔ "COULD NOT COMPARE" IS NOT "CLEAN" — the other half of the same signal. With no checkout to
# compare against, the old code returned "" for BOTH "no drift" and "never compared", so --verify
# could print SCHEDULE VERIFIED over the one check that exists to stop a cell certifying a build it
# is not running. The arm must be NAMED beside the verdict, so a reader can tell the two apart.
out="$(env -u INFRA_ROOT -u AGENT_INFRA_PATH TEMPLATES_DIR="$ROOT/templates/launchd" \
      python3 "$STAGED/fleet-schedule.py" --verify 2>&1)"
grep -q 'NOTE .*could not be compared with a checkout' <<<"$out" \
  && ok "--verify NAMES the staged-copy arm it could not run (a pass is never silent about it)" \
  || bad "--verify was silent about a staged-copy arm that never ran (the no-op-gate shape): $out"

# ── 1g. the FOURTH copy of the contract: PLACEHOLDERS vs placeholder_values() ────────────────
# The three-way comparison above covers the runtime tuple, the installer array and the template
# tokens. It does NOT cover the resolver, and that gap is the #2804 asymmetry by a fourth route:
# a name declared in all three compared artifacts with no entry in placeholder_values() resolved to
# "" and was filed as "absent on this machine" — a designed per-machine SKIP — while macOS rendered
# it from its env. So the job could never run on ANY cell, with every gate green (measured: rc 0,
# "DECLARATIONS OK — … 0 errors", and exporting the variable changed nothing).
NO_RESOLVER="$FIX/no-resolver"; mkdir -p "$NO_RESOLVER"; cp "$GOOD/RETIRED" "$NO_RESOLVER/RETIRED"
cat > "$T/noresolver.spec" <<'PY'
PLIST = {
    "Label": "com.test.noresolver",
    "ProgramArguments": ["/bin/sh", "-c", "true"],
    "EnvironmentVariables": {"NEW": "{{NO_RESOLVER_PROBE}}"},
    "StartInterval": 60,
}
PY
mkplist "$NO_RESOLVER" com.test.noresolver "$T/noresolver.spec"
mkplist "$NO_RESOLVER" com.test.echo       "$T/echo.spec"   # so the set is never zero-live

case_ "1g. a declared placeholder with NO resolver is a DECLARATION error, not this machine's absence"
# Control arm: the UNMUTATED runtime does not know the name at all (#2639's original shape), so the
# fixture is proven to reach the loader rather than being ignored.
out="$(TEMPLATES_DIR="$NO_RESOLVER" python3 "$SCHED" --check 2>&1)"; rc=$?
grep -q 'does not know: {{NO_RESOLVER_PROBE}}' <<<"$out" \
  && ok "control: an undeclared name is still the loud #2639 ERROR" \
  || bad "the fixture does not reach the unknown-placeholder arm (rc=$rc): $out"
# The mutation DECLARES the name in PLACEHOLDERS and leaves placeholder_values() alone — i.e. it
# puts the tuple and the resolver out of step, exactly what "add the name in both files" produces.
NO_RESOLVER_MUTANT="$T/fleet-schedule.no-resolver.py"
python3 - "$SCHED" "$NO_RESOLVER_MUTANT" <<'PY'
import sys
src = open(sys.argv[1]).read()
out = src.replace('    "PI_BIN_DIR",\n', '    "PI_BIN_DIR",\n    "NO_RESOLVER_PROBE",\n', 1)
assert out != src, "the mutation did not apply — PLACEHOLDERS no longer lists PI_BIN_DIR"
open(sys.argv[2], "w").write(out)
PY
out="$(TEMPLATES_DIR="$NO_RESOLVER" NO_RESOLVER_PROBE=/fixture/x \
       python3 "$NO_RESOLVER_MUTANT" --check 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "a declared-but-unresolvable name FAILS --check (rc=1)" \
  || bad "--check certified a job that can never run anywhere (rc=$rc): $out"
grep -q 'NO resolver in placeholder_values()' <<<"$out" \
  && ok "the failure names the missing RESOLVER, which is what the operator has to add" \
  || bad "the failure does not name the missing resolver: $out"
grep -q 'absent on this machine' <<<"$out" \
  && bad "the unresolvable name is still reported as this machine's absence (a false statement): $out" \
  || ok "it is NOT reported as 'absent on this machine' (it is absent on every machine)"

# ── 1h. --check's exit code is a CROSS-PLATFORM contract ───────────────────────────────────
# The CONTRACT (§CONTRACT) says 3 for "no declarations at all" and 1 for a set this runtime cannot
# run. A nonexistent TEMPLATES_DIR is the former — `--start` answers 3 for it and
# docs/ops/fleet-schedule.md documents 3 — but the linux arm fell into a blanket
# `except ScheduleError -> 1` while the darwin arm tested `isdir` and answered 3. One tree, two
# verdicts for one state, and 1 is the code cloud-cell-supervisor.sh treats as FATAL.
case_ "1h. the 'no declarations at all' state is exit 3 on BOTH platforms (and 1 is not widened)"
darwin_check() { # darwin_check <templates-dir> → prints output, returns the real rc
  python3 - "$SCHED" "$1" 2>&1 <<'PY'
import os, sys
sys.platform = "darwin"
path, tdir = sys.argv[1], sys.argv[2]
os.environ["TEMPLATES_DIR"] = tdir
sys.argv = [path, "--check"]
exec(compile(open(path).read(), path, "exec"), {"__name__": "__main__", "__file__": path})
PY
}
GONE="$T/there-is-no-such-templates-dir"
TEMPLATES_DIR="$GONE" python3 "$SCHED" --check >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "linux: an unresolvable templates dir is exit 3 (a state, not a broken set)" \
  || bad "linux classified 'no declarations at all' as rc=$rc, not 3"
darwin_check "$GONE" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "darwin: the SAME state is exit 3 (the two platforms agree)" \
  || bad "darwin classified the same state as rc=$rc — the two platforms disagree"
EMPTYDIR="$T/empty-templates"; mkdir -p "$EMPTYDIR"
TEMPLATES_DIR="$EMPTYDIR" python3 "$SCHED" --check >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "linux: a dir that EXISTS but holds no declaration set stays exit 1 (unchanged)" \
  || bad "an existing-but-unusable declarations dir became rc=$rc, not 1"
darwin_check "$EMPTYDIR" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "darwin: the same, so 3 was not widened to cover a broken set" \
  || bad "darwin answered rc=$rc for an existing-but-unusable dir, not 1"

# ── 1i. the AI_MULTI_REPO TRIPLE: its RESOLVED VALUE reaches the job (the fifth route) ────────
# Case 1g compares the tuple against `placeholder_values()` by MEMBERSHIP only. A resolver keyed to a
# mistyped env name stays a member, so the name resolves to "", the job is filed as "absent on this
# machine" — a designed per-machine SKIP — and macOS (which renders `{{NAME}}` from its own env)
# disagrees. That is the #2804 asymmetry by a fifth route, on the very template this change gives a
# schedule. The drainer pair was value-pinned in 1c/1d; the multi-repo triple had no such arm.
MULTI="$FIX/multirepo"; mkdir -p "$MULTI"; cp "$GOOD/RETIRED" "$MULTI/RETIRED"
MRMARK="$T/out/multirepo.log"
cat > "$T/multirepo.spec" <<PY
PLIST = {
    "Label": "com.test.multirepo",
    "ProgramArguments": ["/bin/sh", "-c", "echo \"\$OR|\$REPO|\$O\" >> '$MRMARK'"],
    "EnvironmentVariables": {"OR": "{{AI_MULTI_REPO_SLUG}}", "REPO": "{{AI_MULTI_REPO_REPO}}",
                            "O": "{{AI_MULTI_REPO_STATE}}"},
    "StartInterval": 1,
}
PY
mkplist "$MULTI" com.test.multirepo "$T/multirepo.spec"
mkplist "$MULTI" com.test.echo      "$T/echo.spec"   # so the set is never zero-live

case_ "1i. the AI_MULTI_REPO triple renders its VALUEs (membership is not resolution)"
state_reset "$MULTI"
out="$(env -u AI_MULTI_REPO_SLUG -u AI_MULTI_REPO_REPO -u AI_MULTI_REPO_STATE \
       TEMPLATES_DIR="$MULTI" python3 "$SCHED" --install 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "unset → --install exits 0 (the triple is a named SKIP, as designed)" \
  || bad "--install failed with the multi-repo identity unset (rc=$rc): $out"
[ ! -s "$MRMARK" ] && ok "unset → the job did NOT run with empty values" \
  || bad "the job ran with an unresolved identity: $(cat "$MRMARK" 2>/dev/null)"
state_reset "$MULTI"
out="$(AI_MULTI_REPO_SLUG=owner/repo AI_MULTI_REPO_REPO=/fixture/repo AI_MULTI_REPO_STATE=/fixture/state \
       TEMPLATES_DIR="$MULTI" python3 "$SCHED" --install 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "set → --install exits 0" || bad "--install failed with the triple set (rc=$rc): $out"
grep -qx 'owner/repo|/fixture/repo|/fixture/state' "$MRMARK" 2>/dev/null \
  && ok "all three rendered env values reached the job (a mistyped resolver key would leave one empty)" \
  || bad "the job ran with '$(cat "$MRMARK" 2>/dev/null)' — a resolver does not deliver its env value"
out="$(AI_MULTI_REPO_SLUG=owner/repo AI_MULTI_REPO_REPO=/fixture/repo AI_MULTI_REPO_STATE=/fixture/state \
       TEMPLATES_DIR="$ROOT/templates/launchd" python3 "$SCHED" --check 2>&1)"
# ⛔ IT STAYS A SKIP ON THIS RUNTIME — that is the DESIGNED arm for a resident body (the 900 s
# top-up is a macOS job; a cell's resident controller belongs to the cell's supervisor). So the
# assertion is that the identity is NO LONGER the reason and no ERROR appears: with the trio set the
# skip must be the RESIDENCY, by name. Asserting `ok` here would demand the opposite of the design.
grep -qE '^  SKIP +com.eldato.ai-multi-repo +daemon \(FleetResident\)' <<<"$out" \
  && ok "set → the SHIPPED multi-repo template skips for DECLARED RESIDENCY, not for its identity" \
  || bad "with its identity set the shipped multi-repo template is not a by-name resident skip: $out"
grep -qE 'com.eldato.ai-multi-repo.*unresolved placeholder' <<<"$out" \
  && bad "the shipped multi-repo template is STILL blamed for its (now set) identity: $out" \
  || ok "set → no placeholder blame is left on that row"
grep -qE '^  (ERROR|FAIL) .*com.eldato.ai-multi-repo' <<<"$out" \
  && bad "the shipped multi-repo template is an ERROR with its identity set: $out" \
  || ok "set → not an ERROR (a resident declaration is never a layer-wide refusal)"
run "$MULTI" --stop >/dev/null 2>&1

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
# ⛔ `stat -c %Y` is GNU-only, so on BSD/macOS this read returned NOTHING on every pass — the wait
# loop never broke, and the two assertions below then graded `--verify` against a state the arm had
# not established (a false red, measured on the box this was written on). The portable pair: GNU
# spelling first, BSD `-f %m` second. CI is Linux, where the first form answers.
tick_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
for _ in $(seq 1 40); do
  sleep 1
  # wait for a pass to complete after the backdating (the loop skips the locked job)
  if [ -n "$(tick_mtime "$FLEET_SCHEDULE_STATE/tick")" ]; then
    age=$(( $(date +%s) - $(tick_mtime "$FLEET_SCHEDULE_STATE/tick") ))
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
# ⛔ RETIRED IS A DISPOSITION ON A MACHINE AND A REFUSAL AT THE DECLARATION GATE (#2908).
# The label is in RETIRED while its template still exists. That contradiction lives in two REPO
# files, so the AUTHORING gate refuses it — and every MACHINE verb honours the manifest instead,
# because the old unconditional refusal took the whole layer down: cells 3 and 4 reached
# `FATAL: the scheduled layer would not start (rc=1)`, i.e. no reaping, no liveness detection and
# no canary, over one stale manifest line.
state_reset "$BAD_RETIRED"
out="$(run "$BAD_RETIRED" --install)"; rc=$?
[ "$rc" -eq 0 ] && ok "--install honours RETIRED over a leftover template (rc=0, the layer starts)" \
  || bad "--install refused the whole layer over one RETIRED line (rc=$rc): $out"
grep -q 'SKIP.*com.test.retired-both.*RETIRED' <<<"$out" && ok "the retired job is a NAMED SKIP, not a silent absence" \
  || bad "the retired job is not named as SKIP/RETIRED: $out"
grep -q 'com.test.echo' <<<"$out" && ok "the other job in the same set still runs" \
  || bad "the layer lost every other job too: $out"
# The mutation arm: the SAME fixture, graded by the declaration gate, must still be REFUSED — the
# contradiction is not laundered into an accepted set just because a machine can carry on.
out="$(run "$BAD_RETIRED" --check)"; rc=$?
[ "$rc" -eq 1 ] && ok "--check still refuses the RETIRED/template contradiction (authoring gate)" \
  || bad "--check accepted a RETIRED label with a template (rc=$rc): $out"
grep -q 'RETIRED but a template still exists' <<<"$out" && ok "the --check refusal names both halves" \
  || bad "--check refusal is not diagnosable: $out"
# ⛔ THE CADENCE COLUMN IS PART OF THE ROW, AND NOTHING ASSERTED IT (#2908 review, P3). A retired
# job is built with NEITHER an interval nor a calendar (its body is never parsed), so `human_secs(self.
# interval or 0)` rendered it as `every 0s` — a cadence that says the job runs constantly, in the same
# row whose SKIP says it never runs. `Job.cadence` returns "-" for that state, and a mutant restoring
# the old expression reddened NOTHING: the assertion above greps `SKIP.*…RETIRED` and never reaches the
# cadence column. Pin the exact rendered row, including the column that was wrong.
state_reset "$BAD_RETIRED"
out="$(run "$BAD_RETIRED" --status)"; rc=$?
[ "$rc" -eq 0 ] && ok "--status exits 0 over a retired label with a template" \
  || bad "--status failed over the retired fixture (rc=$rc): $out"
grep -qE '^  SKIP   com\.test\.retired-both +- +RETIRED' <<<"$out" \
  && ok "the retired job's cadence column renders '-' (not 'every 0s') beside its SKIP" \
  || bad "the retired row's cadence is not '-' — a job that never runs must not render a cadence: $out"
grep -q 'every 0s' <<<"$out" \
  && bad "a retired job is rendered as 'every 0s' — the cadence contradicts the SKIP: $out" \
  || ok "no retired job renders a bogus 'every 0s' cadence"
state_reset "$BAD_RETIRED"
# ⛔ A LEFTOVER TEMPLATE THAT DOES NOT PARSE MUST NOT DISARM THE CELL (#2908 review, P2). The retired
# short-circuit used to sit BELOW `plistlib.load`, so one stale `RETIRED` line still raised
# "cannot parse" whenever the file it failed to delete was corrupt/truncated — a layer-wide rc 1, which
# is the exact #2908 failure mode the split exists to end (measured on cells 3/4). Retirement is
# decidable from the manifest + the FILENAME, so it is now decided before the body is read.
# The `--check` arm is what keeps this honest: the AUTHORING gate must still refuse the contradiction.
cp "$BAD_RETIRED/RETIRED" "$T/retired.manifest.bak"
printf 'com.test.retired-corrupt\n' >> "$BAD_RETIRED/RETIRED"
printf 'this is not a plist \000\001 truncated \002' > "$BAD_RETIRED/com.test.retired-corrupt.plist"
out="$(run "$BAD_RETIRED" --install)"; rc=$?
[ "$rc" -eq 0 ] && ok "--install survives an UNPARSABLE leftover template of a retired label (rc=0)" \
  || bad "a corrupt leftover template took the whole layer down over one RETIRED line (rc=$rc): $out"
grep -q 'SKIP.*com.test.retired-corrupt.*RETIRED' <<<"$out" \
  && ok "the unparsable retired template is a NAMED SKIP, not a parse refusal" \
  || bad "the unparsable retired template is not named as SKIP/RETIRED: $out"
grep -q 'cannot parse' <<<"$out" \
  && bad "the retired label's body was parsed anyway (a 'cannot parse' refusal): $out" \
  || ok "the retired label's unreadable body was never parsed"
out="$(run "$BAD_RETIRED" --check)"; rc=$?
[ "$rc" -eq 1 ] && ok "--check still refuses the contradiction even with an unparsable leftover" \
  || bad "--check accepted the contradiction behind an unparsable template (rc=$rc): $out"
rm -f "$BAD_RETIRED/com.test.retired-corrupt.plist"
cp "$T/retired.manifest.bak" "$BAD_RETIRED/RETIRED"
state_reset "$BAD_RETIRED"

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

# ── 9d. ...and 3 is ALSO the answer when a pointer RESOLVES but cannot be read ──────────────
# The 9c shape (no path at all) was the ONLY shape that produced rc=3, because main() tests the
# template PATH, not the declarations. A remembered templates-dir pointer aimed at a deleted
# checkout, or at a directory holding no *.plist, fell straight through to spawn: --start printed
# "loop started (pid …)", exited 0, and the supervisor's warn-vs-fatal split — written for exactly
# "this cell was never installed" — never fired, over a loop that could never schedule anything.
# `start` is the only thing that revives the schedule on a running cell (#1864), so that was a
# cell with no reaping and no liveness detection reported as a success.
case_ "9d. --start exits 3 when the declarations it is pointed at are gone or empty"
# Its own empty dir: case 12's EMPTY is declared FURTHER DOWN this file, and depending on it here
# would be a forward reference that reads as a pass only because `set -u` is off.
EMPTY9="$T/empty-decl"; mkdir -p "$EMPTY9"; printf '# no retired labels\n' > "$EMPTY9/RETIRED"
for badroot in "$T/gone-checkout/templates/launchd" "$EMPTY9"; do
  state_reset "$badroot"
  out="$(run "$badroot" --start 2>&1)"; rc=$?
  [ "$rc" -eq 3 ] && ok "--start exits 3 for ${badroot#$T/} (not a silent 0)" \
    || bad "--start returned $rc over unusable declarations at ${badroot#$T/}: $out"
  grep -qE 'loop started' <<<"$out" && bad "it claimed a running loop over declarations it cannot read: $out" \
    || ok "it does not claim to have started a loop it could not feed"
  [ ! -f "$FLEET_SCHEDULE_STATE/loop.pid" ] && ok "no loop pid was recorded for unreadable declarations" \
    || bad "a loop pid was recorded over unreadable declarations"
done

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
# ⛔ A RETIRED LABEL MUST NOT FAIL macOS `--verify` (#2908 review, P1). The delegate's scan treats
# NOT INSTALLED / DRIFTED / "not loaded" as FAIL, and a retired job is DELIBERATELY never installed —
# so the false FAIL this PR removes on Linux stayed on the macOS backend, over the one-line manifest
# edit `templates/launchd/RETIRED:12-14` advertises as "an operator action on ONE file": --install
# started the layer, and --verify then called it broken. systemd's comparable (`mask`) names the
# state (`masked`) rather than reporting the unit absent, and `install-launchd.sh --status` now does
# the same — pinned here through the SHIPPED --verify, so the two halves cannot drift apart.
#
# Both polarities are pinned, because only one of them is "the fix": the NOT INSTALLED arm is the
# PRE-FIX behaviour and must stay a FAILURE (a scan that stopped flagging absences would be a false
# PASS, worse than the false FAIL being closed); the RETIRED arm is what the fix makes certifiable.
cat > "$DARWIN_ROOT/scripts/install-launchd.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-<no args>}" >> "$DELEGATE_RECORD"
cat <<'STATUS'
=== agent-infra launchd status (templates: /fixture) ===
  com.eldato.hub-state-check: RETIRED (manifest wins — template present; remove the template in the repo)
  com.eldato.lane-liveness: installed=loaded version=v0.1.0 (in sync)
STATUS
exit 0
SH
chmod +x "$DARWIN_ROOT/scripts/install-launchd.sh"
out="$(darwin_run --verify)"; rc=$?
[ "$rc" -eq 0 ] && ok "--verify CERTIFIES a set whose only retirement is a named RETIRED state (no false FAIL)" \
  || bad "a retired label was reported as FAIL on macOS (rc=$rc): $out"
grep -q 'FAIL' <<<"$out" && bad "--verify printed a FAIL line for a named retirement: $out" \
  || ok "--verify prints no FAIL line for a named retirement"
# The scan must stay strict: the same fixture worded the way it WAS (a bare absence) still fails.
cat > "$DARWIN_ROOT/scripts/install-launchd.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-<no args>}" >> "$DELEGATE_RECORD"
cat <<'STATUS'
=== agent-infra launchd status (templates: /fixture) ===
  com.eldato.hub-state-check: NOT INSTALLED (template v0.1.0)
STATUS
exit 0
SH
chmod +x "$DARWIN_ROOT/scripts/install-launchd.sh"
out="$(darwin_run --verify)"; rc=$?
[ "$rc" -eq 1 ] && ok "--verify still FAILS a genuine NOT INSTALLED (the scan was not neutered by the fix)" \
  || bad "closing the retired false-FAIL also stopped flagging real absences (rc=$rc): $out"

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

# ── 12b. ZERO LIVE jobs is the SAME false PASS, reached by a longer route ─────────────────────
# An empty DIRECTORY is refused by load_jobs(). But a set where every declared job is a NAMED SKIP
# — a cell with no swarm root and no tortoise checkout — reached the verdict line as
#   SCHEDULE VERIFIED — 0 job(s) live on this machine …, N skipped for a named reason
# and exited 0. cloud-cell-bringup.sh then printed "scheduled layer live: …" and the cell reached
# CELL READY with nothing scheduled at all: the exact string the acceptance forbids, on a host with
# no reaping and no liveness detection. Skips are non-fatal only while ONE job is live.
case_ "12b. a job set where EVERY job is skipped is refused, not verified with 0 live"
ALLSKIP="$FIX/allskip"; mkdir -p "$ALLSKIP"; printf '# no retired labels\n' > "$ALLSKIP/RETIRED"
mkplist "$ALLSKIP" com.test.skipme "$T/skipme.spec"   # {{SWARM_ROOT}} is unset below → SKIP
state_reset "$ALLSKIP"
unset SWARM_ROOT
out="$(run "$ALLSKIP" --install 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "--install refuses a set with no live job (rc=1)" \
  || bad "a zero-live job set was accepted (rc=$rc): $out"
grep -q 'SCHEDULE VERIFIED' <<<"$out" && bad "it printed SCHEDULE VERIFIED over 0 live jobs: $out" \
  || ok "nothing was certified as verified with zero live jobs"
grep -q 'NOT ONE is live' <<<"$out" && ok "the refusal says that no job is live, not that all is well" \
  || bad "the refusal is not diagnosable: $out"
grep -q 'SKIP.*com.test.skipme.*{{SWARM_ROOT}}' <<<"$out" \
  && ok "the skip is still NAMED with its reason (it is counted, not hidden)" \
  || bad "the skip lost its name in the refusal: $out"
out="$(run "$ALLSKIP" --verify 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "--verify also refuses a zero-live set" \
  || bad "--verify passed a set with no live job (rc=$rc): $out"

# ── 12c. "the file exists" is not "it can run" ─────────────────────────────────────────────
# `subprocess` raises OSError for a target that exists but has lost its +x bit (or whose shebang
# interpreter is gone). That arm sets rc=127, and because the stamp was written whenever rc was not
# None, the job was STAMPED — and --verify counts any stamp as live. Measured on the shipped
# script: install rc=0, "SCHEDULE VERIFIED — 1 job(s) live", stamp {"rc": 127}. A cell reached
# CELL READY with a job that had never once run. The execute bit is now part of the declaration
# check, and an exec failure writes no stamp at all.
case_ "12c. a target that exists but cannot execute is refused, never counted as a live run"
NOEXEC_DIR="$FIX/noexec"; mkdir -p "$NOEXEC_DIR"; printf '# no retired labels\n' > "$NOEXEC_DIR/RETIRED"
NOEXEC_TARGET="$T/not-executable.sh"
printf '#!/bin/sh\necho hi\n' > "$NOEXEC_TARGET"
chmod 644 "$NOEXEC_TARGET"
cat > "$T/noexec.spec" <<PY
PLIST = {
    "Label": "com.test.noexec",
    "ProgramArguments": ["$NOEXEC_TARGET"],
    "StartInterval": 60,
}
PY
mkplist "$NOEXEC_DIR" com.test.noexec "$T/noexec.spec"
state_reset "$NOEXEC_DIR"
out="$(run "$NOEXEC_DIR" --install 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "--install refuses a target that exists but is not executable (rc=1)" \
  || bad "a non-executable target was accepted (rc=$rc): $out"
grep -q 'not executable' <<<"$out" && ok "the refusal names the missing execute bit" \
  || bad "the refusal is not diagnosable: $out"
grep -q 'SCHEDULE VERIFIED' <<<"$out" && bad "it certified a job that can never run: $out" \
  || ok "nothing was certified over a non-executable job"
[ ! -f "$FLEET_SCHEDULE_STATE/jobs/com.test.noexec.json" ] \
  && ok "no stamp was written for the job that could not be executed" \
  || bad "a stamp was written for a job that never executed"

# ── 12d. a stamp carrying "rc": null is NOT evidence of a run ──────────────────────────────────
# Stamps written by an earlier copy of this runtime (and by the exec-failure path above) carry
# "rc": null. Not writing them any more does not remove the ones already on disk, so --verify must
# also refuse to COUNT one: it certified such a job as live.
case_ "12d. a pre-existing stamp with a null rc is not counted as a run"
state_reset "$GOOD"
mkdir -p "$FLEET_SCHEDULE_STATE/jobs"
python3 - "$FLEET_SCHEDULE_STATE/jobs/com.test.hourly.json" <<'PYNULL'
import json, sys, time
now = time.time()
json.dump({"label": "com.test.hourly", "started": now - 10, "finished": now - 9,
           "rc": None, "duration": 1}, open(sys.argv[1], "w"))
PYNULL
out="$(run "$GOOD" --verify 2>&1)"
grep -q 'com.test.hourly: declared and runnable here, but has NEVER RUN' <<<"$out" \
  && ok "a null-rc stamp does NOT count as a run" \
  || bad "a null-rc stamp was counted as a run: $out"

# ── 12e. a stamp dated in the FUTURE is not a live job ────────────────────────────────────────
# due_at() is `last + interval`, so a `started` ahead of now makes a job permanently NOT due —
# nothing dispatches it — while --verify counted it live because a stamp exists at all. A cell
# clock that stepped back (a resumed VM, an NTP correction of a fast RTC) is enough, and if it is
# the only live job the zero-live guard is satisfied too.
case_ "12e. a stamp dated in the future is refused, not counted as a live job"
state_reset "$GOOD"
mkdir -p "$FLEET_SCHEDULE_STATE/jobs"
python3 - "$FLEET_SCHEDULE_STATE/jobs/com.test.hourly.json" <<'PYFUT'
import json, sys, time
now = time.time()
json.dump({"label": "com.test.hourly", "started": now + 86400 * 365, "finished": now + 86400 * 365,
           "rc": 0, "duration": 1}, open(sys.argv[1], "w"))
PYFUT
out="$(run "$GOOD" --verify 2>&1)"
grep -q 'com.test.hourly: its last-run stamp is IN THE FUTURE' <<<"$out" \
  && ok "a future-dated stamp FAILS --verify and names the cause" \
  || bad "a stamp dated in the future was counted as a live job: $out"

# ── 12f. a THIRD-PARTY target that cannot execute is a SKIP, not a fleet-wide refusal ────────
# The missing-target arm already splits layer from third party: absent under <home>/.pi/agent is an
# incomplete FARM (fatal), absent anywhere else is a named SKIP (a tortoise checkout without its
# .venv must not block a cell). The execute-bit arm originally ignored that split, so a restored
# venv that lost its mode bits refused CELL READY on every cell — the opposite of the rule the PR
# states. Inside the layer it stays fatal; outside it is a SKIP.
case_ "12f. a third-party argv[0] that exists but cannot execute is a named SKIP, not fatal"
MIXED="$FIX/mixed"; mkdir -p "$MIXED"; printf '# no retired labels\n' > "$MIXED/RETIRED"
TP_NOEXEC="$T/thirdparty-not-executable.sh"
printf '#!/bin/sh\necho tp\n' > "$TP_NOEXEC"; chmod 644 "$TP_NOEXEC"
cat > "$T/tp-noexec.spec" <<PY
PLIST = {
    "Label": "com.test.tp-noexec",
    "ProgramArguments": ["$TP_NOEXEC"],
    "StartInterval": 60,
}
PY
mkplist "$MIXED" com.test.tp-noexec "$T/tp-noexec.spec"
mkplist "$MIXED" com.test.echo     "$T/echo.spec"
state_reset "$MIXED"
out="$(run "$MIXED" --install 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "--install still certifies the cell (the broken job is third-party)" \
  || bad "a third-party non-executable target refused the whole cell (rc=$rc): $out"
grep -q 'SKIP.*com.test.tp-noexec.*not executable' <<<"$out" \
  && ok "it is NAMED as a SKIP with the reason" \
  || bad "the third-party failure is not named as a skip: $out"
grep -q 'com.test.echo .*rc=0' <<<"$out" && ok "the runnable job still ran" \
  || bad "the runnable job did not run: $out"


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

# ── 13b. --stop must not SIGNAL a recycled pid ───────────────────────────────────────────────
# The mirror of 13 on the kill side: `loop_pid()` answers "is that pid alive", and after the loop
# died its number can be recycled onto an unrelated process (a lane, the controller, the
# supervisor). Without the command-line check --stop SIGTERMs it and reports "loop stopped", i.e.
# it kills someone else's work and calls that a successful shutdown.
case_ "13b. --stop refuses a recycled pid instead of signalling the process that now owns it"
state_reset "$GOOD"
sleep 60 & bystander=$!; echo "$bystander" >> "$T/pids"
printf '%s\n' "$bystander" > "$FLEET_SCHEDULE_STATE/loop.pid"
out="$(run "$GOOD" --stop)"; rc=$?
[ "$rc" -eq 0 ] && ok "--stop exits 0 over a recycled pid (a no-op, not an error)" \
  || bad "--stop failed over a recycled pid (rc=$rc): $out"
kill -0 "$bystander" 2>/dev/null \
  && ok "the unrelated process was NOT killed" \
  || bad "--stop SIGTERMed a process that is not fleet-schedule --loop"
[ -f "$FLEET_SCHEDULE_STATE/loop.pid" ] \
  && bad "the stale pidfile survived (the next reader sees the same false 'running')" \
  || ok "the stale pidfile was repaired"
[ -f "$FLEET_SCHEDULE_STATE/OFF" ] \
  && ok "the OFF switch was still set (the decision is recorded)" \
  || bad "--stop did not record the OFF decision"
kill "$bystander" 2>/dev/null

# ── 13c. an OUT-OF-RANGE pid in loop.pid must not wedge every verb ─────────────────────────────
# `loop_pid()` parses `int(...)` and hands the result to `pid_alive()`, which caught only
# `OSError`. `os.kill(10 ** 400, 0)` raises `OverflowError` — an `ArithmeticError`, NOT an
# `OSError` — so it escaped BOTH recovery callers: `loop_pid()` (used by --status/--verify/--stop/
# --start/--install/--loop, i.e. every recovery command) and `acquire_lock()`'s probe (which then
# raises instead of stealing a dead lock, so that job never runs again on any pass). The pidfile
# is written by a foreign writer / restored state dir / hand-edit — the same producer this file's
# own comments name for the 0-byte and short-write arms. Measured on the pre-fix tree:
# `FAIL: --start: OverflowError: Python int too large to convert to C long`, i.e. the cell's only
# scheduler could never come back.
case_ "13c. an out-of-range pid in loop.pid is not a live loop and cannot wedge every verb"
# The PREMISE, asserted rather than assumed: this is the exact exception class the fix is for.
# Without it the case below could pass for an unrelated reason on some other interpreter.
premise="$(python3 - <<'PYRANGE'
import os, sys
try:
    os.kill(10 ** 400, 0)
except OverflowError:
    print("OverflowError" if not issubclass(OverflowError, OSError) else "WRONG-CLASS")
except Exception as exc:
    print(type(exc).__name__)
PYRANGE
)"
[ "$premise" = "OverflowError" ] \
  && ok "13c premise: an out-of-range pid raises OverflowError, which is NOT an OSError" \
  || bad "13c premise is wrong on this interpreter (got '$premise') — the case below proves nothing"
state_reset "$GOOD"
printf '%s\n' "1000000000000000000000000000000000000000000" > "$FLEET_SCHEDULE_STATE/loop.pid"
out="$(run "$GOOD" --status)"; rc=$?
case "$out" in
  *Traceback*|*OverflowError*) bad "--status died on a corrupt pidfile: $out" ;;
  *) ok "--status survives an out-of-range pid in loop.pid" ;;
esac
out="$(run "$GOOD" --verify)"; rc=$?
case "$out" in
  *Traceback*|*OverflowError*) bad "--verify died on a corrupt pidfile: $out" ;;
  *) ok "--verify survives an out-of-range pid in loop.pid" ;;
esac
# …and the recovery that matters: the loop must still be STARTABLE. A verb that merely avoids the
# traceback but cannot bring the scheduler up leaves the cell just as dead.
out="$(run "$GOOD" --start)"; rc=$?
[ "$rc" -eq 0 ] && ok "--start brings the loop up over an out-of-range pid (rc=0)" \
  || bad "--start could not recover from an out-of-range pid (rc=$rc): $out"
newpid13c="$(cat "$FLEET_SCHEDULE_STATE/loop.pid" 2>/dev/null)"
[ -n "$newpid13c" ] && [ "$newpid13c" != "1000000000000000000000000000000000000000000" ] \
  && ok "loop.pid was rewritten to a REAL pid (the corrupt value did not survive)" \
  || bad "loop.pid still holds the out-of-range value ($newpid13c)"
kill -0 "$newpid13c" 2>/dev/null && ok "the loop it started is alive" \
  || bad "--start claimed a loop that is not alive"
run "$GOOD" --stop >/dev/null 2>&1

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
code_stamp "$FLEET_SCHEDULE_STATE" "$fakepid" "$SCHED"   # a live loop from THIS build also stamps
busy_marker() { # busy_marker <deadline-offset> [<started-offset>] [<label>]
  python3 - "$FLEET_SCHEDULE_STATE" "$1" "${2:--900}" "${3:-com.test.echo}" <<'PY'
import json, os, sys, time
state, offset, started_offset, label = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
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
    {"label": label, "started": now + started_offset, "pid": os.getpid(),
     "deadline": now + offset},
    open(os.path.join(state, "busy", label + ".json"), "w"),
)
PY
}
# The busy exemption's ceiling is the verifier's OWN budget, so the case states the budget it is
# reasoning about instead of inheriting the suite's deliberately small one. A job that has been
# running 900s is plausible only under a budget that allows it.
run_v15() { # run_v15 <job-timeout-seconds>
  TEMPLATES_DIR="$GOOD" FLEET_SCHEDULE_JOB_TIMEOUT="$1" python3 "$SCHED" --verify 2>&1
}
busy_marker +900 -900
out="$(run_v15 1800)"; rc=$?
[ "$rc" -eq 0 ] && ok "a stale tick WITH a live busy job passes --verify (a long job is not a wedge)" \
  || bad "a long-running job failed --verify as a stale loop (rc=$rc): $out"
grep -q 'BUSY' <<<"$out" && ok "the verdict names the job that is running" \
  || bad "the busy job is not named in the verdict: $out"
busy_marker -60 -900
out="$(run_v15 1800)"; rc=$?
[ "$rc" -eq 1 ] && ok "once the deadline EXPIRES the same tick fails --verify (the exemption is bounded)" \
  || bad "an expired busy marker still excused a stale tick (rc=$rc): $out"
grep -q 'tick is .*old' <<<"$out" && ok "the expired case names the stale tick" \
  || bad "the expired case does not name the stale tick: $out"
# ⛔ THE DEADLINE IS SELF-DECLARED, so it cannot outlive the budget THIS process enforces. The same
# marker that excuses the tick under a 1800s budget claims a start 900s old — under the suite's 30s
# budget that job would have been killed at 30s (rc=124), so the marker is stale evidence and must
# be dropped. Without the clamp a marker written once with a generous timeout excuses a wedged tick
# for as long as it says, and "the exemption ends with that deadline" is only true for markers
# written under the current config.
busy_marker +900 -900
out="$(run_v15 30)"; rc=$?
[ "$rc" -eq 1 ] && ok "a self-declared deadline is CLAMPED by the verifier's own job budget (rc=1)" \
  || bad "a marker claiming a start beyond the job budget still excused a stale tick (rc=$rc): $out"
grep -q 'BUSY' <<<"$out" && bad "the clamped marker was still treated as a live job: $out" \
  || ok "the clamped marker is not reported as a running job"
# ⛔ AND A MARKER WITH NO USABLE START IS NOT AN EXEMPTION AT ALL. The clamp needs `started`; a
# marker naming only a far-future deadline (foreign, corrupted, or hand-restored) would otherwise
# excuse a stale tick — and every job's OVERDUE arm — FOR EVER, which is the unbounded exemption
# this file's contract says cannot exist. Our own writer always stamps `started`, so dropping such
# a marker fails CLOSED: the tick reads as stale, which is the truth.
python3 - "$FLEET_SCHEDULE_STATE" <<'PYNOSTART'
import json, os, sys, time
state = sys.argv[1]
os.makedirs(os.path.join(state, "busy"), exist_ok=True)
json.dump({"label": "com.test.echo", "deadline": time.time() + 10 ** 9},
          open(os.path.join(state, "busy", "com.test.echo.json"), "w"))
PYNOSTART
out="$(run_v15 1800)"; rc=$?
[ "$rc" -eq 1 ] && ok "a busy marker with NO started is dropped, not treated as an endless exemption (rc=1)" \
  || bad "a marker with no started excused the stale tick indefinitely (rc=$rc): $out"
grep -q 'BUSY' <<<"$out" && bad "a startless marker was reported as a running job: $out" \
  || ok "no startless marker is reported as a running job"
# ⛔ AND A START DATED IN THE FUTURE IS NOT AN EXEMPTION EITHER. The clamp is computed FROM the
# marker's own `started`, so a future-dated one yields a future deadline and `now <= deadline`
# holds for the whole span — a wedged loop certified as busy for years. It needs no corruption:
# the writer stamps `time.time()`, so a backward clock step during a run (VM resume, NTP
# correcting a fast RTC — the cases the stamp arm already refuses) leaves a SIGKILL-surviving
# marker future-dated, and a restored state dir does it too.
busy_marker $((5 * 365 * 86400)) $((5 * 365 * 86400))
out="$(run_v15 1800)"; rc=$?
[ "$rc" -eq 1 ] && ok "a FUTURE-dated start is dropped, not an exemption for years (rc=1)" \
  || bad "a marker dated years ahead excused the stale tick (rc=$rc): $out"
grep -q 'BUSY' <<<"$out" && bad "a future-dated marker was reported as a running job: $out" \
  || ok "no future-dated marker is reported as a running job"
# ⛔ A NON-FINITE START IS NOT AN EXEMPTION EITHER — AND THIS ONE WAS A FALSE PASS (cycle-5 review,
# P1). EVERY comparison against NaN is False, so `started=NaN` walked through BOTH guards above
# (`nan <= 0` did not drop it, `nan > now + slack` did not drop it) and through the clamp, because
# `min(deadline, nan + …)` returns `deadline` when `nan < deadline` is False. The marker's own
# SELF-DECLARED deadline therefore survived unclamped, the marker read as LIVE, and `--verify`
# certified a WEDGED loop `SCHEDULE VERIFIED` rc=0 — exactly the unbounded exemption the two guards
# above say cannot exist. `json.load` parses `NaN`, and the reachable inputs are the ones this file
# already names: hand-edit, foreign writer, restored state dir. Dropping it fails CLOSED.
python3 - "$FLEET_SCHEDULE_STATE" <<'PYNAN'
import json, os, sys, time
state = sys.argv[1]
os.makedirs(os.path.join(state, "busy"), exist_ok=True)
now = time.time()
# `deadline` is self-declared and huge; without the finite gate it survives the clamp untouched.
json.dump({"label": "com.test.echo", "started": float("nan"),
           "deadline": now + 10 ** 12}, open(os.path.join(state, "busy", "com.test.echo.json"), "w"))
PYNAN
out="$(run_v15 1800)"; rc=$?
[ "$rc" -eq 1 ] && ok "a NaN start is dropped, not an unbounded exemption (rc=1)" \
  || bad "a NaN start excused the stale tick — --verify certified a wedged loop (rc=$rc): $out"
grep -q 'BUSY' <<<"$out" && bad "a NaN-started marker was reported as a running job: $out" \
  || ok "no NaN-started marker is reported as a running job"
# ⛔ AND A BIG-INT DEADLINE MUST NOT RAISE OUT OF --verify (cycle-5 review, P1). `json.load` returns
# an arbitrary-precision int for an integer literal, so a marker holding `10**400` made
# `float(entry["deadline"])` raise OverflowError — an ArithmeticError, NOT a ValueError, so the
# marker-parsing except tuple did not cover it. It aborted the check for every job after the broken
# marker instead of naming it: verbatim the defect `_finite` was added for on the stamp arm.
python3 - "$FLEET_SCHEDULE_STATE" <<'PYBIG'
import json, os, sys, time
state = sys.argv[1]
os.makedirs(os.path.join(state, "busy"), exist_ok=True)
now = time.time()
json.dump({"label": "com.test.echo", "started": now - 60, "deadline": 10 ** 400},
          open(os.path.join(state, "busy", "com.test.echo.json"), "w"))
PYBIG
out="$(run_v15 1800)"; rc=$?
# ⛔ rc ALONE DOES NOT DISCRIMINATE HERE (cycle-6 review, P2). `main()`'s blanket
# `except Exception` turns the uncaught OverflowError into exit 1 TOO, so a bare `rc -eq 1`
# passed on the pre-fix tree while `--verify` was dying on a traceback rather than naming the
# dropped marker. Measured: reverted, this arm read ✅ while its sibling traceback arm read ❌.
# The stale-tick message is the positive control — it is only reachable if the marker was
# DROPPED and the tick then read stale, which is the whole point of the fix.
if [ "$rc" -eq 1 ] && grep -q 'stale after' <<<"$out"; then
  ok "a big-int busy deadline is dropped (named stale tick), not raised out of --verify"
else
  bad "a big-int deadline did not fail closed as a stale tick (rc=$rc): $out"
fi
case "$out" in *OverflowError*|*Traceback*) bad "a big-int deadline RAISED out of --verify: $out" ;; *) ok "…and it did not raise a traceback out of the verifier" ;; esac
grep -q 'BUSY' <<<"$out" && bad "a big-int-deadline marker was reported as a running job: $out" \
  || ok "no big-int-deadline marker is reported as a running job"
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

# ── 18. a failed bookkeeping write costs a TICK, never the loop ─────────────────────────────
# The defect (measured 2026-11-03 on a cmux cell): `mark_tick()` hit ENOSPC on a full disk, the
# OSError escaped `while True`, and the cell's ONLY scheduler was dead for 3.6 days — taking
# `eldato-disk-reaper` with it, i.e. the very job that would have freed the space that killed it.
# A closed feedback loop. `log()` had the same hole from the other side: its file append is
# guarded but it ends in `print(line, flush=True)`, and when the loop's stdout IS loop.log that
# print IS the write — so a failure to report the failure was fatal, and the cell's last words
# were a truncated `OSError: [Errno 28] No space left o`.
# Both cases drive the SHIPPED code and FAIL if either guard is removed (mutation-tested).
case_ "18. a failed bookkeeping write costs one tick, never the process"

# 18a — `mark_tick()` cannot write. A DIRECTORY at the tick path raises IsADirectoryError, an
# OSError of the same family as ENOSPC, hermetically (no full filesystem needed).
state_reset "$GOOD"
rm -f "$MARK"
run "$GOOD" --install >/dev/null 2>&1
pid="$(cat "$FLEET_SCHEDULE_STATE/loop.pid" 2>/dev/null)"
before="$(wc -c < "$MARK" 2>/dev/null || echo 0)"
rm -f "$FLEET_SCHEDULE_STATE/tick"; mkdir -p "$FLEET_SCHEDULE_STATE/tick"
sleep 12   # > 2 ticks at FLEET_SCHEDULE_TICK=5
kill -0 "$pid" 2>/dev/null && ok "the loop SURVIVED a failed tick write" \
  || bad "the loop DIED on a failed bookkeeping write — the cell scheduler is gone"
after="$(wc -c < "$MARK" 2>/dev/null || echo 0)"
[ "$after" -gt "$before" ] && ok "it kept running jobs after the failure (the pass continued past the guard)" \
  || bad "no job ran after the bookkeeping failure — the whole pass was abandoned"
grep -q 'bookkeeping write failed' "$FLEET_SCHEDULE_STATE/loop.log" 2>/dev/null \
  && ok "the failure was REPORTED (silence would hide a broken tick)" \
  || bad "the failure was not reported — an operator would see nothing wrong"
run "$GOOD" --stop >/dev/null 2>&1; rmdir "$FLEET_SCHEDULE_STATE/tick" 2>/dev/null

# 18b — the report itself cannot be written: writing to our own stdout raises ENOSPC, exactly as
# it did on the cell. `log()` must swallow it and the caller must keep going.
# ⚠️ HERMETIC ON PURPOSE. The first version redirected stdout to /dev/full, which exists on Linux
# and NOT on macOS/BSD — this suite is explicitly run on the Mac (it guards /proc and drives the
# Darwin branch), so that version reported a permanent false FAIL there blaming `log()` for a
# missing device node, whose tempting "fix" is to delete the guard under test. An object whose
# write() raises ENOSPC is the same condition on every platform.
out18b="$(python3 - "$SCHED" "$T/state18b" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fsched", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.STATE = sys.argv[2]


class EnospcStdout:
    """stdout whose every write fails the way a full disk fails."""
    def write(self, _s):
        raise OSError(28, "No space left on device")
    def flush(self):
        raise OSError(28, "No space left on device")


_real_stdout = sys.stdout
sys.stdout = EnospcStdout()
try:
    m.log("hello")      # the print() at the end of log() raises ENOSPC — it must be swallowed
finally:
    # Restore it, or the CPython shutdown flush of the fake stdout adds an ignored exception and
    # a "Traceback" line that this case would then mistake for log() having raised.
    # ⛔ NO APOSTROPHE IN THIS BODY, and none in any here-doc body nested in a command substitution:
    # bash 3.2 (macOS) scans such a body as CODE, so an unbalanced quote opens single-quote mode
    # and desynchronises the parse for the REST of the file — reported far below the defect
    # (#2930, #2248). scripts/check-bash32-parse.sh is the gate that measures this.
    sys.stdout = _real_stdout
sys.stderr.write("SURVIVED\n")
PY
)"; rc18b=$?
# Control reaching the line AFTER log(), with no traceback, is the oracle: rc is NOT usable here
# (an un-flushable stdout makes CPython exit 120 at shutdown whatever the caller did).
if [ "$rc18b" -eq 0 ] && grep -q 'SURVIVED' <<<"$out18b" \
   && [ "$(grep -c 'Traceback' <<<"$out18b")" -eq 0 ]; then
  ok "log() survived an ENOSPC on its own print (a logging failure is not a process failure)"
else
  bad "log() raised on an ENOSPC write and took the caller with it (rc=$rc18b): $out18b"
fi

# 18d — a logging failure of a NON-OSError kind. `print()` raises UnicodeEncodeError (a ValueError)
# when the stdout encoding cannot represent the message, and EVERY loop message contains an em dash.
# Measured with PYTHONIOENCODING=ascii on the guard-narrowed file: both the OFF-switch log line and
# the new reporter died with a traceback — i.e. the guard added to keep the loop alive was what
# killed it. An undecodable stdout must cost the line, not the process.
out18d="$(PYTHONIOENCODING=ascii python3 - "$SCHED" "$T/state18d" <<'PY18D' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fsched", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.STATE = sys.argv[2]
m.log("hello — em dash")                       # UnicodeEncodeError from print()
m.report_bookkeeping_failure(OSError(28, "No space left on device"))
sys.stderr.write("SURVIVED\n")
PY18D
)"; rc18d=$?
if [ "$rc18d" -eq 0 ] && grep -q 'SURVIVED' <<<"$out18d" \
   && [ "$(grep -c 'Traceback' <<<"$out18d")" -eq 0 ]; then
  ok "an ASCII/undecodable stdout cost the line, not the process (log and report survived)"
else
  bad "log()/report raised UnicodeEncodeError and took the caller with it (rc=$rc18d): $out18d"
fi

# 18e — the report is emitted EXACTLY ONCE. `spawn_loop` merges stderr into stdout, so a reporter
# that writes to both surfaces doubles every line in the one file an operator reads (~2/ TICK on a
# persistently broken tick). `_stderr_is_stdout` is the gate; this pins it by COUNT, which the
# original `grep -q` (presence) could never do — a mutation test showed deleting the gate left the
# suite green while producing two lines per failure.
out18e="$(python3 - "$SCHED" "$T/state18e" <<'PY18E' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fsched", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.STATE = sys.argv[2]
m.report_bookkeeping_failure(OSError(28, "No space left on device"))
PY18E
)"; n18e="$(grep -c 'bookkeeping write failed' <<<"$out18e" || true)"
[ "${n18e:-0}" -eq 1 ] && ok "the failure was reported exactly ONCE (stderr and stdout merged)" \
  || bad "the failure was reported ${n18e:-0}x, not once — a duplicate in every merged log: $out18e"

# 18f — a job whose STAMP WRITE FAILS must not be wedged. `write_stamp` sits in run_job's `finally`,
# which is the ONLY place the lock and busy marker are released: unguarded, an ENOSPC there aborted
# the block, the lock survived holding the LOOP'S OWN live pid, `acquire_lock` then answered "already
# running" for ever, and the job never ran again — the same closed feedback loop this change exists
# to open, with a healthier-looking log line. Measured on the pre-fix file: the marker froze for 80s+
# after the disk recovered and --verify returned SCHEDULE VERIFIED over a job that never runs.
state_reset "$GOOD"
rm -f "$MARK"
run "$GOOD" --install >/dev/null 2>&1
pidf="$(cat "$FLEET_SCHEDULE_STATE/loop.pid" 2>/dev/null)"
state_reset_jobs="$FLEET_SCHEDULE_STATE/jobs"
if [ "$(id -u)" -eq 0 ]; then
  skip "running as root — a 500 jobs dir blocks nothing, so the stamp-write arm cannot run here"
else
  chmod 500 "$state_reset_jobs" 2>/dev/null || true
  sleep 8            # at least one tick where a due job runs and its stamp write fails
  chmod 755 "$state_reset_jobs" 2>/dev/null || true
  beforef=0; [ -f "$MARK" ] && beforef="$(wc -l < "$MARK" 2>/dev/null || echo 0)"
  sleep 10           # the window in which a wedged job stays frozen
  afterf=0; [ -f "$MARK" ] && afterf="$(wc -l < "$MARK" 2>/dev/null || echo 0)"
  [ "${afterf:-0}" -gt "${beforef:-0}" ] \
    && ok "a failed STAMP write did not wedge the job (it kept running after the disk recovered)" \
    || bad "the job was WEDGED by a failed stamp write ($beforef -> $afterf runs) — the lock outlived the failure"
fi
kill -0 "$pidf" 2>/dev/null && ok "the loop survived the failed stamp write" \
  || bad "the loop died on a failed stamp write"
run "$GOOD" --stop >/dev/null 2>&1

# 18g — --verify/--status must NAME unusable stamp/calendar values, not raise. They are the
# surfaces whose whole job is to DIAGNOSE bad state, and they used to traceback (aborting the check
# for every job after the broken one) on: a stamp that is not an object, a `started` that is not a
# finite number, and a calendar value that is not a number.
# ⚠️ No `rc -eq 1` assertion here: `--verify` fails for many reasons, so that arm could never fail
# (a mutation test showed it stayed green with the guard removed). The oracle is the absence of a
# traceback plus a message that NAMES the broken job — both of which disappear with the guard.
state_reset "$GOOD"
run "$GOOD" --install >/dev/null 2>&1
badstamp() { # badstamp <label> <json> <needle>
  printf '%s\n' "$2" > "$FLEET_SCHEDULE_STATE/jobs/$1.json"
  local out rc
  out="$(run "$GOOD" --verify)"; rc=$?
  if [ "$(grep -c 'Traceback' <<<"$out")" -eq 0 ] && grep -q "$3" <<<"$out"; then
    ok "--verify names a $3 instead of raising"
  else
    bad "--verify did not diagnose '$3' (rc=$rc): $out"
  fi
  rm -f "$FLEET_SCHEDULE_STATE/jobs/$1.json"
}
badstamp com.test.hourly '[1, 2, 3]' "not a job record"
badstamp com.test.hourly '{"label": "com.test.hourly", "started": NaN, "finished": 1, "rc": 0, "duration": 0}' "no usable 'started' value"
badstamp com.test.hourly '{"label": "com.test.hourly", "started": 1e999, "finished": 1, "rc": 0, "duration": 0}' "no usable 'started' value"
# ⛔ A BIG-ENOUGH INT IS STILL AN int, and `math.isfinite` RAISES OverflowError on it. So the guard
# that exists to NAME an unusable `started` was itself a re-raiser for this one value class: a stamp
# holding `10**400` tracebacked out of `--verify`, aborting the check for every job after it — the
# defect the guard replaced, one class over (#3340, found by fresh-context review).
python3 -c 'import json,sys; json.dump({"label":"com.test.hourly","started":10**400,"finished":1,"rc":0,"duration":0}, open(sys.argv[1],"w"))' \
  "$FLEET_SCHEDULE_STATE/jobs/com.test.hourly.json"
out_big="$(run "$GOOD" --verify)"; rc_big=$?
if [ "$(grep -c 'Traceback' <<<"$out_big")" -eq 0 ] \
   && grep -q "no usable 'started' value" <<<"$out_big"; then
  ok "18g --verify NAMES a 10**400 started instead of raising out of math.isfinite"
else
  bad "18g --verify raised on a big-int started (rc=$rc_big): $(head -3 <<<"$out_big")"
fi
rm -f "$FLEET_SCHEDULE_STATE/jobs/com.test.hourly.json"
badstamp com.test.hourly '{"label": "com.test.hourly", "started": "yesterday", "finished": 1, "rc": 0, "duration": 0}' "no usable 'started' value"
# NaN must not read as "live": every comparison against NaN is False, so an unguarded type check
# certified it SCHEDULE VERIFIED (rc=0) with zero runs and an empty log — the closed loop again.
printf '{"label": "com.test.hourly", "started": NaN, "finished": 1, "rc": 0, "duration": 0}\n' \
  > "$FLEET_SCHEDULE_STATE/jobs/com.test.hourly.json"
out_nan="$(run "$GOOD" --verify)"; rc_nan=$?
[ "$rc_nan" -eq 1 ] && ok "a NaN started FAILS --verify (it is never due, and never runs)" \
  || bad "a NaN started was certified healthy (rc=$rc_nan): $out_nan"
rm -f "$FLEET_SCHEDULE_STATE/jobs/com.test.hourly.json"

# A calendar value that is not a number: load_jobs validates a calendar's SHAPE, not its values.
BAD_CAL="$FIX/badcal"; mkdir -p "$BAD_CAL"; cp "$GOOD/RETIRED" "$BAD_CAL/RETIRED" 2>/dev/null || true
cat > "$T/badcal.spec" <<PL
PLIST = {
    "Label": "com.test.badcal",
    "ProgramArguments": ["/bin/sh", "-c", "true"],
    "StartCalendarInterval": {"Hour": "noon", "Minute": 0},
}
PL
mkplist "$BAD_CAL" com.test.badcal "$T/badcal.spec"
mkdir -p "$FLEET_SCHEDULE_STATE/jobs"
printf '{"label": "com.test.badcal", "started": 1, "finished": 2, "rc": 0, "duration": 1}\n' \
  > "$FLEET_SCHEDULE_STATE/jobs/com.test.badcal.json"
out_cal="$(TEMPLATES_DIR="$BAD_CAL" python3 "$SCHED" --verify 2>&1)"; rc_cal=$?
if [ "$(grep -c 'Traceback' <<<"$out_cal")" -eq 0 ] \
   && grep -qE "unusable value|unusable calendar|calendar has an unusable" <<<"$out_cal"; then
  ok "--verify names a non-numeric calendar value instead of raising"
else
  bad "--verify raised on a non-numeric calendar value (rc=$rc_cal): $out_cal"
fi
out_stat="$(TEMPLATES_DIR="$BAD_CAL" python3 "$SCHED" --status 2>&1)"
if [ "$(grep -c 'Traceback' <<<"$out_stat")" -eq 0 ] && grep -q 'com.test.badcal' <<<"$out_stat"; then
  ok "--status still prints a row for a job with a non-numeric calendar value"
else
  bad "--status tracebacked or dropped the row: $out_stat"
fi
rm -rf "$BAD_CAL"
run "$GOOD" --stop >/dev/null 2>&1

# 18c — the OTHER two ways a pass can fail escape the loop, both found by fresh-context review and
# both measured to kill the shipped pre-fix loop (rc=1, every job on the box stopped for good):
#   (a) load_jobs() reads UNTRUSTED plists: a templates dir that passes `isdir` and then fails
#       (EACCES/EIO/EMFILE/ESTALE) raised PermissionError out of the old `except ScheduleError`,
#       and a plist whose ROOT is an array raises AttributeError.
#   (b) a stamp a hand-edit or foreign writer left malformed ({"started": "yesterday"}) reaches
#       `float(last)` inside is_due and raises ValueError.
# The two arms are measured SEPARATELY and in this order, because they interact: while the
# templates dir is unreadable the loop deliberately keeps the PREVIOUS job set, so a job declared
# during that window is not in it and cannot be used to prove anything about the pass.
state_reset "$GOOD"
rm -f "$MARK" "$MARK.after"
cat > "$T/zzzafter.spec" <<PL
PLIST = {
    "Label": "com.test.zzzafter",
    "ProgramArguments": ["/bin/sh", "-c", "echo after >> '$MARK.after'"],
    "StartInterval": 2,
}
PL
# A job that sorts AFTER com.test.hourly: without it this case proves only that SOME job ran, and a
# mutation test showed that is not the invariant (com.test.echo sorts FIRST, so it wrote the marker
# even while the rest of the set was abandoned).
mkplist "$GOOD" com.test.zzzafter "$T/zzzafter.spec"
run "$GOOD" --install >/dev/null 2>&1
pidc="$(cat "$FLEET_SCHEDULE_STATE/loop.pid" 2>/dev/null)"

# ── arm (a): the templates dir cannot be read ────────────────────────────────────────────────
if [ "$(id -u)" -eq 0 ]; then
  # ⛔ The ASSERTION is inside the skip too. An earlier version skipped only the chmod, so under
  # root it printed ✅ over a directory that was never made unreadable — and a mutation test showed
  # the load_jobs guard could be reverted with the suite fully green. A vacuous ✅ is worse than a
  # missing case: it is the false PASS this whole suite exists to prevent.
  skip "running as root — chmod 000 blocks nothing, so arm (a) cannot be exercised here"
else
  chmod 000 "$GOOD" 2>/dev/null || true
  sleep 10
  kill -0 "$pidc" 2>/dev/null && ok "an unreadable templates dir did not kill the loop (previous set kept)" \
    || bad "an unreadable templates dir killed the loop — one EACCES on the templates dir stops the whole cell"
  chmod 755 "$GOOD" 2>/dev/null || true
fi

# ── arm (b): one job's stamp is unparseable ──────────────────────────────────────────────────
rm -f "$MARK.after"
printf '{"label": "com.test.hourly", "started": "yesterday", "rc": 0, "duration": 0}\n' \
  > "$FLEET_SCHEDULE_STATE/jobs/com.test.hourly.json" 2>/dev/null || true
sleep 12
kill -0 "$pidc" 2>/dev/null && ok "a malformed stamp did not kill the loop" \
  || bad "a malformed stamp killed the loop — one bad file on disk stops the whole cell"
tailran=0; [ -f "$MARK.after" ] && tailran="$(wc -l < "$MARK.after" 2>/dev/null || echo 0)"
rm -f "$FLEET_SCHEDULE_STATE/jobs/com.test.hourly.json" "$GOOD/com.test.zzzafter.plist" 2>/dev/null || true
[ "${tailran:-0}" -gt 0 ] && ok "the job sorting AFTER the broken one still ran ($tailran runs) — the set was not abandoned" \
  || bad "the job after the broken one ran 0x while a stamp was malformed — one bad stamp silently unschedules the rest"
run "$GOOD" --stop >/dev/null 2>&1

# 18h — a ZERO-BYTE loop.pid must be recovered, not fatal. The loop truncates the pidfile
# (`open(pidfile,"w")`) and then writes it; on ENOSPC that write raised and left an empty file — and
# `loop_pid()` did `"".split()[0]`, an IndexError, which it did not catch. `loop_pid()` is called by
# EVERY command (--loop/--start/--install/--verify/--status/--stop), so a 0-byte pidfile made all of
# them die with a traceback and the cell's only scheduler could never come up again, self-
# perpetuat ingly: each attempt died at the same line before it could rewrite the file. A human
# `rm loop.pid` was the only way back. Measured on the pre-fix file.
state_reset "$GOOD"
run "$GOOD" --install >/dev/null 2>&1
run "$GOOD" --stop >/dev/null 2>&1
: > "$FLEET_SCHEDULE_STATE/loop.pid"          # the exact wreckage an ENOSPC-truncated write leaves
outh="$(run "$GOOD" --verify)"; rch=$?
[ "$(grep -c 'Traceback' <<<"$outh")" -eq 0 ] && ok "--verify survives a zero-byte loop.pid" \
  || bad "--verify raised IndexError on a zero-byte loop.pid: $outh"
# `--start` is the cell's revival path (it also clears the OFF switch a previous --stop set).
outh2="$(run "$GOOD" --start)"; rc_start=$?
[ "$rc_start" -eq 0 ] && ok "--start recovers from a zero-byte loop.pid (it can still come up)" \
  || bad "--start could not recover from a zero-byte loop.pid (rc=$rc_start): $outh2"
pidd="$(cat "$FLEET_SCHEDULE_STATE/loop.pid" 2>/dev/null)"
[ -n "$pidd" ] && kill -0 "$pidd" 2>/dev/null && ok "the loop is running again after an empty pidfile" \
  || bad "no live loop after recovering an empty pidfile"
run "$GOOD" --stop >/dev/null 2>&1

# 18i — a ZERO-BYTE lock file must be STOLEN, not fatal. `acquire_lock` creates the lock then writes
# the pid; a failed write (ENOSPC on a small write) left a 0-byte lock, and the next pass raised
# IndexError on `"".split()[0]` — a job that NEVER runs again on any pass, with no self-healing path,
# until a human deletes the lock. That defeats acquire_lock's own documented invariant ("a lock whose
# pid is GONE is stolen") and, if the job that lost the race is the disk reaper, is the same closed
# feedback loop this PR opens everywhere else.
state_reset "$GOOD"
rm -f "$MARK"
run "$GOOD" --install >/dev/null 2>&1
pidi="$(cat "$FLEET_SCHEDULE_STATE/loop.pid" 2>/dev/null)"
mkdir -p "$FLEET_SCHEDULE_STATE/locks"
: > "$FLEET_SCHEDULE_STATE/locks/com.test.echo.lock"
rm -f "$FLEET_SCHEDULE_STATE/jobs/com.test.echo.json"      # make it due on the next pass
beforei=0; [ -f "$MARK" ] && beforei="$(wc -l < "$MARK" 2>/dev/null || echo 0)"
sleep 12
afteri=0; [ -f "$MARK" ] && afteri="$(wc -l < "$MARK" 2>/dev/null || echo 0)"
[ "${afteri:-0}" -gt "${beforei:-0}" ] && ok "an empty lock file was STOLEN and the job ran again" \
  || bad "an empty lock file wedged the job ($beforei -> $afteri runs) — no self-healing path"
kill -0 "$pidi" 2>/dev/null && ok "the loop survived an empty lock file" \
  || bad "the loop died on an empty lock file"
run "$GOOD" --stop >/dev/null 2>&1

# 18j — THE PUBLISH RACE: a lock created by `O_EXCL` is EMPTY until its pid is written, and a racer's
# probe reads that as an unusable lock, matches the inode (nothing replaced it), and steals it. Then
# BOTH callers return a lock path and the same job runs twice concurrently — the one invariant
# `acquire_lock` exists to hold. Measured on the pre-fix file by widening the create→write window:
# both callers were told they held it. Each leg is fault-injected instead of raced, so the case is
# deterministic: `os.write` is patched to let a racer steal the empty lock and publish its own.
out18j="$(python3 - "$SCHED" "$T/state18j" <<'PY18J' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fleet_schedule_18j", sys.argv[1])
fs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fs)
state = sys.argv[2]
os.makedirs(os.path.join(state, "locks"), exist_ok=True)
fs.STATE = state
path = os.path.join(state, "locks", "demo.lock")
real_write = os.write
def racer(fd, data):
    # the racer steals our just-created, still-EMPTY lock and publishes its own
    try:
        os.unlink(path)
    except OSError:
        pass
    with open(path, "w") as fh:
        fh.write("%d\n" % os.getpid())     # a LIVE pid: ours, in this process
    return real_write(fd, data)
os.write = racer
try:
    got = fs.acquire_lock("demo")
finally:
    os.write = real_write
print("RESULT", "NONE" if got is None else "PATH")
PY18J
)"; rc18j=$?
[ "$rc18j" -eq 0 ] && grep -q 'RESULT NONE' <<<"$out18j" \
  && ok "a lock stolen while EMPTY is not handed to BOTH callers (the publisher loses, nobody wins twice)" \
  || bad "both callers were told they hold the same lock after a mid-publish steal: $out18j"
grep -q 'Traceback' <<<"$out18j" && bad "the publish-race case raised instead of answering: $out18j" || true

# 18k — THE CLEANUP MUST NOT DELETE A RACER'S LOCK. When the pid write fails (ENOSPC on a small
# write), the create arm removes the file it made — but "we made it, so it is ours" stops being true
# once a racer can steal an empty lock and publish its own at the same path. Measured on the pre-fix
# file: the racer's live lock was DELETED by our cleanup (acquire_lock then re-raised, and the job
# was left with no lock at all while another run held one).
out18k="$(python3 - "$SCHED" "$T/state18k" <<'PY18K' 2>&1
import errno, importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fleet_schedule_18k", sys.argv[1])
fs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fs)
state = sys.argv[2]
os.makedirs(os.path.join(state, "locks"), exist_ok=True)
fs.STATE = state
path = os.path.join(state, "locks", "demo.lock")
real_write = os.write
def failing(fd, data):
    try:
        os.unlink(path)
    except OSError:
        pass
    with open(path, "w") as fh:
        fh.write("%d\n" % os.getpid())
    raise OSError(errno.ENOSPC, "No space left on device")
os.write = failing
try:
    fs.acquire_lock("demo")
    print("RESULT NO-RAISE")
except OSError as exc:
    print("RESULT RAISED", exc.errno)
finally:
    os.write = real_write
print("SURVIVED", os.path.exists(path))
PY18K
)"; rc18k=$?
[ "$rc18k" -eq 0 ] && grep -q 'RESULT RAISED' <<<"$out18k" \
  && grep -q 'SURVIVED True' <<<"$out18k" \
  && ok "a failed pid write still RE-RAISES the cause, and leaves a racer's lock in place" \
  || bad "a failed pid write answered wrongly or deleted the racer's lock: $out18k"

# 18l — `--install` READS DUE-NESS BEFORE IT RUNS ANYTHING, and that read is the same untrusted pair
# (`read_stamp` + `is_due`) the loop guards per job. Measured at this head: one hand-edited stamp
# (`{"started": "yesterday"}`) made `float(last)` raise out of `cmd_install` — `--install` returned 1
# with NO `loop.pid`, i.e. the cell was left with no scheduler, one line above the guard whose comment
# says that outcome must not happen. The malformed job must be NAMED and skipped, and the rest of the
# set must still run and install.
state_reset "$GOOD"
rm -f "$MARK"
run "$GOOD" --install >/dev/null 2>&1                      # first pass: writes the stamps
run "$GOOD" --stop >/dev/null 2>&1
# `--stop` drops the OFF switch, which `--install` deliberately refuses to fight; this case is
# about a malformed STAMP, not about the switch.
rm -f "$FLEET_SCHEDULE_STATE/OFF"
printf '{"label": "com.test.hourly", "started": "yesterday", "rc": 0, "duration": 0}\n' \
  > "$FLEET_SCHEDULE_STATE/jobs/com.test.hourly.json"
beforel=0; [ -f "$MARK" ] && beforel="$(wc -l < "$MARK" 2>/dev/null || echo 0)"
sleep 3        # com.test.echo's interval is 2s: let it be DUE, so the case can see the set survive
outl="$(run "$GOOD" --install)"; rcl=$?
[ "$(grep -c 'Traceback' <<<"$outl")" -eq 0 ] \
  && ok "--install did not raise on a malformed stamp (no traceback)" \
  || bad "--install died on a malformed stamp: $outl"
grep -q 'com.test.hourly due-ness unusable' <<<"$outl" \
  && ok "--install NAMED the unusable job" \
  || bad "--install did not name the job whose due-ness it could not read: $outl"
afterl=0; [ -f "$MARK" ] && afterl="$(wc -l < "$MARK" 2>/dev/null || echo 0)"
[ "${afterl:-0}" -gt "${beforel:-0}" ] \
  && ok "--install still ran the healthy due job ($beforel -> $afterl) — one bad stamp did not abandon the set" \
  || bad "--install ran nothing while one stamp was malformed ($beforel -> $afterl)"
lpidl="$(cat "$FLEET_SCHEDULE_STATE/loop.pid" 2>/dev/null)"
[ -n "$lpidl" ] && kill -0 "$lpidl" 2>/dev/null \
  && ok "--install still ended with a RUNNING loop (the cell is not left without a scheduler)" \
  || bad "--install left the cell with NO scheduler over one malformed stamp"
run "$GOOD" --stop >/dev/null 2>&1
rm -f "$FLEET_SCHEDULE_STATE/jobs/com.test.hourly.json" "$FLEET_SCHEDULE_STATE/OFF"

# 18m — a plist whose ROOT is not a dict must be NAMED, not raised. `plistlib.load` returns a LIST for
# a truncated/hand-edited file and the parse SUCCEEDS, so the `except Exception` around the load does
# not cover it; `data.get("Label")` then raised AttributeError. `cmd_loop` had to widen its own call
# site for this input, but `--check`/`--verify`/`--install` call `load_jobs` bare and `main()` caught
# only ScheduleError — so every one of them died with a traceback out of main(), and `--install` left
# the cell with no scheduler.
BADROOT="$FIX/bad-root"; mkdir -p "$BADROOT"; cp "$GOOD/RETIRED" "$BADROOT/RETIRED"
rm -f "$FLEET_SCHEDULE_STATE/OFF"        # --install must reach the DECLARATIONS, not the switch
mkplist "$BADROOT" com.test.echo "$T/echo.spec"
cat > "$BADROOT/com.test.badroot.plist" <<'PL18M'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><array><string>not-a-declaration</string></array></plist>
PL18M
for m18 in --check --verify --install; do
  out18m="$(run "$BADROOT" "$m18")"; rc18m=$?
  [ "$(grep -c 'Traceback' <<<"$out18m")" -eq 0 ] \
    && ok "$m18 did not raise on a non-dict plist root (no traceback)" \
    || bad "$m18 raised a traceback out of main() on a non-dict plist root: $(tail -3 <<<"$out18m")"
  [ "$rc18m" -ne 0 ] && ok "$m18 REFUSED the unreadable declaration set (rc=$rc18m, not a silent pass)" \
    || bad "$m18 returned 0 over a declaration set it could not read"
  grep -q 'com.test.badroot.plist' <<<"$out18m" \
    && ok "$m18 NAMED the file whose root is unusable" \
    || bad "$m18 did not name the offending plist: $out18m"
done

# 18n — a create failure is NOT "somebody else holds it". The create arm re-raises (EACCES/EROFS/
# ENOSPC on `os.open`), so the caller's per-job guard logs the REAL cause. Answering None here was the
# measured defect: on the very ENOSPC recovery this change is about, the operator read
# `SKIP <job>: already running (lock held)` for a job nothing held, and the disk-full cause never
# reached the log. The assertion is inside the root skip for the same reason case 18c's is.
if [ "$(id -u)" -eq 0 ]; then
  skip "running as root — chmod 500 blocks nothing, so the create-failure arm cannot be exercised here"
else
  out18n="$(python3 - "$SCHED" "$T/state18n" <<'PY18N' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fleet_schedule_18n", sys.argv[1])
fs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fs)
state = sys.argv[2]
locks = os.path.join(state, "locks")
os.makedirs(locks, exist_ok=True)
fs.STATE = state
os.chmod(locks, 0o500)          # creatable? no: the CREATE itself must fail
print("RESULT", end=" ")
try:
    got = fs.acquire_lock("demo")
    print("NONE" if got is None else "PATH")
except OSError as exc:
    print("RAISED", type(exc).__name__)
finally:
    os.chmod(locks, 0o700)
PY18N
)"
  grep -q 'RESULT RAISED' <<<"$out18n" \
    && ok "an unwritable locks dir RE-RAISES the cause instead of reporting 'already running'" \
    || bad "an unwritable locks dir answered without naming the real cause: $out18n"
fi


# ── 18. residency is DECLARED, read in every documented form, and refused by name ───────────
# Both P2s a fresh review left on PR #2954 are the #2908 shape: a VALID declaration the runtime did
# not model, whose only reachable outcome is a refused LAYER (cell4, measured 2026-10-27: MainPID=0,
# no controller, no reaping, no liveness, no canary). So the fixtures are the declarations launchd
# documents, not the ones this runtime happened to read.
case_ "18. a RESIDENT body is declared (KeepAlive true/dict/int, RunAtLoad, FleetResident) and refused by name"
RES="$FIX/resident"; mkdir -p "$RES"; cp "$GOOD/RETIRED" "$RES/RETIRED"
cat > "$T/resident-dict.spec" <<PY
PLIST = {
    "Label": "com.test.resident-dict",
    "ProgramArguments": ["/bin/sh", "-c", "echo dict >> '$MARK.residentdict'"],
    "KeepAlive": {"SuccessfulExit": False},
}
PY
cat > "$T/resident-int.spec" <<PY
PLIST = {
    "Label": "com.test.resident-int",
    "ProgramArguments": ["/bin/sh", "-c", "echo int >> '$MARK.residentint'"],
    "KeepAlive": 1,
}
PY
cat > "$T/resident-ral.spec" <<PY
PLIST = {
    "Label": "com.test.resident-ral",
    "ProgramArguments": ["/bin/sh", "-c", "echo ral >> '$MARK.residentral'"],
    "RunAtLoad": 1,
}
PY
cat > "$T/resident-sched.spec" <<PY
PLIST = {
    "Label": "com.test.resident-sched",
    "ProgramArguments": ["/bin/sh", "-c", "echo sched >> '$MARK.residentsched'; sleep 60"],
    "FleetResident": True,
    "StartInterval": 1,
}
PY
mkplist "$RES" com.test.resident-dict  "$T/resident-dict.spec"
mkplist "$RES" com.test.resident-int   "$T/resident-int.spec"
mkplist "$RES" com.test.resident-ral   "$T/resident-ral.spec"
mkplist "$RES" com.test.resident-sched "$T/resident-sched.spec"
mkplist "$RES" com.test.echo           "$T/echo.spec"   # so the set is never all-skip

out="$(run "$RES" --check)"; rc=$?
[ "$rc" -eq 0 ] && ok "an UNMODELLED-BUT-VALID declaration is ACCEPTED, not refused (rc=0)" \
  || bad "a valid declaration is refused again — this is the shape that took a whole cell down: $out"
grep -q 'DECLARATIONS OK' <<<"$out" && ok "--check printed its verdict (a read, not an empty output)" \
  || bad "--check printed no verdict: $out"
grep -qE '^  (ERROR|FAIL) .*com.test.resident' <<<"$out" \
  && bad "a resident DECLARATION is an ERROR: $out" \
  || ok "no resident declaration is an ERROR (0 ERROR rows on all four forms)"
for pair in "resident-dict|KeepAlive dict" "resident-int|KeepAlive" "resident-ral|RunAtLoad" "resident-sched|FleetResident"; do
  lbl="${pair%%|*}"; decl="${pair##*|}"
  grep -qE "^  SKIP .*com.test.$lbl .*declared $decl" <<<"$out" \
    && ok "com.test.$lbl is a NAMED skip: 'declared $decl'" \
    || bad "com.test.$lbl is not refused by the name of the key that declared it ($decl): $out"
done

# ENFORCEMENT, NOT PROSE: the resident bodies must NEVER be started. A "scheduled" resident job is
# the P2-2 defect — it would be started and killed at the ceiling, every ceiling (resident-sched's
# body sleeps 60 s against the suite's 30 s FLEET_SCHEDULE_JOB_TIMEOUT precisely so a regression is
# a kill, not a clean exit).
state_reset "$RES"
before="$(wc -l < "$MARK" 2>/dev/null || echo 0)"
out="$(run "$RES" --install)"; rc=$?
[ "$rc" -eq 0 ] && ok "--install exits 0 with the resident jobs skipped" || bad "--install failed (rc=$rc): $out"
after="$(wc -l < "$MARK" 2>/dev/null || echo 0)"
[ "$after" -gt "$before" ] && ok "the non-resident fixture DID run — the case is not vacuous" \
  || bad "no job ran at all ($before → $after lines), so 'the resident job did not run' would prove nothing"
for m in residentdict residentint residentral residentsched; do
  [ ! -f "$MARK.$m" ] && ok "com.test.$m did NOT run (a resident body is never scheduled into a kill)" \
    || bad "com.test.$m RAN — a resident body is being scheduled, and would be killed at the ceiling"
done
out="$(run "$RES" --status)"
grep -qE 'com.test.resident-sched .*daemon \(FleetResident\)' <<<"$out" \
  && ok "--status names the reason in the truth table, not just in --check" \
  || bad "--status does not name the resident declaration: $out"
run "$RES" --stop >/dev/null 2>&1

# 18b: the BOUNDARY of the dict reading is stated, not implied: launchd's dict form is a SET of
# conditions, so an EMPTY one declares none — it stays the error it already was.
RES_EMPTY="$FIX/resident-empty"; mkdir -p "$RES_EMPTY"; cp "$GOOD/RETIRED" "$RES_EMPTY/RETIRED"
cat > "$T/resident-empty.spec" <<PY
PLIST = {
    "Label": "com.test.resident-empty",
    "ProgramArguments": ["/bin/sh", "-c", "true"],
    "KeepAlive": {},
}
PY
mkplist "$RES_EMPTY" com.test.resident-empty "$T/resident-empty.spec"
mkplist "$RES_EMPTY" com.test.echo          "$T/echo.spec"
out="$(run "$RES_EMPTY" --check)"; rc=$?
[ "$rc" -eq 1 ] && grep -qE '^  FAIL .*com.test.resident-empty.*no StartInterval' <<<"$out" \
  && ok "an EMPTY KeepAlive dict declares no condition and is still refused (the boundary is stated)" \
  || bad "an empty KeepAlive dict is now a resident skip (the reading is too wide): rc=$rc $out"

# 18c: FleetResident marks a body whose SCHEDULE starts it — so it must NOT rescue the
# SCHEDULELESS shape. It did: residency is decided before the schedule and both schedule branches
# are guarded by `not job.daemon`, so `FleetResident: true` with no schedule fell through to the
# resident SKIP and the layer was certified ("DECLARATIONS OK … 0 errors") over a plist no backend
# would ever start — launchd loads it and never runs it (the #1864 defect a cell refuses the whole
# layer over). docs/ops/fleet-schedule.md states the rule; this pins it to the code.
RES_NOSCHED="$FIX/resident-nosched"; mkdir -p "$RES_NOSCHED"; cp "$GOOD/RETIRED" "$RES_NOSCHED/RETIRED"
cat > "$T/resident-nosched.spec" <<PY
PLIST = {
    "Label": "com.test.resident-nosched",
    "ProgramArguments": ["/bin/sh", "-c", "echo nosched >> '$MARK.residentnosched'"],
    "FleetResident": True,
}
PY
mkplist "$RES_NOSCHED" com.test.resident-nosched "$T/resident-nosched.spec"
mkplist "$RES_NOSCHED" com.test.echo           "$T/echo.spec"   # so a certified set is reachable
out="$(run "$RES_NOSCHED" --check)"; rc=$?
[ "$rc" -eq 1 ] && grep -qiE '^  (ERROR|FAIL) .*com.test.resident-nosched.*no StartInterval' <<<"$out" \
  && ok "FleetResident with NO schedule is a hard ERROR (the doc's own sentence, enforced)" \
  || bad "a scheduleless FleetResident was certified as a named SKIP — the job would never run on either backend: rc=$rc $out"
grep -q 'DECLARATIONS OK' <<<"$out" \
  && bad "the layer was certified over a template that can never run: $out" \
  || ok "the set is NOT certified green"

# 18c: SELF-PROVING. Restore the PRE-FIX reading this P2 named (`KeepAlive is True`, with no dict
# branch at all) and the DICT-form fixture must REDDEN — a guard that cannot fail is the defect the
# repo keeps re-finding.
MUTANT="$T/mutant-identity.py"
python3 - "$SCHED" "$MUTANT" <<'PY'
import sys
src = open(sys.argv[1]).read()
old = (
    '    keep_alive = data.get("KeepAlive")\n'
    '    if plist_true(keep_alive):\n'
    '        return "KeepAlive"\n'
    '    if isinstance(keep_alive, dict) and keep_alive:\n'
    '        return "KeepAlive dict"\n'
)
new = (
    '    keep_alive = data.get("KeepAlive")\n'
    '    if keep_alive is True:  # the PRE-FIX reading, restored by the mutation\n'
    '        return "KeepAlive"\n'
)
assert old in src, "the mutation target moved: resident_declaration no longer reads KeepAlive that way"
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PY
out="$(TEMPLATES_DIR="$RES" python3 "$MUTANT" --check 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "MUTATION (KeepAlive read by identity again) makes the set FAIL (rc=1)" \
  || bad "the mutation stayed GREEN — the fixture does not grade the identity comparison (rc=$rc): $out"
grep -qE '^  (ERROR|FAIL) .*com.test.resident-dict' <<<"$out" \
  && ok "the mutation fails ON THE DICT FORM, by name: $(grep -E '^  (ERROR|FAIL) .*resident-dict' <<<"$out" | head -1 | cut -c1-96)" \
  || bad "the mutation reddens something else; the dict-form fixture is not what grades this: $out"


# 18o — the two `load_jobs` OSError hardenings are PINNED, not decorative. An earlier revision of
# this change carried them with NO test: removing BOTH left the suite fully green (PASS=233 FAIL=0),
# so the guards that headline the commit ("ENOSPC/EACCES can no longer escape load_jobs") graded
# nothing. Two arms, each a named refusal rather than a traceback, each mutated back to prove the
# case is what grades it:
#   (a) RETIRED is unreadable (mode 000) — must be a named ScheduleError, never a raw OSError, and
#       no verb may die with a traceback (main() catches only ScheduleError).
#   (b) TEMPLATES_DIR cannot be listed — same requirement.
# `chmod 000` does not stop root, so both arms SKIP there; a SKIP is honest and visible, a false
# PASS is not.
if [ "$(id -u)" = "0" ]; then
  skip "18o(a) RETIRED unreadable → named refusal (root can read anything)"
  skip "18o(b) TEMPLATES_DIR unlistable → named refusal (root can read anything)"
else
  for arm in retired listdir; do
    D18O="$T/18o-$arm"
    mkdir -p "$D18O/tpl"
    mkplist "$D18O/tpl" com.test.echo "$T/echo.spec"
    printf '# nothing retired\n' > "$D18O/tpl/RETIRED"
    MUT18O="$T/mut-18o-$arm.py"
    python3 - "$SCHED" "$MUT18O" "$arm" <<'PY18O'
import sys
src = open(sys.argv[1]).read()
arm = sys.argv[3]
# ⛔ THE MUTATION MUST STAY A VALID PROGRAM. Replacing `try:` with `if True:` orphans the
# `except` clauses the guard sits on, so the mutant was a SyntaxError: it could not emit the named
# refusal, and the "no named refusal" assertion below is then satisfied by ANY failure — the arm
# would have stayed green for a script that never ran, i.e. graded nothing. Neutering the HANDLER
# keeps the file compilable and restores the pre-fix behaviour exactly (the OSError escapes).
if arm == "retired":
    old = '    except OSError as exc:\n        # ⛔ A NAMED REFUSAL, NOT A TRACEBACK.'
    new = '    except RuntimeError as exc:  # the PRE-FIX reading, restored by the mutation\n        # ⛔ A NAMED REFUSAL, NOT A TRACEBACK.'
else:
    old = '    except OSError as exc:\n        raise ScheduleError(\n            "cannot list %s: %s: %s"'
    new = '    except RuntimeError as exc:  # the PRE-FIX reading, restored by the mutation\n        raise ScheduleError(\n            "cannot list %s: %s: %s"'

assert old in src, "the 18o mutation target moved (%s)" % arm
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PY18O
    # 000 on RETIRED isolates the RETIRED read; 0111 on the DIRECTORY isolates the listdir call —
    # a dir you may enter but not read lets a KNOWN filename (RETIRED) be opened, so the RETIRED
    # guard stays green and only `os.listdir` can fail. Using 000 for both made the listdir arm
    # fire the RETIRED guard instead, i.e. the case graded the wrong guard (caught by its own
    # mutation).
    if [ "$arm" = "retired" ]; then
      chmod 000 "$D18O/tpl/RETIRED"
    else
      chmod 0111 "$D18O/tpl"
    fi
    out="$(TEMPLATES_DIR="$D18O/tpl" python3 "$SCHED" --check 2>&1)"; rc=$?
    # restore before ANY assertion so a failure cannot leave an unreadable dir behind
    [ "$arm" = "retired" ] && chmod 644 "$D18O/tpl/RETIRED" || chmod 755 "$D18O/tpl"
    grep -q 'cannot read\|cannot list' <<<"$out" \
      && ok "18o($arm) is a NAMED refusal, not a traceback" \
      || bad "18o($arm) did not name the failure: rc=$rc $out"
    grep -q 'Traceback' <<<"$out" \
      && bad "18o($arm) died with a traceback (main() must catch it): $out" \
      || ok "18o($arm) never reaches a traceback"
    [ "$rc" -ne 0 ] && ok "18o($arm) exits non-zero ($rc)" \
      || bad "18o($arm) exited 0 on an unreadable declaration set"
    # MUTATION: restore the pre-fix reading and the case must go RED (a traceback, not a name)
    if [ "$arm" = "retired" ]; then
      chmod 000 "$D18O/tpl/RETIRED"
    else
      chmod 0111 "$D18O/tpl"
    fi
    mout="$(TEMPLATES_DIR="$D18O/tpl" python3 "$MUT18O" --check 2>&1)"; mrc=$?
    [ "$arm" = "retired" ] && chmod 644 "$D18O/tpl/RETIRED" || chmod 755 "$D18O/tpl"
    # ⛔ THE MUTANT MUST BE SHOWN TO HAVE RUN. An earlier revision made this mutant a SyntaxError
    # (replacing `try:` orphaned its `except` clauses); it printed NOTHING, and "does not name the
    # failure" is trivially true of no output — so the arm reported that the case discriminates
    # while grading a file that never parsed. Two positive requirements now: the mutant must emit a
    # named refusal AT ALL (a PermissionError naming the path, i.e. main()'s last net caught the
    # raw OSError the guard used to convert), and it must NOT be the guard's own phrasing.
    if [ -z "$mout" ]; then
      bad "18o($arm) MUTATION produced NO OUTPUT — it did not run (a SyntaxError mutant grades nothing): rc=$mrc"
    elif ! grep -qi 'permission denied\|PermissionError' <<<"$mout"; then
      bad "18o($arm) MUTATION did not run the pre-fix path either (no PermissionError in its output): $mout"
    elif grep -q 'cannot read\|cannot list' <<<"$mout"; then
      bad "18o($arm) MUTATION still produced the guard's named refusal — the case grades nothing: $mout"
    else
      ok "18o($arm) MUTATION ran and lost the named refusal (raw OSError surfaced instead, rc=$mrc)"
    fi
  done
fi


# 18p — A FAILED STAT ON THE PUBLISH VERIFY IS NOT "SOMEONE ELSE'S LOCK". The publish re-verify
# (`os.stat` after the pid write) skips the candidate when the file is no longer ours. An
# `except OSError: continue` conflated "the path is GONE" with "the stat itself failed" (EIO,
# ESTALE, an EACCES flip landing after the create — the fault 18n already constructs), so a caller
# ABANDONED a lock it still held, with its OWN LIVE PID inside it. Every later `acquire_lock` then
# reads a live holder and answers "held": the job logs `SKIP <job>: already running (lock held)`
# for a lock this very process created, and never runs again until the loop restarts. That is the
# wedged-job class this change exists to close, so the arm is pinned in both directions:
#   (a) a transient stat failure  → the caller KEEPS the lock (path returned, our pid inside)
#   (b) a really-vanished file    → the caller re-examines and re-creates it (never wedged)
out18p="$(python3 - "$SCHED" "$T/state18p" <<'PY18P' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fleet_schedule_18p", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = sys.argv[2]; os.makedirs(os.path.join(d, "locks"), exist_ok=True)
m.STATE = d
L = os.path.join(d, "locks")
real_stat, real_unlink = os.stat, os.unlink

# (a) EIO on the FIRST verify stat: we still hold the inode, so the lock must be kept.
calls = {"n": 0}
def flaky(path, *a, **k):
    if str(path).endswith("eio.lock"):
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError(5, "Input/output error")
    return real_stat(path, *a, **k)
os.stat = flaky
r = m.acquire_lock("eio")
os.stat = real_stat
pid = None
p = os.path.join(L, "eio.lock")
if os.path.exists(p):
    pid = open(p).read().strip()
if r and pid == str(os.getpid()):
    print("RESULT EIO KEPT")
else:
    print("RESULT EIO LOST result=%r pid_in_lock=%r" % (r, pid))

# (b) the file really vanishes between close and verify: the retry loop must re-create it.
calls2 = {"n": 0}
def vanish(path, *a, **k):
    if str(path).endswith("gone.lock") and calls2["n"] == 0:
        calls2["n"] += 1
        real_unlink(path)
        raise FileNotFoundError(2, "No such file or directory")
    return real_stat(path, *a, **k)
os.stat = vanish
r2 = m.acquire_lock("gone")
os.stat = real_stat
held = None
p2 = os.path.join(L, "gone.lock")
if r2 and os.path.exists(p2):
    held = open(p2).read().strip() == str(os.getpid())
print("RESULT ENOENT %s" % ("RECREATED" if held else "WEDGED result=%r" % (r2,)))
PY18P
)"
grep -q 'RESULT EIO KEPT' <<<"$out18p" \
  && ok "18p(a) a transient stat failure keeps the lock we hold (was: abandoned → job wedged)" \
  || bad "18p(a) abandoned a lock it still held on a transient stat error: $out18p"
grep -q 'RESULT ENOENT RECREATED' <<<"$out18p" \
  && ok "18p(b) a really-vanished lock is recreated, not left wedged" \
  || bad "18p(b) did not recover a vanished lock: $out18p"
# MUTATION: restore the PRE-FIX `except OSError: continue` and case (a) must REDDEN. Without this
# the case could pass on an implementation that never abandons anything for any reason.
MUT18P="$T/mut-18p.py"
python3 - "$SCHED" "$MUT18P" <<'PYMUT'
import sys
src = open(sys.argv[1]).read()
old = '            except OSError:\n                cur = None\n'
new = '            except OSError:  # the PRE-FIX reading, restored by the mutation\n                continue\n'
assert old in src, "the 18p mutation target moved"
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PYMUT
mout18p="$(python3 - "$MUT18P" "$T/state18p-mut" <<'PYMU' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fleet_schedule_18pmut", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = sys.argv[2]; os.makedirs(os.path.join(d, "locks"), exist_ok=True)
m.STATE = d
L = os.path.join(d, "locks")
real_stat = os.stat
calls = {"n": 0}
def flaky(path, *a, **k):
    if str(path).endswith("eio.lock"):
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError(5, "Input/output error")
    return real_stat(path, *a, **k)
os.stat = flaky
r = m.acquire_lock("eio")
os.stat = real_stat
pid = None
p = os.path.join(L, "eio.lock")
if os.path.exists(p):
    pid = open(p).read().strip()
print("MUTATION %s" % ("STILL-KEPT (case grades nothing)"
                       if (r and pid == str(os.getpid()))
                       else "RED result=%r pid_in_lock=%r" % (r, pid)))
PYMU
)"
grep -q 'MUTATION RED' <<<"$mout18p" \
  && ok "18p MUTATION (pre-fix except OSError) abandons the lock — the case discriminates" \
  || bad "18p MUTATION stayed green, so the case grades nothing: $mout18p"


# 18q — `os.fstat` ON THE CREATE LEG CAN FAIL, AND THE HANDLER READS ITS RESULT. An earlier revision
# dropped the `own = None` initialiser as "tidiness" and the suite stayed fully green (PASS=244
# FAIL=0) because nothing injects an fstat fault. A stat failure on a full or dying filesystem
# (EIO/ESTALE) is exactly this change's fault class, and without the initialiser it became
# `UnboundLocalError` — a coding error replacing the real cause — raised BEFORE the identity-checked
# cleanup, so the 0-byte lock the create had just made was left behind. Pinned both ways:
#   (a) an fstat fault surfaces the REAL OSError (never UnboundLocalError)
#   (b) the lock left behind is self-healing: the next `acquire_lock` steals it
out18q="$(python3 - "$SCHED" "$T/state18q" <<'PY18Q' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fleet_schedule_18q", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = sys.argv[2]; os.makedirs(os.path.join(d, "locks"), exist_ok=True)
m.STATE = d
real_fstat = os.fstat
def bad_fstat(fd):
    raise OSError(5, "Input/output error")
os.fstat = bad_fstat
try:
    m.acquire_lock("fstatfault")
    print("RESULT NO-RAISE")
except UnboundLocalError as exc:
    print("RESULT UNBOUND %s" % exc)
except OSError as exc:
    print("RESULT REAL-OSERROR %s" % exc)
finally:
    os.fstat = real_fstat
print("LOCK-LEFT %s" % os.path.exists(os.path.join(d, "locks", "fstatfault.lock")))
# (b) the residue must be self-healing, not a wedge
r = m.acquire_lock("fstatfault")
print("RESULT SELFHEAL %s" % ("OK" if r else "WEDGED"))
PY18Q
)"
grep -q 'RESULT REAL-OSERROR' <<<"$out18q" \
  && ok "18q(a) an fstat fault surfaces the real OSError" \
  || bad "18q(a) an fstat fault did not surface the real cause: $out18q"
grep -q 'RESULT UNBOUND' <<<"$out18q" \
  && bad "18q(a) an fstat fault became UnboundLocalError (the initialiser is load-bearing): $out18q" \
  || ok "18q(a) never becomes UnboundLocalError"
grep -q 'RESULT SELFHEAL OK' <<<"$out18q" \
  && ok "18q(b) the lock residue self-heals on the next attempt" \
  || bad "18q(b) an fstat fault left a wedge: $out18q"
MUT18Q="$T/mut-18q.py"
python3 - "$SCHED" "$MUT18Q" <<'PYMUTQ'
import sys
src = open(sys.argv[1]).read()
old = '            own = None\n            try:\n                own = os.fstat(fd)\n'
new = '            try:\n                own = os.fstat(fd)\n'
assert old in src, "the 18q mutation target moved"
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PYMUTQ
mout18q="$(python3 - "$MUT18Q" "$T/state18q-mut" <<'PYMUQ' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fleet_schedule_18qmut", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = sys.argv[2]; os.makedirs(os.path.join(d, "locks"), exist_ok=True)
m.STATE = d
real_fstat = os.fstat
def bad_fstat(fd):
    raise OSError(5, "Input/output error")
os.fstat = bad_fstat
try:
    m.acquire_lock("fstatfault")
    print("MUTATION NO-RAISE")
except UnboundLocalError:
    print("MUTATION RED")
except OSError:
    print("MUTATION STILL-REAL")
finally:
    os.fstat = real_fstat
PYMUQ
)"
grep -q 'MUTATION RED' <<<"$mout18q" \
  && ok "18q MUTATION (initialiser removed) raises UnboundLocalError — the case discriminates" \
  || bad "18q MUTATION did not redden, so the case grades nothing: $mout18q"


# 18r — "CANNOT STAT" IS NOT "IT IS OURS". 18p(a) pins the wedge (a transient stat failure must not
# abandon a lock we still hold); this pins the OPPOSITE wrong answer, which `except OSError: return
# path` gave: `O_EXCL` speaks about CREATE time, not about what now sits at `path`. When the stat
# failure coincides with the documented steal (a racer reads our zero-byte lock, matches the inode,
# replaces it and publishes its own live pid), returning the path made us run the job CONCURRENTLY
# with the racer, and our `finally` then unlinked the RACER's lock by name — after which a third
# caller acquired it too. So on a stat failure the caller must ask the probe's question: read the
# file and compare the pid to ours. Ours ⇒ keep (18p). Not ours ⇒ we lost. Unreadable ⇒ fail closed.
out18r="$(python3 - "$SCHED" "$T/state18r" <<'PY18R' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fleet_schedule_18r", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = sys.argv[2]; os.makedirs(os.path.join(d, "locks"), exist_ok=True)
m.STATE = d
L = os.path.join(d, "locks")
p = os.path.join(L, "stolen.lock")
RACER = 4000000 + (os.getpid() % 1000)   # a pid that is NOT us; liveness of it is irrelevant here
real_stat, real_getpid = os.stat, os.getpid
state = {"n": 0}
def racy_stat(path, *a, **k):
    # the steal lands exactly in the verify window: the file now holds a FOREIGN pid, and the
    # stat that would have told us that fails. (No apostrophe here — this body is nested in a
    # command substitution, and bash 3.2 scans it as CODE: an unbalanced quote desynchronises the
    # whole file. See scripts/check-bash32-parse.sh, #2930/#2248.)
    if os.path.abspath(str(path)) == os.path.abspath(p) and state["n"] == 0:
        state["n"] += 1
        with open(p, "w") as fh:
            fh.write("%d\n" % RACER)
        raise OSError(5, "Input/output error")
    return real_stat(path, *a, **k)
os.stat = racy_stat
try:
    r = m.acquire_lock("stolen")
finally:
    os.stat = real_stat
content = None
if os.path.exists(p):
    try:
        content = open(p).read().strip()
    except OSError:
        content = "unreadable"
if r and content not in (None, str(real_getpid())):
    print("RESULT DOUBLE-HOLD returned=%r content=%r (MUST NOT HAPPEN)" % (r, content))
elif r:
    print("RESULT KEPT-OURS content=%r" % (content,))
else:
    print("RESULT LOST-CORRECTLY content=%r" % (content,))
PY18R
)"
grep -q 'RESULT DOUBLE-HOLD' <<<"$out18r" \
  && bad "18r returned a lock whose content is ANOTHER caller's pid (two holders): $out18r" \
  || ok "18r a stat failure coinciding with a steal never returns the racer's lock"
grep -qE 'RESULT (LOST-CORRECTLY|KEPT-OURS)' <<<"$out18r" \
  && ok "18r resolves to a defensible answer: $(grep -o 'RESULT [A-Z-]*' <<<"$out18r" | head -1)" \
  || bad "18r produced neither a correct loss nor our own lock: $out18r"
# MUTATION: restore the blind `except OSError: return path` and 18r must REDDEN.
MUT18R="$T/mut-18r.py"
python3 - "$SCHED" "$MUT18R" <<'PYMUTR'
import sys
src = open(sys.argv[1]).read()
old = '            except OSError:\n                cur = None\n'
new = '            except OSError:  # the PRE-FIX reading, restored by the mutation\n                return path\n'
assert old in src, "the 18r mutation target moved"
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PYMUTR
mout18r="$(python3 - "$MUT18R" "$T/state18r-mut" <<'PYMUR' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fleet_schedule_18rmut", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = sys.argv[2]; os.makedirs(os.path.join(d, "locks"), exist_ok=True)
m.STATE = d
p = os.path.join(d, "locks", "stolen.lock")
RACER = 4000000 + (os.getpid() % 1000)
real_stat, real_getpid = os.stat, os.getpid
state = {"n": 0}
def racy_stat(path, *a, **k):
    if os.path.abspath(str(path)) == os.path.abspath(p) and state["n"] == 0:
        state["n"] += 1
        with open(p, "w") as fh:
            fh.write("%d\n" % RACER)
        raise OSError(5, "Input/output error")
    return real_stat(path, *a, **k)
os.stat = racy_stat
try:
    r = m.acquire_lock("stolen")
finally:
    os.stat = real_stat
content = None
if os.path.exists(p):
    try:
        content = open(p).read().strip()
    except OSError:
        content = "unreadable"
print("MUTATION %s" % ("RED double-hold" if (r and content not in (None, str(real_getpid())))
                       else "still-correct r=%r content=%r" % (r, content)))
PYMUR
)"
grep -q 'MUTATION RED' <<<"$mout18r" \
  && ok "18r MUTATION (blind return path) produces two holders — the case discriminates" \
  || bad "18r MUTATION stayed green, so the case grades nothing: $mout18r"


# 18s — EVERY WAY THE CONTENT READ CAN FAIL MUST STILL NOT WEDGE. 18p patches only `os.stat`, so the
# content read always succeeds there and the arm graded only the sub-case that works. Measured on the
# revision before this case: a stat failure plus a read that RAISES (EACCES/EIO) or returns b""
# (no exception at all) abandoned a lock this process had created, leaving it on disk holding OUR
# OWN LIVE PID — after which every later `acquire_lock` read a live holder and refused, i.e. the job
# logged `SKIP <job>: already running (lock held)` for a lock we made, for the life of the daemon.
# The invariant is therefore stated over the FAULT SHAPES, not one of them: a lock this process
# created must still be usable by this process afterwards, whatever the read did.
out18s="$(python3 - "$SCHED" "$T/state18s" <<'PY18S' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fleet_schedule_18s", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
base = sys.argv[2]
real_stat, real_open, real_getpid = os.stat, open, os.getpid

class EmptyRead:
    def __init__(self, fh): self._fh = fh
    def read(self, n=-1): return b""
    def fileno(self): return self._fh.fileno()   # the probe fstats the fd it opened
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def close(self): pass

def run(name, read_behaviour):
    d = os.path.join(base, name); os.makedirs(os.path.join(d, "locks"), exist_ok=True)
    m.STATE = d
    path = os.path.join(d, "locks", "w.lock")
    state = {"stat": 0}
    def bad_stat(p, *a, **k):
        if os.path.abspath(str(p)) == os.path.abspath(path) and state["stat"] == 0:
            state["stat"] += 1
            raise OSError(5, "Input/output error")
        return real_stat(p, *a, **k)
    reads = {"n": 0}
    def bad_open(p, *a, **k):
        # ⛔ TRANSIENT — the ownership read only. Faulting EVERY open also faulted the PROBE, which
        # then read b""/EIO, parsed pid=None and STOLE the file: the harness healed exactly what
        # wedges in production, so this loop passed on the PRE-FIX code as well (a false pass,
        # measured). One faulted read is both the realistic shape and the discriminating one.
        if os.path.abspath(str(p)) == os.path.abspath(path) and reads["n"] == 0:
            reads["n"] += 1
            if read_behaviour == "eacces":
                raise PermissionError(13, "Permission denied")
            if read_behaviour == "eio":
                raise OSError(5, "Input/output error")
            if read_behaviour == "empty":
                fh = real_open(p, *a, **k)
                return EmptyRead(fh)
            if read_behaviour == "enoent":
                # the ONE-SHOT lie a dying mount tells: ENOENT for a file that is still there
                raise FileNotFoundError(2, "No such file or directory")
        return real_open(p, *a, **k)
    import builtins
    os.stat = bad_stat
    if read_behaviour != "ok":
        builtins.open = bad_open
    try:
        first = m.acquire_lock("w")
    finally:
        os.stat = real_stat
        builtins.open = real_open
    # The invariant is a JOB's lifecycle, not "acquire twice in one process" (a second acquire in
    # the SAME process is correctly refused — the holder is alive, so the lock is not stale). The
    # wedge is different: a FAILED acquire that leaves the lock on disk holding our own live pid, so
    # EVERY later pass is refused. So: the acquire must succeed, we release as run_job's `finally`
    # does, and the next pass must be able to take it again.
    try:
        os.unlink(path)
    except OSError:
        pass
    second = m.acquire_lock("w")
    held_content = None
    if os.path.exists(path):
        try:
            held_content = real_open(path).read().strip()
        except OSError:
            held_content = "unreadable"
    # ⛔ NOT "the content looks like our pid" — THIS process wrote that pid, so that clause can
    # never fail and would make the case vacuous (measured: it stayed green on a wedging mutant).
    # The invariant is the one that matters to a job: this process must still be able to acquire it.
    # ⛔ `second` IS NOT THE INVARIANT. The harness unlinks the lock first, so re-acquiring is
    # trivially true and `bool(first) and bool(second)` reduced to `bool(first)` — measured: it was
    # True in every run, including rows where the code had left a wedge on disk. The invariant that
    # a job actually feels is "THIS ATTEMPT DID NOT LEAVE ME LOCKED OUT", i.e. the acquire returned a
    # path; `second` is kept only as a smoke check that the lifecycle still works afterwards.
    okish = bool(first) and bool(second)   # first is the invariant; second is a smoke check
    print("%-8s first=%-5s second=%-5s content=%r %s"
          % (read_behaviour, bool(first), bool(second), held_content,
             "USABLE" if okish else "WEDGED"))

run("ok", "ok")
run("eacces", "eacces")
run("eio", "eio")
run("empty", "empty")
run("enoent", "enoent")
PY18S
)"
for shape in ok eacces eio empty enoent; do
  grep -qE "^$shape .*USABLE" <<<"$out18s" \
    && ok "18s(stat-fail + read-$shape) leaves the lock USABLE (no wedge)" \
    || bad "18s(stat-fail + read-$shape) WEDGED the job: $(grep -E "^$shape " <<<"$out18s")"
done
# MUTATION: the pre-fix `except OSError: continue` (fail-"closed" to not-ours) must redden the
# read-failure arms — that is exactly the wedge this case exists to prevent.
MUT18S="$T/mut-18s.py"
python3 - "$SCHED" "$MUT18S" <<'PYMUTS'
import sys
src = open(sys.argv[1]).read()
old = '                except OSError:\n                    mine = None       # undeterminable'
new = '                except OSError:\n                    continue          # the PRE-FIX reading, restored'
assert old in src, "the 18s mutation target moved"
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PYMUTS
mout18s="$(python3 - "$MUT18S" "$T/state18s-mut" <<'PYMUTSR' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fleet_schedule_18smut", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
base = sys.argv[2]
real_stat, real_open, real_getpid = os.stat, open, os.getpid
d = os.path.join(base, "eio"); os.makedirs(os.path.join(d, "locks"), exist_ok=True)
m.STATE = d
path = os.path.join(d, "locks", "w.lock")
state = {"stat": 0}
def bad_stat(p, *a, **k):
    if os.path.abspath(str(p)) == os.path.abspath(path) and state["stat"] == 0:
        state["stat"] += 1
        raise OSError(5, "Input/output error")
    return real_stat(p, *a, **k)
def bad_open(p, *a, **k):
    if os.path.abspath(str(p)) == os.path.abspath(path):
        raise OSError(5, "Input/output error")
    return real_open(p, *a, **k)
import builtins
os.stat = bad_stat; builtins.open = bad_open
try:
    first = m.acquire_lock("w")
finally:
    os.stat = real_stat; builtins.open = real_open
second = m.acquire_lock("w")
content = None
if os.path.exists(path):
    try: content = real_open(path).read().strip()
    except OSError: content = "unreadable"
wedged = not (bool(first) and bool(second))
print("MUTATION %s first=%s second=%s content=%r" % ("RED wedged" if wedged else "still-usable", bool(first), bool(second), content))
PYMUTSR
)"
grep -q 'MUTATION RED' <<<"$mout18s" \
  && ok "18s MUTATION (fail-'closed' to not-ours) WEDGES the job — the case discriminates" \
  || bad "18s MUTATION stayed usable, so the case grades nothing: $mout18s"


# 18t — THE TWO GUARDS THAT WERE CORRECT BUT GRADED BY NOTHING. Both were added in the same commit
# as 18s and neither could redden: the short-write check (no case patched `os.write` to a short
# count) and the stat-ENOENT re-ask (18p(b) builds a GENUINE deletion, which passes identically with
# and without the re-ask). A guard no case can fail is the class this file exists to prevent, so
# each is driven here WITH its own mutation.
#   (a) a SHORT `os.write` leaves a TRUNCATED pid in a lock we created — "3" parses as a live pid, so
#       the probe refuses the lock forever. The create leg must raise and leave nothing behind.
#   (b) a filesystem that answers ENOENT for a file it still holds (ESTALE→ENOENT) must not be
#       believed on ONE answer; the re-ask keeps our own lock instead of abandoning it.
out18t="$(python3 - "$SCHED" "$T/state18t" <<'PY18T' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fleet_schedule_18t", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
base = sys.argv[2]
real_write, real_stat, real_open = os.write, os.stat, open

def short_write(name):
    d = os.path.join(base, name); os.makedirs(os.path.join(d, "locks"), exist_ok=True)
    m.STATE = d
    path = os.path.join(d, "locks", "sw.lock")
    def one_byte(fd, data):
        return real_write(fd, data[:1])          # a real short write, not an exception
    os.write = one_byte
    try:
        raised = None
        try:
            r = m.acquire_lock("sw")
        except OSError as exc:
            raised = exc; r = None
    finally:
        os.write = real_write
    left = os.path.exists(path)
    content = None
    if left:
        try: content = real_open(path).read().strip()
        except OSError: content = "unreadable"
    print("SHORTWRITE raised=%s left=%s content=%r result=%r"
          % (type(raised).__name__ if raised else None, left, content, r))

def enoent_lie(name):
    d = os.path.join(base, name); os.makedirs(os.path.join(d, "locks"), exist_ok=True)
    m.STATE = d
    path = os.path.join(d, "locks", "lie.lock")
    st = {"n": 0}
    def lying_stat(p, *a, **k):
        if os.path.abspath(str(p)) == os.path.abspath(path) and st["n"] == 0:
            st["n"] += 1
            raise FileNotFoundError(2, "No such file or directory")   # the lie
        return real_stat(p, *a, **k)
    os.stat = lying_stat
    try:
        r = m.acquire_lock("lie")
    finally:
        os.stat = real_stat
    content = None
    if os.path.exists(path):
        try: content = real_open(path).read().strip()
        except OSError: content = "unreadable"
    print("ENOENTLIE result=%s content=%r" % (bool(r), content))

short_write("a")
enoent_lie("b")
PY18T
)"
grep -qE '^SHORTWRITE raised=OSError left=False' <<<"$out18t" \
  && ok "18t(a) a short write raises and leaves NO truncated-pid lock" \
  || bad "18t(a) a short write did not raise-and-clean: $(grep '^SHORTWRITE' <<<"$out18t")"
grep -q '^ENOENTLIE result=True' <<<"$out18t" \
  && ok "18t(b) a one-shot ENOENT lie from the stat does not abandon our own lock" \
  || bad "18t(b) believed a one-shot ENOENT and abandoned the lock: $(grep '^ENOENTLIE' <<<"$out18t")"

# MUTATIONS — each guard removed must redden its own arm.
MUT18TA="$T/mut-18ta.py"; MUT18TB="$T/mut-18tb.py"
python3 - "$SCHED" "$MUT18TA" "$MUT18TB" <<'PYMUTT'
import sys
src = open(sys.argv[1]).read()
# (a) drop the short-write check
a_old = ('                written = os.write(fd, payload)\n'
         '                if written != len(payload):\n')
assert a_old in src, "18t(a) mutation target moved"
a_new = ('                written = os.write(fd, payload)\n'
         '                if False:\n')
open(sys.argv[2], "w").write(src.replace(a_old, a_new, 1))
# (b) trust a single ENOENT from the stat again
b_old = ('            except FileNotFoundError:\n'
         '                # Same reasoning: one unreliable filesystem can answer ENOENT for a file it holds.\n')
assert b_old in src, "18t(b) mutation target moved"
b_new = ('            except FileNotFoundError:\n'
         '                continue  # PRE-FIX: trust one ENOENT\n'
         '                # Same reasoning: one unreliable filesystem can answer ENOENT for a file it holds.\n')
open(sys.argv[3], "w").write(src.replace(b_old, b_new, 1))
PYMUTT
mout18ta="$(python3 - "$MUT18TA" "$T/state18ta" <<'PYMUTTA' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("m18ta", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = sys.argv[2]; os.makedirs(os.path.join(d, "locks"), exist_ok=True); m.STATE = d
path = os.path.join(d, "locks", "sw.lock")
real_write, real_open = os.write, open
os.write = lambda fd, data: real_write(fd, data[:1])
try:
    raised = None
    try: r = m.acquire_lock("sw")
    except OSError as exc: raised = exc; r = None
finally: os.write = real_write
left = os.path.exists(path)
content = None
if left:
    try: content = real_open(path).read().strip()
    except OSError: content = "unreadable"
print("MUTATION %s raised=%s left=%s content=%r" % ("RED" if not (raised and not left) else "still-clean",
      type(raised).__name__ if raised else None, left, content))
PYMUTTA
)"
grep -q 'MUTATION RED' <<<"$mout18ta" \
  && ok "18t(a) MUTATION (short-write check removed) leaves a truncated-pid lock — discriminates" \
  || bad "18t(a) MUTATION stayed clean, so the case grades nothing: $mout18ta"
mout18tb="$(python3 - "$MUT18TB" "$T/state18tb" <<'PYMUTTB' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("m18tb", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = sys.argv[2]; os.makedirs(os.path.join(d, "locks"), exist_ok=True); m.STATE = d
path = os.path.join(d, "locks", "lie.lock")
real_stat, real_open = os.stat, open
st = {"n": 0}
def lying(p, *a, **k):
    if os.path.abspath(str(p)) == os.path.abspath(path) and st["n"] == 0:
        st["n"] += 1
        raise FileNotFoundError(2, "No such file or directory")
    return real_stat(p, *a, **k)
os.stat = lying
try: r = m.acquire_lock("lie")
finally: os.stat = real_stat
print("MUTATION %s result=%s" % ("RED" if not r else "still-holds", bool(r)))
PYMUTTB
)"
grep -q 'MUTATION RED' <<<"$mout18tb" \
  && ok "18t(b) MUTATION (one ENOENT trusted) abandons our own lock — discriminates" \
  || bad "18t(b) MUTATION still holds, so the case grades nothing: $mout18tb"


# 18u — "UNDETERMINABLE STAT" MUST NOT MEAN "RETURN THE PATH". The stat-ENOENT re-ask's fall-through
# arm first read `return path`, justified as "anything else resolves to OURS". Measured false: with
# a RACER's live-pid lock in place (the steal this publish block exists to survive) plus a one-shot
# ENOENT then EIO, the caller returned a path while the lock on disk named the racer — and
# `run_job`'s `finally` then unlinked the RACER's lock by name, after which a THIRD caller acquired
# it: two concurrent runs of one job. The arm must fall through to the pid read (keep only if ours).
# Nothing in the suite could see this direction — the 18t(b) mutation only reddens the ABANDON
# direction — so the case is pinned here in its own right, mutated back.
out18u="$(python3 - "$SCHED" "$T/state18u" <<'PY18U' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fleet_schedule_18u", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = sys.argv[2]; os.makedirs(os.path.join(d, "locks"), exist_ok=True)
m.STATE = d
path = os.path.join(d, "locks", "race.lock")
RACER = 4000000 + (os.getpid() % 1000)
real_stat, real_open, real_unlink = os.stat, open, os.unlink
seq = {"n": 0}

def racy_stat(p, *a, **k):
    # ⛔ THE STEAL LANDS INSIDE THE STAT WINDOW — the racer replaces our freshly created lock with
    # one naming ITS OWN pid, with a real unlink+create, and only THEN does the filesystem lie.
    # (An earlier version of this case interposed on `open`, which the `return path` arm never
    # calls — so the mutant saw no steal and the case could not redden: the harness was the bug.)
    if os.path.abspath(str(p)) == os.path.abspath(path):
        seq["n"] += 1
        if seq["n"] == 1:
            try:
                real_unlink(path)
            except OSError:
                pass
            with real_open(path, "w") as fh:
                fh.write("%d\n" % RACER)
            raise FileNotFoundError(2, "No such file or directory")
        if seq["n"] == 2:
            raise OSError(5, "Input/output error")
    return real_stat(p, *a, **k)

os.stat = racy_stat
try:
    r = m.acquire_lock("race")
finally:
    os.stat = real_stat
content = None
if os.path.exists(path):
    try:
        content = real_open(path).read().strip()
    except OSError:
        content = "unreadable"
print("RESULT %s contend=%r content=%r"
      % ("DOUBLE-HOLD" if (r and content != str(os.getpid())) else
         ("REFUSED" if not r else "HELD-OURS"), bool(r), content))
PY18U
)"
grep -q 'RESULT DOUBLE-HOLD' <<<"$out18u" \
  && bad "18u returned a lock naming ANOTHER live pid (two holders, then a deleted racer lock): $out18u" \
  || ok "18u an undeterminable stat never returns a foreign lock: $(grep -o 'RESULT [A-Z-]*' <<<"$out18u")"

MUT18U="$T/mut-18u.py"
python3 - "$SCHED" "$MUT18U" <<'PYMUTU'
import sys
src = open(sys.argv[1]).read()
old = ('                    # pid, keep only if it is ours.\n'
       '                    cur = None\n')
new = ('                    # pid, keep only if it is ours.\n'
       '                    return path  # the PRE-FIX reading, restored by the mutation\n')
assert old in src, "the 18u mutation target moved"
open(sys.argv[2], "w").write(src.replace(old, new, 1))
PYMUTU
mout18u="$(python3 - "$MUT18U" "$T/state18u-mut" <<'PYMUTUR' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("m18u", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = sys.argv[2]; os.makedirs(os.path.join(d, "locks"), exist_ok=True); m.STATE = d
path = os.path.join(d, "locks", "race.lock")
RACER = 4000000 + (os.getpid() % 1000)
real_stat, real_open, real_unlink = os.stat, open, os.unlink
seq = {"n": 0}
def racy_stat(p, *a, **k):
    if os.path.abspath(str(p)) == os.path.abspath(path):
        seq["n"] += 1
        if seq["n"] == 1:
            try: real_unlink(path)
            except OSError: pass
            with real_open(path, "w") as fh: fh.write("%d\n" % RACER)
            raise FileNotFoundError(2, "ENOENT")
        if seq["n"] == 2: raise OSError(5, "EIO")
    return real_stat(p, *a, **k)
os.stat = racy_stat
try: r = m.acquire_lock("race")
finally:
    os.stat = real_stat
content = None
if os.path.exists(path):
    try: content = real_open(path).read().strip()
    except OSError: content = "unreadable"
print("MUTATION %s contend=%r content=%r" % ("RED double-hold" if (r and content != str(os.getpid())) else "still-refused", bool(r), content))
PYMUTUR
)"
grep -q 'MUTATION RED' <<<"$mout18u" \
  && ok "18u MUTATION (blind return path) produces two holders — the case discriminates" \
  || bad "18u MUTATION stayed refused, so the case grades nothing: $mout18u"


# ── 19. ONE LOOP PER BOX, not per $STATE (#2890) ────────────────────────────────────────────────
# The defect: the loop's single-instance guard is scoped to $STATE, but the resource it guards is
# the BOX. On cell-4 (2026-11-06, recorded on #2890) SEVEN `--loop` instances ran one job set on one
# machine, resolving five different state dirs — a cell home, the operator's home, three lane-
# worktree homes and a stale fixture home. Every one of them was internally correct; none could see
# the others, and every due reaper/canary/doctor ran seven times, concurrently.
#
# Every arm drives the SHIPPED script through its real entry point. `s19` pins the box lock to a
# per-run root, so the suite stays hermetic and the arms stay independent of each other AND of this
# host's own production scheduler. Each arm KILLS its loop before the next starts: the whole point is
# that only one loop may hold the box.
#
# ⛔ THE LOCK RECORD IS JSON, AND EVERY ARM BELOW WRITES IT AS JSON. The first cut of §19 wrote it
# whitespace-separated, which `read_loop_lock()` rejects as corrupt — so 19d/19e were silently
# exercise the CORRUPT-record path while claiming to grade the dead-pid and recycled-pid arms, and a
# mutation deleting the whole start-time identity check left them green. Found by the [VGATE] pass.
echo
case_ "19. one scheduler loop per BOX, not per \$STATE (#2890)"
L19="$T/box19"; mkdir -p "$L19"
X19="$T/box19-x"; mkdir -p "$X19"
s19() { # s19 <state> <templates> <args...>
  local st="$1" dir="$2"; shift 2
  env TEMPLATES_DIR="$dir" FLEET_SCHEDULE_STATE="$st" FLEET_SCHEDULE_LOCK_ROOT="$L19" \
      python3 "$SCHED" "$@" 2>&1
}
s19loop() { # s19loop <state> [script] — foreground --loop, bounded so a NON-refusal cannot hang.
  timeout 15 env TEMPLATES_DIR="$GOOD" FLEET_SCHEDULE_STATE="$1" FLEET_SCHEDULE_LOCK_ROOT="${3:-$L19}" \
      python3 "${2:-$SCHED}" --loop 2>&1
}
lock19() { # lock19 <root> <pid> <start> <state> — write a real (JSON) lock record
  python3 -c 'import json,sys; print(json.dumps({"pid": int(sys.argv[1]), "start": sys.argv[2], "state": sys.argv[3]}))' \
    "$2" "$3" "$4" > "$1/loop.lock"
}
starttime19() { # starttime19 <pid> — the same /proc field the runtime records
  python3 -c 'import sys;raw=open("/proc/%s/stat"%sys.argv[1]).read();print(raw[raw.rfind(")")+2:].split()[19])' "$1"
}

# 19a — the measured condition: a SECOND state dir on the same box.
s19 "$T/s19a" "$GOOD" --start >/dev/null 2>&1
pidA="$(cat "$T/s19a/loop.pid" 2>/dev/null)"
if [ -n "$pidA" ] && kill -0 "$pidA" 2>/dev/null; then
  ok "19a baseline: a loop is running for state dir A (pid $pidA)"
else
  bad "19a baseline loop never came up — the rest of §19 grades nothing"
fi
out19a="$(s19loop "$T/s19b")"; rc19a=$?
[ "$rc19a" -eq 0 ] \
  && ok "19a a second loop for a DIFFERENT state dir exits 0 (no failure signal on a healthy box)" \
  || bad "19a the refused second loop exited $rc19a, not 0: $out19a"
grep -q 'already has a scheduler' <<<"$out19a" \
  && ok "19a the refusal says the BOX already has a scheduler" \
  || bad "19a the refusal does not name the condition: $out19a"
grep -q "pid $pidA" <<<"$out19a" \
  && ok "19a the refusal NAMES the holding pid ($pidA)" \
  || bad "19a the refusal does not name the holding pid: $out19a"
grep -q '\$STATE=' <<<"$out19a" \
  && ok "19a the refusal names the state dir that holds it" \
  || bad "19a the refusal does not say where the holder keeps its state: $out19a"
[ ! -f "$T/s19b/loop.pid" ] \
  && ok "19a the refused loop left NO loop.pid — it ran no pass of its own" \
  || bad "19a the refused loop wrote a pidfile: $(cat "$T/s19b/loop.pid" 2>/dev/null)"
[ ! -f "$T/s19b/tick" ] \
  && ok "19a the refused loop left NO tick" || bad "19a the refused loop ticked"
kill -0 "$pidA" 2>/dev/null \
  && ok "19a the HOLDER survived the refused start" || bad "19a the refused start killed the holder"

# 19b — `--start` from the second home must say "already running", not "did not come up". That false
# FAIL is what would brick a two-home cell's bring-up (#3029).
out19b="$(s19 "$T/s19b" "$GOOD" --start)"; rc19b=$?
[ "$rc19b" -eq 0 ] \
  && ok "19b --start from the second home exits 0 (no false 'did not come up')" \
  || bad "19b --start from a second home failed (rc=$rc19b): $out19b"
grep -q 'loop already running' <<<"$out19b" \
  && ok "19b --start reports the existing box scheduler instead of failing" \
  || bad "19b --start did not report the existing scheduler: $out19b"
# ⛔ AND IT MUST NOT THEN CLAIM IT STARTED ONE. "loop started (pid N)" over a loop this verb did not
# create is a false report to the operator — and it reported the OTHER home's pid.
grep -q 'loop started' <<<"$out19b" \
  && bad "19b --start claimed 'loop started' when it started nothing: $out19b" \
  || ok "19b --start does not claim to have started a loop it did not start"
[ ! -f "$T/s19b/loop.pid" ] \
  && ok "19b the second home started no loop of its own" \
  || bad "19b a second loop.pid exists for the second home"

# 19c — `--verify` from the second home must not report a DEAD scheduler, and must disclose who does
# hold the box. ⛔ THIS ARM CANNOT GRADE THE VERDICT-LINE CRASH, AND DOES NOT PRETEND TO: the second
# home has no job stamps, so `cmd_verify` appends its per-job NEVER-RUN failures and returns BEFORE
# the verdict line — which is exactly why a `grep 'FAIL:'` here is vacuous (the real failure format
# is `  FAIL   <label>: …`, three spaces and no colon after FAIL, so the pattern never matched even
# when the line WAS printed). The [VGATE] pass proved it: all three greps below pass against a
# pre-fix mutant that still has the `%d`/None crash. The crash is graded by 19c2, the verb bring-up
# actually runs, which reaches the verdict line because its inline pass writes the stamps first.
out19c="$(s19 "$T/s19b" "$GOOD" --verify)"
grep -q 'DIFFERENT state dir' <<<"$out19c" \
  && ok "19c --verify names that the box is scheduled under another state dir" \
  || bad "19c --verify does not disclose the foreign holder: $out19c"
grep -q 'NOT RUNNING' <<<"$out19c" \
  && bad "19c --verify reported a DEAD scheduler on a scheduled box (the false FAIL that bricks bring-up)" \
  || ok "19c --verify does not claim the box's scheduler is dead"
grep -q 'Traceback' <<<"$out19c" \
  && bad "19c the foreign-holder arm died with a traceback: $out19c" \
  || ok "19c the foreign-holder arm did not die with a traceback"
[ "$(s19 "$T/s19b" "$GOOD" --verify >/dev/null 2>&1; echo $?)" -eq 0 ] \
  && ok "19c --verify from a second home is rc 0 when the holder IS passing (it grades the holder)" \
  || bad "19c --verify from a second home refuses a box whose holder is passing"

# 19c2 — `--install` is the verb bring-up actually runs, and it reaches the verdict line through
# `return cmd_verify()`. On a two-home box it must finish cleanly, not die on a format specifier.
out19c2="$(s19 "$T/s19b" "$GOOD" --install)"; rc19c2=$?
# ⛔ THE VERDICT LINE MUST HAVE BEEN REACHED, or this arm inherits 19c's blindness. `--install`
# writes the stamps inline, so every job is fresh and the run reaches `SCHEDULE VERIFIED` — where
# the pre-fix `%d` on a None pid raised TypeError, which `main`'s net reported as
# `FAIL: --install: TypeError: %d format: …` and rc=1.
grep -q 'SCHEDULE VERIFIED' <<<"$out19c2" \
  && ok "19c2 --install from a second home reached the VERDICT LINE (so 19c2 grades it)" \
  || bad "19c2 never reached the verdict line, so 19c2 grades nothing about it: $out19c2"
grep -qE 'FAIL:|Traceback' <<<"$out19c2" \
  && bad "19c2 --install from a second home crashed or failed: $out19c2" \
  || ok "19c2 --install from a second home produces no FAIL line and no traceback"
[ "$rc19c2" -eq 0 ] \
  && ok "19c2 --install from a second home exits 0 (a two-home cell can still be brought up)" \
  || bad "19c2 --install from a second home exited $rc19c2: $out19c2"
kill "$pidA" 2>/dev/null; sleep 1
[ ! -f "$L19/loop.lock" ] && ok "19c the stopped holder released the box lock" \
                          || bad "19c the box lock outlived its holder"

# 19d — a stale lock (holder provably gone) is RECLAIMED, not deferred to for ever. This is the arm
# that stops the guard becoming #1985: a lock whose owner died must never disable the box.
/bin/true & deadpid=$!; wait "$deadpid" 2>/dev/null
lock19 "$L19" "$deadpid" "$(starttime19 $$)" "$T/s19-gone"
out19d="$(s19 "$T/s19d" "$GOOD" --start)"; rc19d=$?
pid19d="$(cat "$T/s19d/loop.pid" 2>/dev/null)"
[ -n "$pid19d" ] && kill -0 "$pid19d" 2>/dev/null \
  && ok "19d a STALE lock (dead holder pid $deadpid) is reclaimed and the loop starts" \
  || bad "19d a stale lock wedged the box (rc=$rc19d): $out19d"
kill "$pid19d" 2>/dev/null; sleep 1

# 19e — LIVENESS IS NOT IDENTITY (#1985), part 1: a RECYCLED pid. The pid is ALIVE **and carries the
# start time the lock records** (it is the pid of the process reading this line, re-used as a
# stand-in for "the pid now belongs to a different program"), so the START-TIME arm cannot save us —
# the COMMAND-LINE arm has to. A bare-pid guard defers to a stranger that never releases the lock.
lock19 "$L19" "$$" "$(starttime19 $$)" "$T/s19-recycled"
out19e="$(s19 "$T/s19e" "$GOOD" --start)"; rc19e=$?
pid19e="$(cat "$T/s19e/loop.pid" 2>/dev/null)"
[ -n "$pid19e" ] && kill -0 "$pid19e" 2>/dev/null \
  && ok "19e a RECYCLED pid (alive, matching start, not a loop) is not the holder — reclaimed" \
  || bad "19e a recycled pid blocked the box (rc=$rc19e): $out19e"
kill "$pid19e" 2>/dev/null; sleep 1

# 19e2 — part 2: the START-TIME arm itself. The lock records a pid that IS a live `fleet-schedule
# --loop` but with the start time of a DIFFERENT incarnation — exactly what a recycled pid looks like
# after a SIGKILL. The command-line arm says "alive", so only the start-time comparison can tell that
# this is not the holder. Without it the box is stopped by a stranger AND cannot repair the lock it
# defers to.
s19 "$T/s19e2" "$GOOD" --start >/dev/null 2>&1
pidE2="$(cat "$T/s19e2/loop.pid" 2>/dev/null)"
# ⛔ THE BASELINE IS PART OF THE ARM. Without it, a failed `--start` leaves `pidE2` empty, `lock19`
# dies on `int("")` AFTER the shell already truncated the lock, the second start then reclaims via
# the CORRUPT-record path (19f2's case) and the arm goes green while grading nothing about the
# start-time identity — the [VGATE] pass reproduced exactly that.
if [ -n "$pidE2" ] && kill -0 "$pidE2" 2>/dev/null; then
  ok "19e2 baseline: a live loop holds the box before the start-time probe (pid $pidE2)"
else
  bad "19e2 baseline loop never came up — the arm grades nothing (pidE2='$pidE2')"
fi
lock19 "$L19" "$pidE2" "1" "$T/s19-elsewhere"
out19e2="$(s19 "$T/s19e2b" "$GOOD" --start)"; rc19e2=$?
pid19e2="$(cat "$T/s19e2b/loop.pid" 2>/dev/null)"
if [ -n "$pid19e2" ] && kill -0 "$pid19e2" 2>/dev/null && [ "$pid19e2" != "$pidE2" ]; then
  ok "19e2 a live loop pid with the WRONG start time is not the holder — reclaimed (the start arm is load-bearing)"
else
  bad "19e2 the start-time arm did not reclaim a recycled identity (rc=$rc19e2): $out19e2"
fi
kill "$pidE2" 2>/dev/null; kill "$pid19e2" 2>/dev/null; sleep 1

# 19f — an EMPTY recorded start time is an ABSENT datum (a box with no readable /proc), so the
# command line alone decides. The live loop must still be recognised: the identity arm may not
# silently disable the guard. ⛔ THIS ARM CAUGHT A REAL FAIL-OPEN in the first cut: the record was
# whitespace-separated, so an empty `start` collapsed the fields, the state PATH was read as a start
# time, the comparison failed, and a second scheduler JOINED the live one.
s19 "$T/s19f" "$GOOD" --start >/dev/null 2>&1
pid19f="$(cat "$T/s19f/loop.pid" 2>/dev/null)"
lock19 "$L19" "$pid19f" "" "$T/s19f"          # start field deliberately EMPTY
out19f="$(s19loop "$T/s19f2")"
grep -q "pid $pid19f" <<<"$out19f" \
  && ok "19f an EMPTY recorded start time still refuses (the command line alone is enough)" \
  || bad "19f an empty start field disabled the guard: $out19f"
kill "$pid19f" 2>/dev/null; sleep 1

# 19f2 — the other side of the same boundary: a CORRUPT record must not wedge the box (#1985). An
# unreadable lock answers "no readable holder", which RECLAIMS.
printf 'not json at all\n' > "$L19/loop.lock"
out19f2="$(s19 "$T/s19f2b" "$GOOD" --start)"; rc19f2=$?
pid19f2="$(cat "$T/s19f2b/loop.pid" 2>/dev/null)"
[ -n "$pid19f2" ] && kill -0 "$pid19f2" 2>/dev/null \
  && ok "19f2 a CORRUPT box lock is reclaimed, not deferred to for ever" \
  || bad "19f2 a corrupt lock wedged the box (rc=$rc19f2): $out19f2"
kill "$pid19f2" 2>/dev/null; sleep 1

# 19m — a lock record whose pid is NOT AN INTEGER (`1e400` is valid JSON and parses to `inf`) must be
# RECLAIMED, not raised out of the recovery path. ⛔ `OverflowError` is not a `ValueError` — the trap
# `pid_alive` documents. Pre-fix, `--loop`, `--start`, `--install` and `--verify` all died with
# `OverflowError: cannot convert float infinity to integer`, leaving the cell with no scheduler and
# its own repair verb refusing. (`{"pid": NaN}` raised ValueError and was already caught — which is
# what made the gap invisible.)
printf '{"pid": 1e400, "start": "1", "state": "/elsewhere"}\n' > "$L19/loop.lock"
out19m="$(s19 "$T/s19m" "$GOOD" --start)"; rc19m=$?
pid19m="$(cat "$T/s19m/loop.pid" 2>/dev/null)"
[ -n "$pid19m" ] && kill -0 "$pid19m" 2>/dev/null \
  && ok "19m a non-finite pid in the lock is reclaimed, not raised (--start works)" \
  || bad "19m a non-finite pid wedged every verb (rc=$rc19m): $out19m"
grep -q 'OverflowError' <<<"$out19m" \
  && bad "19m OverflowError escaped the recovery path: $out19m" \
  || ok "19m no OverflowError reached the caller"
kill "$pid19m" 2>/dev/null; sleep 1

# 19n — NON-VACUITY for the RECLAIM ITSELF. The staleness decision is made BEFORE the rename, so a
# competitor that publishes its OWN live claim inside that window must not have it renamed away and
# deleted: pre-fix, both starters then conclude they hold the box (the #2890 defect re-created by the
# lock's own reclaim). Driven in-process so the window is deterministic — `os.rename` is wrapped to
# install the competitor's record immediately before the move, which is exactly the interleaving the
# [VGATE] pass reproduced with real kernel ops.
# ⛔ THE HERE-DOC LIVES IN A FUNCTION BODY, NOT IN A `$( )` (bash 3.2, #2930/#2248).
#    bash 3.2's `$( )` scanner does not know about here-documents: it walks the body as CODE,
#    so an APOSTROPHE in this body's prose opens a single-quoted string that never closes and
#    desynchronises the parse state for the REST OF THE FILE. Measured at f05c057d6 (#3615,
#    which introduced this arm): `bash -n` under bash 3.2.57 reports "syntax error near
#    unexpected token `('" at the `ok` message in the 19u arm, ~230 lines BELOW this body, so
#    `check-bash32-parse.sh` (#2930) REDS on every PR. On a stock Mac `/bin/bash` IS 3.2, so while
#    this defect was live the suite never COMPLETED there: bash 3.2 executes command-by-command, so
#    every arm above 19n ran and then the desync aborted the run at the reported line with exit 2 —
#    it produced no verdict rather than refusing to start. The gate redded every PR either way.
#    ⚠️ WHAT IT WAS NOT, measured rather than assumed: a refused install. `install.sh`'s `*.test.sh`
#    case arm (731-739) deliberately WARNs on a test suite's parse error and CONTINUES — `die` is
#    reserved for runtime scripts, which crash-loop under KeepAlive — and that carve-out landed in
#    914d06574 (#2930) BEFORE this defect existed. Both harms are cleared at this commit.
#    bash 5 parses it fine, which is why this suite stayed green and only the gate went red.
#    #2248's remedy: the substitution carries a FUNCTION CALL and no here-doc. RESIDUAL, NOT FIXED
#    HERE: 22 other here-docs in this file still sit inside a `$( )` and are each one prose apostrophe
#    away from the same file-wide failure. This defect's own issue is #3625; the guard that catches
#    the next one is `check-bash32-parse.sh`, which reds the whole file (not the site).
_out19n_probe() { python3 - "$1" "$2" "$3" "$4" <<'PY19N' 2>&1
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("fsched", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
root, live = sys.argv[3], int(sys.argv[4])
os.makedirs(root, exist_ok=True)
m.STATE, m.LOOP_LOCK = sys.argv[2], os.path.join(root, "loop.lock")
# Two stubs, so the interleaving is the only thing under test: every pid reads as alive, and only the
# COMPETITOR reads as a scheduler loop. Its recorded start time is the REAL one, so the identity
# check recognises it — otherwise the test would be grading the start arm, not this one.
# ⛔ NO QUOTE OR BACKTICK CHARACTERS IN THIS BODY (agent-infra#3625). The bash 3.2 scanner does not
# know about here-documents inside a command substitution: it walks the body as code, so one odd
# single-quote opens a state that never closes and the WHOLE FILE fails `bash -n`, reported far
# below the defect. Reworded, not escaped — and the count is kept even to zero, so there is no
# state for the scanner to open. Verify with `bash scripts/check-bash32-parse.sh` after any edit
# in here.
m.pid_alive = lambda p: True
m.pid_is_our_loop = lambda p: p == live
competitor_start = m.proc_start_time(live)
# A STALE record is what we judge and decide to reclaim.
with open(m.LOOP_LOCK, "w") as fh:
    fh.write(json.dumps({"pid": 999999, "start": "1", "state": "/stale"}))
real_rename = os.rename
def racy_rename(src_path, dst_path):
    # The competitor publishes its LIVE claim the instant before we move the name aside.
    with open(m.LOOP_LOCK, "w") as fh:
        fh.write(json.dumps({"pid": live, "start": competitor_start, "state": "/competitor"}))
    return real_rename(src_path, dst_path)
os.rename = racy_rename
try:
    got = m.claim_loop_lock()
finally:
    os.rename = real_rename
try:
    survivor = json.load(open(m.LOOP_LOCK))
except Exception:
    survivor = None
print("CLAIM %r" % (got,))
print("SURVIVOR %r" % (survivor,))
PY19N
}
out19n="$(_out19n_probe "$SCHED" "$T/s19n" "$L19/n" "$$")"
grep -q "CLAIM None" <<<"$out19n" \
  && bad "19n the reclaim STOLE a live claim published inside its own window (claim returned None = 'I hold the box')" \
  || ok "19n the reclaim did not steal a live claim published inside its window"
grep -q "'state': '/competitor'" <<<"$out19n" \
  && ok "19n the competitor's claim SURVIVED the lost reclaim" \
  || bad "19n the competitor's live claim was destroyed by the reclaim: $out19n"

# 19o — a lock root that refuses `link(2)` (FUSE, some tmpfs) must still be claimable: the guard
# falls back to the atomic create rather than degrading to a permit. Ungraded until the [VGATE] pass
# pointed out that a mutant deleting the fallback stayed green.
out19o="$(python3 - "$SCHED" "$T/s19o" "$L19/o" <<'PY19O' 2>&1
import errno, importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fsched", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
os.makedirs(sys.argv[3], exist_ok=True)
m.STATE, m.LOOP_LOCK = sys.argv[2], os.path.join(sys.argv[3], "loop.lock")
os.makedirs(m.STATE, exist_ok=True)
real_link = os.link
def no_link(a, b, *rest, **kw):
    raise OSError(errno.EOPNOTSUPP, "Operation not supported")
os.link = no_link
try:
    got = m.claim_loop_lock()
finally:
    os.link = real_link
rec = m.read_loop_lock()
print("CLAIM %r" % (got,))
print("RECORD %r" % (rec,))
PY19O
)"
grep -q "CLAIM None" <<<"$out19o" \
  && ok "19o a link-refusing lock root is still CLAIMED (atomic-create fallback)" \
  || bad "19o a link-refusing root was not claimed — the guard silently permitted: $out19o"
grep -q "GUARD OFF" <<<"$out19o" \
  && bad "19o the fallback took the permit path (disclosed) instead of claiming: $out19o" \
  || ok "19o the fallback did NOT fall through to a silent permit"

# 19y — ⛔ THE FALLBACK MUST NOT CLAIM A NAME IT NO LONGER OWNS, AND MUST NOT PERMIT EITHER.
# `O_EXCL` makes the CREATE atomic, not the write that follows: a contender that reclaims inside it
# renames our empty claim away and publishes its own, so writing lands in an inode nobody can see.
# Two ways to get this wrong, and the first cut had both — believing the create (two loops), or
# permitting (one loop beside a live holder). The fallback must therefore re-examine, and a LIVE
# holder must come back to the caller as a refusal. Driven in-process, with `link` refusing and
# `write` letting a real, live loop take the name mid-publish.
s19y_state="$T/s19ybox"
env TEMPLATES_DIR="$GOOD" FLEET_SCHEDULE_STATE="$s19y_state" FLEET_SCHEDULE_LOCK_ROOT="$L19/y" \
    python3 "$SCHED" --start >/dev/null 2>&1
pidY="$(cat "$s19y_state/loop.pid" 2>/dev/null)"
if [ -n "$pidY" ] && kill -0 "$pidY" 2>/dev/null; then
  ok "19y baseline: a live loop holds the box lock under $L19/y (pid $pidY)"
  rec19y="$(python3 -c 'import json,sys;print(json.dumps({"pid":int(sys.argv[1]),"start":sys.argv[2],"state":sys.argv[3]}))' \
      "$pidY" "$(starttime19 "$pidY")" "$s19y_state")"
  out19y="$(python3 - "$SCHED" "$T/s19y" "$L19/y" "$rec19y" <<'PY19Y' 2>&1
import errno, importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fsched", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.STATE, m.LOOP_LOCK = sys.argv[2], os.path.join(sys.argv[3], "loop.lock")
os.makedirs(m.STATE, exist_ok=True)
takeover = sys.argv[4].encode()
real_link, real_write = os.link, os.write
def no_link(a, b, *rest, **kw):
    raise OSError(errno.EOPNOTSUPP, "Operation not supported")
def takeover_write(fd, data):
    os.unlink(m.LOOP_LOCK)
    with open(m.LOOP_LOCK, "wb") as fh:
        fh.write(takeover)
    return real_write(fd, data)
os.link, os.write = no_link, takeover_write
try:
    got = m.claim_loop_lock()
finally:
    os.link, os.write = real_link, real_write
print("CLAIM %r" % (got,))
PY19Y
)"
  grep -q 'CLAIM None' <<<"$out19y" \
    && bad "19y the fallback claimed a lock whose name a live holder took during its write — TWO scheduler loops on one box: $out19y" \
    || ok "19y the fallback does NOT claim a lock a live holder took during its write"
  grep -q "CLAIM ($pidY," <<<"$out19y" \
    && ok "19y it reports the LIVE holder to the caller, so the pass is refused (pid $pidY)" \
    || bad "19y the fallback did not surface the live holder: $out19y"
  grep -q 'GUARD OFF' <<<"$out19y" \
    && bad "19y the fallback PERMITTED the pass beside a live holder: $out19y" \
    || ok "19y it did not fall through to a disclosed permit beside a live holder"
else
  bad "19y baseline loop never came up — the arm grades nothing"
fi
kill "$pidY" 2>/dev/null; sleep 1

# 19p — NON-VACUITY for the reclaim's DISCLOSURE. When a third claim takes the name before the
# restore, the displaced claim's record must be PRESERVED and the outcome ANNOUNCED: deleting it is
# how two loops run with nothing in any log. Driven in-process, with `os.link` stubbed to fail only
# for the RESTORE so the third-party takeover is deterministic.
out19p="$(python3 - "$SCHED" "$T/s19p" "$L19/p" "$$" <<'PY19P' 2>&1
import errno, importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("fsched", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
root, live = sys.argv[3], int(sys.argv[4])
os.makedirs(root, exist_ok=True)
m.STATE, m.LOOP_LOCK = sys.argv[2], os.path.join(root, "loop.lock")
m.pid_alive = lambda p: True
m.pid_is_our_loop = lambda p: p == live
start = m.proc_start_time(live)
with open(m.LOOP_LOCK, "w") as fh:
    fh.write(json.dumps({"pid": 999999, "start": "1", "state": "/stale"}))
real_rename, real_link = os.rename, os.link
def racy_rename(a, b):
    with open(m.LOOP_LOCK, "w") as fh:      # the competitor's LIVE claim lands just before the move
        fh.write(json.dumps({"pid": live, "start": start, "state": "/competitor"}))
    return real_rename(a, b)
def blocked_link(a, b, *r, **k):
    # A THIRD party takes the freed name — but ONLY for the RESTORE. The initial claim's own
    # `link(staged, LOOP_LOCK)` must reach the real kernel (it fails EEXIST legitimately, because the
    # stale record is still there), so the stub fails only when the SOURCE is a `.reclaim.` duplicate.
    if ".reclaim." in str(a):
        raise OSError(errno.EEXIST, "File exists")
    return real_link(a, b, *r, **k)
os.rename, os.link = racy_rename, blocked_link
try:
    got = m.claim_loop_lock()
finally:
    os.rename, os.link = real_rename, real_link
kept = [f for f in os.listdir(root) if ".reclaim." in f]
print("CLAIM %r" % (got,))
print("KEPT %r" % (sorted(kept),))
print("KEPT_RECORD %r" % (json.load(open(os.path.join(root, kept[0]))) if kept else None,))
PY19P
)"
grep -q "'state': '/competitor'" <<<"$out19p" \
  && ok "19p the DISPLACED live claim is PRESERVED on disk, not deleted" \
  || bad "19p the restore failure destroyed the displaced claim's record: $out19p"
grep -q 'GUARD OFF' <<<"$out19p" \
  && ok "19p the lost restore is DISCLOSED (never a silent second loop)" \
  || bad "19p the lost restore was silent: $out19p"

# 19q — `--start` must still revive THIS state dir's OWN loop. The box-holder pre-check may only
# short-circuit for a holder in ANOTHER state dir: an own-state holder whose pidfile went missing (a
# state this file documents) used to fall into the "this state dir starts none" arm, leaving the
# operator's OFF switch in place — the loop then exited and the box had no scheduler, while the
# revival verb answered 0. Found by the [VGATE] pass; this path had no arm at all.
s19 "$T/s19q" "$GOOD" --start >/dev/null 2>&1
pidQ="$(cat "$T/s19q/loop.pid" 2>/dev/null)"
if [ -n "$pidQ" ] && kill -0 "$pidQ" 2>/dev/null; then
  ok "19q baseline: this state dir's own loop holds the box (pid $pidQ)"
else
  bad "19q baseline loop never came up — the arm grades nothing"
fi
rm -f "$T/s19q/loop.pid"                     # the documented "loop still runs, no pidfile" state
: > "$T/s19q/OFF"                            # a deliberate stop the operator is now resuming
out19q="$(s19 "$T/s19q" "$GOOD" --start)"; rc19q=$?
[ "$rc19q" -eq 0 ] && ok "19q --start over an own-state holder exits 0" \
                   || bad "19q --start exited $rc19q: $out19q"
[ ! -f "$T/s19q/OFF" ] \
  && ok "19q --start CLEARED the OFF switch for its own loop (the box stays scheduled)" \
  || bad "19q --start left OFF in place over its own loop — the box dies at the next check: $out19q"
grep -q 'starts none' <<<"$out19q" \
  && bad "19q --start claimed 'this state dir starts none' about its OWN holder: $out19q" \
  || ok "19q --start does not deny starting its own state dir's loop"
kill "$pidQ" 2>/dev/null; sleep 1

# 19r — `--install` is the verb bring-up runs, and its INLINE first pass is the box-level job set. On
# a two-home box it must not run those jobs beside the holder's loop: that is the double-execution
# this change exists to make impossible, and `--install` used to reach its pass before any box check
# (measured by the [VGATE] pass: one job, two runs, one box).
mkdir -p "$T/tpl19r"
MARK19R="$T/out/s19r-marker.log"; : > "$MARK19R"
python3 - "$T/tpl19r" "$MARK19R" <<'PY19R'
import plistlib, os, sys
tpl, mark = sys.argv[1], sys.argv[2]
open(os.path.join(tpl, "RETIRED"), "w").write("# none\n")
d = {"Label": "com.test.dup19r",
     "ProgramArguments": ["/bin/sh", "-c", "echo run >> %s" % mark],
     "StartInterval": 3600}
with open(os.path.join(tpl, "com.test.dup19r.plist"), "wb") as fh:
    plistlib.dump(d, fh)
PY19R
# ONE job set for BOTH homes — the real shape. Home A installs first, so its inline pass stamps the
# job and its loop holds the box; that stamp is what makes the second home's verdict meaningful.
s19 "$T/s19rA" "$T/tpl19r" --install >/dev/null 2>&1
pidR="$(cat "$T/s19rA/loop.pid" 2>/dev/null)"
[ -n "$pidR" ] && kill -0 "$pidR" 2>/dev/null \
  && ok "19r baseline: a loop holds the box for state dir A (pid $pidR)" \
  || bad "19r baseline loop never came up"
n19r_before="$(wc -l < "$MARK19R" 2>/dev/null || echo 0)"
[ "$n19r_before" -ge 1 ] \
  && ok "19r baseline: the job has run $n19r_before time(s), so a second run would be visible" \
  || bad "19r baseline: the job never ran even on the first install — the arm grades nothing"
out19r="$(s19 "$T/s19rB" "$T/tpl19r" --install)"; rc19r=$?
n19r_after="$(wc -l < "$MARK19R" 2>/dev/null || echo 0)"
[ "$n19r_after" -eq "$n19r_before" ] \
  && ok "19r --install on a two-home box ran NO box-level job ($n19r_after, unchanged)" \
  || bad "19r --install ran the job BESIDE the live loop ($n19r_before -> $n19r_after): $out19r"
grep -q 'inline first pass is SKIPPED' <<<"$out19r" \
  && ok "19r --install SAYS the inline pass was skipped, and why" \
  || bad "19r --install skipped nothing and did not say so: $out19r"
grep -q 'SCHEDULE VERIFIED' <<<"$out19r" \
  && ok "19r --install still reaches a verdict line (bring-up greps for it, so it must exist)" \
  || bad "19r --install printed no verdict line, so cloud-cell-bringup.sh would die: $out19r"
[ "$rc19r" -eq 0 ] \
  && ok "19r --install on a two-home box exits 0 (the box IS scheduled, by the holder)" \
  || bad "19r --install exited $rc19r on a two-home box: $out19r"
# ⛔ THE POSITIVE CONTROL, without which the "ran NO job" assertion grades nothing: with the holder
# gone, the SAME plist in the SAME state dir MUST run. That proves the fixture job is runnable and
# that the skip above was the guard's doing, not an inert declaration.
kill "$pidR" 2>/dev/null; sleep 1
out19r2="$(s19 "$T/s19rB" "$T/tpl19r" --install)"; rc19r2=$?
n19r_control="$(wc -l < "$MARK19R" 2>/dev/null || echo 0)"
[ "$n19r_control" -gt "$n19r_after" ] \
  && ok "19r CONTROL: with no holder, the same --install DOES run the job ($n19r_after -> $n19r_control) — the skip discriminates" \
  || bad "19r CONTROL: the plist never runs even without a holder, so the skip assertion grades nothing: $out19r2"
s19 "$T/s19rB" "$T/tpl19r" --stop >/dev/null 2>&1
sleep 1

# 19s — ⛔ THE WEDGED HOLDER, which is the arm that decides whether the two-home relaxation is a
# false PASS. `--verify` from a second home must grade the HOLDER's tick: the previous cut SKIPPED the
# staleness arm entirely and certified a holder whose tick was 3 hours old, which bring-up turns into
# CELL READY on a cell with no reaping and no liveness detection (#1864, reproduced by [VGATE]).
s19 "$T/s19s" "$GOOD" --start >/dev/null 2>&1
pidS="$(cat "$T/s19s/loop.pid" 2>/dev/null)"
if [ -n "$pidS" ] && kill -0 "$pidS" 2>/dev/null; then
  ok "19s baseline: a loop holds the box for state dir S (pid $pidS)"
else
  bad "19s baseline loop never came up — the arm grades nothing"
fi
kill -STOP "$pidS" 2>/dev/null        # frozen: alive, and no longer passing
touch -d '-1 hour' "$T/s19s/tick" 2>/dev/null || touch -t 197001010000 "$T/s19s/tick"
out19s="$(s19 "$T/s19w" "$GOOD" --verify)"; rc19s=$?
[ "$rc19s" -ne 0 ] \
  && ok "19s --verify REFUSES a box whose foreign holder is wedged (rc=$rc19s)" \
  || bad "19s --verify CERTIFIED a wedged foreign holder — a false PASS on a dead box: $out19s"
grep -q 'tick is' <<<"$out19s" \
  && ok "19s the refusal names the holder's STALE TICK" \
  || bad "19s the refusal does not name the stale tick: $out19s"
kill -CONT "$pidS" 2>/dev/null; kill "$pidS" 2>/dev/null; sleep 1

# 19t — a STALE `loop.pid` in the second home (a recycled pid) must not brick a correctly-scheduled
# box: the foreign arm used to be gated on `not pid`, so one stale byte made bring-up `die` (#3029).
s19 "$T/s19tA" "$GOOD" --start >/dev/null 2>&1
pidT="$(cat "$T/s19tA/loop.pid" 2>/dev/null)"
sleep 30 & recycT=$!; echo "$recycT" >> "$T/pids"
mkdir -p "$T/s19tB"
printf '%s\n' "$recycT" > "$T/s19tB/loop.pid"   # the stale, recycled pid in the SECOND home
out19t="$(s19 "$T/s19tB" "$GOOD" --install)"; rc19t=$?
grep -q 'is not fleet-schedule' <<<"$out19t" \
  && bad "19t a stale pidfile in the second home refused a correctly-scheduled box: $out19t" \
  || ok "19t a stale loop.pid in the second home does NOT refuse the box"
[ "$rc19t" -eq 0 ] \
  && ok "19t --install from a home with a stale pidfile exits 0 (bring-up is not bricked)" \
  || bad "19t --install exited $rc19t over a stale pidfile: $out19t"
kill "$pidT" 2>/dev/null; kill "$recycT" 2>/dev/null

# 19u — the same stale-pid rule INSIDE the graded dir: a recycled pid in the HOLDER's own loop.pid
# must not refuse a box whose loop is verifiably alive behind the box lock. `cmd_loop` documents this
# state (a failed pidfile write leaves the previous file intact), and `loop_pid()` answers "alive",
# not "is the loop".
s19 "$T/s19u" "$GOOD" --start >/dev/null 2>&1
pidU="$(cat "$T/s19u/loop.pid" 2>/dev/null)"
sleep 30 & recycU=$!; echo "$recycU" >> "$T/pids"
printf '%s\n' "$recycU" > "$T/s19u/loop.pid"    # a recycled pid in the HOLDER's own dir
out19u="$(s19 "$T/s19u" "$GOOD" --verify)"; rc19u=$?
grep -q 'is not fleet-schedule' <<<"$out19u" \
  && bad "19u a recycled pid in the holder's own loop.pid refused a passing box: $out19u" \
  || ok "19u a recycled pid in the holder's own loop.pid does NOT refuse the box"
[ "$rc19u" -eq 0 ] \
  && ok "19u --verify passes: the identity-verified box lock outranks the pidfile" \
  || bad "19u --verify exited $rc19u over a stale pidfile and a live loop: $out19u"
# ⛔ NOT A BLANKET RESCUE: with NO live loop the stale pid must still be refused (case 4b's rule,
# restated here so this arm cannot be satisfied by weakening the refusal).
# ⛔ THE PIDFILE IS RESTORED BEFORE `--stop` ON PURPOSE. `cmd_stop` reads its target from `loop.pid`,
# so stopping while the file holds the recycled pid TERMs an unrelated process, leaves the real loop
# running, and leaks a BOX-lock holder into every later arm (measured: it turned 19h red). The stop
# verb's reliance on `loop.pid` is the pre-existing subject of its own follow-up, not this arm's point.
printf '%s\n' "$pidU" > "$T/s19u/loop.pid"
s19 "$T/s19u" "$GOOD" --stop >/dev/null 2>&1
sleep 1
kill -0 "$pidU" 2>/dev/null && kill -9 "$pidU" 2>/dev/null
sleep 30 & recycU2=$!; echo "$recycU2" >> "$T/pids"
printf '%s\n' "$recycU2" > "$T/s19u/loop.pid"   # recycled pid, and NO loop behind it
out19u2="$(s19 "$T/s19u" "$GOOD" --verify)"; rc19u2=$?
[ "$rc19u2" -ne 0 ] && grep -q 'NOT RUNNING\|is not fleet-schedule' <<<"$out19u2" \
  && ok "19u a stale pid with NO live loop is still REFUSED (the rescue is not a blanket pass)" \
  || bad "19u a dead scheduler behind a stale pid was certified (rc=$rc19u2): $out19u2"
kill "$recycU" "$recycU2" 2>/dev/null
# belt and braces: this arm must not leave a box-lock holder for the arms that follow
kill "$pidU" 2>/dev/null; sleep 1

# 19v — ⛔ A RELATIVE `FLEET_SCHEDULE_LOCK_ROOT` MUST NOT BE TWO LOCKS. The root is the mutex's NAME,
# and a name resolved against the caller's cwd here but against `cwd="/"` in the loop child is two
# names — the parent creates `$PWD/relock`, the child cannot create `/relock` and degrades to
# `$STATE/loop.lock`, so both homes believe they hold the box and #2890 is reproduced with the guard
# reporting success (measured by the reviewer: two live loops, no lock file on the parent's path).
# The arm pins a RELATIVE root from a scratch cwd and asserts the second home is still refused.
mkdir -p "$T/relcwd" "$T/s19vA" "$T/s19vB"
out19v_1="$(cd "$T/relcwd" && env TEMPLATES_DIR="$GOOD" FLEET_SCHEDULE_STATE="$T/s19vA" \
  FLEET_SCHEDULE_LOCK_ROOT=relock19v python3 "$SCHED" --start 2>&1)"
pidV="$(cat "$T/s19vA/loop.pid" 2>/dev/null)"
[ -n "$pidV" ] && kill -0 "$pidV" 2>/dev/null \
  && ok "19v baseline: a loop holds the box under a RELATIVE lock root (pid $pidV)" \
  || bad "19v baseline loop never came up under a relative root: $out19v_1"
[ -f "$T/relcwd/relock19v/loop.lock" ] \
  && ok "19v the relative root resolved to the CALLER's cwd (dir created where the parent can see it)" \
  || bad "19v no lock file under the caller's cwd — the root was not made absolute"
out19v_2="$(cd "$T/relcwd" && env TEMPLATES_DIR="$GOOD" FLEET_SCHEDULE_STATE="$T/s19vB" \
  FLEET_SCHEDULE_LOCK_ROOT=relock19v python3 "$SCHED" --start 2>&1)"; rc19v=$?
[ "$rc19v" -eq 0 ] \
  && ok "19v --start in a second home under a relative root still exits 0" \
  || bad "19v --start exited $rc19v: $out19v_2"
grep -q 'one loop per box, so this state dir starts none' <<<"$out19v_2" \
  && ok "19v ⛔ the second home is REFUSED under a relative root — one name is one mutex (#2890)" \
  || bad "19v a relative lock root let a second loop start on the same box: $out19v_2"
[ ! -f "$T/s19vB/loop.pid" ] \
  && ok "19v the refused home left no pidfile of its own" \
  || bad "19v the refused home wrote a pidfile — it ran a loop"
kill "$pidV" 2>/dev/null; sleep 1

# 19w — `--start` is the revival verb, so the OFF switch it finds must be CLEARED even when the loop
# is already alive. An OFF set while the loop ran outlived the verb: the loop exited at its next
# check, the box went dark, and `--start` had answered 0 having changed nothing (#1864's shape).
s19 "$T/s19w" "$GOOD" --start >/dev/null 2>&1
pidW="$(cat "$T/s19w/loop.pid" 2>/dev/null)"
if [ -n "$pidW" ] && kill -0 "$pidW" 2>/dev/null; then
  ok "19w baseline: a live loop is running for state dir W (pid $pidW)"
else
  bad "19w baseline loop never came up — the arm grades nothing"
fi
: > "$T/s19w/OFF"
out19w="$(s19 "$T/s19w" "$GOOD" --start)"; rc19w=$?
[ "$rc19w" -eq 0 ] \
  && ok "19w --start over a live own-state loop exits 0" \
  || bad "19w --start exited $rc19w: $out19w"
[ ! -e "$T/s19w/OFF" ] \
  && ok "19w ⛔ --start CLEARED the OFF switch even though the loop was already alive (the box stays scheduled)" \
  || bad "19w the OFF switch outlived --start — the loop exits at its next check and the box goes dark"
grep -q 'OFF switch cleared' <<<"$out19w" \
  && ok "19w --start SAID it cleared the switch (never a silent change)" \
  || bad "19w --start cleared the switch silently: $out19w"
s19 "$T/s19w" "$GOOD" --stop >/dev/null 2>&1; sleep 1

# 19x — a TWO-HOME box whose homes declare DIFFERENT job sets. Two things must hold at once:
#   (1) the verdict grades the HOLDER's declarations, so a job only the caller declares is not
#       reported as `NEVER RUN` against the holder's stamps (the misleading false FAIL), and
#   (2) that job is still a FAILURE, because bring-up certifies a cell on rc=0 + `SCHEDULE VERIFIED`
#       and dies only on a `^ *FAIL` line — a NOTE would print CELL READY for a job no loop on the
#       box runs, i.e. trade a false FAIL for a false PASS. The holder is started with `--start`
#       (not `--install`) on purpose: `--start` must also record its declaration set, or the holder's
#       set is unknown and the caller's set is graded again.
mkdir -p "$T/tpl19xA" "$T/tpl19xB"
cp "$GOOD"/*.plist "$T/tpl19xA/" 2>/dev/null
cp "$GOOD"/*.plist "$T/tpl19xB/" 2>/dev/null
printf '# none\n' > "$T/tpl19xA/RETIRED"; printf '# none\n' > "$T/tpl19xB/RETIRED"
python3 - "$T/tpl19xB" <<'PY19X'
import plistlib, os, sys
d = {"Label": "com.test.extra19x", "ProgramArguments": ["/bin/true"], "StartInterval": 3600}
with open(os.path.join(sys.argv[1], "com.test.extra19x.plist"), "wb") as fh:
    plistlib.dump(d, fh)
PY19X
s19 "$T/s19xA" "$T/tpl19xA" --start >/dev/null 2>&1
pidX="$(cat "$T/s19xA/loop.pid" 2>/dev/null)"
[ -n "$pidX" ] && kill -0 "$pidX" 2>/dev/null \
  && ok "19x baseline: home A's loop holds the box (pid $pidX)" \
  || bad "19x baseline loop never came up"
[ -f "$T/s19xA/templates-dir" ] \
  && ok "19x --start recorded its declaration set (the pointer is how a later grade learns it)" \
  || bad "19x --start did not record templates-dir — a second home cannot know the holder's set"
out19x="$(s19 "$T/s19xB" "$T/tpl19xB" --install)"; rc19x=$?
grep -q 'NEVER RUN' <<<"$out19x" \
  && bad "19x a job only the SECOND home declares was graded NEVER RUN against the holder's stamps: $out19x" \
  || ok "19x the caller's extra declaration is not graded against the holder's stamps"
grep -q 'run by NO loop on this box: com.test.extra19x' <<<"$out19x" \
  && ok "19x ⛔ the divergence is REPORTED — a declaration no loop on the box runs is not silent" \
  || bad "19x the divergence vanished without a word: $out19x"
grep -q '^  FAIL' <<<"$out19x" \
  && ok "19x it is a FAIL line, which is what bring-up's gate reads (a NOTE would certify CELL READY)" \
  || bad "19x the divergence was not a FAIL line, so bring-up would print CELL READY: $out19x"
[ "$rc19x" -ne 0 ] \
  && ok "19x --install exits non-zero on a genuine job-set divergence (rc=$rc19x)" \
  || bad "19x --install exited 0 over a job no loop on this box runs: $out19x"
# ⛔ THE POSITIVE CONTROL: with the SAME set on both homes there is no divergence and no FAIL — so
# the assertions above grade the difference, not a blanket failure.
out19x2="$(s19 "$T/s19xA" "$T/tpl19xA" --verify)"; rc19x2=$?
[ "$rc19x2" -eq 0 ] && ! grep -q '^  FAIL' <<<"$out19x2" \
  && ok "19x CONTROL: the holder's own home verifies clean over the same set (no blanket FAIL)" \
  || bad "19x CONTROL: the holder's own home failed over its own set (rc=$rc19x2): $out19x2"
kill "$pidX" 2>/dev/null; sleep 1

# 19z — ⛔ A STALE RECORD ON A LINK-REFUSING ROOT MUST BE RECLAIMED, not permitted for ever. The
# fallback re-checked the holder but never reclaimed, so a stale or corrupt record made EVERY
# claimant take the disclosed permit while the dead record sat unchanged — #2890 with the guard
# announcing its own absence on every pass (measured with two real processes by the [VGATE] pass).
for stale19z in '{"pid": 999999, "start": "", "state": "/nowhere"}' '{"pid": 1e400}'; do
  rm -rf "$L19/z"; mkdir -p "$L19/z"
  printf '%s' "$stale19z" > "$L19/z/loop.lock"
  out19z="$(python3 - "$SCHED" "$T/s19z" "$L19/z" <<'PY19Z' 2>&1
import errno, importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fsched", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.STATE, m.LOOP_LOCK = sys.argv[2], os.path.join(sys.argv[3], "loop.lock")
os.makedirs(m.STATE, exist_ok=True)
real_link = os.link
def no_link(a, b, *rest, **kw):
    raise OSError(errno.EOPNOTSUPP, "Operation not supported")
os.link = no_link
try:
    got = m.claim_loop_lock()
finally:
    os.link = real_link
print("CLAIM %r" % (got,))
print("MYPID %d" % os.getpid())
print("NOW %r" % (m.read_loop_lock(),))
PY19Z
)"
  grep -q 'GUARD OFF' <<<"$out19z" \
    && bad "19z a stale/corrupt record on a link-refusing root PERMITTED the pass ($stale19z): $out19z" \
    || ok "19z a stale record ($(echo "$stale19z" | cut -c1-28)…) is RECLAIMED on a link-refusing root"
  grep -q "CLAIM None" <<<"$out19z" \
    && ok "19z the reclaim CLAIMED the box afterwards" \
    || bad "19z the reclaim did not claim: $out19z"
  own19z="$(grep -o 'MYPID [0-9]*' <<<"$out19z" | awk '{print $2}')"
  recpid19z="$(sed -n "s/^NOW (\([0-9]*\),.*/\1/p" <<<"$out19z")"
  [ -n "$own19z" ] && [ "$recpid19z" = "$own19z" ] \
    && ok "19z the record at the path is now OURS (pid $own19z), not the stale one" \
    || bad "19z the stale record survived the reclaim (record pid=$recpid19z, ours=$own19z): $out19z"
done

# 19aa — ⛔ EVERY normalized path knob must reach the child resolved, not just the lock root. The
# child runs with cwd="/", so a RELATIVE `FLEET_SCHEDULE_STATE` was re-resolved there: measured
# `PermissionError: /relstate` surfacing as "the loop did not come up", and as root a loop running
# over a state dir the parent never reads — one that `--stop` cannot reach.
mkdir -p "$T/relcwd2"
out19aa="$(cd "$T/relcwd2" && env TEMPLATES_DIR="$GOOD" FLEET_SCHEDULE_STATE=relstate19aa \
  FLEET_SCHEDULE_LOCK_ROOT="$L19/aa" python3 "$SCHED" --start 2>&1)"; rc19aa=$?
[ "$rc19aa" -eq 0 ] \
  && ok "19aa --start with a RELATIVE state dir exits 0 (the child agrees with the parent)" \
  || bad "19aa --start exited $rc19aa with a relative state dir: $out19aa"
[ -f "$T/relcwd2/relstate19aa/loop.pid" ] \
  && ok "19aa the child wrote its pidfile into the SAME resolved dir the parent reads" \
  || bad "19aa the child wrote its state somewhere else: $out19aa"
pidAA="$(cat "$T/relcwd2/relstate19aa/loop.pid" 2>/dev/null)"
if [ -n "$pidAA" ] && kill -0 "$pidAA" 2>/dev/null; then
  out19aa2="$(cd "$T/relcwd2" && env TEMPLATES_DIR="$GOOD" FLEET_SCHEDULE_STATE=relstate19aa \
    FLEET_SCHEDULE_LOCK_ROOT="$L19/aa" python3 "$SCHED" --stop 2>&1)"
  sleep 1
  kill -0 "$pidAA" 2>/dev/null \
    && bad "19aa --stop could not stop the loop it started (a loop nothing can reach)" \
    || ok "19aa --stop STOPS the loop it started (one state dir, one spelling)"
else
  bad "19aa baseline loop never came up — the arm grades nothing"
  kill "$pidAA" 2>/dev/null
fi

# 19ab — ⛔ A PRE-EXISTING lock root keeps ITS mode. `makedirs(exist_ok=True)` cannot tell "just
# created" from "pre-existing", so the umask correction turned an operator's deliberate 0700 pin
# into 1777 on the first `--start` — after which any local uid can plant a `loop.lock` naming a live
# `fleet-schedule --loop` it runs, and every operator loop refuses while `--start` exits 0.
mkdir -p "$L19/ab"; chmod 0700 "$L19/ab"
env TEMPLATES_DIR="$GOOD" FLEET_SCHEDULE_STATE="$T/s19ab" FLEET_SCHEDULE_LOCK_ROOT="$L19/ab" \
    python3 "$SCHED" --start >/dev/null 2>&1
mode19ab="$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o7777))' "$L19/ab")"
[ "$mode19ab" = "0o700" ] \
  && ok "19ab a pre-existing private lock root keeps its 0700 mode (never widened)" \
  || bad "19ab the lock root was widened to $mode19ab — a foreign uid could plant the box's lock"
pidAB="$(cat "$T/s19ab/loop.pid" 2>/dev/null)"; kill "$pidAB" 2>/dev/null; sleep 1
# ⛔ AND A ROOT WE CREATE IS NOT WORLD-WRITABLE EITHER. `makedirs`'s mode is umask-filtered (0o1755
# under the usual 022), so this cut's `if created: chmod(root, 0o1777)` ADDED world-write that `main`
# never had — for no benefit: the `st_uid != getuid()` arm refuses a root another uid owns whatever
# its mode, so a world-writable root can never be SHARED across uids, only ATTACKED. World-write here
# is the bypass the arm above describes: any local uid can plant a `loop.lock` naming a live
# `fleet-schedule --loop` it runs, and every operator loop then refuses while `--start` exits 0.
rm -rf "$L19/ab2"
# ⛔ UNDER A PERMISSIVE UMASK ON PURPOSE. `makedirs`'s mode is umask-filtered and a umask can only
# CLEAR bits, so the requested mode is what decides the FLOOR: a requested 0o1777 measured 0o1777
# here under `umask 0` (services, containers and some CI images set exactly that), which is the
# plant-a-`loop.lock` bypass this arm exists to refuse. `umask 022` would make the arm pass on a
# world-writable request, i.e. the arm would be green wherever the operator's umask happened to be
# conservative and the defect would ship.
( umask 000
  env TEMPLATES_DIR="$GOOD" FLEET_SCHEDULE_STATE="$T/s19ab2" FLEET_SCHEDULE_LOCK_ROOT="$L19/ab2" \
      python3 "$SCHED" --start >/dev/null 2>&1 )
mode19ab2="$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o0002))' "$L19/ab2")"
[ "$mode19ab2" = "0o0" ] \
  && ok "19ab a lock root WE created is NOT world-writable even under umask 000 (requested mode is the floor)" \
  || bad "19ab a created lock root is world-writable ($mode19ab2) — any uid can plant the box's lock"
pidAB2="$(cat "$T/s19ab2/loop.pid" 2>/dev/null)"; kill "$pidAB2" 2>/dev/null; sleep 1

# 19ac — ⛔ A RELATIVE `TEMPLATES_DIR` MUST REACH THE CHILD RESOLVED TOO. The child runs `cwd="/"`,
# so a relative set left it reading `/tpl`: `--start` printed "loop started", the loop logged
# `template dir not found` every tick and ran ZERO jobs, while cloud-cell-supervisor.sh keys on the
# exit code and therefore reported a scheduled layer on a cell that runs nothing.
mkdir -p "$T/relcwd3/tpl19ac"          # relative to the CWD the verb below runs in
cp "$GOOD"/*.plist "$T/relcwd3/tpl19ac/" 2>/dev/null
printf '# none\n' > "$T/relcwd3/tpl19ac/RETIRED"
out19ac="$(cd "$T/relcwd3" && env TEMPLATES_DIR=tpl19ac FLEET_SCHEDULE_STATE="$T/s19ac" \
  FLEET_SCHEDULE_LOCK_ROOT="$L19/ac" python3 "$SCHED" --start 2>&1)"; rc19ac=$?
[ "$rc19ac" -eq 0 ] \
  && ok "19ac --start with a RELATIVE templates dir exits 0" \
  || bad "19ac --start exited $rc19ac: $out19ac"
grep -q 'template dir not found' "$T/s19ac/loop.log" 2>/dev/null \
  && bad "19ac the loop child could not find the declarations (it resolved them against /)" \
  || ok "19ac the child found the SAME declarations the parent resolved"
grep -qx "$T/relcwd3/tpl19ac" "$T/s19ac/templates-dir" 2>/dev/null \
  && ok "19ac the recorded pointer is the RESOLVED path (a later grade can trust it)" \
  || bad "19ac the pointer records a relative/unresolved path: $(cat "$T/s19ac/templates-dir" 2>/dev/null)"
pidAC="$(cat "$T/s19ac/loop.pid" 2>/dev/null)"; kill "$pidAC" 2>/dev/null; sleep 1

# 19ad — ⛔ `--start` MUST NOT REWRITE THE DECLARATION POINTER WHEN IT STARTS NOTHING. The pointer
# says "this is the set the box's loop runs"; on the documented "own-state loop alive, pidfile
# missing" state this verb falls through and starts nothing, so writing it from the caller's
# environment made the pointer lie — after which the home that verified clean returned
# `FAIL … NEVER RUN` for a job its loop had never heard of (the #3029 false FAIL, self-inflicted).
mkdir -p "$T/tpl19adA" "$T/tpl19adB"
cp "$GOOD"/*.plist "$T/tpl19adA/" 2>/dev/null; printf '# none\n' > "$T/tpl19adA/RETIRED"
cp "$GOOD"/*.plist "$T/tpl19adB/" 2>/dev/null; printf '# none\n' > "$T/tpl19adB/RETIRED"
s19 "$T/s19ad" "$T/tpl19adA" --start >/dev/null 2>&1
pidAD="$(cat "$T/s19ad/loop.pid" 2>/dev/null)"
pointer_before="$(cat "$T/s19ad/templates-dir" 2>/dev/null)"
rm -f "$T/s19ad/loop.pid"          # the documented state: own-state holder, pidfile missing
out19ad="$(s19 "$T/s19ad" "$T/tpl19adB" --start)"; rc19ad=$?
[ "$rc19ad" -eq 0 ] \
  && ok "19ad --start over an own-state holder with no pidfile exits 0" \
  || bad "19ad --start exited $rc19ad: $out19ad"
[ "$(cat "$T/s19ad/templates-dir" 2>/dev/null)" = "$pointer_before" ] \
  && ok "19ad ⛔ the declaration pointer still names the set the RUNNING loop reads" \
  || bad "19ad --start rewrote the pointer to a set nothing runs ($pointer_before -> $(cat "$T/s19ad/templates-dir" 2>/dev/null))"
kill "$pidAD" 2>/dev/null; sleep 1

# 19ae — ⛔ THE FALLBACK'S RECLAIM MUST NOT RESTORE BY `rename`. `rename` REPLACES the destination, so
# putting a displaced claim back would destroy a record a fourth party published in the meantime, and
# an `os.path.exists` guard only narrows that window (the same read-then-act the claim itself
# refuses). The ruling is the link path's: PRESERVE the displaced record, never delete it, and SAY SO.
# Driven deterministically: a LIVE claim takes the name between the staleness read and the rename, so
# the record we move is live — which is exactly the case the restore was supposed to handle.
s19 "$T/s19aeLive" "$GOOD" --start >/dev/null 2>&1
pidAE="$(cat "$T/s19aeLive/loop.pid" 2>/dev/null)"
if [ -n "$pidAE" ] && kill -0 "$pidAE" 2>/dev/null; then
  ok "19ae baseline: a real live loop exists to impersonate the fourth party (pid $pidAE)"
  recAE="$(python3 -c 'import json,sys;print(json.dumps({"pid":int(sys.argv[1]),"start":sys.argv[2],"state":"/fourth"}))' \
      "$pidAE" "$(starttime19 "$pidAE")")"
  rm -rf "$L19/ae"; mkdir -p "$L19/ae"
  printf '{"pid": 999999, "start": "", "state": "/nowhere"}' > "$L19/ae/loop.lock"
  out19ae="$(python3 - "$SCHED" "$T/s19ae" "$L19/ae" "$recAE" <<'PY19AE' 2>&1
import errno, importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fsched", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.STATE, m.LOOP_LOCK = sys.argv[2], os.path.join(sys.argv[3], "loop.lock")
os.makedirs(m.STATE, exist_ok=True)
live_rec = sys.argv[4]
real_link, real_rename, real_write = os.link, os.rename, os.write
def no_link(a, b, *rest, **kw):
    raise OSError(errno.EOPNOTSUPP, "Operation not supported")
def takeover_write(fd, data):
    # attempt 1: the content window of the create is lost to a third party that publishes a STALE
    # record. ⛔ KEEP THE APOSTROPHE COUNT IN THIS BODY EVEN (#3625): this here-doc lives inside a
    # `$( … )`, and the bash 3.2 scanner walks the body as code, so one odd single-quote opens a
    # state that never closes and the WHOLE FILE fails `bash -n`, far below the defect.
    os.unlink(m.LOOP_LOCK)
    with open(m.LOOP_LOCK, "w") as fh:
        fh.write('{"pid": 999999, "start": "", "state": "/third"}')
    return real_write(fd, data)
def racing_rename(src, dst, *rest, **kw):
    # attempt 2: between the staleness read and the reclaim, a LIVE claim takes the name
    if src == m.LOOP_LOCK:
        with open(m.LOOP_LOCK, "w") as fh:
            fh.write(live_rec)
    return real_rename(src, dst, *rest, **kw)
os.link, os.rename, os.write = no_link, racing_rename, takeover_write
try:
    got = m.claim_loop_lock()
finally:
    os.link, os.rename, os.write = real_link, real_rename, real_write
print("CLAIM %r" % (got,))
print("PRESERVED %r" % (sorted(f for f in os.listdir(sys.argv[3]) if ".reclaim." in f),))
PY19AE
)"
  grep -q 'turned out to be LIVE' <<<"$out19ae" \
    && ok "19ae the displaced LIVE claim is DISCLOSED (never a silent dual-run)" \
    || bad "19ae a displaced LIVE claim was moved aside with no word: $out19ae"
  grep -q 'PRESERVED \[\]' <<<"$out19ae" \
    && bad "19ae the displaced record was DELETED — the evidence is gone: $out19ae" \
    || ok "19ae the displaced record is PRESERVED on disk (not restored over, not deleted)"
  # ⛔ THE PASS MUST REFUSE, AND THIS ASSERTION IS THE ONE EARLIER CUTS OMITTED ON PURPOSE. The
  # omission reasoned "a path-based mutex cannot make this race disappear", which is true — and does
  # not license the opposite. `permit` + `continue` GUARANTEES the bad outcome: the `rename` freed
  # `LOOP_LOCK`, `link` still refuses (the arm's precondition), so the next attempt's `O_EXCL` create
  # SUCCEEDS, the inode check passes, and `claim_loop_lock` returns None = "I hold the box" — two
  # loops, AND the lock now names the NEWCOMER, so a later `--verify` sees one healthy holder with a
  # fresh tick and prints `SCHEDULE VERIFIED`. Returning the live holder is already what the sibling
  # `fallen_holder` arm does 40 lines above; the asymmetry was the defect.
  grep -q "CLAIM ($pidAE," <<<"$out19ae" \
    && ok "19ae ⛔ the pass REFUSES by returning the live holder (it does not claim the freed name)" \
    || bad "19ae the pass did not return the displaced live holder — it goes on to CLAIM the freed name and run beside it (two loops): $out19ae"
else
  bad "19ae baseline loop never came up — the arm grades nothing"
fi
kill "$pidAE" 2>/dev/null; sleep 1

# 19af — ⛔ `started` MUST BE TRUE FOR THE CHILD THIS VERB SPAWNED, even when its first tick lands
# after the poll gives up (a slow declaration read on a loaded cell). Returning False there made
# `--start` print "this state dir starts none" one line after starting one, and — because `--start`
# records the declaration set only when it started something — left the box with NO recorded set, so
# the supervisor's bare-env revival exits 3 and only warns. Driven in-process with `loop_pid` stubbed
# to None, which is exactly "the tick poll never succeeds" without a real 10 s wait per attempt.
s19af_state="$T/s19af"
out19af="$(python3 - "$SCHED" "$s19af_state" "$GOOD" "$L19/af" <<'PY19AF' 2>&1
import importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location("fsched", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.STATE, m.TEMPLATES_DIR = sys.argv[2], sys.argv[3]
m.LOOP_LOCK = os.path.join(sys.argv[4], "loop.lock")
m.LOOP_LOCK_ROOT = sys.argv[4]
os.environ["FLEET_SCHEDULE_LOCK_ROOT"] = sys.argv[4]
os.makedirs(sys.argv[4], exist_ok=True)
os.makedirs(m.STATE, exist_ok=True)
real_loop_pid = m.loop_pid
m.loop_pid = lambda: None          # the poll can never see a tick
try:
    pid, started = m.spawn_loop()
finally:
    m.loop_pid = real_loop_pid
print("SPAWN %r" % ((pid, started),))
print("ALIVE %s" % (pid and m.pid_is_our_loop(pid),))
PY19AF
)"
grep -q 'SPAWN ([0-9]*, True)' <<<"$out19af" \
  && ok "19af ⛔ a slow-first-tick spawn reports started=True (it IS the loop this verb created)" \
  || bad "19af spawn_loop reported started=False for its own child: $out19af"
grep -qx 'ALIVE True' <<<"$out19af" \
  && ok "19af the reported pid really is the loop it started" \
  || bad "19af the reported pid is not a live loop: $out19af"
spawned19af="$(grep -o 'SPAWN ([0-9]*' <<<"$out19af" | tr -dc '0-9')"
kill "$spawned19af" 2>/dev/null; sleep 1

# 19ag — ⛔ A POINTER-SOURCED RELATIVE TEMPLATES_DIR MUST BE RESOLVED TOO. The normalisation ran
# BEFORE the pointer fallback, so a pointer written by an earlier relative-env run (which
# remember_templates_dir re-writes verbatim, so it self-perpetuates) reached the `cwd="/"` child
# unresolved: `--start` printed "loop started", the child logged `template dir not found: /tpl` and
# ran ZERO jobs — the same false PASS one path over.
mkdir -p "$T/relcwd4/tpl19ag"
cp "$GOOD"/*.plist "$T/relcwd4/tpl19ag/" 2>/dev/null
printf '# none\n' > "$T/relcwd4/tpl19ag/RETIRED"
mkdir -p "$T/s19ag"
printf 'tpl19ag\n' > "$T/s19ag/templates-dir"       # a RELATIVE pointer
# ⛔ A COPY IN A SCRATCH DIR, DELIBERATELY: `resolve_infra_root()` walks up from the SCRIPT's own
# location, so running the checkout's copy always resolves the real farm's templates and the pointer
# is never consulted. Only a script with no checkout above it exercises the pointer fallback.
mkdir -p "$T/bin19ag"; cp "$SCHED" "$T/bin19ag/fleet-schedule.py"
out19ag="$(cd "$T/relcwd4" && env -u TEMPLATES_DIR -u INFRA_ROOT -u AGENT_INFRA_PATH \
  FLEET_SCHEDULE_STATE="$T/s19ag" FLEET_SCHEDULE_LOCK_ROOT="$L19/ag" \
  python3 "$T/bin19ag/fleet-schedule.py" --start 2>&1)"; rc19ag=$?
[ "$rc19ag" -eq 0 ] \
  && ok "19ag --start over a relative pointer exits 0" \
  || bad "19ag --start exited $rc19ag: $out19ag"
grep -q 'template dir not found' "$T/s19ag/loop.log" 2>/dev/null \
  && bad "19ag the child could not find the pointer's set (it resolved it against /)" \
  || ok "19ag the child read the SAME set the pointer named"
grep -qx "$T/relcwd4/tpl19ag" "$T/s19ag/templates-dir" 2>/dev/null \
  && ok "19ag the pointer is rewritten RESOLVED (the relative value does not self-perpetuate)" \
  || bad "19ag the pointer is still relative: $(cat "$T/s19ag/templates-dir" 2>/dev/null)"
pidAG="$(cat "$T/s19ag/loop.pid" 2>/dev/null)"; kill "$pidAG" 2>/dev/null; sleep 1

# 19ah — ⛔ WHEN THE PARENT DEGRADES, THE CHILD MUST DEGRADE TO THE SAME PATH. The handover matters
# ONLY when the parent's root comes from something the child does NOT simply inherit: `spawn_loop`
# POPS `FLEET_SCHEDULE_TMPFS_ROOT`, so a root derived from that knob is the one route where the child
# could resolve somewhere else. Earlier this arm pinned `FLEET_SCHEDULE_LOCK_ROOT`, which the child
# inherits verbatim through `os.environ.copy()` — so the arm was GREEN with the handover reverted, and
# the fix it claimed to pin was graded by nothing (found by the [VGATE] pass with a mutant).
mkdir -p "$T/notadir19ah"; : > "$T/notadir19ah/file"    # a FILE where the root's parent should be
# ⛔ AND `FLEET_SCHEDULE_LOCK_ROOT` IS UNSET HERE ON PURPOSE (this suite exports it for hermeticity):
# leaving it set would pre-empt the TMPFS-derived root and re-create the vacuity above.
out19ah_a="$(env -u FLEET_SCHEDULE_LOCK_ROOT TEMPLATES_DIR="$GOOD" FLEET_SCHEDULE_STATE="$T/s19ahA" \
  FLEET_SCHEDULE_TMPFS_ROOT="$T/notadir19ah/file" python3 "$SCHED" --start 2>&1)"; rc19ah_a=$?
grep -q 'box lock root .* is unusable' <<<"$out19ah_a" \
  && ok "19ah baseline: the parent DEGRADES on an unusable TMPFS-derived root (and says so)" \
  || bad "19ah baseline did not degrade as intended: $out19ah_a"
[ "$rc19ah_a" -eq 0 ] \
  && ok "19ah baseline --start exits 0 while degraded" \
  || bad "19ah baseline --start exited $rc19ah_a: $out19ah_a"
# ⛔ THE ASSERTION THAT ACTUALLY PINS THE HANDOVER: the CHILD must have claimed the path the PARENT
# tested. Reverting the handover sends the child to the DEFAULT /dev/shm root, so this file is absent
# (and on a box whose real scheduler holds /dev/shm, the child then refuses and `--start` reports a
# false "did not come up").
[ -f "$T/s19ahA/loop.lock" ] \
  && ok "19ah ⛔ the child claimed the SAME degraded path the parent tested (\$STATE/loop.lock)" \
  || bad "19ah the child resolved a DIFFERENT lock path than the parent — the handover did not arrive"
pidAH="$(cat "$T/s19ahA/loop.pid" 2>/dev/null)"
[ -n "$pidAH" ] && kill -0 "$pidAH" 2>/dev/null \
  && ok "19ah the degraded loop is running (pid $pidAH)" \
  || bad "19ah no degraded loop is running — the arm grades nothing"
out19ah_b="$(env -u FLEET_SCHEDULE_LOCK_ROOT TEMPLATES_DIR="$GOOD" FLEET_SCHEDULE_STATE="$T/s19ahB" \
  FLEET_SCHEDULE_TMPFS_ROOT="$T/notadir19ah/file" python3 "$SCHED" --start 2>&1)"; rc19ah_b=$?
grep -q 'did not come up' <<<"$out19ah_b" \
  && bad "19ah a second home under a degraded root reported 'did not come up' on a scheduled box: $out19ah_b" \
  || ok "19ah a second home under a degraded root does NOT report a false 'did not come up'"
[ "$rc19ah_b" -eq 0 ] \
  && ok "19ah the second home exits 0 under a degraded root" \
  || bad "19ah the second home exited $rc19ah_b: $out19ah_b"
# ⛔ BOTH HOMES' LOOPS ARE REAPED: a degraded box legitimately allows one loop per state dir (the
# documented dual-run residual), so B commonly starts one — leaving it running would leak a holder
# into every later arm.
for pidAH in "$T/s19ahA/loop.pid" "$T/s19ahB/loop.pid"; do
  p="$(cat "$pidAH" 2>/dev/null)"; [ -n "$p" ] && kill "$p" 2>/dev/null
done
sleep 1

# 19ai — ⛔ A RELATIVE `INFRA_ROOT` MUST REACH THE CHILD RESOLVED TOO. `INFRA_ROOT` is `abspath`-ed in
# `resolve_infra_root()` and rendered as `{{AGENT_INFRA_PATH}}` into five shipped templates
# (ai-drainer, ai-multi-repo, controller-watchdog, objective-reminder, worker-supply), but the child
# re-derived it from the RAW environment against `cwd="/"`. A relative value therefore rendered a
# DIFFERENT checkout in the loop than in the parent's inline pass; with none of the child's own
# fallbacks a checkout the placeholder rendered EMPTY, `render()` classified the job as a named SKIP,
# and the loop ran ZERO of those five jobs while `--install` printed `SCHEDULE VERIFIED` — the same
# false PASS as a relative `TEMPLATES_DIR` (19ac), one knob over (measured by the #3636 reviewer).
# ⛔ A COPY IN A SCRATCH DIR, DELIBERATELY (the same reason as 19ag/19ah): running the CHECKOUT's copy
# makes the child's `here`-based fallback resolve the real farm, which masks the divergence entirely.
mkdir -p "$T/bin19ai" "$T/fakeinfra19ai/root/templates/launchd" "$T/relcwd19ai"
cp "$SCHED" "$T/bin19ai/fleet-schedule.py"
printf '# none\n' > "$T/fakeinfra19ai/root/templates/launchd/RETIRED"
MARK19AI="$T/out/marker19ai.log"
python3 - "$T/fakeinfra19ai/root/templates/launchd" "$MARK19AI" <<'PY19AI'
import os, plistlib, sys
d = {"Label": "com.test.ainfra19ai",
     "ProgramArguments": ["/bin/sh", "-c", "echo ainfra={{AGENT_INFRA_PATH}} >> %s" % sys.argv[2]],
     "StartInterval": 2}
with open(os.path.join(sys.argv[1], "com.test.ainfra19ai.plist"), "wb") as fh:
    plistlib.dump(d, fh)
PY19AI
out19ai="$(cd "$T/relcwd19ai" && env -u AGENT_INFRA_PATH -u TEMPLATES_DIR INFRA_ROOT=../fakeinfra19ai/root \
  FLEET_SCHEDULE_STATE="$T/s19ai" FLEET_SCHEDULE_LOCK_ROOT="$L19/ai" FLEET_SCHEDULE_TICK=2 \
  python3 "$T/bin19ai/fleet-schedule.py" --start 2>&1)"; rc19ai=$?
[ "$rc19ai" -eq 0 ] \
  && ok "19ai --start with a RELATIVE INFRA_ROOT exits 0" \
  || bad "19ai --start exited $rc19ai: $out19ai"
wait19ai=0
while [ ! -s "$MARK19AI" ] && [ "$wait19ai" -lt 25 ]; do sleep 1; wait19ai=$((wait19ai + 1)); done
[ -s "$MARK19AI" ] \
  && ok "19ai the loop child RAN the {{AGENT_INFRA_PATH}} job (it rendered the placeholder)" \
  || bad "19ai the child never ran the job — INFRA_ROOT resolved differently there: $out19ai / $(tail -3 "$T/s19ai/loop.log" 2>/dev/null)"
grep -qvx "ainfra=$T/fakeinfra19ai/root" "$MARK19AI" 2>/dev/null \
  && bad "19ai the child rendered a DIFFERENT {{AGENT_INFRA_PATH}}: $(grep -v '^ainfra=' "$MARK19AI" | head -2)" \
  || ok "19ai ⛔ the child's render IS the path the parent resolved (one checkout, one argv)"
pidAI="$(cat "$T/s19ai/loop.pid" 2>/dev/null)"; kill "$pidAI" 2>/dev/null; sleep 1

# 19aj — ⛔ A NAMED SKIP IS NOT A DIVERGENCE. 19x turns a declaration no loop on the box runs into a
# FAIL on purpose, but a declaration THIS HOST cannot run is a `SKIP … for a named reason` everywhere
# else in the runtime (`--check` prints DECLARATIONS OK over it and the graded loop continues past it).
# Counting one as a divergence produced a `^  FAIL`, which `cloud-cell-bringup.sh` `die`s on: two homes
# with version-skewed checkouts (the operator's vs a cell's farmed copy, which lags by design) plus any
# shipped template that is a SKIP on a box without swarm/tortoise env bricked bring-up — #3029's shape.
mkdir -p "$T/tpl19ajA" "$T/tpl19ajB"
cp "$GOOD"/*.plist "$T/tpl19ajA/" 2>/dev/null
cp "$GOOD"/*.plist "$T/tpl19ajB/" 2>/dev/null
printf '# none\n' > "$T/tpl19ajA/RETIRED"; printf '# none\n' > "$T/tpl19ajB/RETIRED"
mkplist "$T/tpl19ajB" com.test.skipme "$T/skipme.spec"
# ⛔ THE PREMISE, ASSERTED: on THIS host the extra declaration is a named SKIP and not a runnable job.
# Without it the arm would grade an ordinary divergence, and 19x would rightly still demand a FAIL.
env -u SWARM_ROOT TEMPLATES_DIR="$T/tpl19ajB" FLEET_SCHEDULE_STATE="$T/s19ajB" \
    python3 "$SCHED" --check > "$T/out/check19aj.txt" 2>&1
grep -q 'SKIP .*com.test.skipme' "$T/out/check19aj.txt" \
  && ok "19aj premise: the extra declaration is a NAMED SKIP on this host" \
  || bad "19aj premise failed — the arm would grade an ordinary divergence: $(cat "$T/out/check19aj.txt")"
s19 "$T/s19ajA" "$T/tpl19ajA" --install >/dev/null 2>&1
pidAJ="$(cat "$T/s19ajA/loop.pid" 2>/dev/null)"
[ -n "$pidAJ" ] && kill -0 "$pidAJ" 2>/dev/null \
  && ok "19aj baseline: home A's loop holds the box (and its inline pass stamped its jobs)" \
  || bad "19aj baseline loop never came up — the arm grades nothing"
out19aj="$(env -u SWARM_ROOT TEMPLATES_DIR="$T/tpl19ajB" FLEET_SCHEDULE_STATE="$T/s19ajB" \
  FLEET_SCHEDULE_LOCK_ROOT="$L19" python3 "$SCHED" --install 2>&1)"; rc19aj=$?
grep -q '^  FAIL' <<<"$out19aj" \
  && bad "19aj a named-SKIP declaration was graded a divergence: $out19aj" \
  || ok "19aj ⛔ a named SKIP is NOT reported as a declaration no loop on the box runs"
[ "$rc19aj" -eq 0 ] \
  && ok "19aj --install exits 0 over a skipped extra declaration (bring-up is not bricked)" \
  || bad "19aj --install exited $rc19aj over a named SKIP: $out19aj"
grep -q "NOTE .*DIFFERENT state dir" <<<"$out19aj" \
  && ok "19aj the two-home state is still DISCLOSED (only the SKIP became non-fatal)" \
  || bad "19aj the divergence NOTE vanished — the fix over-reached: $out19aj"
# ⛔ POSITIVE CONTROL: a RUNNABLE extra declaration is STILL a FAIL, so 19x's contract is not softened.
python3 - "$T/tpl19ajB" <<'PY19AJ'
import os, plistlib, sys
d = {"Label": "com.test.extra19aj", "ProgramArguments": ["/bin/true"], "StartInterval": 3600}
with open(os.path.join(sys.argv[1], "com.test.extra19aj.plist"), "wb") as fh:
    plistlib.dump(d, fh)
PY19AJ
out19aj2="$(env -u SWARM_ROOT TEMPLATES_DIR="$T/tpl19ajB" FLEET_SCHEDULE_STATE="$T/s19ajB" \
  FLEET_SCHEDULE_LOCK_ROOT="$L19" python3 "$SCHED" --install 2>&1)"; rc19aj2=$?
grep -q 'run by NO loop on this box: com.test.extra19aj' <<<"$out19aj2" \
  && ok "19aj CONTROL: a RUNNABLE extra declaration is still a FAIL (19x's contract intact)" \
  || bad "19aj CONTROL: the fix swallowed a genuine divergence (rc=$rc19aj2): $out19aj2"
kill "$pidAJ" 2>/dev/null; sleep 1

# 19ak — ⛔ A RELATIVE `TORTOISE_REPO` MUST REACH THE CHILD RESOLVED TOO, and this one is NOT a matter
# of taste: `placeholder_values()` decides with `os.path.isdir(tortoise)` whether to KEEP the value or
# replace it with an absolute fallback checkout, so a relative pin kept its relative form in the parent
# and was replaced (or emptied) in the child. Measured by the #3636 reviewer: `--install` printed
# `SCHEDULE VERIFIED — 2 job(s) live` while the loop child rendered `{{TORTOISE_REPO}}` as "" and
# classified the tortoise job as a named SKIP — the loop ran zero of it and `--verify` never saw it.
# `absolutize_path_knobs()` now rewrites the knob in the PARENT, so `os.environ.copy()` hands the child
# the resolved value and both processes render the same argv.
mkdir -p "$T/bin19ak" "$T/tpl19ak" "$T/relcwd19ak/tort19ak/.git"
cp "$SCHED" "$T/bin19ak/fleet-schedule.py"
printf '# none\n' > "$T/tpl19ak/RETIRED"
MARK19AK="$T/out/marker19ak.log"
python3 - "$T/tpl19ak" "$MARK19AK" <<'PY19AK'
import os, plistlib, sys
d = {"Label": "com.test.tort19ak",
     "ProgramArguments": ["/bin/sh", "-c", "echo tort={{TORTOISE_REPO}} >> %s" % sys.argv[2]],
     "StartInterval": 2}
with open(os.path.join(sys.argv[1], "com.test.tort19ak.plist"), "wb") as fh:
    plistlib.dump(d, fh)
PY19AK
out19ak="$(cd "$T/relcwd19ak" && env -u CELL_HOME -u SWARM_ROOT TORTOISE_REPO=tort19ak \
  TEMPLATES_DIR="$T/tpl19ak" FLEET_SCHEDULE_STATE="$T/s19ak" FLEET_SCHEDULE_LOCK_ROOT="$L19/ak" \
  FLEET_SCHEDULE_TICK=2 python3 "$T/bin19ak/fleet-schedule.py" --start 2>&1)"; rc19ak=$?
[ "$rc19ak" -eq 0 ] \
  && ok "19ak --start with a RELATIVE TORTOISE_REPO exits 0" \
  || bad "19ak --start exited $rc19ak: $out19ak"
wait19ak=0
while [ ! -s "$MARK19AK" ] && [ "$wait19ak" -lt 25 ]; do sleep 1; wait19ak=$((wait19ak + 1)); done
[ -s "$MARK19AK" ] \
  && ok "19ak the loop child RAN the {{TORTOISE_REPO}} job (the placeholder rendered)" \
  || bad "19ak the child never ran the job — a relative TORTOISE_REPO emptied there: $out19ak / $(tail -3 "$T/s19ak/loop.log" 2>/dev/null)"
grep -qvx "tort=$T/relcwd19ak/tort19ak" "$MARK19AK" 2>/dev/null \
  && bad "19ak the child rendered a DIFFERENT {{TORTOISE_REPO}}: $(grep -v '^tort=' "$MARK19AK" | head -2)" \
  || ok "19ak ⛔ the child's render IS the checkout the parent resolved (one repo, one argv)"
pidAK="$(cat "$T/s19ak/loop.pid" 2>/dev/null)"; kill "$pidAK" 2>/dev/null; sleep 1

# 19al — ⛔ `--install` MUST NOT REWRITE THE DECLARATION POINTER WHEN THE LOOP WAS ALREADY RUNNING. The
# pointer became LOAD-BEARING in this change (`cmd_verify` reads it and grades THAT set), and
# `--install` wrote it unconditionally at the top — so an install with a different TEMPLATES_DIR over an
# already-running loop replaced "the set the box runs" with "the set this invocation happened to look
# at". Measured: pointer tplA -> tplB while `loop.log` still start-named tplA, after which a second
# home's `--verify` graded tplB and left every job of the loop's REAL set ungraded — the same lie 19ad
# pins for `--start`, injected by the sibling entry point. `--start`'s ruling applies here verbatim:
# record the set only when this invocation actually STARTED the loop.
mkdir -p "$T/tpl19alA" "$T/tpl19alB"
cp "$GOOD"/*.plist "$T/tpl19alA/" 2>/dev/null
cp "$GOOD"/*.plist "$T/tpl19alB/" 2>/dev/null
printf '# none\n' > "$T/tpl19alA/RETIRED"; printf '# none\n' > "$T/tpl19alB/RETIRED"
s19 "$T/s19al" "$T/tpl19alA" --install >/dev/null 2>&1
pidAL="$(cat "$T/s19al/loop.pid" 2>/dev/null)"
[ -n "$pidAL" ] && kill -0 "$pidAL" 2>/dev/null \
  && ok "19al baseline: --install started a loop for state dir AL" \
  || bad "19al baseline loop never came up — the arm grades nothing"
[ "$(cat "$T/s19al/templates-dir" 2>/dev/null)" = "$T/tpl19alA" ] \
  && ok "19al --install records the declaration set when it STARTED the loop (the pointer is written)" \
  || bad "19al --install did not record its own set: $(cat "$T/s19al/templates-dir" 2>/dev/null)"
out19al="$(s19 "$T/s19al" "$T/tpl19alB" --install 2>&1)"
grep -q 'loop already running' <<<"$out19al" \
  && ok "19al the second --install found the live loop (so the pointer must not move)" \
  || bad "19al the second --install did not see the running loop: $out19al"
[ "$(cat "$T/s19al/templates-dir" 2>/dev/null)" = "$T/tpl19alA" ] \
  && ok "19al ⛔ --install over a RUNNING loop did NOT rewrite the pointer to a set nothing reads" \
  || bad "19al --install rewrote the pointer to a set the loop does not read ($T/tpl19alA -> $(cat "$T/s19al/templates-dir" 2>/dev/null))"
kill "$pidAL" 2>/dev/null; sleep 1

# 19ap — ⛔ A MISSING `loop.pid` MUST NOT LET `--install` REWRITE THE DECLARATION POINTER. 19al pins the
# pointer rule for the EASY state (pidfile present); it granted no protection in the two states this
# file documents as reachable — `cmd_loop` leaves the previous pidfile alone when its own write fails,
# and #3029's recycled pid fails the identity test — because the owner test was `loop_pid()` ONLY. On
# either, `--install` read "no loop here" over a LIVE loop, rewrote the pointer to the caller's set,
# and a later `--verify` graded a set nothing runs and printed `SCHEDULE VERIFIED` over it. Measured
# before the fix: real loop on tplA, `rm loop.pid`, `--install TEMPLATES_DIR=tplB` -> pointer tplB while
# `loop.log` still start-named tplA. The owner test now reads the identity-verified BOX lock, which is
# what `--verify` and `--start` already use for the same question.
mkdir -p "$T/tpl19apA" "$T/tpl19apB"
cp "$GOOD"/*.plist "$T/tpl19apA/" 2>/dev/null
cp "$GOOD"/*.plist "$T/tpl19apB/" 2>/dev/null
printf '# none\n' > "$T/tpl19apA/RETIRED"; printf '# none\n' > "$T/tpl19apB/RETIRED"
s19 "$T/s19ap" "$T/tpl19apA" --install >/dev/null 2>&1
pidAP="$(cat "$T/s19ap/loop.pid" 2>/dev/null)"
[ -n "$pidAP" ] && kill -0 "$pidAP" 2>/dev/null \
  && ok "19ap baseline: --install started a loop for state dir AP" \
  || bad "19ap baseline loop never came up — the arm grades nothing"
[ "$(cat "$T/s19ap/templates-dir" 2>/dev/null)" = "$T/tpl19apA" ] \
  && ok "19ap baseline: the pointer names the set the loop started with (A)" \
  || bad "19ap baseline pointer is not A: $(cat "$T/s19ap/templates-dir" 2>/dev/null)"
rm -f "$T/s19ap/loop.pid"
out19ap="$(s19 "$T/s19ap" "$T/tpl19apB" --install 2>&1)"
[ "$(cat "$T/s19ap/templates-dir" 2>/dev/null)" = "$T/tpl19apA" ] \
  && ok "19ap ⛔ with loop.pid GONE the live loop was still found through the BOX LOCK, so the pointer did NOT move" \
  || bad "19ap a missing loop.pid bypassed the owner test — --install rewrote the pointer to a set the live loop never reads ($T/tpl19apA -> $(cat "$T/s19ap/templates-dir" 2>/dev/null))"
# …and the refusal is per-state-dir, not a blanket: a loop still holds the box, so no SECOND loop may
# have been started for this state dir either (spawn_loop must defer to the verified holder).
[ ! -f "$T/s19ap/loop.pid" ] \
  && ok "19ap --install did not start a second loop for this state dir (it deferred to the box lock's holder)" \
  || bad "19ap --install started a SECOND loop over a box that already had one (#2890): $(cat "$T/s19ap/loop.pid" 2>/dev/null)"
kill "$pidAP" 2>/dev/null; sleep 1

# 19am — ⛔ A RELATIVE ARMING RECORD MUST REACH THE CHILD RESOLVED TOO, and this one is not academic:
# `WORKTREE_HYGIENE_ARM_FILE` / `REAP_ORPHAN_ARM_FILE` OVERRIDE the `home/.pi/agent/state/...` default and
# are then read with `open()`, so a relative override decided `--apply` vs `--dry-run` by the CALLER's cwd.
# Measured before the fix: one `SCHEDULE VERIFIED` over a marker carrying `wt=--apply` (the parent's inline
# pass) AND `wt=--dry-run` (the loop child) — on the two shipped templates that carry these placeholders, so
# the worktree sweeper's dry-run/apply decision differed between what was certified and what runs.
mkdir -p "$T/bin19am" "$T/tpl19am" "$T/relcwd19am"
cp "$SCHED" "$T/bin19am/fleet-schedule.py"
printf '# none\n' > "$T/tpl19am/RETIRED"
MARK19AM="$T/out/marker19am.log"
python3 - "$T/tpl19am" "$MARK19AM" <<'PY19AM'
import os, plistlib, sys
d = {"Label": "com.test.wt19am",
     "ProgramArguments": ["/bin/sh", "-c", "echo wt={{WORKTREE_HYGIENE_MODE}} >> %s" % sys.argv[2]],
     "StartInterval": 2}
with open(os.path.join(sys.argv[1], "com.test.wt19am.plist"), "wb") as fh:
    plistlib.dump(d, fh)
PY19AM
# The arming record, RELATIVE to the caller's cwd, carrying the two keys `wt_hygiene_mode()` requires.
printf 'armed-by=test-19am\narmed-date=2026-11-07\n' > "$T/relcwd19am/armed19am"
out19am="$(cd "$T/relcwd19am" && env -u CELL_HOME WORKTREE_HYGIENE_ARM_FILE=armed19am \
  TEMPLATES_DIR="$T/tpl19am" FLEET_SCHEDULE_STATE="$T/s19am" FLEET_SCHEDULE_LOCK_ROOT="$L19/am" \
  FLEET_SCHEDULE_TICK=2 python3 "$T/bin19am/fleet-schedule.py" --start 2>&1)"; rc19am=$?
[ "$rc19am" -eq 0 ] \
  && ok "19am --start with a RELATIVE arming record exits 0" \
  || bad "19am --start exited $rc19am: $out19am"
wait19am=0
while [ ! -s "$MARK19AM" ] && [ "$wait19am" -lt 25 ]; do sleep 1; wait19am=$((wait19am + 1)); done
[ -s "$MARK19AM" ] \
  && ok "19am the loop child RAN the {{WORKTREE_HYGIENE_MODE}} job" \
  || bad "19am the child never ran the job: $out19am / $(tail -3 "$T/s19am/loop.log" 2>/dev/null)"
grep -qvx 'wt=--apply' "$MARK19AM" 2>/dev/null \
  && bad "19am the child rendered a DIFFERENT {{WORKTREE_HYGIENE_MODE}}: $(head -3 "$MARK19AM")" \
  || ok "19am ⛔ the child resolved the SAME arming record the parent did (--apply, not --dry-run)"
pidAM="$(cat "$T/s19am/loop.pid" 2>/dev/null)"; kill "$pidAM" 2>/dev/null; sleep 1

# 19as — ⛔ A RELATIVE `SWARM_ROOT` MUST REACH THE CHILD RESOLVED TOO, and the placeholder that DIVERGES
# is not `{{SWARM_ROOT}}` (rendered verbatim from the env in BOTH processes) but `{{PYTHON_BIN}}`, which
# `placeholder_values()` DERIVES from it: `os.access(join(SWARM_ROOT, ".venv/bin/python"), os.X_OK)` is
# cwd-relative, so a relative swarm root is found by the parent and NOT by the loop child (`cwd="/"`),
# which falls through to `command -v python3` — two different interpreters rendered into one
# `SCHEDULE VERIFIED`. This is the sixth of the twelve knobs `absolutize_path_knobs()` normalises and
# the one #3636's own review measured as UNGRADED: deleting `"SWARM_ROOT"` from that tuple left the
# suite GREEN, every assertion happy — the guard was advertised covered and was not (#3442).
mkdir -p "$T/bin19as" "$T/tpl19as" "$T/relcwd19as/swarm19as/.venv/bin"
cp "$SCHED" "$T/bin19as/fleet-schedule.py"
printf '# none\n' > "$T/tpl19as/RETIRED"
# A REAL executable at the path `placeholder_values()` probes: the arm grades the DERIVED placeholder,
# so the probe has to SUCCEED for the resolved branch to be the one under test.
printf '#!/bin/sh\nexec python3 "$@"\n' > "$T/relcwd19as/swarm19as/.venv/bin/python"
chmod +x "$T/relcwd19as/swarm19as/.venv/bin/python"
MARK19AS="$T/out/marker19as.log"
python3 - "$T/tpl19as" "$MARK19AS" <<'PY19AS'
import os, plistlib, sys
d = {"Label": "com.test.swarm19as",
     "ProgramArguments": ["/bin/sh", "-c", "echo py={{PYTHON_BIN}} >> %s" % sys.argv[2]],
     "StartInterval": 2}
with open(os.path.join(sys.argv[1], "com.test.swarm19as.plist"), "wb") as fh:
    plistlib.dump(d, fh)
PY19AS
out19as="$(cd "$T/relcwd19as" && env -u AGENT_INFRA_PATH -u INFRA_ROOT -u CELL_HOME -u PYTHON_BIN SWARM_ROOT=swarm19as \
  TEMPLATES_DIR="$T/tpl19as" FLEET_SCHEDULE_STATE="$T/s19as" FLEET_SCHEDULE_LOCK_ROOT="$L19/as" \
  FLEET_SCHEDULE_TICK=2 python3 "$T/bin19as/fleet-schedule.py" --start 2>&1)"; rc19as=$?
[ "$rc19as" -eq 0 ] \
  && ok "19as --start with a RELATIVE SWARM_ROOT exits 0" \
  || bad "19as --start exited $rc19as: $out19as"
wait19as=0
while [ ! -s "$MARK19AS" ] && [ "$wait19as" -lt 25 ]; do sleep 1; wait19as=$((wait19as + 1)); done
[ -s "$MARK19AS" ] \
  && ok "19as the loop child RAN the {{PYTHON_BIN}} job (the placeholder rendered)" \
  || bad "19as the child never ran the job: $out19as / $(tail -3 "$T/s19as/loop.log" 2>/dev/null)"
grep -qvx "py=$T/relcwd19as/swarm19as/.venv/bin/python" "$MARK19AS" 2>/dev/null \
  && bad "19as the child DERIVED a different {{PYTHON_BIN}} from the same SWARM_ROOT: $(head -3 "$MARK19AS")" \
  || ok "19as ⛔ the child derived the SAME interpreter the parent resolved (one swarm root, one argv)"
pidAS="$(cat "$T/s19as/loop.pid" 2>/dev/null)"; kill "$pidAS" 2>/dev/null; sleep 1

# 19at — ⛔ A RELATIVE `CELL_HOME` MUST REACH THE CHILD RESOLVED TOO. `home` is `CELL_HOME or HOME` and
# BOTH arming records default THROUGH it (`open(home/.pi/agent/state/worktree-hygiene.armed)`,
# `…/pi-reap-orphans.armed`), so a relative `CELL_HOME` decided the parent's `--apply`/armed answer by the
# CALLER's cwd while the child (`cwd="/"`) read `/cell…`, hit `OSError` and answered `--dry-run`/disarmed
# — one `SCHEDULE VERIFIED` over a sweeper that does not sweep and a reaper that does not reap. 19am
# grades the `*_ARM_FILE` OVERRIDES; this is the DEFAULT they fall back to, and neither had an arm.
mkdir -p "$T/bin19at" "$T/tpl19at" "$T/relcwd19at/cell19at/.pi/agent/state"
cp "$SCHED" "$T/bin19at/fleet-schedule.py"
printf '# none\n' > "$T/tpl19at/RETIRED"
printf 'armed-by=test-19at\narmed-date=2026-11-07\n' \
  > "$T/relcwd19at/cell19at/.pi/agent/state/worktree-hygiene.armed"
printf 'armed-by=test-19at\narmed-date=2026-11-07\n' \
  > "$T/relcwd19at/cell19at/.pi/agent/state/pi-reap-orphans.armed"
MARK19AT="$T/out/marker19at.log"
python3 - "$T/tpl19at" "$MARK19AT" <<'PY19AT'
import os, plistlib, sys
d = {"Label": "com.test.cell19at",
     "ProgramArguments": ["/bin/sh", "-c", "echo wt={{WORKTREE_HYGIENE_MODE}} reap={{REAP_ORPHAN_MODE}} >> %s" % sys.argv[2]],
     "StartInterval": 2}
with open(os.path.join(sys.argv[1], "com.test.cell19at.plist"), "wb") as fh:
    plistlib.dump(d, fh)
PY19AT
out19at="$(cd "$T/relcwd19at" && env -u AGENT_INFRA_PATH -u INFRA_ROOT -u WORKTREE_HYGIENE_ARM_FILE -u REAP_ORPHAN_ARM_FILE CELL_HOME=cell19at \
  TEMPLATES_DIR="$T/tpl19at" FLEET_SCHEDULE_STATE="$T/s19at" FLEET_SCHEDULE_LOCK_ROOT="$L19/at" \
  FLEET_SCHEDULE_TICK=2 python3 "$T/bin19at/fleet-schedule.py" --start 2>&1)"; rc19at=$?
[ "$rc19at" -eq 0 ] \
  && ok "19at --start with a RELATIVE CELL_HOME exits 0" \
  || bad "19at --start exited $rc19at: $out19at"
wait19at=0
while [ ! -s "$MARK19AT" ] && [ "$wait19at" -lt 25 ]; do sleep 1; wait19at=$((wait19at + 1)); done
[ -s "$MARK19AT" ] \
  && ok "19at the loop child RAN the arming-record jobs" \
  || bad "19at the child never ran the job: $out19at / $(tail -3 "$T/s19at/loop.log" 2>/dev/null)"
grep -qvx 'wt=--apply reap=0' "$MARK19AT" 2>/dev/null \
  && bad "19at the child resolved a DIFFERENT CELL_HOME, so the armed records read as UNARMED: $(head -3 "$MARK19AT")" \
  || ok "19at ⛔ the child found the SAME armed records through the relative CELL_HOME (--apply / armed)"
pidAT="$(cat "$T/s19at/loop.pid" 2>/dev/null)"; kill "$pidAT" 2>/dev/null; sleep 1

# 19au — ⛔ A RELATIVE `REAP_ORPHAN_ARM_FILE` MUST REACH THE CHILD RESOLVED TOO — the 0-vs-1 twin of the
# `WORKTREE_HYGIENE_ARM_FILE` leg 19am grades. Both OVERRIDE a path that is opened with `open()`, so a
# relative override decides armed-vs-disarmed by the CALLER's cwd; measured here on the reaper, where the
# wrong answer is `1` (dry run) over a record that says the box IS armed, i.e. a reaper that never reaps.
mkdir -p "$T/bin19au" "$T/tpl19au" "$T/relcwd19au"
cp "$SCHED" "$T/bin19au/fleet-schedule.py"
printf '# none\n' > "$T/tpl19au/RETIRED"
printf 'armed-by=test-19au\narmed-date=2026-11-07\n' > "$T/relcwd19au/armed19au"
MARK19AU="$T/out/marker19au.log"
python3 - "$T/tpl19au" "$MARK19AU" <<'PY19AU'
import os, plistlib, sys
d = {"Label": "com.test.reap19au",
     "ProgramArguments": ["/bin/sh", "-c", "echo reap={{REAP_ORPHAN_MODE}} >> %s" % sys.argv[2]],
     "StartInterval": 2}
with open(os.path.join(sys.argv[1], "com.test.reap19au.plist"), "wb") as fh:
    plistlib.dump(d, fh)
PY19AU
out19au="$(cd "$T/relcwd19au" && env -u AGENT_INFRA_PATH -u INFRA_ROOT -u CELL_HOME -u WORKTREE_HYGIENE_ARM_FILE REAP_ORPHAN_ARM_FILE=armed19au \
  TEMPLATES_DIR="$T/tpl19au" FLEET_SCHEDULE_STATE="$T/s19au" FLEET_SCHEDULE_LOCK_ROOT="$L19/au" \
  FLEET_SCHEDULE_TICK=2 python3 "$T/bin19au/fleet-schedule.py" --start 2>&1)"; rc19au=$?
[ "$rc19au" -eq 0 ] \
  && ok "19au --start with a RELATIVE reaper arming record exits 0" \
  || bad "19au --start exited $rc19au: $out19au"
wait19au=0
while [ ! -s "$MARK19AU" ] && [ "$wait19au" -lt 25 ]; do sleep 1; wait19au=$((wait19au + 1)); done
[ -s "$MARK19AU" ] \
  && ok "19au the loop child RAN the {{REAP_ORPHAN_MODE}} job" \
  || bad "19au the child never ran the job: $out19au / $(tail -3 "$T/s19au/loop.log" 2>/dev/null)"
grep -qvx 'reap=0' "$MARK19AU" 2>/dev/null \
  && bad "19au the child resolved a DIFFERENT arming record, so an armed reaper rendered as disarmed: $(head -3 "$MARK19AU")" \
  || ok "19au ⛔ the child resolved the SAME reaper arming record the parent did (armed, not dry-run)"
pidAU="$(cat "$T/s19au/loop.pid" 2>/dev/null)"; kill "$pidAU" 2>/dev/null; sleep 1

# 19av — ⛔ THE THREE ENV-VALUED PATH KNOBS MUST REACH THE CHILD RESOLVED TOO — and the `os.sep`
# CONDITION on the last two is part of the contract, not an optimisation. `PYTHON_BIN`, `PI_NODE_BIN` and
# `SWARM_ENV_FILE` are rendered VERBATIM into job argv, and the loop child runs with `cwd="/"`, so a
# relative value pointed the job at `/py` rather than at the caller's `./py`. A BARE name is deliberately
# left alone (`python3` is a PATH lookup and `abspath("python3")` invents a file that does not exist), so
# the control row below pins that the normalisation does not over-reach — that is the arm a blanket
# `abspath` on every knob would redden.
mkdir -p "$T/bin19av" "$T/tpl19av" "$T/relcwd19av/pib19av"
cp "$SCHED" "$T/bin19av/fleet-schedule.py"
printf '# none\n' > "$T/tpl19av/RETIRED"
printf '#!/bin/sh\nexec python3 "$@"\n' > "$T/relcwd19av/py19av"; chmod +x "$T/relcwd19av/py19av"
printf '#!/bin/sh\nexit 0\n' > "$T/relcwd19av/pib19av/pi"; chmod +x "$T/relcwd19av/pib19av/pi"
MARK19AV="$T/out/marker19av.log"
python3 - "$T/tpl19av" "$MARK19AV" <<'PY19AV'
import os, plistlib, sys
d = {"Label": "com.test.paths19av",
     "ProgramArguments": ["/bin/sh", "-c",
                         "echo py={{PYTHON_BIN}} pib={{PI_BIN_DIR}} env={{SWARM_ENV_FILE}} >> %s" % sys.argv[2]],
     "StartInterval": 2}
with open(os.path.join(sys.argv[1], "com.test.paths19av.plist"), "wb") as fh:
    plistlib.dump(d, fh)
PY19AV
out19av="$(cd "$T/relcwd19av" && env -u AGENT_INFRA_PATH -u INFRA_ROOT -u CELL_HOME PYTHON_BIN=./py19av PI_NODE_BIN=./pib19av/pi \
  SWARM_ENV_FILE=swarmenv19av \
  TEMPLATES_DIR="$T/tpl19av" FLEET_SCHEDULE_STATE="$T/s19av" FLEET_SCHEDULE_LOCK_ROOT="$L19/av" \
  FLEET_SCHEDULE_TICK=2 python3 "$T/bin19av/fleet-schedule.py" --start 2>&1)"; rc19av=$?
[ "$rc19av" -eq 0 ] \
  && ok "19av --start with RELATIVE PYTHON_BIN/PI_NODE_BIN/SWARM_ENV_FILE exits 0" \
  || bad "19av --start exited $rc19av: $out19av"
wait19av=0
while [ ! -s "$MARK19AV" ] && [ "$wait19av" -lt 25 ]; do sleep 1; wait19av=$((wait19av + 1)); done
[ -s "$MARK19AV" ] \
  && ok "19av the loop child RAN the path-placeholder job" \
  || bad "19av the child never ran the job: $out19av / $(tail -3 "$T/s19av/loop.log" 2>/dev/null)"
grep -q "py=$T/relcwd19av/py19av " "$MARK19AV" 2>/dev/null \
  && ok "19av ⛔ a relative PYTHON_BIN rendered RESOLVED in the child (a job's interpreter is not cwd-relative)" \
  || bad "19av the child rendered a DIFFERENT {{PYTHON_BIN}}: $(head -3 "$MARK19AV")"
grep -q "pib=$T/relcwd19av/pib19av " "$MARK19AV" 2>/dev/null \
  && ok "19av ⛔ a relative PI_NODE_BIN rendered its RESOLVED directory in the child" \
  || bad "19av the child rendered a DIFFERENT {{PI_BIN_DIR}}: $(head -3 "$MARK19AV")"
grep -q "env=$T/relcwd19av/swarmenv19av$" "$MARK19AV" 2>/dev/null \
  && ok "19av ⛔ a relative SWARM_ENV_FILE rendered RESOLVED in the child" \
  || bad "19av the child rendered a DIFFERENT {{SWARM_ENV_FILE}}: $(head -3 "$MARK19AV")"
pidAV="$(cat "$T/s19av/loop.pid" 2>/dev/null)"; kill "$pidAV" 2>/dev/null; sleep 1
# ⛔ THE CONTROL: a BARE `PYTHON_BIN` is a PATH lookup and must stay BARE. Normalising it to `$PWD/python3`
# would point every job at a file that does not exist — the over-reach a blanket `abspath` would ship.
MARK19AVB="$T/out/marker19avb.log"
mkdir -p "$T/tpl19avb"; printf '# none\n' > "$T/tpl19avb/RETIRED"
python3 - "$T/tpl19avb" "$MARK19AVB" <<'PY19AVB'
import os, plistlib, sys
d = {"Label": "com.test.bare19av",
     "ProgramArguments": ["/bin/sh", "-c", "echo pybare={{PYTHON_BIN}} >> %s" % sys.argv[2]],
     "StartInterval": 2}
with open(os.path.join(sys.argv[1], "com.test.bare19av.plist"), "wb") as fh:
    plistlib.dump(d, fh)
PY19AVB
out19avb="$(cd "$T/relcwd19av" && env -u CELL_HOME -u AGENT_INFRA_PATH -u INFRA_ROOT PYTHON_BIN=python3 \
  TEMPLATES_DIR="$T/tpl19avb" FLEET_SCHEDULE_STATE="$T/s19avB" FLEET_SCHEDULE_LOCK_ROOT="$L19/avb" \
  FLEET_SCHEDULE_TICK=2 python3 "$T/bin19av/fleet-schedule.py" --start 2>&1)"; rc19avb=$?
wait19avb=0
while [ ! -s "$MARK19AVB" ] && [ "$wait19avb" -lt 25 ]; do sleep 1; wait19avb=$((wait19avb + 1)); done
grep -qx 'pybare=python3' "$MARK19AVB" 2>/dev/null \
  && ok "19av CONTROL: a BARE PYTHON_BIN is left alone (a PATH name is not a path)" \
  || bad "19av CONTROL: a bare PYTHON_BIN was rewritten to something else: $(head -3 "$MARK19AVB") (rc=$rc19avb)"
pidAVB="$(cat "$T/s19avB/loop.pid" 2>/dev/null)"; kill "$pidAVB" 2>/dev/null; sleep 1

# 19an — ⛔ AN `--install` THAT STARTS NOTHING MUST STILL RECORD ITS DECLARATION SET. This is the
# cell-bringup shape: a second state dir installs while another holds the BOX lock, so `spawn_loop`
# returns the foreign holder with `started=False` — and the pointer is the ONLY thing the supervisor's
# bare-env revival (`HOME=$CELL_HOME CELL_HOME=$CELL_HOME … --start`, no INFRA_ROOT/TEMPLATES_DIR) has to
# find the declarations. Gating the write on `started` (the 19al fix, first cut) silently dropped it here:
# measured `FAIL: no job declarations found` rc=3, which the supervisor logs as a WARN, so a cell that
# bring-up had just certified ran with no reap, no liveness detection and no canary. `main`'s arm returned
# rc=0 in the same shape. The rule is "no loop OF THIS STATE DIR is running", not "this verb started one".
mkdir -p "$T/tpl19anA" "$T/tpl19anB" "$T/bin19an"
cp "$GOOD"/*.plist "$T/tpl19anA/" 2>/dev/null
cp "$GOOD"/*.plist "$T/tpl19anB/" 2>/dev/null
printf '# none\n' > "$T/tpl19anA/RETIRED"; printf '# none\n' > "$T/tpl19anB/RETIRED"
cp "$SCHED" "$T/bin19an/fleet-schedule.py"
s19 "$T/s19anA" "$T/tpl19anA" --install >/dev/null 2>&1
pidAN="$(cat "$T/s19anA/loop.pid" 2>/dev/null)"
[ -n "$pidAN" ] && kill -0 "$pidAN" 2>/dev/null \
  && ok "19an baseline: home A's loop holds the box" \
  || bad "19an baseline loop never came up — the arm grades nothing"
out19an="$(s19 "$T/s19anB" "$T/tpl19anB" --install 2>&1)"; rc19an=$?
grep -q 'loop already running' <<<"$out19an" \
  && ok "19an home B's --install started NOTHING (the box lock is held by A — the bring-up shape)" \
  || bad "19an home B's --install did not take the foreign-holder path: $out19an"
[ -f "$T/s19anB/templates-dir" ] \
  && ok "19an ⛔ home B's declaration set WAS recorded even though it started nothing" \
  || bad "19an home B recorded NO declaration set — a later bare-env --start there cannot find the declarations"
[ "$(cat "$T/s19anB/templates-dir" 2>/dev/null)" = "$T/tpl19anB" ] \
  && ok "19an the pointer names HOME B's set, not the holder's" \
  || bad "19an the pointer names the wrong set: $(cat "$T/s19anB/templates-dir" 2>/dev/null)"
# ⛔ THE REVIVAL SHAPE ITSELF, from a scratch-dir copy so the child's `here` fallback cannot mask a
# missing pointer: no INFRA_ROOT, no AGENT_INFRA_PATH, no TEMPLATES_DIR — only what an install recorded.
out19an2="$(env -u INFRA_ROOT -u AGENT_INFRA_PATH -u TEMPLATES_DIR \
  FLEET_SCHEDULE_STATE="$T/s19anB" FLEET_SCHEDULE_LOCK_ROOT="$L19" \
  python3 "$T/bin19an/fleet-schedule.py" --start 2>&1)"; rc19an2=$?
[ "$rc19an2" -eq 0 ] \
  && ok "19an a bare-env --start finds the recorded set and exits 0 (the supervisor's revival works)" \
  || bad "19an a bare-env --start exited $rc19an2 — the cell runs with no scheduled layer: $out19an2"
grep -q 'no job declarations found' <<<"$out19an2" \
  && bad "19an the revival reported 'no job declarations found' (rc=3 is only a WARN to the supervisor)" \
  || ok "19an the revival did NOT report a missing declaration set"
kill "$pidAN" 2>/dev/null; sleep 1

# 19g — an UNUSABLE lock root must NOT wedge the box: it degrades to the state dir and DISCLOSES it.
: > "$T/not-a-dir"
out19g="$(env TEMPLATES_DIR="$GOOD" FLEET_SCHEDULE_STATE="$T/s19g" \
             FLEET_SCHEDULE_LOCK_ROOT="$T/not-a-dir/box" \
             python3 "$SCHED" --start 2>&1)"; rc19g=$?
pid19g="$(cat "$T/s19g/loop.pid" 2>/dev/null)"
[ -n "$pid19g" ] && kill -0 "$pid19g" 2>/dev/null \
  && ok "19g an unusable lock root still starts the loop (the box's alarm is not taken offline)" \
  || bad "19g an unusable lock root refused to start the scheduler (rc=$rc19g): $out19g"
grep -q 'box lock root' <<<"$out19g" \
  && ok "19g the degraded guard is DISCLOSED on stderr, not silent" \
  || bad "19g the degraded guard ran silently: $out19g"
kill "$pid19g" 2>/dev/null; sleep 1

# 19h — release on exit: a loop that stops must not leave its lock behind.
s19 "$T/s19h" "$GOOD" --start >/dev/null 2>&1
pid19h="$(cat "$T/s19h/loop.pid" 2>/dev/null)"
[ -f "$L19/loop.lock" ] && ok "19h baseline: the running loop holds the box lock" \
                       || bad "19h the running loop took no box lock"
s19 "$T/s19h" "$GOOD" --stop >/dev/null 2>&1
sleep 1
[ ! -f "$L19/loop.lock" ] && ok "19h a loop that exited RELEASED its own lock" \
                          || bad "19h the lock outlived its holder"
kill "$pid19h" 2>/dev/null

# 19i — NON-VACUITY, arm 1: defuse the CLAIM and the measured condition comes back (two state dirs,
# two loops, one box).
MUT19="$T/mut19"; mkdir -p "$MUT19"
sed 's/^    holder = claim_loop_lock()$/    holder = None  # MUTANT/' "$SCHED" > "$MUT19/fleet-schedule.py"
if grep -q 'MUTANT' "$MUT19/fleet-schedule.py"; then
  L19M="$T/box19m"; mkdir -p "$L19M"
  for arm in m1 m2; do
    env TEMPLATES_DIR="$GOOD" FLEET_SCHEDULE_STATE="$T/s19$arm" FLEET_SCHEDULE_LOCK_ROOT="$L19M" \
        python3 "$MUT19/fleet-schedule.py" --start >/dev/null 2>&1
  done
  n19m=0
  for arm in m1 m2; do
    p="$(cat "$T/s19$arm/loop.pid" 2>/dev/null)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then n19m=$((n19m + 1)); kill "$p" 2>/dev/null; fi
  done
  [ "$n19m" -eq 2 ] \
    && ok "19i MUTATION (claim defused) => TWO loops on one box: the arms discriminate" \
    || bad "19i MUTATION still produced $n19m loop(s) — §19 grades nothing"
else
  bad "19i could not build the mutant (the claim line moved) — the mutation arm did not run"
fi

# 19k — NON-VACUITY, arm 2: defuse the START-TIME half of the identity and 19e2 must go RED. This is
# the arm the [VGATE] pass showed was completely ungraded: with the comparison deleted, every §19
# assertion still passed, so the change's #1985 protection was untested.
sed 's/^        if observed is not None and observed != start:$/        if False:  # MUTANT/' "$SCHED" \
  > "$MUT19/fleet-schedule-k.py"
if grep -q 'MUTANT' "$MUT19/fleet-schedule-k.py"; then
  L19K="$T/box19k"; mkdir -p "$L19K"
  env TEMPLATES_DIR="$GOOD" FLEET_SCHEDULE_STATE="$T/s19k" FLEET_SCHEDULE_LOCK_ROOT="$L19K" \
      python3 "$MUT19/fleet-schedule-k.py" --start >/dev/null 2>&1
  pidK="$(cat "$T/s19k/loop.pid" 2>/dev/null)"
  lock19 "$L19K" "$pidK" "1" "$T/s19k-elsewhere"
  out19k="$(s19loop "$T/s19k2" "$MUT19/fleet-schedule-k.py" "$L19K")"
  if grep -q "pid $pidK" <<<"$out19k"; then
    ok "19k MUTATION (start-time arm deleted) => the stale identity is DEFERRED to: 19e2 discriminates"
  else
    bad "19k the mutant reclaimed anyway — 19e2 grades nothing: $out19k"
  fi
  kill "$pidK" 2>/dev/null
else
  bad "19k could not build the start-time mutant (that line moved) — the mutation arm did not run"
fi

# 19aq — THE FALLBACK'S DISCLOSURE NAMES THE ERROR THAT ACTUALLY STOPPED IT. `os.link` refusing is
# what SELECTS the `O_EXCL` fallback; the create is a SECOND syscall and can fail on its own
# (ENOSPC/EDQUOT/EACCES). The permit message was built from the link exception in both arms, so a
# full disk or an unwritable lock root was disclosed as the LINK's errno — measured at the pre-fix
# head as `cannot create the box lock at … (OSError: [Errno 95] Operation not supported)` while the
# create had actually failed with ENOSPC. An operator reading the one line this file emits on the
# permit path was sent to the wrong cause, on the failure the fallback exists to survive (#2890).
# Both syscalls are driven in-process so the two errnos cannot coincide.
out19aq="$(python3 - "$SCHED" "$T/state19aq" <<'PY19AQ' 2>&1
import errno, importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fleet_schedule_19aq", sys.argv[1])
fs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fs)
state = sys.argv[2]
os.makedirs(state, exist_ok=True)
fs.STATE = state
fs.LOOP_LOCK = os.path.join(state, "loop.lock")
real_link, real_open = os.link, os.open
def no_link(src, dst):
    raise OSError(errno.EOPNOTSUPP, os.strerror(errno.EOPNOTSUPP))
def full_disk(path, flags, mode=0o777):
    raise OSError(errno.ENOSPC, os.strerror(errno.ENOSPC))
os.link = no_link
os.open = full_disk
try:
    verdict = fs.claim_loop_lock()
finally:
    os.link, os.open = real_link, real_open
print("VERDICT", verdict)
PY19AQ
)"
grep -q 'VERDICT None' <<<"$out19aq" \
  && ok "19aq a create failure on a link-refusing root still PERMITS (the box is not left unscheduled)" \
  || bad "19aq the create failure did not permit: $out19aq"
grep -q 'No space left on device' <<<"$out19aq" \
  && ok "19aq ⛔ the disclosure names the CREATE's own failure (ENOSPC), not the link's" \
  || bad "19aq the disclosure did not name the create error (ENOSPC): $out19aq"
grep -q 'Operation not supported' <<<"$out19aq" \
  && bad "19aq the disclosure reported the LINK errno for a CREATE failure: $out19aq" \
  || ok "19aq the link errno is NOT reported for a create failure (attribution is per-syscall)"
grep -q 'cannot create the box lock' <<<"$out19aq" \
  && ok "19aq the create path is still NAMED as the create path" \
  || bad "19aq the create failure was not named: $out19aq"


# ── 20. THE FILE AND THE PROCESS ARE DIFFERENT FACTS (#2961) ─────────────────────────────────
# `staged_copy_report()` grades the FILE against the CHECKOUT. It structurally cannot see the second
# seam: the loop is a LONG-LIVED Python process — it re-reads DECLARATIONS every pass (`cmd_loop` →
# `load_jobs`) but never re-execs, so the module it loaded at startup is the code it runs for ever.
# So after `cell-install.sh --install` refreshes the farm, the staged file byte-matches the checkout,
# `--verify` compares the two FILES, and prints `SCHEDULE VERIFIED` over a cell whose ticking loop is
# still the pre-refresh module — and `--start` could not help either, because it returned 0 at
# `loop already running` before any staleness question was asked. `cloud-cell-bringup.sh` turns that
# green into `CELL READY`, so an operator who lands a fix, refreshes, and watches the gate go green
# believes the fix is live on that cell. It is not. The runtime now records WHAT IT LOADED
# (`loop.code`: digest + pid + path) and grades the PROCESS against the file it recorded.
case_ "20. the LIVE loop is graded against the file it loaded, and a stale one is restartable (#2961)"
if [ "$(uname -s)" = "Darwin" ]; then
  skip "--install/--start/--verify delegate to launchd on macOS, so the build stamp cannot be driven here"
else
  S20="$T/st20-staged"; ST20="$T/st20-state"
  mkdir -p "$S20" "$ST20"
  cp "$SCHED" "$S20/fleet-schedule.py"      # a STAGED copy — the cell's own delivery path
  # ⛔ ITS OWN box-lock root: §19's may still hold another arm's loop, and a foreign holder would
  # make every --install below answer "this state dir starts none" and grade nothing. And
  # INFRA_ROOT/AGENT_INFRA_PATH are unset ON PURPOSE: this arm grades PROCESS against FILE, so the
  # file-vs-checkout arm must stay out of it (a staged snapshot is not this working tree, and the
  # `differs` failure would mask every assertion below — case 1f owns that arm).
  s20() { env -u INFRA_ROOT -u AGENT_INFRA_PATH TEMPLATES_DIR="$GOOD" FLEET_SCHEDULE_STATE="$ST20" \
             FLEET_SCHEDULE_LOCK_ROOT="$T/st20-box-lock" \
             python3 "$S20/fleet-schedule.py" "$@" 2>&1; }

  out="$(s20 --install)"; rc=$?
  [ "$rc" -eq 0 ] && ok "20 baseline: --install on the staged copy exits 0" \
                  || bad "20 baseline install failed (rc=$rc): $out"
  pid20="$(cat "$ST20/loop.pid" 2>/dev/null)"
  grep -q '"digest"' "$ST20/loop.code" 2>/dev/null \
    && ok "20 the loop RECORDS a build stamp (digest + pid + path) when it starts" \
    || bad "20 no build stamp was written: $(ls "$ST20" 2>&1)"
  out="$(s20 --status)"
  grep -q 'code=current' <<<"$out" \
    && ok "20 --status answers WHICH BUILD the live loop runs (code=current)" \
    || bad "20 --status does not report the running build: $out"
  out="$(s20 --verify)"; rc=$?
  [ "$rc" -eq 0 ] \
    && ok "20 a loop running the file it loaded verifies clean (no false alarm)" \
    || bad "20 a CURRENT loop was refused (rc=$rc): $out"

  # THE DEFECT, EXACTLY: refresh the FILE the loop loaded and leave the process alone. This is the
  # state `cell-install.sh --install` creates, and it is invisible to any file-to-file comparison
  # because the file IS already the new one.
  printf '\n# refreshed by the farm — the PROCESS above never loaded this\n' >> "$S20/fleet-schedule.py"
  out="$(s20 --verify)"; rc=$?
  [ "$rc" -eq 1 ] \
    && ok "20 ⛔ --verify FAILS over a loop still executing the pre-refresh build" \
    || bad "20 a cell whose loop runs the OLD build was certified (rc=$rc): $out"
  grep -q 'THE FILE WAS REFRESHED AND THE PROCESS WAS NOT' <<<"$out" \
    && ok "20 the failure names the seam (file refreshed, process not), not some other arm" \
    || bad "20 the failure does not name the refreshed-file/old-process state: $out"
  grep -q -- '--start' <<<"$out" \
    && ok "20 the failure says how to make the landing live (--start)" \
    || bad "20 the failure named no remedy: $out"
  kill -0 "$pid20" 2>/dev/null \
    && ok "20 --verify graded the PROCESS without killing it (a gate is not a restart)" \
    || bad "20 --verify killed the loop it was asked to diagnose"

  # `--start` is the revival verb, and it used to answer `loop already running` here: exit 0,
  # nothing changed, no staleness question asked.
  out="$(s20 --start)"; rc=$?
  [ "$rc" -eq 0 ] && ok "20 --start over a stale loop exits 0" \
                  || bad "20 --start failed over a stale loop (rc=$rc): $out"
  pid20b="$(cat "$ST20/loop.pid" 2>/dev/null)"
  [ -n "$pid20b" ] && [ "$pid20b" != "$pid20" ] \
    && ok "20 --start REPLACED the stale loop instead of reporting it as current" \
    || bad "20 --start left the pre-refresh process running (pid $pid20 -> $pid20b)"
  grep -q 'restarting the loop so the file on disk is the code that runs' <<<"$out" \
    && ok "20 --start says what it did (a restart is an ACT, reported as one)" \
    || bad "20 --start restarted without saying so: $out"
  out="$(s20 --verify)"; rc=$?
  [ "$rc" -eq 0 ] \
    && ok "20 after the restart the same --verify passes (the landing is now LIVE)" \
    || bad "20 --verify still refuses after a real restart (rc=$rc): $out"
  grep -q "\"pid\": $pid20b" "$ST20/loop.code" 2>/dev/null \
    && ok "20 the replacement loop stamped ITS OWN pid (the stamp is not the stale one)" \
    || bad "20 the stamp was not rewritten by the new loop: $(cat "$ST20/loop.code" 2>&1)"

  # ⛔ "COULD NOT COMPARE" NEVER READS AS CLEAN. A loop started by a build that PREDATES the stamp
  # writes none, so absence is not evidence of being current — it is the pre-fix build, and it is
  # graded stale (fail-closed) rather than cleared. Clearing it is the no-op-gate shape: the one arm
  # that exists to stop a cell certifying an unrunnable build would be skipped on exactly the cells
  # that have not been refreshed yet.
  rm -f "$ST20/loop.code"
  out="$(s20 --verify)"; rc=$?
  [ "$rc" -eq 1 ] \
    && ok "20 a MISSING stamp under a live loop is STALE, not clean (fail-closed)" \
    || bad "20 a loop that cannot show which build it runs was certified (rc=$rc): $out"
  grep -q 'NO build stamp' <<<"$out" \
    && ok "20 the missing-stamp failure says there is NO evidence, and how to produce it" \
    || bad "20 the missing-stamp failure is unattributed: $out"
  out="$(s20 --start)"; rc=$?
  pid20c="$(cat "$ST20/loop.pid" 2>/dev/null)"
  [ "$rc" -eq 0 ] && [ -n "$pid20c" ] && [ "$pid20c" != "$pid20b" ] \
    && ok "20 --start also replaces an UNSTAMPED loop (the pre-fix build is restartable)" \
    || bad "20 --start left an unstamped loop in place (rc=$rc, pid $pid20b -> $pid20c): $out"

  # ⛔ THE FALSE-ALARM DIRECTION, WHICH IS WHAT MAKES THE ARM USABLE. A rewrite that does not change
  # the BYTES is not a new build: same digest, still current, still verified. An mtime or an inode
  # would fail this, and an operator who is told "stale" over an identical file learns to ignore it.
  cp "$S20/fleet-schedule.py" "$S20/rewritten" && mv "$S20/rewritten" "$S20/fleet-schedule.py"
  out="$(s20 --verify)"; rc=$?
  [ "$rc" -eq 0 ] \
    && ok "20 a byte-identical rewrite is NOT stale (the comparison is content, not mtime)" \
    || bad "20 an identical file was reported stale (a false alarm trains operators to ignore it): $out"

  # ⛔ THE STAMP DOES NOT OUTLIVE ITS LOOP. A `loop.code` left behind after a stop is a record on
  # disk claiming a build is live when nothing is running.
  s20 --stop >/dev/null 2>&1
  [ ! -f "$ST20/loop.code" ] \
    && ok "20 --stop removes the stamp with the pidfile (no record of a loop that is gone)" \
    || bad "20 the build stamp outlived its loop: $(cat "$ST20/loop.code" 2>&1)"

  # ── 20b. F1 — `--install` REPAIRS a recycled pid, and it did not ────────────────────────────────
  # `loop_pid()` answers LIVENESS only: a pidfile holding a recycled pid (a lane, the controller, a
  # supervisor) is TRUTHY while `pid_is_our_loop` says it is not the loop. Gating the spawn on
  # `if not pid:` therefore started nothing in exactly the state the pre-fix `else:` repaired — and
  # `--install` is the verb `cloud-cell-bringup.sh --check` runs and `die`s on, so the box was left
  # with no scheduler at all. Case 4b pins this state for `--verify` and case 13 for `--start`;
  # NOTHING drove `--install`, which is why the suite was green over it.
  rm -f "$ST20/OFF"   # §20a's --stop recorded a decision; --install refuses to reverse it (by design)
  sleep 60 & bystander20=$!; echo "$bystander20" >> "$T/pids"
  printf '%s\n' "$bystander20" > "$ST20/loop.pid"
  out="$(s20 --install)"; rc=$?
  [ "$rc" -eq 0 ] \
    && ok "20b F1: --install REPAIRS a recycled pid in loop.pid (it used to start nothing and fail)" \
    || bad "20b F1: --install failed over a recycled pid (rc=$rc) — the box is left unscheduled: $out"
  pid20d="$(cat "$ST20/loop.pid" 2>/dev/null)"
  [ -n "$pid20d" ] && [ "$pid20d" != "$bystander20" ] \
    && ok "20b F1: loop.pid now names a DIFFERENT pid than the recycled one" \
    || bad "20b F1: loop.pid still holds the recycled pid ($pid20d)"
  # ⛔ THIS IDENTITY READ IS PORTABLE ON PURPOSE. `/proc/<pid>/cmdline` is Linux-only, and this file's
  # two pre-existing reads are already AT their counted budget (`scripts/portability-baseline.tsv`:
  # `scripts/fleet-schedule.test.sh procfs-macos-absent 2`), so a third would RAISE the ratchet — the
  # one direction `scripts/check-portability-traps.sh` refuses (`live > baseline`, exit 1). `ps` is
  # that gate's own named replacement, and it answers the same question on BOTH hosts — so this arm
  # now also ASSERTS on macOS instead of silently skipping there. `-ww` is load-bearing: BSD `ps`
  # truncates `args` to the screen width, and the state dir path is long enough to lose `--loop`
  # (the same reason `ci_runner_pool.sh:771` uses it).
  args20d="$(ps -ww -o args= -p "$pid20d" 2>/dev/null)"
  if [ -n "$args20d" ]; then
    grep -q -- '--loop' <<<"$args20d" \
      && ok "20b F1: the pid it recorded really is fleet-schedule --loop" \
      || bad "20b F1: the recorded pid is not a scheduler: $args20d"
  else
    skip "20b F1: no readable command line for pid $pid20d on this platform"
  fi
  kill -0 "$bystander20" 2>/dev/null \
    && ok "20b F1: the unrelated process was NOT signalled (a repair is not a kill)" \
    || bad "20b F1: --install killed the process that owned the recycled pid"
  kill "$bystander20" 2>/dev/null

  # ── 20c. F2 — staleness must be read from the pid the GATE grades, not only the pidfile ────────
  # `--verify` falls back to the identity-verified box lock when `loop.pid` is absent (a state this
  # file documents as reachable: a failed pidfile write leaves the previous file, 19ad removes it),
  # and 19ad/19q pin that state for the POINTER and the OFF switch. Nothing crossed it with §20, so
  # `--start` read only the pidfile — saw no loop — restarted NOTHING, and answered 0 over a stale
  # loop while `--verify` printed "restart it: --start". A named remedy that no-ops.
  s20 --install >/dev/null 2>&1               # a fresh, CURRENT loop
  pid20e="$(cat "$ST20/loop.pid" 2>/dev/null)"
  kill -0 "$pid20e" 2>/dev/null \
    && ok "20c F2 baseline: a real loop is live before the pidfile is removed (the arm grades something)" \
    || bad "20c F2 baseline: no live loop — this arm would grade an empty state"
  printf '\n# refreshed again — the running process still holds the previous module\n' \
    >> "$S20/fleet-schedule.py"
  rm -f "$ST20/loop.pid"                     # …and its pidfile is gone (the ENOSPC / 19ad state)
  out="$(s20 --verify)"; rc=$?
  [ "$rc" -eq 1 ] && grep -q 'THE FILE WAS REFRESHED AND THE PROCESS WAS NOT' <<<"$out" \
    && ok "20c F2 setup: --verify fails stale with NO pidfile (it grades the box-lock holder)" \
    || bad "20c F2 setup: --verify did not read the stale holder without a pidfile (rc=$rc): $out"
  out="$(s20 --start)"; rc=$?
  [ "$rc" -eq 0 ] && ok "20c F2: --start over a stale, pidfile-less own holder exits 0" \
                  || bad "20c F2: --start exited $rc: $out"
  grep -q 'restarting the loop so the file on disk is the code that runs' <<<"$out" \
    && ok "20c F2: ⛔ --start RESTARTED it — the remedy --verify named is no longer a no-op" \
    || bad "20c F2: --start answered with nothing / 'already running' over a stale loop (the named remedy no-ops): $out"
  pid20f="$(cat "$ST20/loop.pid" 2>/dev/null)"
  [ -n "$pid20f" ] && [ "$pid20f" != "$pid20e" ] \
    && ok "20c F2: the pid actually changed (a restart is an act, not a message)" \
    || bad "20c F2: no new loop was started (pid $pid20e -> $pid20f)"
  out="$(s20 --verify)"; rc=$?
  [ "$rc" -eq 0 ] && ok "20c F2: and the same --verify then passes" \
                  || bad "20c F2: --verify still refuses after the restart (rc=$rc): $out"

  # ── 20d. F2 (foreign holder) — this home cannot restart another home's loop, so it must SAY so ──
  # On a two-home box the box's scheduler belongs to whichever state dir holds the lock (#2890).
  # `--start` correctly refuses to spawn a competitor — but it used to do so silently about the ONE
  # thing the operator was told to do (`--verify` rebinds to the holder and fails `stale`), leaving
  # them with a repair instruction and no home to run it in. The exit code must stay 0 (the box IS
  # scheduled and `cloud-cell-supervisor.sh` keys on it) and the stamp must be read from the HOLDER.
  ST20B="$T/st20b-state"; mkdir -p "$ST20B"
  s20b() { env -u INFRA_ROOT -u AGENT_INFRA_PATH TEMPLATES_DIR="$GOOD" FLEET_SCHEDULE_STATE="$ST20B" \
               FLEET_SCHEDULE_LOCK_ROOT="$T/st20-box-lock" \
               python3 "$S20/fleet-schedule.py" "$@" 2>&1; }
  s20 --stop >/dev/null 2>&1               # home A must own NO loop before B can hold the box
  s20b --install >/dev/null 2>&1           # home B's loop takes the box lock
  sleep 1
  kill -0 "$(cat "$ST20B/loop.pid" 2>/dev/null)" 2>/dev/null \
    && ok "20d baseline: home B's loop holds the box (the arm grades a REAL foreign holder)" \
    || bad "20d baseline: home B's loop never came up, so the foreign-holder arm grades nothing"
  printf '\n# and B is refreshed out from under its loop\n' >> "$S20/fleet-schedule.py"
  out="$(s20 --start)"; rc=$?
  [ "$rc" -eq 0 ] \
    && ok "20d a foreign holder still exits 0 from this home (the box is scheduled — the supervisor keys on it)" \
    || bad "20d --start exited $rc over a foreign holder: $out"
  grep -q 'STALE' <<<"$out" \
    && ok "20d ⛔ the FOREIGN holder's staleness is REPORTED, not silent" \
    || bad "20d --start said nothing about a foreign holder running an older build: $out"
  grep -q "FLEET_SCHEDULE_STATE=$ST20B" <<<"$out" \
    && ok "20d the remedy names the HOME that can actually restart it" \
    || bad "20d the message does not name the holder's state dir: $out"
  grep -q 'restarting the loop' <<<"$out" \
    && bad "20d this home restarted ANOTHER home's loop (it must not move the box's scheduler): $out" \
    || ok "20d this home did not restart the foreign loop"
  s20b --stop >/dev/null 2>&1

  # ── 20e. ROUND-2 F1 — a pidfile naming ANOTHER home's live loop is not a title deed ──────────────
  # `pid_is_our_loop` proves only "a fleet-schedule --loop": EVERY loop on the box satisfies it, so a
  # `loop.pid` holding a RECYCLED pid that landed on a foreign home's loop (the #3029 hazard; a state
  # dir restored from another home reaches it too) resolved to a pid this verb does not own. The new
  # stale branch then graded it against THIS dir's stamp (unstamped BY CONSTRUCTION — a false
  # statement about a loop that stamped correctly at home), SIGTERMed it and spawned a successor from
  # here, silently MOVING the box's scheduler. Pre-fix `--install` printed `loop already running` and
  # let `cmd_verify` rebind to the holder and grade the real loop; nothing was signalled. The box
  # lock is the ownership fact.
  rm -f "$ST20/OFF" "$ST20B/OFF"      # both stops above recorded a decision; --install honours it
  s20b --install >/dev/null 2>&1                  # B (re)takes the box
  printf '\n# and the loop at B predates this refresh\n' >> "$S20/fleet-schedule.py"   # → B is STALE
  sleep 1
  pid20B="$(cat "$ST20B/loop.pid" 2>/dev/null)"
  kill -0 "$pid20B" 2>/dev/null \
    && ok "20e baseline: B's loop really holds the box and is stale (the arm cannot pass vacuously)" \
    || bad "20e baseline: B's loop is not live — the ownership arm would grade nothing"
  printf '%s\n' "$pid20B" > "$ST20/loop.pid"      # this home's pidfile names B's LIVE loop
  out="$(s20 --install)"; rc=$?
  [ "$rc" -eq 1 ] && grep -q 'THE FILE WAS REFRESHED AND THE PROCESS WAS NOT' <<<"$out" \
    && ok "20e --install reports the foreign holder's staleness (via cmd_verify, which rebinds to it)" \
    || bad "20e --install did not report the stale foreign holder (rc=$rc): $out"
  grep -q 'restarting the loop' <<<"$out" \
    && bad "20e ⛔ this home TORE DOWN another home's loop and re-homed the box's scheduler: $out" \
    || ok "20e ⛔ it did NOT terminate a loop it does not own (no re-homing under #2890)"
  grep -q "FLEET_SCHEDULE_STATE=$ST20B" <<<"$out" \
    && ok "20e the message names the home that must act" \
    || bad "20e the message does not name the owning home: $out"
  kill -0 "$pid20B" 2>/dev/null \
    && ok "20e the foreign loop SURVIVED (it was never signalled)" \
    || bad "20e --install SIGTERMed another state dir's live loop"
  [ "$(cat "$ST20B/loop.pid" 2>/dev/null)" = "$pid20B" ] \
    && ok "20e the box's scheduler was not moved to this home" \
    || bad "20e the box's scheduler was re-homed (B's pidfile now reads '$(cat "$ST20B/loop.pid" 2>&1)')"
  s20b --stop >/dev/null 2>&1

  # ── 20f. ROUND-2 F2 — a restart must re-record the declaration pointer ────────────────────────
  # The successor inherits the CALLER's `TEMPLATES_DIR`. A pointer written only by the pre-restart
  # arm then names a set the running loop does NOT read (19al/19ap's measured state: "pointer tplA ->
  # tplB while loop.log still start-named tplA"), and a later bare-env `--start` — the supervisor's
  # revival, which is why the pointer is load-bearing — resurrects a loop over the wrong set.
  # `cmd_start` records on `started`; `--install` did not.
  rm -f "$ST20/OFF"
  s20 --install >/dev/null 2>&1                     # a current loop, and its pointer is correct
  printf '\n# refreshed once more for the pointer arm\n' >> "$S20/fleet-schedule.py"
  printf '%s\n' "$T/a-decoy-templates-dir" > "$ST20/templates-dir"   # a set nothing runs
  out="$(s20 --install)"; rc=$?
  [ "$rc" -eq 0 ] && ok "20f --install restarts a stale loop and still exits 0" \
                  || bad "20f --install exited $rc over a stale loop: $out"
  [ "$(cat "$ST20/templates-dir" 2>/dev/null)" = "$GOOD" ] \
    && ok "20f ⛔ the restart RE-RECORDED the pointer to the set the successor actually runs" \
    || bad "20f the pointer still names a set nothing runs ('$(cat "$ST20/templates-dir" 2>&1)') — a later bare-env --start revives the wrong set"
  s20 --stop >/dev/null 2>&1
fi


echo
echo "───────────────────────────────────────────────────────────────"
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
