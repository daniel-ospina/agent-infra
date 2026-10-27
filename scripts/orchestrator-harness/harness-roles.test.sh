#!/usr/bin/env bash
# harness-roles.test.sh — the proofs behind ONE installable/healable/dispatchable unit, on both OSes.
#
# Every assertion drives the SHIPPED `scripts/orchestrator-harness/harness-roles.sh` (sourced) and the
# SHIPPED `scripts/harness-up` (for the verb surface). A re-implementation of any check would pass on a
# broken copy, which is the defect these suites exist against.
#
# WHAT IS PROVEN, and why each one is RED on the tree that shipped before it (2026-10-25: the merge
# role was installed and never started, a unit pointed at a /tmp cwd died every ten minutes, and
# `status` read "installed" as if it were "ok"):
#
#   (A) `up` INSTALLS EXACTLY THE ROLES THE CONFIG NAMES, and nothing else. The roster comes from the
#       box's own `$O/harness-roles.conf`; a role the config does not name is never installed, however
#       available it is on the platform.
#   (B) `up` TWICE IS A NO-OP. A role already RUNNING is left alone — its installer is NOT re-run
#       (re-running one can cycle a live unit, and `up` must be safe to run twice).
#   (C) A ROLE WHOSE WORKING DIRECTORY DOES NOT EXIST REFUSES, AND WRITES NOTHING — for the WHOLE
#       roster, before the first provider runs. This is the `/tmp`-cwd death made un-installable: the
#       refusal names the role, the directory and the variable. MUTATION: delete the `[ -d "$cwd" ]`
#       check ⇒ this assertion reddens (driven below, on a mutant copy).
#   (D) `status` ON A FAILED UNIT PRINTS THE UNIT'S OWN ERROR LINE and never prints a healthy state.
#       MUTATION: make the reader trust the unit file (FragmentPath non-empty ⇒ RUNNING) ⇒ reddens.
#   (E) `heal` RE-DRIVES a dead role and REPORTS AN UNFIXABLE ONE as NOT HEALED, non-zero — and a
#       DANGLING unit (its target reaped) is NOT "restarted", because restarting it cannot work.
#   (F) A ROLE THIS PLATFORM HAS NO UNIT FOR is SKIPPED with a reason and is NOT rendered healthy.
#
# Hermetic: throwaway HOME/O, stubbed systemctl/journalctl/launchctl/providers, no sudo, no real
# units, no network. bash 3.2 compatible (the fleet's Macs run 3.2.57); no `timeout` (macOS has none).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="$HERE/harness-roles.sh"
UP="$HERE/../../scripts/harness-up"
fails=0
assertions=0
ck() { # <name> <0|1>
  assertions=$((assertions + 1))
  if [ "$2" -eq 0 ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}
has()   { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
lacks() { case "$1" in *"$2"*) return 1 ;; *) return 0 ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/harness-roles.XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; TOOLS="$TMP/tools"; UNITS="$TMP/units"; O="$TMP/orch"; REPO="$TMP/repo"
mkdir -p "$BIN" "$TOOLS" "$UNITS" "$O" "$REPO" "$TMP/home"

# ── the stubs ────────────────────────────────────────────────────────────────────────────────────
# The service manager is a STATE MACHINE, not a canned answer: each test seeds what the unit's own
# record says (fragment / ActiveState / Result / exit), and the provider stubs may CHANGE it — that
# is what makes (B) "the second run is a no-op" a measurement rather than a claim.
cat > "$BIN/systemctl" <<'SH'
#!/usr/bin/env bash
# systemctl show -p FragmentPath -p ActiveState -p Result -p ExecMainStatus <unit>
unit=""
for a in "$@"; do case "$a" in -*) : ;; *) unit="$a" ;; esac; done
[ -f "$UNITS/$unit.frag" ]   || exit 0            # no fragment: systemd does not have the unit
echo "FragmentPath=$(cat "$UNITS/$unit.frag")"
echo "ActiveState=$(cat "$UNITS/$unit.active" 2>/dev/null || echo inactive)"
echo "Result=$(cat "$UNITS/$unit.result" 2>/dev/null || echo success)"
echo "ExecMainStatus=$(cat "$UNITS/$unit.exit" 2>/dev/null || echo 0)"
SH
cat > "$BIN/journalctl" <<'SH'
#!/usr/bin/env bash
cat "$JOURNAL" 2>/dev/null || true
SH
cat > "$BIN/launchctl" <<'SH'
#!/usr/bin/env bash
# launchctl print gui/<uid>/<label>
label="${2##*/}"
[ -f "$UNITS/$label.loaded" ] || exit 1
echo "	state = $(cat "$UNITS/$label.state" 2>/dev/null || echo not running)"
echo "	last exit status = $(cat "$UNITS/$label.exit" 2>/dev/null || echo 0)"
SH
chmod +x "$BIN/systemctl" "$BIN/journalctl" "$BIN/launchctl"
export JOURNAL="$TMP/journal.txt"

