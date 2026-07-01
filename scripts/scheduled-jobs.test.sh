#!/usr/bin/env bash
# scripts/scheduled-jobs.test.sh — the ONE installer/controller's proof (agent-infra#2048).
#
# THE FIVE REQUIREMENTS, AS ASSERTIONS (nothing below is satisfied by prose):
#   S1  ONE declaration, BOTH platforms: `install` on Linux writes a systemd unit+timer; on Darwin a
#       launchd plist bootstrapped into the domain — from the SAME record, with the same script/args
#   S2  `install` is ONE command for the WHOLE set: the managed record is installed by this command
#       and the unmanaged one is DELEGATED to its named owner in the same run
#   S3  IDEMPOTENT: a second install changes nothing and reloads nothing
#   S4  ARMING IS VISIBLE (#1678): the shipped stance renders the report-only flag INTO the artifact;
#       `--apply` arms; `status` reads the arming off the INSTALLED artifact; `--report-only` reverts
#   S5  `start|stop|restart` act on the SET — every declared unit/label, not one hardcoded job
#   S6  A NON-ZERO EXIT OR AN ABSENT UNIT IS A FAILURE, NEVER OK — `status` is non-zero for absent,
#       non-zero for failed, and `install` ends by running the parity gate
#   S7  a changed SCRIPT reloads its job (#1738): an edit is inert until the job is reloaded
#   S8  impossible states are LOUD: `--only` naming an undeclared id, a missing owner installer, no
#       scheduler at all, a temp HOME on Darwin (#446), an unknown verb
#   S9  `uninstall` removes only what this command installed, and `status` then fails
#   S10 THE PORTABILITY SHIM IS USED BY EVERY COMPONENT: every shell entry point in the declaration
#       sources lib/portable.sh and carries no GNU-only spelling in EXECUTED code — and the population
#       is non-empty and derived from the declaration (so a new component cannot escape the check)
#   S11 `--preview` writes nothing
#   S12 the rendered artifacts carry no placeholder and no SuccessExitStatus that would mask a failure
#
# Hermetic: throwaway HOME/state/farm/unit/agent dirs, shim `systemctl`/`launchctl`, a fake owner
# installer, and a fixture declaration. Nothing here touches the real scheduler.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INST="$HERE/scheduled-jobs.sh"
ROOT="$(cd "$HERE/.." && pwd)"
REAL_DECL="$ROOT/config/scheduled-jobs.declaration"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: '$1', want: '$2')"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_absent()   { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }
assert_file()     { if [ -f "$1" ]; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
assert_nofile()   { if [ -f "$1" ]; then bad "$2 (present: $1)"; else ok "$2"; fi; }
count_in()        { printf '%s\n' "$1" | grep -cF -- "$2"; }

[ -f "$INST" ] || { echo "FATAL: $INST missing — this suite tests the installer, and there is none"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/sj-inst-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/farm" "$T/state" "$T/bin" "$T/owners"

# ── fixtures ───────────────────────────────────────────────────────────────────────────────────
mk_script() { printf '#!/usr/bin/env bash\necho "%s $*"\nexit 0\n' "$1" >"$T/farm/$1"; chmod +x "$T/farm/$1"; }
mk_script alpha.sh
mk_script beta.sh

# systemctl shim: a real active-state file, so "installed" and "active" stay two facts.
cat >"$T/bin/systemctl" <<'SC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SC_LOG:-/dev/null}"
state="${SC_STATE:-/nonexistent}"
case "${1:-}" in
  is-active)  grep -qxF "$2" "$state" 2>/dev/null && { echo active; exit 0; }; echo inactive; exit 3 ;;
  is-enabled) echo "${SC_ENABLED:-enabled}"; [ "${SC_ENABLED:-enabled}" = "enabled" ] && exit 0; exit 1 ;;
  show)       [ "${SC_SHOW_RC:-0}" = "0" ] || exit "${SC_SHOW_RC}"
              [ "${SC_SHOW_EMPTY:-0}" = "1" ] && exit 0
              echo "${SC_EXIT:-0}"; exit 0 ;;
  enable|start|restart|daemon-reload)
              case "${1:-}" in enable) printf '%s\n' "$3" >>"$state" ;; esac
              exit 0 ;;
  disable)
              grep -vxF "$3" "$state" >"$state.n" 2>/dev/null; mv -f "$state.n" "$state" 2>/dev/null; exit 0 ;;
  stop)       exit 0 ;;
  --version)  echo "systemd 255"; exit 0 ;;
esac
exit 0
SC
chmod +x "$T/bin/systemctl"

# launchctl shim: loaded-state is a file; bootstrap takes the plist path and records its label.
cat >"$T/bin/launchctl" <<'LC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LC_LOG:-/dev/null}"
state="${LC_STATE:-/nonexistent}"
case "${1:-}" in
  print)      lbl="${2##*/}"; grep -qxF "$lbl" "$state" 2>/dev/null || exit 1
              printf '\tstate = running\n\tlast exit code = %s\n' "${LC_EXIT:-0}"; exit 0 ;;
  list)       printf 'PID\tStatus\tLabel\n'
              [ -f "$state" ] && while IFS= read -r l; do [ -n "$l" ] && printf -- '-\t0\t%s\n' "$l"; done <"$state"; exit 0 ;;
  bootstrap)  p="${3:-}"; [ -f "$p" ] || exit 1; basename "$p" .plist >>"$state"; exit 0 ;;
  bootout)    lbl="${2##*/}"; grep -vxF "$lbl" "$state" >"$state.n" 2>/dev/null; mv -f "$state.n" "$state" 2>/dev/null; exit 0 ;;
  enable|kickstart) exit 0 ;;
esac
exit 0
LC
chmod +x "$T/bin/launchctl"
# ── the #446 HOME comparison, made DETERMINISTIC on every host (#2048) ─────────────────────────
# The guard reads the real home from `dscl`, which is macOS-only: on a Linux runner it cannot answer, so
# the guard refuses one step EARLIER ("could not be determined") and the temp-HOME comparison below was
# never exercised there — a guard with the comparison deleted outright still passed this suite (measured
# by a fresh-context review). Shimming `dscl` in the fixture's own bin dir makes the same arm run on
# every host, so S8/S11 assert the comparison itself. The unmeasurable arm keeps its own dedicated case
# further down (`$T/bin-nodscl`), so neither branch is inferred from the other.
cat >"$T/bin/dscl" <<'DSCL'
#!/usr/bin/env bash
# `dscl . -read /Users/<user> NFSHomeDirectory` — a fixed, non-temp answer, so a $HOME under $T can
# only be refused by the COMPARISON.
printf 'NFSHomeDirectory: /Users/a-real-user\n'
DSCL
chmod +x "$T/bin/dscl"

# ── the THIRD scheduler, made DETERMINISTIC on every host (#2071) ──────────────────────────────
# `install` ends with the parity gate, and the gate reads the crontab population as a third surface.
# `crontab` is NOT installed on every host (measured: absent on a stock macOS dev box, rc=127), and an
# unreadable surface is correctly a FAILURE — so without a shim this suite's whole install path fails
# with `verdict=UNMEASURABLE` on any box that lacks the binary, and the suites above (S1/S3/S6) go red
# for a reason that has nothing to do with what they assert. An empty crontab is a real measurement here;
# the cron arm of the gate has its own coverage in check-scheduled-parity.test.sh.
cat >"$T/bin/crontab" <<'CRON'
#!/usr/bin/env bash
# `crontab -l` with no crontab for this user: rc=1 is "no crontab", which the library reads as an
# EMPTY surface (not an unreadable one). Any other invocation is refused loudly so a test cannot
# silently install a real cron entry.
case "${1:-}" in
  -l) exit 1 ;;
  *)  echo "crontab shim: refusing '$*' — this suite installs no real cron entries" >&2; exit 2 ;;
esac
CRON
chmod +x "$T/bin/crontab"

