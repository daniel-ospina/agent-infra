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


echo
echo "───────────────────────────────────────────────────────────────"
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
