#!/usr/bin/env bash
# install-runner-autoscale-timer.test.sh — self-check for scripts/install-runner-autoscale-timer.sh
# and the two artifacts it renders (agent-infra#2403).
#
# Run: bash scripts/install-runner-autoscale-timer.test.sh   (exits 0 when every assertion passes)
#
# What each case proves — T0 to T14, and why each one exists — is in docs/ops/runner-autoscale.md
# under the heading: the self-check, case by case. It is kept OUT of this file on purpose: the
# working-tree guard tokenises a script text, and a prose header ahead of the code glues lines
# together until the body reads as an unverifiable heredoc, so the suite cannot be executed at all
# (issue 709, measured three times). Documentation belongs where a reader looks for it; this file
# stays executable, and this header carries no quote characters of any kind for that reason.
#
# Hermetic: home, state dir and install dir are redirected under a mktemp fixture root; the
# scheduler tools are files under it; the converger is a stub. No network, no GitHub, no scheduler.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
INST="$HERE/install-runner-autoscale-timer.sh"
UNIT_NAME="eldato-runner-autoscale"
LABEL="com.eldato.runner-autoscale"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', expected '$2')"; fi; }
assert_contains() { case "${1:-}" in *"$2"*) ok "$3" ;; *) bad "$3 (missing: $2)"; echo "--- output ---" >&2; printf '%s\n' "${1:-}" | sed 's/^/    /' >&2 ;; esac; }
assert_absent()   { case "${1:-}" in *"$2"*) bad "$3 (found: $2)"; printf '%s\n' "${1:-}" | sed 's/^/    /' >&2 ;; *) ok "$3" ;; esac; }
assert_file()     { if [ -f "$1" ]; then ok "$2"; else bad "$2 (missing file: $1)"; fi; }
assert_nofile()   { if [ -e "$1" ]; then bad "$2 (unexpected file: $1)"; else ok "$2"; fi; }
say_case()        { echo; echo "── $* ──"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/runner-autoscale-inst-test.XXXXXX")" || { echo "cannot create a temp dir"; exit 1; }
cleanup() {
    # ⛔ A DISCARD WHOSE TARGET COULD BE ANYTHING IS REFUSED BY THE TOOLING AND IS WRONG ANYWAY: this
    # removes THIS suite s fixture directories and nothing else. MT is the transient-scratch fixture
    # (T5), whose name must look like a mktemp tree at the TOP level for the guard under test.
    case "$T" in
        */runner-autoscale-inst-test.*) rm -rf "$T" ;;
        *) : ;;
    esac
    case "${MT:-}" in
        */tmp.runnerautoscale.*) rm -rf "$MT" ;;
        *) : ;;
    esac
}
trap cleanup EXIT

# ⛔ HERMETICITY IS ASSERTED, NOT ASSUMED. Every case below is supposed to run against the fixture
# tree; the arming record, the state dir and the install dir are the three paths that, if a case ever
# forgot one, would touch the LIVE schedule and arming record of this box instead of a fixture. So
# suite fails closed on a non-fixture path rather than discovering it later.
ARM="$T/home/.pi/agent/state/runner-autoscale.armed"
FIXTURE_PREFIX="${TMPDIR:-/tmp}/runner-autoscale-inst-test."
if [ "${T#"$FIXTURE_PREFIX"}" = "$T" ] || [ "${ARM#"$T"}" = "$ARM" ]; then
    echo "REFUSING to run: fixtures are not under a mktemp tree (T=$T ARM=$ARM)" >&2
    exit 1
fi