# The fake owner installer for the `managed=no` record: writes the artifact the way its real owner
# would, so the closing parity gate has something true to compare against.
cat >"$T/owners/owner-fixture.sh" <<'OWN'
#!/usr/bin/env bash
set -uo pipefail
touch "${OWNER_MARKER:-/dev/null}"
plat="${PORTABLE_PLATFORM:-linux}"
case "$plat" in
  linux)
    mkdir -p "${SJ_SYSTEMD_UNIT_DIR:-/nonexistent}"
    printf '[Unit]\nDescription=fixture beta\n' >"${SJ_SYSTEMD_UNIT_DIR}/eldato-beta.service"
    printf '[Timer]\nOnUnitActiveSec=3600s\n' >"${SJ_SYSTEMD_UNIT_DIR}/eldato-beta.timer"
    printf 'eldato-beta.timer\n' >>"${SC_STATE:-/dev/null}"
    ;;
  darwin)
    mkdir -p "${SJ_LAUNCHD_DIR:-/nonexistent}"
    cat >"${SJ_LAUNCHD_DIR}/com.eldato.beta.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>com.eldato.beta</string>
<key>StartInterval</key><integer>3600</integer></dict></plist>
P
    printf 'com.eldato.beta\n' >>"${LC_STATE:-/dev/null}"
    ;;
esac
exit 0
OWN
chmod +x "$T/owners/owner-fixture.sh"

mk_decl() { # mk_decl <path> <owner>
    cat >"$1" <<D
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

job beta
  description=fixture beta
  platforms=linux,darwin
  schedule=3600s
  script=beta.sh
  runner=bash
  managed=no
  owner=$2
  label=com.eldato.beta
  unit=eldato-beta
D
}
DECL="$T/decl"; mk_decl "$DECL" owner-fixture.sh

run_lin() { # run_lin <args...>
    HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=linux \
    SJ_DECLARATION="$DECL" SJ_UNMANAGED_REGISTER="$T/none.register" SJ_FARM="$T/farm" \
    SJ_STATE_DIR="$T/state-lin" SJ_OWNER_DIR="$T/owners" \
    SJ_SYSTEMD_UNIT_DIR="$T/units" SJ_SYSTEMCTL="$T/bin/systemctl" \
    SC_STATE="$T/active" SC_LOG="$T/sc.log" OWNER_MARKER="$T/owner-ran-lin" \
    bash "$INST" "$@"
}
run_mac() { # run_mac <args...>
    HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=darwin \
    SJ_DECLARATION="$DECL" SJ_UNMANAGED_REGISTER="$T/none.register" SJ_FARM="$T/farm" \
    SJ_STATE_DIR="$T/state-mac" SJ_OWNER_DIR="$T/owners" \
    SJ_LAUNCHD_DIR="$T/agents" SJ_LAUNCHCTL="$T/bin/launchctl" \
    SJ_LAUNCHD_DOMAIN="gui/999" ELDATO_ALLOW_TEST_HOME=1 \
    LC_STATE="$T/loaded" LC_LOG="$T/lc.log" OWNER_MARKER="$T/owner-ran-mac" \
    bash "$INST" "$@"
}

fresh_all() {
    rm -rf "$T/units" "$T/agents"; mkdir -p "$T/units" "$T/agents"
    : >"$T/active"; : >"$T/loaded"; : >"$T/sc.log"; : >"$T/lc.log"
    rm -f "$T/owner-ran-lin" "$T/owner-ran-mac"
    rm -rf "$T/state-lin" "$T/state-mac"
}

echo "── S1/S2 install is ONE command for the WHOLE set, on BOTH platforms ──"
fresh_all
OUT="$(run_lin install 2>&1)"; RC=$?
assert_eq "$RC" "0" "S1 a full Linux install succeeds (and its closing parity gate agrees)"
assert_file "$T/units/eldato-alpha.service" "S1 the managed record becomes a systemd service"
assert_file "$T/units/eldato-alpha.timer"   "S1 …with a timer"
assert_contains "$(cat "$T/units/eldato-alpha.service")" "$T/farm/alpha.sh" "S1 the unit runs the DECLARED script"
assert_contains "$(cat "$T/units/eldato-alpha.service")" 'FIXTURE_VAR=hello' "S1 the record's env is rendered in"
assert_contains "$(cat "$T/units/eldato-alpha.timer")" 'OnUnitActiveSec=900s' "S1 the declared interval is the timer's"
assert_eq "$(count_in "$(cat "$T/sc.log")" 'enable --now eldato-alpha.timer')" "1" "S1 the timer is enabled+started"
# S2: the unmanaged record was DELEGATED, not skipped and not rendered here.
assert_file "$T/owner-ran-lin" "S2 install DELEGATES the managed=no record to its named owner"
assert_file "$T/units/eldato-beta.timer" "S2 …and the whole set is present after ONE command"
assert_contains "$OUT" "delegated beta" "S2 …and says so"
assert_eq "$(count_in "$OUT" 'owned by')" "0" "S2 …as a delegation, never as a skip"

OUT="$(run_mac install 2>&1)"; RC=$?
assert_eq "$RC" "0" "S1 a full Darwin install succeeds (and its closing parity gate agrees)"
assert_file "$T/agents/com.eldato.alpha.plist" "S1 the SAME record becomes a launchd plist"
assert_contains "$(cat "$T/agents/com.eldato.alpha.plist")" "$T/farm/alpha.sh" "S1 …running the same declared script"
assert_contains "$(cat "$T/loaded")" "com.eldato.alpha" "S1 …and it is bootstrapped into the domain"
assert_file "$T/owner-ran-mac" "S2 the unmanaged record is delegated on Darwin too"

echo "── S3 IDEMPOTENT: a second install changes and reloads NOTHING ──"
BOOT_BEFORE="$(count_in "$(cat "$T/lc.log")" 'bootstrap')"
OUT="$(run_mac install 2>&1)"; RC=$?
assert_eq "$RC" "0" "S3 the second Darwin install succeeds"
assert_contains "$OUT" "installed alpha: scheduler=launchd label=com.eldato.alpha changed=0" "S3 changed=0"
assert_contains "$OUT" "reload_reason=none" "S3 …and nothing was reloaded"
assert_eq "$(count_in "$(cat "$T/lc.log")" 'bootstrap')" "$BOOT_BEFORE" "S3 no extra bootstrap was issued"
OUT="$(run_lin install 2>&1)"
assert_contains "$OUT" "changed=0" "S3 the second Linux install is a no-op too"

echo "── S4 ARMING is visible in the ARTIFACT (#1678) ──"
assert_contains "$(cat "$T/units/eldato-alpha.service")" '--dry-run' "S4 the shipped stance is report-only, IN the unit"
assert_absent   "$(cat "$T/units/eldato-alpha.service")" '--apply' "S4 …and nothing is armed by default"
OUT="$(run_lin install --apply 2>&1)"
assert_contains "$(cat "$T/units/eldato-alpha.service")" '--apply' "S4 --apply renders the armed flag INTO the unit"
assert_absent   "$(cat "$T/units/eldato-alpha.service")" '--dry-run' "S4 …replacing the report-only flag"
OUT="$(run_lin status 2>&1)"
assert_contains "$OUT" "armed=apply" "S4 status reads the arming off the INSTALLED artifact"
run_lin install --report-only >/dev/null 2>&1
assert_contains "$(cat "$T/units/eldato-alpha.service")" '--dry-run' "S4 --report-only reverts, one copy, no drift"
OUT="$(run_mac install --apply 2>&1)"
assert_contains "$(cat "$T/agents/com.eldato.alpha.plist")" '--apply' "S4 the plist carries the arming too"
assert_contains "$OUT" "armed=apply" "S4 …and the install output says which stance landed"
run_mac install --report-only >/dev/null 2>&1

echo "── S5 start|stop|restart act on the SET ──"
: >"$T/sc.log"
run_lin stop >/dev/null 2>&1
assert_eq "$(count_in "$(cat "$T/sc.log")" 'stop eldato-alpha.timer')" "1" "S5 stop reaches the managed unit"
assert_eq "$(count_in "$(cat "$T/sc.log")" 'stop eldato-beta.timer')"  "1" "S5 …and the DELEGATED one — the verb acts on the set"
: >"$T/sc.log"
run_lin restart >/dev/null 2>&1
assert_eq "$(count_in "$(cat "$T/sc.log")" 'restart eldato-alpha.timer')" "1" "S5 restart reaches both"
assert_eq "$(count_in "$(cat "$T/sc.log")" 'restart eldato-beta.timer')"  "1" "S5 …restart on the set"
: >"$T/lc.log"
run_mac stop >/dev/null 2>&1
assert_eq "$(count_in "$(cat "$T/lc.log")" 'bootout gui/999/com.eldato.alpha')" "1" "S5 stop boots out the Darwin job"
assert_eq "$(count_in "$(cat "$T/lc.log")" 'bootout gui/999/com.eldato.beta')"  "1" "S5 …for every declared label"
run_mac install >/dev/null 2>&1   # restore