# The role programs the preflight resolves (a role's binary must exist to be installable at all).
for b in orch-loop.sh harness-apply-pass.sh watchdog-loop.sh objective-reminder.sh cloud-cell-doctor.sh admin-merge.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TOOLS/$b"
done
chmod +x "$TOOLS"/*

# Provider / starter stubs. Each RECORDS the invocation (the whole point of (A)/(B)/(C)) and, when
# told to, moves the role's measured state — so `heal` is judged by a re-read, not by an exit code.
mkprov() { # <name> [activate-unit]
  cat > "$BIN/$1" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$1" "\$*" >> "\$PROVIDER_LOG"
${2:+printf '/etc/systemd/system/%s\n' "$2" > "\$UNITS/$2.frag"; printf 'active\n' > "\$UNITS/$2.active"; }
exit 0
SH
  chmod +x "$BIN/$1"
}
export PROVIDER_LOG="$TMP/provider.log"; : > "$PROVIDER_LOG"
mkprov prov-apply eldato-harness-apply.timer
mkprov prov-watchdog eldato-controller-watchdog.timer
mkprov prov-controller
mkprov start-controller eldato-orchestrator.service

# ── the harness under test ───────────────────────────────────────────────────────────────────────
# Sourced with the seams pointed at the fixture. `HR_MODULE_UNDER_TEST` lets the mutation arms swap in
# a copy of the SHIPPED module with one guard removed — a mutation that reddens a test proves the test
# is measuring the guard and not the fixture.
MODULE_UNDER_TEST="${HR_MODULE_UNDER_TEST:-$MODULE}"
load() { # <module path> -> sources it with the fixture's seams
  # shellcheck source=/dev/null
  . "${1:-$MODULE_UNDER_TEST}"
  HR_TOOLS_DIR="$TOOLS"; O="$O"; REPO="$REPO"   # exported through the environment below
}
export HR_TOOLS_DIR="$TOOLS" O REPO UNITS SYSTEMCTL="$BIN/systemctl" JOURNALCTL="$BIN/journalctl"
export LAUNCHCTL="$BIN/launchctl" SYSTEMD_UNIT_DIR="$UNITS" LAUNCH_AGENT_DIR="$TMP/la"
export HOME="$TMP/home" HARNESS_UP_OS=Linux HR_DOCTOR_STALE_S=5400
mkdir -p "$TMP/la"
export HARNESS_ROLE_PROVIDER_APPLY="$BIN/prov-apply --install"
export HARNESS_ROLE_PROVIDER_WATCHDOG="$BIN/prov-watchdog --install"
export HARNESS_ROLE_PROVIDER_CONTROLLER="$BIN/prov-controller --install"
export HARNESS_ROLE_START_CONTROLLER="$BIN/start-controller --install"
# shellcheck source=/dev/null
. "$MODULE_UNDER_TEST"
ck "the module defines the shipped interface (hr_status/hr_preflight/hr_heal/hr_dispatch)" \
   "$(declare -f hr_status >/dev/null && declare -f hr_preflight >/dev/null && declare -f hr_heal >/dev/null && declare -f hr_dispatch >/dev/null && echo 0 || echo 1)"

# ── (A) exactly the roles the config names ───────────────────────────────────────────────────────
# The roster is the box's OWN FILE (not the default), so the assertion covers "the config names" as
# the brief words it.
printf '# only these two\napply\nwatchdog\n' > "$O/harness-roles.conf"
: > "$PROVIDER_LOG"
rm -f "$UNITS"/*.frag "$UNITS"/*.active
a_out="$(hr_install_roster 2>&1)"; a_rc=$?
ck "(A) up installs the roles the CONFIG names (apply, watchdog)" \
   "$(has "$(cat "$PROVIDER_LOG")" "prov-apply" && has "$(cat "$PROVIDER_LOG")" "prov-watchdog" && echo 0 || echo 1)"
ck "(A) …and installs NOTHING ELSE (no controller, no reminder, no doctor provider ran)" \
   "$(lacks "$(cat "$PROVIDER_LOG")" "prov-controller" && echo 0 || echo 1)"
ck "(A) the roster it read is the file's, not the platform default" \
   "$(has "$a_out" "configured (HR_ROLES / \$O/harness-roles.conf / platform default): apply watchdog" && echo 0 || echo 1)"
ck "(A) a successful install is not a failure exit" "$([ "$a_rc" -eq 0 ] && echo 0 || echo 1)"
# ⛔ "INSTALLED" IS NOT THE ASSERTION — "it now RUNS" is. The providers above behave like a real
# installer (`enable --now`), and the check re-READS the unit state rather than trusting what the
# installer printed.
ck "(A) …and after the install the roles are MEASURED RUNNING (installed is not started)" \
   "$(hr_role_state apply >/dev/null 2>&1 && hr_role_state watchdog >/dev/null 2>&1 && echo 0 || echo 1)"

# ── (B) idempotent: the second run is a no-op ───────────────────────────────────────────────────
for u in eldato-harness-apply.timer eldato-controller-watchdog.timer; do
  printf '/etc/systemd/system/%s\n' "$u" > "$UNITS/$u.frag"; printf 'active\n' > "$UNITS/$u.active"
done
: > "$PROVIDER_LOG"
hr_install_roster >/dev/null 2>&1
ck "(B) a second up re-runs NO installer for a role already running" \
   "$([ ! -s "$PROVIDER_LOG" ] && echo 0 || echo 1)"
ck "(B) …and it says so, per role" \
   "$(has "$(hr_install_roster 2>&1)" "CURRENT     already running" && echo 0 || echo 1)"

# ── (C) a configured cwd that does not exist REFUSES, and writes nothing ────────────────────────
# REPO is the CONTROLLER's working directory: the /tmp-cwd shape is a checkout that was reaped, so the
# unit's cwd no longer exists while the unit (and its installer) are still there.
printf 'apply\ncontroller\n' > "$O/harness-roles.conf"
: > "$PROVIDER_LOG"
c_out="$(REPO="$TMP/gone-checkout" HR_ROLES="apply controller" hr_preflight apply controller 2>&1)"; c_rc=$?
ck "(C) a role whose working directory is gone REFUSES (rc non-zero)" "$([ "$c_rc" -ne 0 ] && echo 0 || echo 1)"
ck "(C) …naming the role, the directory and the variable" \
   "$(has "$c_out" "REFUSED controller" && has "$c_out" "$TMP/gone-checkout" && has "$c_out" "DOES NOT EXIST" && has "$c_out" "REPO" && echo 0 || echo 1)"
# The all-or-nothing half: `up` preflights the WHOLE roster before running the first provider, so a
# bad entry cannot leave a half-installed roster behind.
c_up="$(REPO="$TMP/gone-checkout" hr_install_roster 2>&1)"; c_up_rc=$?
ck "(C) up refuses and writes NOTHING when any configured role is un-installable" \
   "$([ "$c_up_rc" -ne 0 ] && [ ! -s "$PROVIDER_LOG" ] && echo 0 || echo 1)"
ck "(C) …and the refusal names it rather than reporting a partial success" \
   "$(has "$c_up" "NOTHING was written or started" && echo 0 || echo 1)"
# MUTATION: remove the guard BLOCK (not just its header line — a half-removed guard does not parse,
# and a mutant that cannot run proves nothing) ⇒ the refusal disappears.
cat > "$TMP/mk-mut-c.py" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
start = s.index('    [ -d "$cwd" ] || {')
end = s.index('    if hr_role_needs_rail "$role"; then')
open(dst, 'w').write(s[:start] + s[end:])
PY
cat > "$TMP/run-mut-c.sh" <<'SH'
#!/usr/bin/env bash
set -u
. "$HR_MODULE_UNDER_TEST"
: > "$PROVIDER_LOG"
hr_preflight controller >/dev/null 2>&1; echo "preflight-rc=$?"
SH
chmod +x "$TMP/run-mut-c.sh"
python3 "$TMP/mk-mut-c.py" "$MODULE" "$TMP/mut-c.sh"
c_mut="$(REPO="$TMP/gone-checkout" HR_MODULE_UNDER_TEST="$TMP/mut-c.sh" bash "$TMP/run-mut-c.sh" 2>&1)"
ck "(C) MUTATION: with the cwd check removed the refusal DISAPPEARS (so (C) measures the guard)" \
   "$(has "$c_mut" "preflight-rc=0" && echo 0 || echo 1)"
# …and the OTHER half of the same refusal: a role whose PROGRAM is not on this box.
c_bin="$(HR_TOOLS_DIR="$TMP/nothing-here" HR_ROOT="$TMP/nothing-here" hr_preflight reminder 2>&1)"; c_bin_rc=$?
ck "(C) a role whose BINARY is missing REFUSES too (a unit exec-ing nothing cannot start)" \
   "$([ "$c_bin_rc" -ne 0 ] && has "$c_bin" "REFUSED reminder" && has "$c_bin" "objective-reminder.sh" && echo 0 || echo 1)"

# ── (D) status on a FAILED unit prints the error line, and never says ok ─────────────────────────
printf 'eldato-objective-reminder.timer: Failed to start: No such file or directory\n' > "$JOURNAL"
printf '/etc/systemd/system/eldato-objective-reminder.timer\n' > "$UNITS/eldato-objective-reminder.timer.frag"
printf 'failed\n' > "$UNITS/eldato-objective-reminder.timer.active"
printf 'exit-code\n' > "$UNITS/eldato-objective-reminder.timer.result"
printf '1\n'      > "$UNITS/eldato-objective-reminder.timer.exit"
d_out="$(HR_ROLES=reminder hr_status 2>&1)"; d_rc=$?
ck "(D) a failed unit reports FAILED, not a healthy state" \
   "$(has "$d_out" "FAILED" && lacks "$d_out" "RUNNING" && echo 0 || echo 1)"
ck "(D) …and prints the unit's OWN last error line" \
   "$(has "$d_out" "No such file or directory" && echo 0 || echo 1)"
ck "(D) …and the verdict is not a pass" "$([ "$d_rc" -ne 0 ] && echo 0 || echo 1)"
# MUTATION: make the reader trust the unit file (a fragment exists ⇒ RUNNING) ⇒ (D) must redden.
python3 - "$MODULE" "$TMP/mut-d.sh" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
needle = '  case "$act" in\n    active)\n'
assert needle in s, "anchor not found"
s = s.replace(needle, '  act=active\n' + needle, 1)
open(dst, 'w').write(s)
PY
cat > "$TMP/run-mut-d.sh" <<'SH'
#!/usr/bin/env bash
set -u
. "$HR_MODULE_UNDER_TEST"
HR_ROLES=reminder hr_status
SH
chmod +x "$TMP/run-mut-d.sh"
d_mut="$(HR_MODULE_UNDER_TEST="$TMP/mut-d.sh" bash "$TMP/run-mut-d.sh" 2>&1)"
ck "(D) MUTATION: a reader that trusts the unit file prints RUNNING ⇒ (D) reddens" \
   "$(has "$d_mut" "RUNNING" && lacks "$d_mut" "FAILED" && echo 0 || echo 1)"

# ── (E) heal re-drives a dead role, and reports an unfixable one as unfixable ───────────────────
# (E1) DEAD + a starter that actually brings it up ⇒ HEALED, exit 0.
printf '/etc/systemd/system/eldato-orchestrator.service\n' > "$UNITS/eldato-orchestrator.service.frag"
printf 'inactive\n' > "$UNITS/eldato-orchestrator.service.active"
e1_out="$(HR_ROLES=controller hr_heal 2>&1)"; e1_rc=$?
ck "(E) heal re-drives a DEAD role and says HEALED" \
   "$(has "$e1_out" "HEALED" && [ "$e1_rc" -eq 0 ] && echo 0 || echo 1)"
ck "(E) …and the verdict is the RE-READ (the state file moved), not the starter's exit code" \
   "$([ "$(cat "$UNITS/eldato-orchestrator.service.active")" = active ] && echo 0 || echo 1)"
# (E2) DANGLING: the unit's own script was reaped. Restarting cannot fix it, so heal must NOT claim to.
printf '/etc/systemd/system/eldato-controller-watchdog.timer\n' > "$UNITS/eldato-controller-watchdog.timer.frag"
printf 'inactive\n' > "$UNITS/eldato-controller-watchdog.timer.active"
e2_unit="$UNITS/eldato-controller-watchdog.timer"
printf 'ExecStart=/bin/bash %s/vanished-watchdog.sh\n' "$TMP" > "$e2_unit"
e2_out="$(HR_ROLES=watchdog hr_heal 2>&1)"; e2_rc=$?
ck "(E) heal reports a DANGLING unit as NOT HEALED, non-zero" \
   "$(has "$e2_out" "NOT HEALED" && has "$e2_out" "vanished-watchdog.sh" && [ "$e2_rc" -ne 0 ] && echo 0 || echo 1)"
ck "(E) …and does not run a starter for something a restart cannot fix" \
   "$(lacks "$e2_out" "re-driving" && echo 0 || echo 1)"
# (E3) a role that cannot be READ is reported, never repaired by guesswork.
rm -f "$UNITS"/*.frag "$UNITS"/*.active
export SYSTEMCTL="$TMP/bin/no-such-systemctl"
e3_out="$(HR_ROLES=controller hr_heal 2>&1)"
export SYSTEMCTL="$BIN/systemctl"
ck "(E) an unreadable state is NOT HEALED by guesswork" \
   "$(has "$e3_out" "NEVER-INSTALLED" && echo 0 || echo 1)"

# ── (F) a role with no unit on this platform is SKIPPED with a reason, never healthy ────────────
f_out="$(HARNESS_UP_OS=Darwin HR_ROLES=doctor hr_status 2>&1)"
ck "(F) the doctor on macOS is SKIPPED with a reason (not RUNNING, not OK)" \
   "$(has "$f_out" "SKIPPED" && has "$f_out" "no macOS unit exists" && echo 0 || echo 1)"
f_rc=$?
ck "(F) …and a skip is a PASS for the verdict (a Mac is not broken for having no cell doctor)" \
   "$([ "$f_rc" -eq 0 ] && echo 0 || echo 1)"

# ── dispatch: one role, once, in the foreground ────────────────────────────────────────────────
cat > "$TMP/bin/disp-doctor" <<'SH'
#!/usr/bin/env bash
printf 'dispatched:%s\n' "$*"
exit 0
SH
chmod +x "$TMP/bin/disp-doctor"
disp_out="$(HARNESS_ROLE_DISPATCH_DOCTOR="$TMP/bin/disp-doctor" hr_dispatch doctor merge 2>&1)"; disp_rc=$?
ck "dispatch runs ONE role in the foreground and passes its own pass name" \
   "$([ "$disp_rc" -eq 0 ] && has "$disp_out" "dispatched:merge" && echo 0 || echo 1)"

# ── the verb surface of the ONE entry point ─────────────────────────────────────────────────────
ck "harness-up --help names the five verbs (up/status/heal/logs/dispatch)" \
   "$(bash "$UP" --help 2>&1 | tr '\n' ' ' | { read -r h; for v in heal logs dispatch; do has "$h" "harness-up $v" || exit 1; done; exit 0; } && echo 0 || echo 1)"
ck "harness-up refuses 'dispatch' with no role instead of dispatching nothing" \
   "$(bash "$UP" dispatch >/dev/null 2>&1; [ $? -eq 2 ] && echo 0 || echo 1)"
ck "harness-up refuses an UNKNOWN role by name (known roles are listed)" \
   "$(bash "$UP" logs not-a-role 2>&1 | grep -q 'unknown role' && echo 0 || echo 1)"
ck "harness-up parses on bash 3.2 (the fleet's Macs)" "$(bash -n "$UP" >/dev/null 2>&1 && echo 0 || echo 1)"
ck "harness-roles.sh parses on bash 3.2" "$(bash -n "$MODULE" >/dev/null 2>&1 && echo 0 || echo 1)"

printf '\n%s assertions, %s failed\n' "$assertions" "$fails"
[ "$fails" -eq 0 ] || exit 1
exit 0