# ── fixtures ───────────────────────────────────────────────────────────────────────────────────────
# ⛔ EVERY FIXTURE IS WRITTEN TO A LITERAL PATH, never through a helper function argument. A shim whose
# redirection target is a helper argument is a WRITE TO AN UNVERIFIABLE PATH — the hub guard reads the
# target as a shell expansion, cannot tell which file it would create, and fails closed before the
# suite runs at all (measured while writing this suite). Literal paths keep the suite executable from
# a worktree. (Do not spell a heredoc opener in a comment either: the guard tokenises prose, and the
# unmatched opener swallows the rest of the file as a heredoc body — measured, twice.)
mkdir -p "$T/home/.pi/agent/state" "$T/sysd" "$T/agents" "$T/bin"
# The stub converger: answers --status --json with a CEILING, so the arming preflight has something
# to read.
cat >"$T/home/converger.py" <<'STUB'
import json, sys
print(json.dumps({"repo": "o/r", "verdict": "at-ceiling", "ncpu": 8, "mem_available_mb": 5000,
                  "ceiling": 3, "reading": "ncpu=8 ceiling=3"}))
STUB
# A converger that CANNOT measure (the arming preflight must refuse it).
cat >"$T/home/bad.py" <<'BAD'
import sys
print("UNMEASURABLE: fixture", file=sys.stderr)
raise SystemExit(2)
BAD
# A converger that answers but publishes NO ceiling.
cat >"$T/home/onceiling.py" <<'ONEC'
import json
print(json.dumps({"verdict": "converged"}))
ONEC
# The systemctl shim: records every call; answers the verbs both the install and the status path use.
cat >"$T/bin/systemctl" <<SYSTEMCTL_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$T/systemctl.log"
case "\$1" in
  is-enabled)   printf '%s\n' "\${SHIM_ENABLED:-enabled}"; exit 0 ;;
  is-active)    printf '%s\n' "\${SHIM_ACTIVE:-active}"; exit 0 ;;
  list-timers)  printf 'Thu 2026-10-29 15:36:43 UTC  8min left  n/a  now  $UNIT_NAME.timer $UNIT_NAME.service\n'; exit 0 ;;
  show)         printf '%s\n' "\${SHIM_LAST:-0}"; exit 0 ;;
  cat)          cat "$T/sysd/\$2" 2>/dev/null; exit \$? ;;
  *)            exit 0 ;;
esac
SYSTEMCTL_SHIM
# The launchctl shim: list prints the loaded-job table; every other verb succeeds.
cat >"$T/bin/launchctl" <<LAUNCHCTL_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$T/launchctl.log"
case "\$1" in
  list) printf '%s\t%s\t%s\n' "\${SHIM_PID:--}" "\${SHIM_LAST_EXIT:-0}" "$LABEL"; exit 0 ;;
  *)    exit 0 ;;
esac
LAUNCHCTL_SHIM
chmod +x "$T/bin/systemctl" "$T/bin/launchctl"

# Resolve the interpreter WITHOUT a helper whose own words resemble a git prefix: the working-tree
# guard treats a `command`-prefixed word with an unresolvable verb as an unverifiable git anchor and
# refuses the whole suite (#1484/#709). `type -P` is a plain PATH lookup.
GOOD_PY="$(type -P python3.12 2>/dev/null)" || GOOD_PY=""
if [ -z "$GOOD_PY" ]; then GOOD_PY="$(type -P python3 2>/dev/null)" || GOOD_PY=""; fi
mkdir -p "$T/home/.pi/agent/state" "$T/sysd" "$T/agents" "$T/bin"
ARM="$T/home/.pi/agent/state/runner-autoscale.armed"