echo "── S6 a non-zero exit or an ABSENT unit is a FAILURE, never OK ──"
OUT="$(run_lin status 2>&1)"; RC=$?
assert_eq "$RC" "0" "S6 a healthy set reports success"
assert_contains "$OUT" "verdict=OK platform=linux" "S6 …with an explicit verdict"
rm -f "$T/units/eldato-alpha.timer"
OUT="$(run_lin status 2>&1)"; RC=$?
assert_eq "$RC" "1" "S6 an ABSENT unit makes status exit non-zero"
assert_contains "$OUT" "verdict=ABSENT" "S6 …and names it ABSENT"
run_lin install >/dev/null 2>&1
OUT="$(SC_EXIT=7 run_lin status 2>&1)"; RC=$?
assert_eq "$RC" "1" "S6 a NON-ZERO last exit makes status exit non-zero"
assert_contains "$OUT" "verdict=FAILED" "S6 …and names it FAILED"
assert_contains "$OUT" "last_exit=7" "S6 …publishing the code it read"
# An absent Darwin job is a failure on that platform too.
rm -f "$T/agents/com.eldato.alpha.plist"
OUT="$(run_mac status 2>&1)"; RC=$?
assert_eq "$RC" "1" "S6 an absent launchd job fails on Darwin"
run_mac install >/dev/null 2>&1
# …and install itself cannot pass while the host disagrees with the declaration.
rm -f "$T/agents/com.eldato.alpha.plist"; : >"$T/loaded"
OUT="$(run_mac install 2>&1)"; RC=$?
assert_eq "$RC" "0" "S6 install REPAIRS a missing artifact (it re-renders and bootstraps)"
run_mac uninstall >/dev/null 2>&1
# A job that is DECLARED, uninstalled and now only registered nowhere: parity must fail the install.
OUT="$(run_lin install --only alpha 2>&1; echo "rc=$?")"
assert_contains "$OUT" "rc=0" "S6 a single-record install of a healthy record passes"

echo "── S6b an INSTALLED-but-inert job is a FAILURE, and an unreadable last exit is UNKNOWN ──"
# ⛔ `enabled=disabled` used to read as healthy: the unit existed, so `installed=yes` and the verdict
# was OK — over a job systemd will never start. The unit file proves the ARTIFACT, not the ACTIVITY.
OUT="$(SC_ENABLED=disabled run_lin status 2>&1)"; RC=$?
assert_eq "$RC" "1" "S6b a DISABLED timer makes status exit non-zero"
assert_contains "$OUT" "INERT" "S6b …and names it INERT (installed, but it will never run)"
# ⛔ `last_exit=unknown` used to be green. "systemctl could not answer" is not "the job never ran":
# the second is fine, the first means the status line is describing nothing.
OUT="$(SC_SHOW_EMPTY=1 run_lin status 2>&1)"; RC=$?
assert_eq "$RC" "1" "S6b a last exit that COULD NOT BE READ makes status exit non-zero"
assert_contains "$OUT" "verdict=UNKNOWN" "S6b …as UNKNOWN, never as a fresh job"
OUT="$(SC_SHOW_RC=1 run_lin status 2>&1)"; RC=$?
assert_eq "$RC" "1" "S6b a FAILED `systemctl show` is a failure too (it is not an absent schema)"
# The P0 shape: the timer is there, the SERVICE it triggers has been deleted, so the install is only
# half present. A `[ -f "$dir/$base.timer" ]` test called that installed=yes.
OUT="$(run_lin install >/dev/null 2>&1; rm -f "$T/units/eldato-alpha.service"; run_lin status 2>&1)"; RC=$?
assert_eq "$RC" "1" "S6b a timer whose .service is GONE fails status"
assert_contains "$OUT" "ABSENT-UNIT" "S6b …as ABSENT-UNIT (a half-present job is not installed)"
run_lin install >/dev/null 2>&1

echo "── S6c a plain install PRESERVES the installed arming stance (#1678) ──"
# The artifact is the decision of record: re-running the installer must not silently flip a job to
# report-only, and must not silently ARM one either. Only an explicit flag changes it, and it says so.
run_lin install --report-only >/dev/null 2>&1
assert_contains "$(cat "$T/units/eldato-alpha.service")" "--dry-run" "S6c an explicit --report-only renders the report-only flag (--dry-run) into the unit"
OUT="$(run_lin install 2>&1)"
assert_contains "$(cat "$T/units/eldato-alpha.service")" "--dry-run" "S6c a subsequent plain install KEEPS report-only (no silent arming)"
assert_contains "$OUT" "armed=dry-run" "S6c …and REPORTS the stance it preserved (read back from the artifact)"
OUT="$(run_lin install --apply 2>&1)"
assert_contains "$(cat "$T/units/eldato-alpha.service")" "--apply" "S6c an explicit --apply is the only way to arm"
assert_absent "$(cat "$T/units/eldato-alpha.service")" "--dry-run" "S6c …and the report-only flag is gone (the two stances do not coexist)"
assert_contains "$OUT" "ARMING CHANGED" "S6c …and a change is ANNOUNCED, never implied"
run_lin install >/dev/null 2>&1

echo "── S7 a changed SCRIPT reloads its job (#1738) ──"
printf '#!/usr/bin/env bash\necho "alpha v2 $*"\nexit 0\n' >"$T/farm/alpha.sh"; chmod +x "$T/farm/alpha.sh"
OUT="$(run_lin install 2>&1)"
assert_contains "$OUT" "pass_changed=1" "S7 the pass digest change is detected"
assert_contains "$OUT" "reload_reason=pass-changed" "S7 …and the reload reason is named"
OUT="$(run_lin status 2>&1)"
assert_contains "$OUT" "pass_drift=in-sync" "S7 after the reload the job matches the script"
printf '#!/usr/bin/env bash\necho "alpha v3 $*"\n' >"$T/farm/alpha.sh"; chmod +x "$T/farm/alpha.sh"
OUT="$(run_lin status 2>&1)"; RC=$?
assert_contains "$OUT" "CHANGED since install" "S7 a stale install is REPORTED, not inferred from a log"
# ⛔ REPORTED IS NOT JUDGED. The field was published and never used in the verdict, so `status` exited 0
# over a job that runs DIFFERENT bytes than the one that was installed.
[ "$RC" -ne 0 ] && ok "S7 …and status FAILS on it (rc=$RC): the running job is not the job that was installed" \
    || bad "S7 status exited 0 over a script that CHANGED since install"
assert_contains "$OUT" "verdict=STALE-SCRIPT" "S7 …named STALE-SCRIPT, not a note"
run_lin install >/dev/null 2>&1

echo "── S8 impossible states are LOUD ──"
OUT="$(run_lin install --only nosuchjob 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "S8 --only naming an undeclared id FAILS (rc=$RC)" || bad "S8 --only silently selected nothing"
assert_contains "$OUT" "does not define" "S8 …and names the id"
DECL2="$T/decl-noowner"; sed 's|owner=owner-fixture.sh|owner=missing-owner.sh|' "$DECL" >"$DECL2"
OUT="$(HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=linux SJ_DECLARATION="$DECL2" \
       SJ_FARM="$T/farm" SJ_STATE_DIR="$T/state-lin" SJ_OWNER_DIR="$T/owners" \
       SJ_SYSTEMD_UNIT_DIR="$T/units" SJ_SYSTEMCTL="$T/bin/systemctl" SC_STATE="$T/active" \
       bash "$INST" install 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "S8 a missing OWNER installer fails the install (rc=$RC)" || bad "S8 a missing owner was skipped"
assert_contains "$OUT" "was not found" "S8 …naming the owner it could not find"
OUT="$(run_lin --bogus 2>&1)"; RC=$?
assert_eq "$RC" "2" "S8 an unknown flag is a usage error (2)"
OUT="$(HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=windows SJ_DECLARATION="$DECL" \
       SJ_FARM="$T/farm" SJ_STATE_DIR="$T/state-lin" bash "$INST" install 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "S8 a platform with no known scheduler is refused (rc=$RC)" || bad "S8 an unknown platform was accepted"
assert_contains "$OUT" "systemd (linux) and launchd (darwin)" "S8 …naming what it does know"
# The Darwin temp-HOME guard (#446) refuses without the explicit test opt-in.
OUT="$(HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=darwin SJ_DECLARATION="$DECL" \
       SJ_STATE_DIR="$T/state-mac" SJ_FARM="$T/farm" SJ_OWNER_DIR="$T/owners" \
       SJ_LAUNCHD_DIR="$T/agents" SJ_LAUNCHCTL="$T/bin/launchctl" LC_STATE="$T/loaded" \
       bash "$INST" install 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "S8 a temp HOME on Darwin is REFUSED (#446)" || bad "S8 a temp HOME bootstrapped a live job"
assert_contains "$OUT" "is not the real home" "S8 …explaining why (the HOME comparison, not a failed dscl)"

echo "── S9 uninstall removes only what THIS command installed ──"
OUT="$(run_mac uninstall 2>&1)"; RC=$?
assert_eq "$RC" "0" "S9 uninstall succeeds"
assert_nofile "$T/agents/com.eldato.alpha.plist" "S9 the managed job is gone"
assert_contains "$OUT" "skip beta" "S9 the unmanaged job is left alone, and named"
assert_file "$T/agents/com.eldato.beta.plist" "S9 …it is still installed"
OUT="$(run_mac status 2>&1)"; RC=$?
assert_eq "$RC" "1" "S9 status after uninstall fails (the set is no longer scheduled)"
run_mac install >/dev/null 2>&1

# ── S9b: `uninstall` must MEASURE the removal, not announce it (#2048 review, BLOCK) ──
# Every removal step discarded its status, so a directory that could not be written printed
# `uninstalled` and exited 0 with the artifact still present and the timer still ENABLED — a disarm
# that does not disarm, on a job whose whole purpose is deleting things.
run_mac install >/dev/null 2>&1
chmod 500 "$T/agents"
OUT="$(run_mac uninstall 2>&1)"; RC=$?
chmod 700 "$T/agents" 2>/dev/null
assert_eq "$RC" "1" "S9b an uninstall whose removal FAILS exits 1, not 0"
assert_contains "$OUT" "INCOMPLETE" "S9b …and says so instead of claiming 'uninstalled'"
assert_absent "$OUT" "uninstalled alpha" "S9b …never printing the success line it did not earn"
run_mac uninstall >/dev/null 2>&1

# ── S9c: the `disable --now` warning is REAL — the program that prints it must define it ──
# ⛔ MEASURED #2058 DEFECT. `uninstall` announced a failed systemd `disable --now` through `warn`, which
# exists only in check-scheduled-parity.sh — a DIFFERENT process. On the Linux arm the line was
# `bash: line 657: warn: command not found`, so at the one moment a disarm did not disarm the operator
# read a shell error, and the branch round 2 added ("a failed disable is announced; the read-back
# decides") announced nothing. This case is RED against that head: `no shell error` and `did not
# confirm` cannot both hold while `warn` is undefined, and the run_lin uninstall path had no coverage
# at all — every existing uninstall assertion was `run_mac`.
mkdir -p "$T/bin-nodisable"
for b in crontab dscl; do [ -f "$T/bin/$b" ] && cp "$T/bin/$b" "$T/bin-nodisable/"; done
cat >"$T/bin-nodisable/systemctl" <<'SCND'
#!/usr/bin/env bash
# The same shim as above, EXCEPT `disable` FAILS the way a real one does when it cannot disarm (a
# read-only unit dir, a unit systemd does not have). Nothing here disarms the artifact: removing it is
# the read-back's job, which is exactly what makes this case test the read-back and not the shim.
printf '%s\n' "$*" >>"${SC_LOG:-/dev/null}"
state="${SC_STATE:-/nonexistent}"
case "${1:-}" in
  is-active)  grep -qxF "$2" "$state" 2>/dev/null && { echo active; exit 0; }; echo inactive; exit 3 ;;
  is-enabled) echo enabled; exit 0 ;;
  show)       echo "${SC_EXIT:-0}"; exit 0 ;;
  disable)    exit 1 ;;
  enable|start|restart|daemon-reload|stop) exit 0 ;;
  --version)  echo "systemd 255"; exit 0 ;;
esac
exit 0
SCND
chmod +x "$T/bin-nodisable/systemctl"
run_lin install >/dev/null 2>&1
assert_file "$T/units/eldato-alpha.timer" "S9c (fixture) the unit is installed before the disarm attempt"
OUT="$(HOME="$T/home" PATH="$T/bin-nodisable:$PATH" PORTABLE_PLATFORM=linux \
       SJ_DECLARATION="$DECL" SJ_UNMANAGED_REGISTER="$T/none.register" SJ_FARM="$T/farm" \
       SJ_STATE_DIR="$T/state-lin" SJ_OWNER_DIR="$T/owners" \
       SJ_SYSTEMD_UNIT_DIR="$T/units" SJ_SYSTEMCTL="$T/bin-nodisable/systemctl" \
       SC_STATE="$T/active" SC_LOG="$T/sc.log" bash "$INST" uninstall --only alpha 2>&1)"; RC=$?
assert_absent "$OUT" "command not found" "S9c a failed 'disable --now' never prints a shell error (warn is DEFINED here)"
assert_contains "$OUT" "did not confirm" "S9c …it announces that the disable did not confirm"
assert_eq "$RC" "0" "S9c the READ-BACK decides: the artifacts were removed, so the disarm is real (rc 0)"
assert_contains "$OUT" "uninstalled alpha" "S9c …and only then is 'uninstalled' claimed"
run_lin install >/dev/null 2>&1

# ── S14: `install` can be GREEN on the Mac it targets — a retired register entry is not STALE ──
# ⛔ THE MEASURED #2058 DEFECT, end to end. Two labels are registered in `config/scheduled-jobs.unmanaged`
# AND declared retired in `templates/launchd/RETIRED`; the darwin install delegates to
# install-launchd.sh, whose retire_pass deletes their plists, and the closing parity gate then reported
# `STALE-REGISTER` for both — so `install` exited 1 on the Mac, and `pi-bootstrap/setup.sh` told the
# owner "this Mac has NO disk-reaper schedule" over a box where the reaper HAD been installed, on every
# auto-sync, until a human hand-edited the register. This case uses the REPO's own two labels and the
# REPO's own manifest (it does not pin SJ_RETIRED_MANIFEST), so it fails if either the gate's exemption
# or the manifest resolution regresses.
REG_REAL="$T/reg-real-retired"
printf '%s\n' \
  'com.eldato.pi-cache-reap|RETIRED into com.eldato.disk-reaper (the `uv` class) — templates/launchd/RETIRED lists it, and install-launchd.sh boots it out and removes the plist on its next run.' \
  'com.tortoise.worktree-reaper|RETIRED into com.eldato.disk-reaper (the `worktree` class) — same retirement path as above.' \
  >"$REG_REAL"
fresh_all
mac_install_with_register() { # mac_install_with_register <register>
    HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=darwin \
    SJ_DECLARATION="$DECL" SJ_UNMANAGED_REGISTER="$1" SJ_FARM="$T/farm" \
    SJ_STATE_DIR="$T/state-mac" SJ_OWNER_DIR="$T/owners" \
    SJ_LAUNCHD_DIR="$T/agents" SJ_LAUNCHCTL="$T/bin/launchctl" \
    SJ_LAUNCHD_DOMAIN="gui/999" ELDATO_ALLOW_TEST_HOME=1 \
    LC_STATE="$T/loaded" LC_LOG="$T/lc.log" OWNER_MARKER="$T/owner-ran-mac" \
    bash "$INST" install 2>&1
}
OUT="$(mac_install_with_register "$REG_REAL")"; RC=$?
assert_eq "$RC" "0" "S14 a darwin install is GREEN with the repo's RETIRED labels registered and gone"
assert_absent "$OUT" "STALE-REGISTER" "S14 …no STALE-REGISTER over the two jobs it just retired"
assert_contains "$OUT" "verdict=OK" "S14 …the closing parity gate agrees"
assert_file "$T/agents/com.eldato.alpha.plist" "S14 …and the schedule really was installed"
# CONTROL: the exemption is exactly as wide as the manifest — a register line that is NOT retired is
# still STALE, so this fix cannot be mistaken for "the register stopped being judged".
REG_CTL="$T/reg-ctl"; cp "$REG_REAL" "$REG_CTL"
printf 'com.eldato.never-retired|registered, no live job, and no retirement declares it\n' >>"$REG_CTL"
OUT="$(mac_install_with_register "$REG_CTL")"; RC=$?
assert_eq "$RC" "1" "S14 …while a register entry that is NOT retired still FAILS the install"
assert_contains "$OUT" "STALE-REGISTER com.eldato.never-retired" "S14 …named STALE"
fresh_all
run_lin install >/dev/null 2>&1; run_mac install >/dev/null 2>&1