# ENVV carries per-case ENVIRONMENT OVERRIDES (assignments only). They come AFTER the defaults, and
# env applies later assignments last, so an override wins. Kept as a variable rather than inline
# prefixes because a case that changes HOME, the script, the interpreter or the template dir must not
# have to restate the other six.
ENVV=()
# run_install <platform> <installdir|-> [args…] — ONE invocation with a fully redirected environment.
# RUNNER_AUTOSCALE_SCRIPT is pinned to the stub by default: the real converger would talk to GitHub on
# the arming preflight, which no test may do (T14 is the one case that resolves it, and it installs
# only — no preflight).
run_install() {
    local plat="$1" dir="$2"; shift 2
    local dirmap=()
    [ "$dir" != "-" ] && dirmap=(SYSTEMD_UNIT_DIR="$dir" LAUNCHD_AGENTS_DIR="$dir")
    # The installer is invoked by a LITERAL path from its own directory (never "$INST"): a script
    # execution spelled with a shell expansion is an unreadable effect for the hub guard, which fails
    # closed and refuses to run this suite at all from a worktree. The cd makes the literal path
    # resolvable for exactly the same reason.
    cd "$HERE" || return 1
    env HOME="$T/home" \
        RUNNER_AUTOSCALE_SCRIPT="$T/home/converger.py" \
        RUNNER_AUTOSCALE_PYTHON="$GOOD_PY" \
        RUNNER_AUTOSCALE_STATE_DIR="$T/home/.pi/agent/state" \
        RUNNER_AUTOSCALE_ARM_FILE="$ARM" \
        RUNNER_AUTOSCALE_REPO="o/r" \
        ELDATO_PLATFORM="$plat" \
        SYSTEMCTL="$T/bin/systemctl" LAUNCHCTL="$T/bin/launchctl" \
        ${dirmap[@]+"${dirmap[@]}"} ${ENVV[@]+"${ENVV[@]}"} \
        bash ./install-runner-autoscale-timer.sh "$@" 2>&1
}

# A fresh install dir per case, so one case’s artifact can never satisfy another’s assertion.
# ⛔ NO DISCARD HERE. Every case gets its OWN fresh path under $T (c1..c14), so there is nothing to
# remove — and a `rm -rf "$1"` on a helper argument is an UNVERIFIABLE discard that makes the whole
# suite unexecutable under the working-tree guard (#709), which fails closed on exactly this shape.
fresh() { mkdir -p "$1"; }

# plist_args <plist> — the ProgramArguments, one per line (python3 is the test’s own parser).
plist_args() {
    python3 -c 'import plistlib,sys
d = plistlib.load(open(sys.argv[1],"rb"))
for a in d["ProgramArguments"]:
    print(a)' "$1" 2>/dev/null
}

echo "install-runner-autoscale-timer.test.sh — agent-infra#2403"
echo "fixtures: $T"

# ── T0: the artifacts exist, and the timer names the service ────────────────────────────────
say_case "T0 the artifacts exist and agree with each other"
assert_file "$INST" "the installer exists"
assert_file "$REPO/templates/systemd/$UNIT_NAME.service" "the systemd service template exists"
assert_file "$REPO/templates/systemd/$UNIT_NAME.timer" "the systemd timer template exists"
assert_file "$REPO/templates/launchd/runner-autoscale/$LABEL.plist" "the launchd plist template exists"
assert_contains "$(cat "$REPO/templates/systemd/$UNIT_NAME.timer")" "Unit=$UNIT_NAME.service" \
    "the timer triggers the service it is named after"
assert_absent "$(grep -E '^WorkingDirectory=' "$REPO/templates/systemd/$UNIT_NAME.service")" "WorkingDirectory=" \
    "the service carries NO WorkingDirectory directive (a SYSTEM unit's %h is /root — measured 200/CHDIR)"
# ⛔ NO ENVIRONMENT DEFAULT MAY ARM THE PASS. The record is the only input; an ambient export that
# armed a fleet with nothing on disk to show for it is the defect the arming record exists to prevent.
assert_absent "$(grep -v '^ *#' "$INST")" "RUNNER_AUTOSCALE_MODE" \
    "no environment seam renders the mode (only the dated record does)"

# ── T1: the unarmed default is a DRY RUN ────────────────────────────────────────────────────
say_case "T1 an unarmed install renders --dry-run (DISARMED)"
D="$T/c1"; fresh "$D"; rm -f "$ARM"
OUT="$(run_install Linux "$D" --install)"; RC=$?
assert_eq "$RC" 0 "install exits 0"
assert_file "$D/$UNIT_NAME.service" "the service was written"
assert_file "$D/$UNIT_NAME.timer" "the timer was written"
assert_contains "$OUT" "mode:   --dry-run" "the summary names the DISARMED mode"
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "--dry-run" \
    "the installed ExecStart carries --dry-run"