# ── S13: a Darwin render must not put a shim dir on the job's PATH (#427, #2048 review) ──
# `~/.pi/agent/shims/gh` symlinks into ~/Documents, which TCC denies to a launchd-spawned process: the
# job resolves gh, gets EPERM and fails closed every hour. install-launchd.sh already strips `*/shims`;
# the shared renderer must agree, or the two installers disagree about the same box.
# ⛔ THIS TEST MUST REACH A RENDER. Without ELDATO_ALLOW_TEST_HOME the #446 temp-HOME guard aborts first
# and the assertion passes on the ABSENCE of output — inert, which is how the plist renderer stayed
# un-wired while this was green (#2048 review).
mkdir -p "$T/shims"
OUT="$(HOME="$T/home" ELDATO_ALLOW_TEST_HOME=1 PATH="$T/shims:$T/bin:/usr/bin:/bin" \
       PORTABLE_PLATFORM=darwin SJ_LAUNCHD_DIR="$T/agents" bash "$INST" install --preview 2>&1)"; RC=$?
assert_eq "$RC" "0" "S13 the darwin preview actually RENDERS (rc 0, not the #446 abort)"
assert_contains "$OUT" "<key>PATH</key>" "S13 …and the plist it renders carries a PATH"
assert_absent "$OUT" "$T/shims" "S13 a darwin render carries NO shim dir on the job PATH"
# …and the rule is DARWIN-ONLY, deliberately: a systemd job runs as the user with no TCC boundary, so
# stripping there would cost a Linux cell tools it can use.
grep -q 'sj_job_path()' "$HERE/lib/scheduled-jobs.sh" \
    && ok "S13 the PATH rule lives in ONE helper, so the two renderers cannot drift" \
    || bad "S13 the PATH rule is duplicated"

echo "── S11/S12 preview writes nothing; artifacts carry no placeholder or masking exit ──"
fresh_all
OUT="$(run_lin install --preview 2>&1)"; RC=$?
assert_eq "$RC" "0" "S11 preview previews cleanly"
assert_nofile "$T/units/eldato-alpha.service" "S11 …and writes no unit"
assert_contains "$OUT" "preview:" "S11 …and says it is a preview"
OUT="$(run_mac install --preview 2>&1)"
assert_nofile "$T/agents/com.eldato.alpha.plist" "S11 …no plist either"
run_lin install >/dev/null 2>&1; run_mac install >/dev/null 2>&1
assert_absent "$(cat "$T/units/eldato-alpha.service" "$T/units/eldato-alpha.timer" | cat)" '{{' "S12 no unresolved placeholder in the unit"
assert_absent "$(cat "$T/agents/com.eldato.alpha.plist")" '{{' "S12 …nor in the plist"
assert_absent "$(cat "$T/units/eldato-alpha.service")" 'SuccessExitStatus' "S12 the unit does not declare a non-zero exit SUCCESSFUL"
assert_contains "$(cat "$T/units/eldato-alpha.service")" 'ExecStart="/bin/bash"' "S12 the unit has a runnable ExecStart"

echo "── S10 THE SHIM IS USED BY EVERY COMPONENT (population from the declaration) ──"
# The population is DERIVED, not listed here: every `.sh` entry point the declaration names on this
# platform must source the shim and carry no GNU-only spelling in EXECUTED code. A component added
# tomorrow is covered without touching this test.
COMPONENTS=""
for id in $(cd "$ROOT" && SJ_DECLARATION="$REAL_DECL" bash -c '. scripts/lib/scheduled-jobs.sh >/dev/null 2>&1; sj_ids'); do
    sc="$(cd "$ROOT" && SJ_DECLARATION="$REAL_DECL" bash -c '. scripts/lib/scheduled-jobs.sh >/dev/null 2>&1; sj_field '"$id"' script')"
    case "$sc" in *.sh) ;; *) continue ;; esac       # a python entry point cannot source a bash shim
    f="$ROOT/scripts/$sc"
    [ -f "$f" ] && COMPONENTS="$COMPONENTS $f"
done
# The delegates a scheduled pass executes are components too, even though the declaration names the
# pass rather than each delegate.
for d in pi-cache-reap.sh reap-lane-venvs.sh pi-reap-worktrees.sh; do
    COMPONENTS="$COMPONENTS $ROOT/scripts/$d"
done
N=0
for f in $COMPONENTS; do
    N=$((N + 1))
    base="$(basename "$f")"
    # ⛔ EXECUTED CODE ONLY, exactly like the GNU-spelling sweep below (#2058 review, P2). This arm used
    # to grep the WHOLE FILE for the string `lib/portable.sh`, which every migrated component carries twice
    # as text that does nothing: `# shellcheck source=lib/portable.sh` (a comment) and the candidate path
    # strings. Deleting the real `. "$_PORTABLE_LIB"` — the #2046 regression this arm exists to catch,
    # where the component starts and every bounded call returns 127 — still read GREEN.
    code="$(grep -v '^[[:space:]]*#' "$f")"
    if grep -qE '^[[:space:]]*\.[[:space:]]+"?\$_PORTABLE_LIB' <<<"$code"; then
        ok "S10 $base loads the portability shim (a SOURCE line, not a comment mentioning it)"
    else
        bad "S10 $base does NOT source the portability shim in executed code"
    fi
    # EXECUTED code only: a comment that names `date -d` explains HISTORY (that is how the defect was
    # recorded) and must not be read as a call site.
    for pat in 'stat -c' 'stat -f' 'date -d' 'date -r' 'date -v'; do
        if grep -qF -- "$pat" <<<"$code"; then bad "S10 $base still carries GNU/BSD-only '$pat' in executed code"; else ok "S10 $base carries no '$pat'"; fi
    done
    if grep -qE '(^|[^_[:alnum:]])timeout [0-9]' <<<"$code"; then
        bad "S10 $base calls a bare 'timeout' (GNU-only, absent on macOS)"
    else ok "S10 $base has no bare 'timeout' call"; fi
    if grep -qE '(^|[^_[:alnum:]])nproc([^_[:alnum:]]|$)' <<<"$code"; then
        bad "S10 $base calls a bare 'nproc' (GNU-only)"
    else ok "S10 $base has no bare 'nproc'"; fi
done
# ⛔ THE ASSERTION MUST BE ABLE TO SAY NO. A pattern can be satisfied by the file it is meant to
# reject, and this one WAS: the probe below is a component whose only mention of the shim is a comment
# and a candidate path string — the exact shape of a file whose real `. "$_PORTABLE_LIB"` was deleted.
# Asserting the probe stays RED is what makes the arm above discriminating rather than decorative.
printf '%s\n' '#!/usr/bin/env bash' \
    '# shellcheck source=lib/portable.sh' \
    '_portable_self_dir="$(cd "$(dirname "$0")" && pwd)"' \
    '_PORTABLE_LIB="$_portable_self_dir/lib/portable.sh"' >"$T/neg-shim.sh"
neg_code="$(grep -v '^[[:space:]]*#' "$T/neg-shim.sh")"
if grep -qE '^[[:space:]]*\.[[:space:]]+"?\$_PORTABLE_LIB' <<<"$neg_code"; then
    bad "S10 the shim assertion is VACUOUS — a file that only NAMES lib/portable.sh passes it"
else
    ok "S10 …and the shim assertion REJECTS a file that merely mentions lib/portable.sh"
fi
[ "$N" -ge 8 ] && ok "S10 the population is non-empty and derived from the declaration ($N components)" \
                || bad "S10 the component population collapsed to $N — the check would be vacuous"