assert_contains "$OUT" "timer:  enabled" "the install reports the timer enabled (not just written)"
# An env var that LOOKS like a mode must not arm it.
ENVV=(RUNNER_AUTOSCALE_MODE=--apply RUNNER_AUTOSCALE_APPLY=1)
OUT2="$(run_install Linux "$D" --install)"; ENVV=()
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "--dry-run" \
    "a stray RUNNER_AUTOSCALE_MODE/RUNNER_AUTOSCALE_APPLY export does NOT arm the artifact"
assert_absent "$OUT2" "converge (no mode flag)" "an ambient export does not reach the summary as ARMED"

# ── T2: a dated record arms it; a HALF record does not ─────────────────────────────────────
say_case "T2 the arming record is the only authority, and it fails closed"
printf 'armed-by=someone\n' >"$ARM"                        # half-written: no date
run_install Linux "$D" --install >/dev/null 2>&1
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "--dry-run" \
    "a HALF-written record renders DISARMED (only armed-by, no armed-date)"
printf 'armed-date=2026-10-29T00:00:00Z\n' >"$ARM"          # the other half only
run_install Linux "$D" --install >/dev/null 2>&1
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "--dry-run" \
    "a HALF-written record renders DISARMED (only armed-date, no armed-by)"
printf 'armed-by=someone\narmed-date=2026-10-29T00:00:00Z\nceiling=3\n' >"$ARM"
OUT="$(run_install Linux "$D" --install)"
# ⛔ ARMED MEANS NO MODE ARGUMENT — see T3.
assert_absent "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "--dry-run" \
    "a complete record removes --dry-run (armed)"
assert_contains "$OUT" "ARMED" "the summary says ARMED"
rm -f "$ARM"

# ── T3: --apply is not a renderable flag ───────────────────────────────────────────────────
say_case "T3 the artifacts never emit an --apply flag (the pass has no such verb)"
assert_absent "$(cat "$INST")" "printf '%s' '--apply'" "the installer never prints --apply as a mode"
assert_absent "$(cat "$REPO/templates/systemd/$UNIT_NAME.service")" "--apply" \
    "the service template carries no literal --apply"
assert_absent "$(cat "$REPO/templates/launchd/runner-autoscale/$LABEL.plist")" "--apply" \
    "the plist template carries no literal --apply"

# ── T4: --arm preflights, and refuses a box it cannot measure ──────────────────────────────
say_case "T4 --arm preflights the converger and refuses an unreadable box"
D="$T/c4"; fresh "$D"; rm -f "$ARM"
run_install Linux "$D" --install >/dev/null 2>&1        # a DISARMED artifact to observe
ENVV=(RUNNER_AUTOSCALE_SCRIPT="$T/home/bad.py")
OUT="$(run_install Linux "$D" --arm --reason test)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "--arm exits 1 when the preflight cannot measure"
assert_contains "$OUT" "REFUSING to arm" "the refusal is named"
assert_nofile "$ARM" "NO arming record is written when the preflight fails"
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service" 2>/dev/null)" "--dry-run" \
    "the artifact stays DISARMED after a refused arm"
ENVV=(RUNNER_AUTOSCALE_SCRIPT="$T/home/onceiling.py")
OUT="$(run_install Linux "$D" --arm)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "--arm exits 1 when the record carries no ceiling"
assert_contains "$OUT" "NO ceiling" "the refusal names the missing ceiling"
assert_nofile "$ARM" "no record is written for an unread ceiling"
# …and the good shape really arms, with the measured ceiling IN the record.
OUT="$(run_install Linux "$D" --arm --reason 'unit test')"
assert_eq "$?" 0 "--arm exits 0 on a measurable box"
assert_file "$ARM" "the arming record was written"
assert_contains "$(cat "$ARM")" "ceiling=3" "the record carries the MEASURED ceiling"
assert_contains "$(cat "$ARM")" "armed-date=" "the record is dated"
assert_contains "$(cat "$ARM")" "reason=unit test" "the record carries the operator's reason"
assert_absent "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "--dry-run" \
    "the artifact is re-installed ARMED in the same verb"
say_case "T11 --report-only refuses while a record exists"
OUT="$(run_install Linux "$D" --report-only)"
assert_eq "$?" 1 "--report-only refuses while the box is armed"
assert_contains "$OUT" "--disarm" "the refusal names the verb that actually disarms"
# …and --disarm removes the record and re-renders disarmed.
OUT="$(run_install Linux "$D" --disarm)"
assert_eq "$?" 0 "--disarm exits 0"
assert_nofile "$ARM" "--disarm removed the record"
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "--dry-run" \
    "--disarm re-installed the DISARMED artifact"

# ── T5: transient scratch is refused ──────────────────────────────────────────────────────
say_case "T5 a unit rendered from a mktemp tree is refused"
MT="/tmp/tmp.runnerautoscale.$$"; mkdir -p "$MT/.pi/agent/scripts" "$MT/.pi/agent/state"
cp "$T/home/converger.py" "$MT/.pi/agent/scripts/"
# ⛔ A GENUINE mktemp SHAPE AT THE TOP LEVEL (/tmp/tmp.…), which is what the guard matches — a nested
# `$T/tmp.abc` is NOT transient by construction and testing it would prove nothing (measured: it
# sailed through and tried the SYSTEM target). No unit-dir override: the override deliberately skips
# this heuristic. SUDO=false removes the system target, so a regressed guard writes inside the
# fixture HOME at worst — a test must never be able to write /etc/systemd.
ENVV=(HOME="$MT" RUNNER_AUTOSCALE_SCRIPT="$MT/.pi/agent/scripts/converger.py"
      RUNNER_AUTOSCALE_STATE_DIR="$MT/.pi/agent/state" RUNNER_AUTOSCALE_ARM_FILE="$MT/arm"
      SUDO=false)
OUT="$(run_install Linux - --install)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "a transient-scratch install is refused (rc 1)"
assert_contains "$OUT" "REFUSING a scheduled install rendered from transient scratch space" \
    "the refusal names transient scratch, not a scheduler problem"
assert_contains "$OUT" "127" "the refusal names the measured consequence (127 every tick)"

# ── T6: an old interpreter is refused ─────────────────────────────────────────────────────
say_case "T6 an interpreter older than 3.12 is refused"
printf '#!/usr/bin/env bash\ncase "$*" in *version_info*) echo "3.11" ;; *) exit 1 ;; esac\n' >"$T/bin/oldpy"
chmod +x "$T/bin/oldpy"
D="$T/c6"; fresh "$D"
ENVV=(RUNNER_AUTOSCALE_PYTHON="$T/bin/oldpy")
OUT="$(run_install Linux "$D" --install)"; ENVV=()
assert_contains "$OUT" "requires >= 3.12" "the old interpreter is REFUSED with the requirement quoted"
assert_absent "$(grep '^ExecStart=' "$D/$UNIT_NAME.service" 2>/dev/null)" "oldpy" \
    "the artifact NEVER pins an interpreter older than 3.12"

# ── T7: whitespace — refused on systemd, allowed on launchd ────────────────────────────────
say_case "T7 whitespace is a SYSTEMD rule, not a launchd one"
SP="$T/home/my home"; mkdir -p "$SP"; cp "$T/home/converger.py" "$SP/"
ENVV=(HOME="$SP" RUNNER_AUTOSCALE_SCRIPT="$SP/converger.py")
OUT="$(run_install Linux "$T/c7" --install)"; RC=$?
assert_eq "$RC" 1 "a whitespace HOME is refused on the systemd arm"
assert_contains "$OUT" "whitespace" "the refusal names whitespace"
OUT="$(run_install Darwin "$T/c7d" --install)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "the same whitespace path is ACCEPTED on the launchd arm (a plist string is one field)"