echo "── S15 a declared args= is an argv the PROGRAM IT NAMES can parse (#2058 review, P2) ──"
# ⛔ `--static` (the documented CI mode) renders every record and checked only for unresolved placeholders
# and plist well-formedness, so a MALFORMED argv was blessed as `verdict=OK`. The measured case:
# `worktree-hygiene` declared `args=@tortoise --repo`, and `scripts/worktree-hygiene-sweep.sh` parses
# `--repo) REPO="$2"; shift 2` — so the rendered argv was `[<repo>, --repo]`: the repo as a stray
# positional and the flag with nothing after it. Nothing asserted a rendered argv is parseable.
# The flags that TAKE A VALUE (from the consumers' own parse loops): none may end an argv.
VALUEFLAGS=" --repo --scope --aged-days --engine --backup-dir --state-dir --script "
DANGLING=""
for id in $(cd "$ROOT" && SJ_DECLARATION="$REAL_DECL" bash -c '. scripts/lib/scheduled-jobs.sh >/dev/null 2>&1; sj_ids'); do
    a="$(cd "$ROOT" && SJ_DECLARATION="$REAL_DECL" bash -c '. scripts/lib/scheduled-jobs.sh >/dev/null 2>&1; sj_field '"$id"' args')"
    [ -n "$a" ] || continue
    last="${a##* }"
    case "$VALUEFLAGS" in *" $last "*) DANGLING="$DANGLING $id($last)" ;; esac
done
if [ -z "$DANGLING" ]; then ok "S15 no record's args= ENDS with a flag that takes a value";
else bad "S15 a record's args= ends with a value-taking flag, so the flag renders valueless:$DANGLING"; fi
# …and the same property read off the ARTIFACT, where it is actually consumed. The value after `--repo`
# must be the resolved repo path; the pre-fix declaration put `--repo` LAST, so this read nothing.
SD="$T/render-decl"; mkdir -p "$SD"
TORTOISE_REPO="$T/farm" HOME="$T/home" SJ_DECLARATION="$REAL_DECL" SJ_FARM="$T/farm" \
    bash -c '. "$0/lib/scheduled-jobs.sh" >/dev/null 2>&1 && sj_render_launchd worktree-hygiene "$1"' \
    "$HERE" "$SD/com.tortoise.worktree-hygiene.plist" >/dev/null 2>&1
WH_PL="$SD/com.tortoise.worktree-hygiene.plist"
assert_file "$WH_PL" "S15 the real worktree-hygiene record renders a plist"
PAIR="$(awk '/<string>--repo<\/string>/{ getline; sub(/^[ \t]*<string>/, ""); sub(/<\/string>[ \t]*$/, ""); print; exit }' "$WH_PL" 2>/dev/null)"
assert_eq "$PAIR" "$T/farm" "S15 …where the word AFTER --repo is its VALUE (a flag with no value is an unusable argv)"


echo "── S11 the verbs reach the LIVE domain only from the real home (#446) ──"
# The temp-HOME guard was applied to `install` and to nothing else: `stop|restart|uninstall` reached the
# live gui/<uid> domain from a throwaway HOME, and `restart` BOOTSTRAPPED a plist that lives inside the
# temp dir — the exact artifact the guard exists to prevent.
for v in stop restart uninstall status; do
    OUT="$(HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=darwin \
           SJ_DECLARATION="$DECL" SJ_FARM="$T/farm" SJ_STATE_DIR="$T/state-mac" \
           SJ_LAUNCHD_DIR="$T/agents" SJ_LAUNCHCTL="$T/bin/launchctl" SJ_LAUNCHD_DOMAIN="gui/999" \
           bash "$INST" "$v" --only alpha 2>&1)"; RC=$?
    [ "$RC" -ne 0 ] && ok "S11 '$v' from a temp HOME is refused (rc=$RC)" || bad "S11 '$v' reached the live launchd domain from a temp HOME"
    assert_contains "$OUT" "is not the real home" "S11 …and '$v' says why"
done
# …and an UNMEASURABLE real home is a refusal, not a pass: `dscl` is macOS-only, so on any other host the
# old `[ -n "$real" ]` fence fell through and install bootstrapped into the LIVE domain from a temp HOME.
mkdir -p "$T/bin-nodscl"
for b in launchctl systemctl crontab; do [ -f "$T/bin/$b" ] && cp "$T/bin/$b" "$T/bin-nodscl/"; done
OUT="$(HOME="$T/home" PATH="$T/bin-nodscl:/usr/bin:/bin" PORTABLE_PLATFORM=darwin \
       SJ_DECLARATION="$DECL" SJ_FARM="$T/farm" SJ_STATE_DIR="$T/state-mac" \
       SJ_LAUNCHD_DIR="$T/agents" SJ_LAUNCHCTL="$T/bin/launchctl" SJ_LAUNCHD_DOMAIN="gui/999" \
       bash -c 'command -v dscl >/dev/null && exit 77; exec "$@"' _ \
       "$BASH" "$INST" install --only alpha 2>&1)"; RC=$?
if [ "$RC" = 77 ]; then
    ok "S11 (skipped: dscl is on PATH — the macOS box always has it)"
else
    [ "$RC" -ne 0 ] && ok "S11 an UNMEASURABLE real home refuses instead of installing (rc=$RC)" \
        || bad "S11 an unmeasurable real home installed into the live domain (#446)"
    assert_contains "$OUT" "could not be determined" "S11 …and names the reason"
fi

echo "── S12 an unmeasurable script digest RELOADS, and `--apply` on a delegated record is announced ──"
# An empty digest used to mean "unchanged" (`[ -n "$sha" ] &&`), so a box without sha256sum/shasum
# installed an edited job and never reloaded it — the #1738 hole, by construction.
mkdir -p "$T/bin-nosha"
for b in systemctl crontab launchctl; do [ -f "$T/bin/$b" ] && cp "$T/bin/$b" "$T/bin-nosha/"; done
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin-nosha/sha256sum"; chmod +x "$T/bin-nosha/sha256sum"
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin-nosha/shasum";   chmod +x "$T/bin-nosha/shasum"
OUT="$(HOME="$T/home" PATH="$T/bin-nosha:/usr/bin:/bin" PORTABLE_PLATFORM=linux \
       SJ_DECLARATION="$DECL" SJ_FARM="$T/farm" SJ_STATE_DIR="$T/state-nosha" SJ_OWNER_DIR="$T/owners" \
       SJ_SYSTEMD_UNIT_DIR="$T/units" SJ_SYSTEMCTL="$T/bin/systemctl" SC_STATE="$T/active" \
       bash "$INST" install --only alpha 2>&1)"; RC=$?
assert_contains "$OUT" "UNVERIFIABLE" "S12 an unavailable digest is reported as UNVERIFIABLE"
assert_contains "$OUT" "pass_changed=1" "S12 …and the job is RELOADED rather than assumed unchanged"
# `--apply` is rendered into the artifacts this command owns and CANNOT be applied to another owner's —
# it used to be silently dropped for those records while the run read as a whole-set success.
OUT="$(run_lin install --apply 2>&1)"
assert_contains "$OUT" "arming NOT applied" "S12 --apply says which delegated records it cannot arm"

echo "── S17 the unit's exit-code stance and delegate pins come from the DECLARATION (#2071) ──"
# The retired unit carried `SuccessExitStatus=0 4 5`, which made a pass that FAILED a class (4) and one
# that found un-reclaimed work (5) read as SUCCESS to `systemctl status` — measured: an estate carried a
# "succeeding" hourly reaper on cells at 94-96% used. #2071 moved it to `0 6` (6 = a delegate DEFERRED,
# the routine state of a busy cell, #2036). #2048 replaces that installer, so the SAME stance has to be
# assertable on the artifact THIS installer renders — otherwise the merge silently drops the fix.
REAL_DECL="$ROOT/config/scheduled-jobs.declaration"
REAL_UNITS="$T/s13/units"; rm -rf "$T/s13"; mkdir -p "$REAL_UNITS"
real_lin() { # real_lin <args...>
    HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=linux \
    SJ_DECLARATION="$REAL_DECL" SJ_FARM="$ROOT/scripts" SJ_STATE_DIR="$T/s13/state" \
    SJ_REPOS="$ROOT" SJ_SYSTEMD_UNIT_DIR="$REAL_UNITS" SJ_SYSTEMCTL="$T/bin/systemctl" \
    SC_STATE="$T/s13/active" SJ_BOOTSTRAP_OK=1 SJ_OWNER_DIR="$T/owners" \
    bash "$INST" --no-parity "$@"
}
real_lin install --only eldato-disk-reaper >/dev/null 2>&1
REAL_UNIT="$REAL_UNITS/eldato-disk-reaper.service"
assert_file "$REAL_UNIT" "S17 the real declaration renders the disk-reaper unit"
UNIT_TXT="$(cat "$REAL_UNIT" 2>/dev/null || true)"
assert_contains "$UNIT_TXT" "SuccessExitStatus=0 6" "S17 the unit declares exit 6 as the ONE green non-zero code"
assert_absent "$UNIT_TXT" "SuccessExitStatus=0 4 5" "S17 …and the masked form (0 4 5) is gone (#2071's measured false PASS)"
case "$UNIT_TXT" in
    *"SuccessExitStatus=0 5 6"*) bad "S17 exit 5 is NOT green: in an apply pass it means work remains (#2071 refuses #2036's literal proposal)" ;;
    *) ok "S17 exit 5 is not whitelisted (work that remains stays RED)" ;;