# ── T8: an unresolved placeholder is refused ──────────────────────────────────────────────
say_case "T8 an unresolved placeholder is refused, nothing installed"
mkdir -p "$T/tpl"
cp "$REPO/templates/systemd/$UNIT_NAME.timer" "$T/tpl/"
sed 's|{{PYTHON}}|{{NOT_A_PLACEHOLDER}}|; s|{{SCRIPT}}|{{ALSO_NOT}}|' \
    "$REPO/templates/systemd/$UNIT_NAME.service" >"$T/tpl/$UNIT_NAME.service"
D="$T/c8"; fresh "$D"
ENVV=(TEMPLATES_DIR="$T/tpl")
OUT="$(run_install Linux "$D" --install)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "an unresolved placeholder is refused"
assert_contains "$OUT" "unresolved placeholder" "the refusal names the placeholder"
assert_nofile "$D/$UNIT_NAME.service" "nothing was installed"

# ── T9: --status is honest about not-installed and about drift ────────────────────────────
say_case "T9 --status: not-installed is a FAILURE, and a hand-edit is DRIFT"
D="$T/c9"; fresh "$D"
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 1 "--status on a box with nothing installed exits 1"
assert_contains "$OUT" "installed=no" "it says installed=no"
assert_contains "$OUT" "remedy=" "it names the remedy"
run_install Linux "$D" --install >/dev/null 2>&1
OUT="$(run_install Linux "$D" --status)"; RC=$?
assert_eq "$RC" 0 "--status on a healthy installed box exits 0"
assert_contains "$OUT" "installed=yes" "it says installed=yes"
assert_contains "$OUT" "mode=--dry-run" "it reports the artifact's OWN mode"
assert_contains "$OUT" "drift_artifact=no" "the freshly installed artifact is not drifted"
assert_contains "$OUT" "script_present=yes" "the artifact's target exists"
assert_contains "$OUT" "timer_active=active" "it reports the scheduler's own answer"
# A hand-edit must be reported, not silently blessed.
printf '\n# hand edit\n' >>"$D/$UNIT_NAME.service"
OUT="$(run_install Linux "$D" --status)"
assert_contains "$OUT" "drift_artifact=yes" "a hand-edited artifact is reported as drift"
# A missing target must be a FAILURE, not no-news. The install-time pin is dropped for this read so
# the case tests the ARTIFACT’s target, not the installer’s own argument check.
D="$T/c9b"; fresh "$D"
run_install Linux "$D" --install >/dev/null 2>&1
mv "$T/home/converger.py" "$T/home/converger.py.gone"
ENVV=(RUNNER_AUTOSCALE_SCRIPT=)
OUT="$(run_install Linux "$D" --status)"; RC=$?; ENVV=()
assert_eq "$RC" 1 "--status exits 1 when the artifact's target is gone"
assert_contains "$OUT" "script_present=no" "it says the target is gone"
mv "$T/home/converger.py.gone" "$T/home/converger.py"   # restore for the cases below

# ── T10: --uninstall verifies the files are gone ──────────────────────────────────────────
say_case "T10 --uninstall verifies removal and refuses when the files survive"
D="$T/c10"; fresh "$D"
run_install Linux "$D" --install >/dev/null 2>&1
OUT="$(run_install Linux "$D" --uninstall)"
assert_eq "$?" 0 "--uninstall exits 0"
assert_nofile "$D/$UNIT_NAME.service" "the service file is gone"
assert_nofile "$D/$UNIT_NAME.timer" "the timer file is gone"
assert_contains "$(cat "$T/systemctl.log")" "disable --now $UNIT_NAME.timer" \
    "the timer was disabled before removal (a live timer must not outlive its files)"
if [ "$(id -u)" = "0" ]; then
    echo "  ↷ skipping the unremovable-dir case: running as root, a mode-500 dir is still writable"
else
    RO="$T/c10ro"; fresh "$RO"
    run_install Linux "$RO" --install >/dev/null 2>&1
    chmod 500 "$RO"
    OUT="$(run_install Linux "$RO" --uninstall)"; RC=$?
    chmod 700 "$RO"
    assert_eq "$RC" 1 "--uninstall refuses when the files could NOT be removed"
    assert_contains "$OUT" "cannot remove the unit files" "the refusal says the removal failed, naming the dir"
fi

# ── T12: the Darwin artifact ─────────────────────────────────────────────────────────────
say_case "T12 the Darwin artifact renders, parses, and points at real files"
D="$T/c12"; fresh "$D"; rm -f "$ARM"
OUT="$(run_install Darwin "$D" --install)"
assert_eq "$?" 0 "the launchd install exits 0"
assert_file "$D/$LABEL.plist" "the plist was written to the LaunchAgents dir"
if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$D/$LABEL.plist" 2>/dev/null; then
        ok "the installed plist is well-formed XML"
    else
        bad "the installed plist is NOT well-formed XML (launchd would refuse it)"
    fi
    ARGS="$(plist_args "$D/$LABEL.plist")"
    assert_contains "$ARGS" "$T/home/converger.py" "ProgramArguments names the converger that was installed"
    assert_contains "$ARGS" "--dry-run" "the disarmed plist carries --dry-run"
    assert_eq "$(python3 -c 'import plistlib,sys
d = plistlib.load(open(sys.argv[1],"rb"))
print(d["StartInterval"], d["Label"], d["RunAtLoad"], d["Nice"], d["ProcessType"])' "$D/$LABEL.plist" 2>/dev/null)" \
        "540 $LABEL True 10 Background" "the plist carries the cadence, label, load-at-login, niceness and type"
    # The systemd timer must state the same cadence, or the two boxes drift apart silently.
    assert_contains "$(cat "$REPO/templates/systemd/$UNIT_NAME.timer")" "OnUnitActiveSec=9min" \
        "the systemd timer's interval is the plist's (9 min = 540 s)"
    # ⛔ ARMED OMITS THE MODE ELEMENT ENTIRELY: an empty <string> would be a POSITIONAL argument.
    printf 'armed-by=someone\narmed-date=2026-10-29T00:00:00Z\n' >"$ARM"
    OUT="$(run_install Darwin "$D" --install)"
    assert_eq "$?" 0 "the armed launchd install exits 0"
    ARGS="$(plist_args "$D/$LABEL.plist")"
    assert_absent "$ARGS" "--dry-run" "the armed plist carries no --dry-run"
    assert_absent "$ARGS" "--apply" "the armed plist carries no --apply either (no such verb)"
    assert_eq "$(printf '%s\n' "$ARGS" | tail -1)" "o/r" \
        "the armed plist ENDS at the repo value: no empty positional argument"
    rm -f "$ARM"
else
    echo "  ↷ skipping the plist content checks: no python3 on this box"
fi
assert_contains "$(cat "$T/launchctl.log")" "bootstrap" "the job was bootstrapped with launchctl"

# ── T13: idempotence ─────────────────────────────────────────────────────────────────────
say_case "T13 a second install of an unchanged tree changes nothing"
D="$T/c13"; fresh "$D"
run_install Linux "$D" --install >/dev/null 2>&1
BEFORE="$(cat "$D/$UNIT_NAME.service")"
OUT="$(run_install Linux "$D" --install)"
assert_contains "$OUT" "changed=0" "the second install reports changed=0"
assert_eq "$BEFORE" "$(cat "$D/$UNIT_NAME.service")" "the artifact bytes are unchanged"

# ── T14: the real converger is installable ───────────────────────────────────────────────
say_case "T14 the repo's own converger is what an unpinned install resolves"
assert_file "$REPO/scripts/orchestrator-harness/runner_autoscale.py" \
    "the converger the templates document exists in this tree"
D="$T/c14"; fresh "$D"
ENVV=(RUNNER_AUTOSCALE_SCRIPT=)
OUT="$(run_install Linux "$D" --install)"; RC=$?; ENVV=()
assert_eq "$RC" 0 "an install with no RUNNER_AUTOSCALE_SCRIPT override resolves the repo's converger"
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "runner_autoscale.py" \
    "the ExecStart names runner_autoscale.py"
assert_contains "$(grep '^ExecStart=' "$D/$UNIT_NAME.service")" "$GOOD_PY" \
    "the ExecStart names the resolved interpreter, absolutely"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