esac
# ⛔ DECLARED PER JOB, NOT BLANKET. A second job with no `success_exit` must render NO line at all, so a
# future edit cannot turn the directive into a repo-wide "non-zero is fine".
BARE_DECL="$T/s13/bare.declaration"
sed '/success_exit_codes=/d' "$REAL_DECL" >"$BARE_DECL"
BARE_UNITS="$T/s13/bare-units"; mkdir -p "$BARE_UNITS"
HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=linux SJ_DECLARATION="$BARE_DECL" \
  SJ_FARM="$ROOT/scripts" SJ_STATE_DIR="$T/s13/state" SJ_REPOS="$ROOT" \
  SJ_SYSTEMD_UNIT_DIR="$BARE_UNITS" SJ_SYSTEMCTL="$T/bin/systemctl" SC_STATE="$T/s13/active2" \
  bash "$INST" --no-parity install --only eldato-disk-reaper >/dev/null 2>&1
assert_absent "$(cat "$BARE_UNITS/eldato-disk-reaper.service" 2>/dev/null || true)" "SuccessExitStatus" \
  "S17 with the key absent the renderer emits NO SuccessExitStatus (declaration-scoped, never a blanket)"
# ── the delegate pins: the INSTALLED copy, never $HOME ────────────────────────────────────────
assert_contains "$UNIT_TXT" "CACHE_REAPER=$ROOT/scripts/pi-cache-reap.sh" \
  "S17 CACHE_REAPER is pinned to the script's own directory, not to \$HOME (a stale farmed copy ran instead, #2071)"
assert_contains "$UNIT_TXT" "VENV_REAPER=$ROOT/scripts/reap-lane-venvs.sh" "S17 …VENV_REAPER likewise"
assert_contains "$UNIT_TXT" "WORKTREE_REAPER=$ROOT/scripts/pi-reap-worktrees.sh" "S17 …WORKTREE_REAPER likewise"
assert_absent "$UNIT_TXT" "@installed" "S17 the placeholder is RESOLVED in the artifact (an unresolved @installed is a 127 every tick)"
# launchd has no way to whitelist an exit status, so the plist must NOT claim the stance it cannot keep.
# Rendered DIRECTLY through the shared renderer: the assertion is about the ARTIFACT, and driving the
# whole darwin install here would couple it to launchd lifecycle state the assertion does not need.
cat >"$T/s15-render-ld.sh" <<'RLD'
#!/usr/bin/env bash
set -uo pipefail
cd "$1" || exit 1
export SJ_DECLARATION="$2" SJ_FARM="$3" PLATFORM=darwin PORTABLE_PLATFORM=darwin SJ_REPOS="$4" SJ_STATE_DIR="$5"
. scripts/lib/scheduled-jobs.sh
sj_render_launchd eldato-disk-reaper "$6"
RLD
chmod +x "$T/s15-render-ld.sh"
LD_PLIST="$T/s15/com.eldato.disk-reaper.plist"; mkdir -p "$T/s15"
out="$("$T/s15-render-ld.sh" "$ROOT" "$REAL_DECL" "$ROOT/scripts" "$ROOT" "$T/s15/state" "$LD_PLIST" 2>&1)"; rc=$?
assert_eq "$rc" "0" "S17 the darwin artifact renders (rc=0)"
LD_TXT="$(cat "$LD_PLIST" 2>/dev/null || true)"
assert_contains "$LD_TXT" "<key>CACHE_REAPER</key>" "S17 the darwin artifact carries the same delegate pins"
assert_contains "$LD_TXT" "$ROOT/scripts/pi-cache-reap.sh" "S17 …resolved to the script's own directory"
assert_absent "$LD_TXT" "SuccessExitStatus" "S17 …but no SuccessExitStatus (launchd cannot whitelist a status; the claim is not silently carried)"

echo "── S18 an artifact that CANNOT RUN is refused before anything is written (#2032/#2071) ──"
# Each case answers a MEASURED defect where the scheduler showed the job as installed and healthy while it
# reclaimed nothing. The refusal is the installer's, and it must fire BEFORE any write.
refuse_run() { # refuse_run <label> <expected-substring> <env-assignments...>
    local label="$1" want="$2"; shift 2
    local dir="$T/s14/$(printf '%s' "$label" | tr -c 'a-zA-Z0-9' '-')"
    rm -rf "$dir"; mkdir -p "$dir"
    local out rc
    out="$(env HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=linux \
            SJ_DECLARATION="$REAL_DECL" SJ_FARM="$ROOT/scripts" \
            SJ_SYSTEMD_UNIT_DIR="$dir/units" SJ_SYSTEMCTL="$T/bin/systemctl" SC_STATE="$dir/active" \
            "$@" bash "$INST" --no-parity install --only eldato-disk-reaper 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && ok "S18 $label is REFUSED (rc=$rc)" || bad "S18 $label installed (rc=0) — an artifact that cannot run was written"
    assert_contains "$out" "$want" "S18 …and the refusal names the reason ($label)"
    assert_eq "$(ls -A "$dir/units" 2>/dev/null | wc -l | tr -d ' ')" "0" \
        "S18 …and NOTHING was written for $label"
}
# (a) a RELATIVE script path: systemd resolves ExecStart against the UNIT's cwd, so it is a permanent 127
#     that the installer's own cwd cannot see.
mkdir -p "$T/s14/relfarm"; printf '#!/bin/bash\nexit 0\n' >"$T/s14/relfarm/r.sh"; chmod +x "$T/s14/relfarm/r.sh"
# ⛔ The reachable arm is a RELATIVE FARM. A `script=./r.sh` joined onto an absolute farm resolves to an
# absolute path and renders fine; what renders a 127 is an operator (or a cell) whose farm is relative —
# the resolved entry point is then relative, and systemd resolves it against the UNIT's own cwd.
mkdir -p "$T/s14/relfarm"; printf '#!/bin/bash\nexit 0\n' >"$T/s14/relfarm/disk-reaper.sh"; chmod +x "$T/s14/relfarm/disk-reaper.sh"
out="$(cd "$T/s14" && HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=linux \
       SJ_DECLARATION="$REAL_DECL" SJ_FARM="relfarm" SJ_STATE_DIR="$T/s14/st" SJ_REPOS="$ROOT" \
       SJ_SYSTEMD_UNIT_DIR="$T/s14/relunits" SJ_SYSTEMCTL="$T/bin/systemctl" SC_STATE="$T/s14/relact" \
       bash "$INST" --no-parity install --only eldato-disk-reaper 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "S18 a RELATIVE farm makes the entry point relative, and it is REFUSED (rc=$rc)" \
    || bad "S18 a relative entry point was accepted — systemd would exit 127 every tick"
assert_contains "$out" "not an absolute path" "S18 …naming the non-absolute path and its consequence"
# (b) whitespace in a rendered value: systemd splits unquoted Environment= values. Declared in the
# RECORD rather than passed through the environment: `sj_resolve_repos` legitimately DROPS an unusable
# repo list, so an env-based probe would be testing that validation, not the renderer.
SPACE_DECL="$T/s14/space.decl"
sed 's|^  env DISK_REAPER_WT_AGED_DAYS=7|  env DISK_REAPER_TOUCHED="a b"|' "$REAL_DECL" >"$SPACE_DECL"
out="$(HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=linux SJ_DECLARATION="$SPACE_DECL" \
       SJ_FARM="$ROOT/scripts" SJ_STATE_DIR="$T/s14/spacest" SJ_REPOS="$ROOT" \
       SJ_SYSTEMD_UNIT_DIR="$T/s14/spaceunits" SJ_SYSTEMCTL="$T/bin/systemctl" SC_STATE="$T/s14/spaceact" \
       bash "$INST" --no-parity install --only eldato-disk-reaper 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "S18 a declared value carrying whitespace is REFUSED (rc=$rc)" \
    || bad "S18 a whitespace-carrying value rendered into a persistent unit"
assert_contains "$out" "contains whitespace" "S18 …and the refusal names the value"
assert_eq "$(ls -A "$T/s14/spaceunits" 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "S18 …and NOTHING was written"
# (c) a non-numeric *_DAYS: baked into a PERSISTENT artifact (measured: systemd keeps '7', drops 'days').
WS_DECL="$T/s14/aged.decl"; sed "s|^  env DISK_REAPER_WT_AGED_DAYS=7|  env DISK_REAPER_WT_AGED_DAYS=abc|" "$REAL_DECL" >"$WS_DECL"
out="$(HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=linux SJ_DECLARATION="$WS_DECL" \
       SJ_FARM="$ROOT/scripts" SJ_STATE_DIR="$T/s14/st2" SJ_REPOS="$ROOT" \
       SJ_SYSTEMD_UNIT_DIR="$T/s14/agedunits" SJ_SYSTEMCTL="$T/bin/systemctl" SC_STATE="$T/s14/agedact" \
       bash "$INST" --no-parity install --only eldato-disk-reaper 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "S18 a non-numeric *_DAYS is REFUSED (rc=$rc) — it would be baked into the unit" \
    || bad "S18 'DISK_REAPER_WT_AGED_DAYS=7 days' rendered into a persistent unit"
assert_contains "$out" "not a whole number" "S18 …and says which value and why"
# `DISK_REAPER_WT_AGED_DAYS="7 days"` trips the WHITESPACE arm instead (checked first) — the other half of
# the same measured defect, where systemd kept `7` and dropped `days` and still exited 0.
SP_DECL="$T/s14/aged-sp.decl"; sed "s|^  env DISK_REAPER_WT_AGED_DAYS=7|  env DISK_REAPER_WT_AGED_DAYS=7 days|" "$REAL_DECL" >"$SP_DECL"
out="$(HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=linux SJ_DECLARATION="$SP_DECL" \
       SJ_FARM="$ROOT/scripts" SJ_STATE_DIR="$T/s14/st2b" SJ_REPOS="$ROOT" \
       SJ_SYSTEMD_UNIT_DIR="$T/s14/agedunits2" SJ_SYSTEMCTL="$T/bin/systemctl" SC_STATE="$T/s14/agedact2" \
       bash "$INST" --no-parity install --only eldato-disk-reaper 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "S18 'DISK_REAPER_WT_AGED_DAYS=7 days' is REFUSED (whitespace arm)" \
    || bad "S18 a two-token AGED_DAYS value rendered into a persistent unit"
# (d) a TRANSIENT SCRATCH target: the artifact would point into a mktemp dir that is gone before the first
#     tick, so every pass exits 127 while the scheduler still shows the job as scheduled (measured on
#     pi-cell-2 at 94% and pi-cell-3 at 96% used). Driven through the REAL install path: without a unit-dir
#     override the installer takes the SYSTEM target, which is the shape the defect was measured in.
SCRATCH_HOME="$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXX")"
mkdir -p "$SCRATCH_HOME/.pi/agent/scripts"
cp "$ROOT/scripts/disk-reaper.sh" "$SCRATCH_HOME/.pi/agent/scripts/"
: >"$T/s14/calls.log"
out="$(HOME="$SCRATCH_HOME" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=linux SJ_DECLARATION="$REAL_DECL" \
       SJ_FARM="$SCRATCH_HOME/.pi/agent/scripts" SJ_STATE_DIR="$SCRATCH_HOME/.pi/agent/state" \
       SJ_REPOS="$ROOT" SJ_SUDO="true" SJ_SYSTEMCTL="$T/bin/systemctl" SYSTEMCTL_CALLS="$T/s14/calls.log" \
       bash "$INST" --no-parity install --only eldato-disk-reaper 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "S18 a SYSTEM install from a transient-scratch HOME is REFUSED (rc=$rc)" \
    || bad "S18 a unit was rendered from a mktemp HOME — the 127-forever shape"
assert_contains "$out" "transient scratch" "S18 …and the refusal names the transient path"
assert_absent "$(cat "$T/s14/calls.log" 2>/dev/null || true)" "enable" \
    "S18 …and nothing is ENABLED for a unit that could never run"
# …and the explicit unit-dir override (the documented test seam, used by every fixture in this suite) is
# NOT blocked by it: the bypass is scoped to the heuristic, not to the whole guard.
SCRATCH_FARM="$T/s14/scratch-farm"; mkdir -p "$SCRATCH_FARM"; cp "$ROOT/scripts/disk-reaper.sh" "$SCRATCH_FARM/"
out="$(HOME="$SCRATCH_HOME" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=linux SJ_DECLARATION="$REAL_DECL" \
       SJ_FARM="$SCRATCH_FARM" SJ_STATE_DIR="$SCRATCH_HOME/.pi/agent/state" SJ_REPOS="$ROOT" \
       SJ_SYSTEMD_UNIT_DIR="$T/s14/scratchunits" SJ_SYSTEMCTL="$T/bin/systemctl" \
       SC_STATE="$T/s14/scratchact" SYSTEMCTL_CALLS="$T/s14/calls2.log" \
       bash "$INST" --no-parity install --only eldato-disk-reaper 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "S18 an explicit unit-dir override still installs (the seam is not a false block)" \
    || bad "S18 the documented override stopped installing (rc=$rc): $(printf '%.200s' "$out")"
rm -rf "$SCRATCH_HOME"
# (e) an UNWRITABLE state dir: the job runs as this user, so every pass would fail closed on an artifact
#     that installed cleanly. And under --dry-run the probe must NOT create it.
mkdir -p "$T/s14/ro-state"; chmod 500 "$T/s14/ro-state"
out="$(HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=linux SJ_DECLARATION="$REAL_DECL" \
       SJ_FARM="$ROOT/scripts" SJ_STATE_DIR="$T/s14/ro-state/state" SJ_REPOS="$ROOT" \
       SJ_SYSTEMD_UNIT_DIR="$T/s14/rounits" SJ_SYSTEMCTL="$T/bin/systemctl" SC_STATE="$T/s14/act5" \
       bash "$INST" --no-parity install --only eldato-disk-reaper 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "S18 an unwritable state dir is REFUSED (rc=$rc)" || bad "S18 an unwritable state dir installed cleanly"
assert_contains "$out" "not writable" "S18 …naming the directory and the user"
chmod 700 "$T/s14/ro-state"
MISSING_STATE="$T/s14/would-create/state"
out="$(HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=linux SJ_DECLARATION="$REAL_DECL" \
       SJ_FARM="$ROOT/scripts" SJ_STATE_DIR="$MISSING_STATE" SJ_REPOS="$ROOT" \
       SJ_SYSTEMD_UNIT_DIR="$T/s14/pvunits" SJ_SYSTEMCTL="$T/bin/systemctl" SC_STATE="$T/s14/act6" \
       bash "$INST" --no-parity install --only eldato-disk-reaper --dry-run 2>&1)"; rc=$?
[ ! -e "$MISSING_STATE" ] && ok "S18 a PREVIEW does not create the state dir it only describes" \
    || bad "S18 --dry-run created $MISSING_STATE (a preview must write nothing)"
# (f) a pinned DELEGATE that does not exist: its class would fail closed (exit 3) every pass, on an
#     artifact that installed cleanly — so it is named at install time.
HALF_FARM="$T/s14/half-farm"; mkdir -p "$HALF_FARM"
cp "$ROOT/scripts/disk-reaper.sh" "$HALF_FARM/"
out="$(HOME="$T/home" PATH="$T/bin:$PATH" PORTABLE_PLATFORM=linux SJ_DECLARATION="$REAL_DECL" \
       SJ_FARM="$HALF_FARM" SJ_STATE_DIR="$T/s14/halfstate" SJ_REPOS="$ROOT" \
       SJ_SYSTEMD_UNIT_DIR="$T/s14/halfunits" SJ_SYSTEMCTL="$T/bin/systemctl" SC_STATE="$T/s14/act7" \
       bash "$INST" --no-parity install --only eldato-disk-reaper 2>&1)"; rc=$?
assert_contains "$out" "which is missing" "S18 a pinned delegate that is absent is NAMED at install time (it would fail closed every pass)"
assert_contains "$out" "pi-cache-reap.sh" "S18 …and the warning names the delegate"

echo
echo "──────────────────────────────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then echo "ALL PASS ($PASS assertions)"; exit 0; fi
echo "FAILURES: $FAIL of $PASS assertions"
exit 1
