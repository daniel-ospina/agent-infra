#!/usr/bin/env bash
# install-disk-reaper-schedule.test.sh — the installer that schedules the disk reaper on BOTH
# platforms (agent-infra#2048).
#
# Run: bash scripts/install-disk-reaper-schedule.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# ⛔ WHAT THIS SUITE EXISTS TO PROVE. On the cells the pass had a timer and on the Mac it had nothing
# (#2048: `launchctl list | grep -i reap` was empty, and the box reached 90% used). A schedule is the
# only thing that makes an unattended reaper exist at all, so the assertions here are about the JOB,
# not about the pass (disk-reaper.test.sh owns the pass):
#
#   T1 ONE VERB, TWO SCHEDULERS. The same installer produces a systemd timer on Linux and a launchd job
#      on Darwin, from the SAME pass, with the SAME mode flag. The two backends are rendered in one run
#      and their flags compared, so "same flags" is checked rather than asserted in a comment.
#   T2 IDEMPOTENT. A second install is a no-op on BOTH (the bring-up re-runs it on every check), and a
#      no-op must also mean NO RELOAD — a bootstrap per bring-up would re-run the pass every time.
#   T3 REPORT-ONLY BY DEFAULT, ARMED ONLY BY AN EXPLICIT FLAG (#1678). No mode flag renders the pass's
#      dry-run flag and `--status` reports armed=dry-run; `--apply` renders the armed flag, `--status`
#      reports armed=apply, and the answer is read from the INSTALLED artifact, never from the flags the
#      invocation was given. `--dry-run` puts the report-only mode back (reversible, one copy).
#   T4 A CHANGED PASS RELOADS ITS JOB (#1738). An edit to a scheduled script is inert until the job is
#      reloaded. An untouched unit whose pass bytes changed must still reload, and say why.
#   T5 ONE STATUS VOCABULARY. The `key=` set is identical on both platforms and both print the SAME pass
#      record — "is this box reaped, by what, when did the last pass run, what did it free, did it
#      succeed" has one answer.
#   T6 UNSCHEDULED IS A LOUD FAILURE, never a silent no-op: a box with no scheduler, a temp HOME on
#      Darwin (#446), a missing pass, an unresolved template placeholder, and a malformed plist are all
#      refusals with a named reason.
#   T7 THE MAC DOES NOT GET A SECOND PASS: the launchd job's entry point is the pass itself, and the
#      template lives at `*.plist.tmpl` so install-launchd.sh's `*.plist` glob cannot bootstrap it
#      half-rendered. One installer owns it.
#
# Hermetic: HOME is redirected into $T, the unit dir is $T, the launchd install dir is $T, and
# `launchctl` is a SHIM on disk — nothing in this suite reaches the real GUI domain or a live unit.
# (launchctl addresses the user domain BY UID, so the shim is not a convenience: it is the isolation.)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INST="$HERE/install-disk-reaper-schedule.sh"
ROOT="$(cd "$HERE/.." && pwd)"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_absent()   { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }
assert_file()     { if [ -f "$1" ]; then ok "$2"; else bad "$2 (missing file: $1)"; fi; }
assert_nofile()   { if [ -f "$1" ]; then bad "$2 (present: $1)"; else ok "$2"; fi; }

[ -f "$INST" ] || { echo "FATAL: $INST missing — this suite tests the installer, and there is none"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/disk-reaper-schedule-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

# ── fixtures ───────────────────────────────────────────────────────────────────────────────────
# A FAKE PASS, not the real one: this suite is about the JOB, and a fake pass makes the status half
# deterministic on a box where the real pass cannot complete yet (macOS has no `timeout`, #2046 —
# which is exactly why the installer must tolerate a non-zero, fail-closed pass).
mkpass() { # mkpass <path> [freed_mb]
    local p="$1" freed="${2:-123}"
    mkdir -p "$(dirname "$p")"
    cat >"$p" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  --print-status)
    echo "status=ok"
    echo "mode=dry-run"
    echo "freed_mb=$freed"
    exit 0 ;;
esac
echo "fake pass ran: \$*"
exit 0
EOF
    chmod +x "$p"
}

# A repo the installer's git probe accepts (the rendered job carries it).
REPO="$T/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q >/dev/null 2>&1 || true

# systemctl shim: logs every call, answers the three queries the status path makes.
mkdir -p "$T/bin"
cat >"$T/bin/systemctl" <<'SC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SYSTEMCTL_CALLS:-/dev/null}"
case "$*" in
  *is-enabled*) echo enabled ;;
  *is-active*) echo active ;;
  *list-timers*) echo "Mon 2026-10-19 00:30:00 UTC 1h left Sun 2026-10-18 23:30:00 UTC 3h ago eldato-disk-reaper.timer eldato-disk-reaper.service" ;;
  *show*) echo "${FAKE_EXEC_STATUS:-0}" ;;
  cat\ *) f="${SYSTEMCTL_UNITS:-}/$(printf '%s' "$*" | sed 's/^cat //')"
           [ -f "$f" ] || exit 1; cat "$f" ;;
esac
exit 0
SC
chmod +x "$T/bin/systemctl"

# launchctl shim: keeps a LOADED-STATE file, so the installer's "is it loaded?" question has a real
# answer without touching the live GUI domain.
cat >"$T/bin/launchctl" <<LC
#!/usr/bin/env bash
STATE="${T}/launchctl.state"
printf '%s\n' "\$*" >>"${T}/launchctl.log"
case "\${1:-}" in
  bootstrap) mkdir -p "\$STATE"; exit 0 ;;
  bootout)   rm -rf "\$STATE"; exit 0 ;;
  enable)    exit 0 ;;
  print)     [ -d "\$STATE" ] || exit 0
             printf '\tstate = not running\n\truns = 2\n\tlast exit code = %s\n' "\${FAKE_LAST_EXIT:-0}"
             exit 0 ;;
esac
exit 0
LC
chmod +x "$T/bin/launchctl"
touch "$T/bin/fakepython"; chmod +x "$T/bin/fakepython"

# ── runners: one per backend, both pointing at throwaway dirs ───────────────────────────────────
home_lin="$T/home-lin"; mkdir -p "$home_lin"
home_mac="$T/home-mac"; mkdir -p "$home_mac/.pi/agent/scripts"
cp "$T/bin/launchctl" "$T/bin/launchctl" # (no-op: keeps the shim path obvious below)
PASSFILE="$T/pass/disk-reaper.sh"; mkpass "$PASSFILE" 123

inst_lin() { # inst_lin <args...>
    HOME="$home_lin" DISK_REAPER="$PASSFILE" DISK_REAPER_REPOS="$REPO" \
    DISK_REAPER_PLATFORM=linux DISK_REAPER_STATE_DIR="$T/state-lin" \
    SYSTEMD_UNIT_DIR="$T/units" SYSTEMCTL="$T/bin/systemctl" SYSTEMCTL_CALLS="$T/systemctl.log" \
    SYSTEMCTL_UNITS="$T/units" \
    bash "$INST" "$@"
}
inst_mac() { # inst_mac <args...>
    HOME="$home_mac" DISK_REAPER="$PASSFILE" DISK_REAPER_REPOS="$REPO" \
    DISK_REAPER_PLATFORM=darwin DISK_REAPER_STATE_DIR="$T/state-mac" \
    DISK_REAPER_AGENTS_DIR="$T/agents" LAUNCHCTL="$T/bin/launchctl" LAUNCHD_DOMAIN="gui/999" \
    DISK_REAPER_PYTHON="$T/bin/fakepython" ELDATO_ALLOW_TEST_HOME=1 \
    bash "$INST" "$@"
}

UNIT_DIR="$T/units"
SVC="$UNIT_DIR/eldato-disk-reaper.service"
TIM="$UNIT_DIR/eldato-disk-reaper.timer"
PLIST="$T/agents/com.eldato.disk-reaper.plist"

echo "── T1. one verb, two schedulers, the SAME pass and the SAME mode flag ──"
OUT_LIN="$(inst_lin --preview 2>&1)"; RC=$?
assert_eq "$RC" "0" "T1 the Linux target previews cleanly"
OUT_MAC="$(inst_mac --preview 2>&1)"; RC=$?
assert_eq "$RC" "0" "T1 the Darwin target previews cleanly"
assert_contains "$OUT_LIN" "would install to $UNIT_DIR" "T1 Linux previews a systemd unit"
assert_contains "$OUT_MAC" "would install to $PLIST" "T1 Darwin previews a launchd plist"
# ONE PASS: both backends name the same file, and neither substitutes a per-class script.
assert_contains "$OUT_LIN" "$PASSFILE" "T1 the timer runs THE pass"
assert_contains "$OUT_MAC" "<string>$PASSFILE</string>" "T1 the launchd job hands THE pass to the launcher (same entry point)"
# SAME FLAGS: compare the flag the two rendered artifacts carry, for each mode, mechanically.
flag_of_svc() { sed -n 's/^  ExecStart=//p' <<<"$1" | grep -o -- '--\(apply\|dry-run\)' | head -1; }
flag_of_plist() { grep -o -- '<string>--\(apply\|dry-run\)</string>' <<<"$1" | head -1 | sed -E 's|</?string>||g'; }
assert_eq "$(flag_of_svc "$OUT_LIN")" "$(flag_of_plist "$OUT_MAC")" \
    "T1 DEFAULT: the timer and the launchd job carry the SAME mode flag"
OUT_MAC_ARMED="$(inst_mac --preview --apply 2>&1)"
assert_eq "$(flag_of_svc "$OUT_LIN")" "--dry-run" "T1 DEFAULT renders the report-only flag (#1678)"
assert_eq "$(flag_of_plist "$OUT_MAC_ARMED")" "--apply" "T1 --apply is rendered into the Darwin job too"
# The Darwin job is an interpreter + the farmed launcher (#1311's TCC seam), NOT a bare bash.
assert_contains "$OUT_MAC" "$T/bin/fakepython" "T1 the Darwin job starts the TCC-holding interpreter"
assert_contains "$OUT_MAC" "pi-reap-worktrees-launchd.py" "T1 and the farmed shared launcher"
assert_contains "$OUT_MAC" "<integer>3600</integer>" "T1 the Darwin job is hourly, like the timer"
assert_contains "$OUT_MAC" "RunAtLoad" "T1 the Darwin job reports immediately on install"

echo "── T2. install, then a second install is a NO-OP (and does not reload) ──"
: >"$T/systemctl.log"; : >"$T/launchctl.log"
OUT="$(inst_lin --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T2 the systemd install exits 0"
assert_file "$TIM" "T2 the timer unit is installed"
assert_file "$SVC" "T2 the service unit is installed"
assert_contains "$OUT" "changed=1" "T2 the first install reports a change"
assert_contains "$(cat "$SVC")" "disk-reaper.sh --dry-run" "T2 the DEFAULT install is REPORT-ONLY (#1678)"
assert_contains "$(cat "$SVC")" "DISK_REAPER_REPOS=$REPO" "T2 the rendered unit carries this box's repos"
assert_contains "$(cat "$T/systemctl.log")" "enable --now eldato-disk-reaper.timer" "T2 the timer is ENABLED, not just written"
: >"$T/systemctl.log"
OUT="$(inst_lin --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T2 the second systemd install exits 0"
assert_contains "$OUT" "changed=0 pass_changed=no reload_reason=none" \
    "T2 a second install is a NO-OP (no unit change, no pass change, no reload)"
assert_absent "$(cat "$T/systemctl.log")" "restart eldato-disk-reaper.timer" "T2 a no-op does NOT restart the timer"

OUT="$(inst_mac --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T2 the launchd install exits 0"
assert_file "$PLIST" "T2 the launchd plist is installed"
assert_contains "$OUT" "changed=1" "T2 the first launchd install reports a change"
assert_contains "$(cat "$T/launchctl.log")" "bootstrap gui/999 $PLIST" "T2 it bootstraps into the user domain"
if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$PLIST" >/dev/null 2>&1 && ok "T2 the installed plist is valid XML (plutil -lint)" \
        || bad "T2 the installed plist is valid XML (plutil -lint)"
fi
if command -v python3 >/dev/null 2>&1; then
    ARGV="$(python3 - "$PLIST" <<'PY' 2>/dev/null
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    d = plistlib.load(fh)
print(" | ".join(d["ProgramArguments"]))
PY
)"
    assert_contains "$ARGV" "--script | $PASSFILE | --dry-run" \
        "T2 the plist argv is interpreter + launcher + the pass + the mode flag (strict parse)"
fi
: >"$T/launchctl.log"
OUT="$(inst_mac --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T2 the second launchd install exits 0"
assert_contains "$OUT" "changed=0 pass_changed=no reload_reason=none" "T2 a second launchd install is a NO-OP"
assert_absent "$(cat "$T/launchctl.log")" "bootstrap" "T2 a no-op does NOT re-bootstrap (which would re-run the pass)"

echo "── T3. arming is an EXPLICIT, VISIBLE, REVERSIBLE step (#1678) ──"
OUT="$(inst_lin --install --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "T3 --apply installs"
assert_contains "$(cat "$SVC")" "disk-reaper.sh --apply" "T3 armed: the flag is IN the unit, not an env default"
assert_contains "$OUT" "changed=1" "T3 arming is a change (the job reloads)"
ST="$(inst_lin --status 2>&1)"
assert_contains "$ST" "armed=apply" "T3 --status reads the arming off the INSTALLED unit"
OUT="$(inst_lin --install --dry-run 2>&1)"
assert_contains "$(cat "$SVC")" "disk-reaper.sh --dry-run" "T3 --dry-run puts the report-only mode back"
ST="$(inst_lin --status 2>&1)"
assert_contains "$ST" "armed=dry-run" "T3 --status follows the re-install (no second copy to drift)"
OUT="$(inst_mac --install --apply 2>&1)"
assert_contains "$(cat "$PLIST")" "<string>--apply</string>" "T3 armed on Darwin: visible in ProgramArguments"
ST="$(inst_mac --status 2>&1)"
assert_contains "$ST" "armed=apply" "T3 and --status says so on Darwin too"
assert_contains "$OUT" "armed:  apply" "T3 the install line names the arming (never implied)"
inst_mac --install --dry-run >/dev/null 2>&1

echo "── T4. a CHANGED PASS reloads its job (#1738) ──"
# The unit text is untouched here on purpose: only the pass's BYTES change. A job that was loaded
# against the old bytes is exactly the silent-inert-reaper shape #1738 recorded.
inst_lin --install >/dev/null 2>&1     # settle on report-only
: >"$T/systemctl.log"
mkpass "$PASSFILE" 124                  # same path, different bytes
ST="$(inst_lin --status 2>&1)"
assert_contains "$ST" "pass_drift=CHANGED since install" "T4 --status SEES the changed pass (before any re-install)"
OUT="$(inst_lin --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T4 the install after a pass edit exits 0"
assert_contains "$OUT" "pass_changed=yes" "T4 it reports the pass change"
assert_contains "$OUT" "reload_reason=pass-changed" "T4 and names the reload reason"
assert_contains "$(cat "$T/systemctl.log")" "daemon-reload" "T4 systemd: the unit files are re-read"
assert_contains "$(cat "$T/systemctl.log")" "restart eldato-disk-reaper.timer" "T4 systemd: the timer is restarted"
ST="$(inst_lin --status 2>&1)"
assert_contains "$ST" "pass_drift=in-sync" "T4 after the reload the stamp matches the pass"
: >"$T/launchctl.log"
mkpass "$PASSFILE" 125
OUT="$(inst_mac --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T4 the launchd install after a pass edit exits 0"
assert_contains "$OUT" "reload_reason=pass-changed" "T4 Darwin: the reload reason is named"
assert_contains "$(cat "$T/launchctl.log")" "bootout gui/999/com.eldato.disk-reaper" "T4 Darwin: the loaded job is booted out"
assert_contains "$(cat "$T/launchctl.log")" "bootstrap gui/999" "T4 Darwin: and bootstrapped again with the new pass"

echo "── T5. ONE status vocabulary, and the SAME pass record on both ──"
ST_LIN="$(inst_lin --status 2>&1)"; RC_LIN=$?
ST_MAC="$(inst_mac --status 2>&1)"; RC_MAC=$?
assert_eq "$RC_LIN" "0" "T5 a scheduled Linux box exits 0"
assert_eq "$RC_MAC" "0" "T5 a scheduled Darwin box exits 0"
for k in platform scheduler job job_path installed enabled active armed next_run interval_seconds last_exit; do
    assert_contains "$ST_LIN" "$k=" "T5 Linux answers '$k'"
    assert_contains "$ST_MAC" "$k=" "T5 Darwin answers '$k'"
done
assert_contains "$ST_LIN" "scheduler=systemd" "T5 Linux names systemd"
assert_contains "$ST_MAC" "scheduler=launchd" "T5 Darwin names launchd"
assert_contains "$ST_MAC" "job=com.eldato.disk-reaper" "T5 Darwin names the job label"
assert_contains "$ST_LIN" "job=eldato-disk-reaper.timer" "T5 Linux names the unit"
assert_contains "$ST_LIN" "interval_seconds=3600" "T5 both are hourly (Linux)"
assert_contains "$ST_MAC" "interval_seconds=3600" "T5 both are hourly (Darwin)"
# The KEY SET must be identical — one vocabulary, not two spellings of the same question.
keys() { sed -n 's/^\([a-z_]*\)=.*/\1/p' <<<"$1" | sort -u; }
assert_eq "$(keys "$ST_MAC")" "$(keys "$ST_LIN")" "T5 the status KEY SET is identical on both platforms"
# The pass record is the same file written by the same pass, so the record block is byte-identical.
rec() { sed -n '/^--- pass record ---/,$p' <<<"$1"; }
assert_contains "$(rec "$ST_LIN")" "  status=ok" "T5 Linux prints the pass record (what the last pass freed, and did it succeed)"
assert_contains "$(rec "$ST_LIN")" "  freed_mb=" "T5 the record carries the byte figure"
assert_eq "$(rec "$ST_MAC")" "$(rec "$ST_LIN")" "T5 Darwin prints the SAME pass record (one record, one vocabulary)"

echo "── T6. unscheduled / impossible is a LOUD failure, never a silent no-op ──"
OUT="$(HOME="$home_lin" DISK_REAPER="$PASSFILE" DISK_REAPER_PLATFORM=solaris \
    DISK_REAPER_STATE_DIR="$T/state-x" bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T6 an unknown platform exits 1"
assert_contains "$OUT" "no scheduler on this platform" "T6 and names the reason"
# No pass at all: refuse (a job pointing at nothing looks scheduled and never runs).
OUT="$(HOME="$home_lin" DISK_REAPER="$T/pass/not-here.sh" DISK_REAPER_PLATFORM=linux \
    SYSTEMD_UNIT_DIR="$T/units-x" DISK_REAPER_STATE_DIR="$T/state-x" bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "2" "T6 a SET-but-missing pass exits 2 (never a silent different copy)"
assert_contains "$OUT" "refusing to install a job that points at a DIFFERENT copy" "T6 and says why"
# #446: launchctl addresses the user domain BY UID, so a throwaway HOME would bootstrap a job whose
# plist path dies with the temp dir. Refused unless a test opts in with a launchctl shim.
# ⛔ THE REAL-HOME PROBE IS A SHIM, NOT THE HOST'S `dscl` (CI-red 2026-10-18). The installer asks
# `dscl . -read /Users/$(id -un) NFSHomeDirectory`; Ubuntu runners have no `dscl`, so `real_home`
# came back EMPTY, the guard SKIPPED, the install proceeded and this section went red ON CI ONLY —
# the mac runner (and this box) has the real binary and passed. Same idiom, and same reason, as
# scripts/install-launchd.test.sh (#446): a deterministic `/test-real-home` never equals a temp
# HOME, so the refusal path is exercised on EVERY platform instead of being skipped on the one
# platform nobody watches. The assertion is unchanged and still requires rc=1, the named reason,
# and NO plist — the shim makes the guard's INPUT deterministic; it does not soften the verdict.
cat >"$T/bin/dscl" <<'SHIM'
#!/usr/bin/env bash
echo "NFSHomeDirectory: /test-real-home"
SHIM
chmod +x "$T/bin/dscl"
# PATH is widened for THIS invocation only: $T/bin also holds the launchctl/systemctl shims, and a
# global PATH change would silently redirect the installer's `command -v systemctl` probes in the
# other sections. Only `dscl` is being supplied here.
OUT="$(HOME="$T/home-tmp" DISK_REAPER="$PASSFILE" DISK_REAPER_PLATFORM=darwin \
    DISK_REAPER_AGENTS_DIR="$T/agents-446" LAUNCHCTL="$T/bin/launchctl" PATH="$T/bin:$PATH" \
    DISK_REAPER_PYTHON="$T/bin/fakepython" DISK_REAPER_STATE_DIR="$T/state-x" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T6 a temp-HOME launchd run is REFUSED (#446)"
assert_contains "$OUT" "is not the real home" "T6 and names the real home it compared against"
assert_nofile "$T/agents-446/com.eldato.disk-reaper.plist" "T6 nothing was registered in that domain"
# An unresolved placeholder must refuse, not install a job whose argument is a literal token.
printf '<?xml version="1.0"?>\n<plist version="1.0"><dict><key>Label</key><string>{{LABEL}}</string><key>X</key><string>{{NOPE}}</string></dict></plist>\n' >"$T/bad.tmpl"
OUT="$(HOME="$home_mac" DISK_REAPER="$PASSFILE" DISK_REAPER_PLATFORM=darwin \
    DISK_REAPER_AGENTS_DIR="$T/agents-bad" LAUNCHCTL="$T/bin/launchctl" LAUNCHD_DOMAIN="gui/999" \
    LAUNCHD_TEMPLATE="$T/bad.tmpl" DISK_REAPER_PYTHON="$T/bin/fakepython" ELDATO_ALLOW_TEST_HOME=1 \
    DISK_REAPER_STATE_DIR="$T/state-x" bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T6 an unresolved placeholder exits 1"
assert_contains "$OUT" "unresolved placeholder" "T6 and names it (a literal token is an inert job)"
assert_nofile "$T/agents-bad/com.eldato.disk-reaper.plist" "T6 and installs nothing"
# A malformed plist is an inert job too (measured in #1719: an unescaped `&` broke the XML).
if command -v plutil >/dev/null 2>&1; then
    printf '<?xml version="1.0"?>\n<plist version="1.0"><dict><key>Label</key><string>{{LABEL}}</string></dict>\n' >"$T/malformed.tmpl"
    OUT="$(HOME="$home_mac" DISK_REAPER="$PASSFILE" DISK_REAPER_PLATFORM=darwin \
        DISK_REAPER_AGENTS_DIR="$T/agents-mal" LAUNCHCTL="$T/bin/launchctl" LAUNCHD_DOMAIN="gui/999" \
        LAUNCHD_TEMPLATE="$T/malformed.tmpl" DISK_REAPER_PYTHON="$T/bin/fakepython" ELDATO_ALLOW_TEST_HOME=1 \
        DISK_REAPER_STATE_DIR="$T/state-x" bash "$INST" --install 2>&1)"; RC=$?
    assert_eq "$RC" "1" "T6 a MALFORMED rendered plist exits 1"
    assert_contains "$OUT" "MALFORMED" "T6 and says so"
    assert_nofile "$T/agents-mal/com.eldato.disk-reaper.plist" "T6 and installs nothing"
fi

echo "── T7. the Mac must not get a second, divergent pass ──"
# One entry point: the launchd job's target IS the pass file, not a per-class script.
assert_contains "$(cat "$PLIST")" "--script" "T7 the Darwin job is told the pass via --script"
assert_contains "$(cat "$PLIST")" "$PASSFILE" "T7 and the pass it names is the scheduled entry point"
for perclass in pi-cache-reap.sh reap-lane-venvs.sh pi-reap-worktrees.sh; do
    assert_absent "$(cat "$PLIST")" "$perclass" "T7 the Darwin job names no per-class reaper ($perclass) — the pass owns them"
done
# The template is `.plist.tmpl` so install-launchd.sh (which renders `*.plist`) cannot bootstrap a
# half-rendered job; one installer owns each job.
TM="$ROOT/templates/launchd/com.eldato.disk-reaper.plist.tmpl"
assert_file "$TM" "T7 the consolidated job's template exists"
case "$(basename "$TM")" in
    *.plist.tmpl) ok "T7 it is NOT in install-launchd's *.plist glob (one installer owns it)" ;;
    *) bad "T7 it is NOT in install-launchd's *.plist glob (one installer owns it)" ;;
esac
# Reachability, not a comment: install-launchd must not manage the label.
OUT="$(bash "$ROOT/scripts/install-launchd.sh" --help 2>&1 || true)"
assert_contains "$(cat "$ROOT/templates/launchd/RETIRED")" "com.eldato.pi-cache-reap" \
    "T7 the per-class cache job is RETIRED in favour of the pass"
assert_contains "$(cat "$ROOT/templates/launchd/RETIRED")" "com.tortoise.worktree-reaper" \
    "T7 the per-class worktree job is RETIRED in favour of the pass"

echo "── T8. uninstall is reversible and leaves no stamp ──"
OUT="$(inst_lin --install >/dev/null 2>&1; inst_lin --uninstall 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8 the systemd uninstall exits 0"
assert_nofile "$TIM" "T8 the timer is removed"
assert_nofile "$SVC" "T8 the service is removed"
assert_nofile "$T/state-lin/disk-reaper.schedule" "T8 the schedule stamp is removed with it"
ST="$(inst_lin --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T8 --status on an uninstalled box exits 1 (the bring-up's FAIL, not a silent absence)"
assert_contains "$ST" "installed=no" "T8 and says installed=no"
OUT="$(inst_mac --uninstall 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8 the launchd uninstall exits 0"
assert_nofile "$PLIST" "T8 the plist is removed"
assert_contains "$(cat "$T/launchctl.log")" "bootout gui/999/com.eldato.disk-reaper" "T8 and the job is booted out"

echo "── T9. static pins: no deletion rule here, and no sysadm-only shortcut ──"
# Every recursive delete must be of a MKTEMP dir this script created ($tmp/$tmpd), never a path it was
# pointed at — an installer that cleans up its own scratch space is fine; one that deletes a unit dir or
# a state dir is the #7795 shape.
RMS_BAD="$(grep -nE '(^|[^a-zA-Z_])rm -rf' "$INST" | grep -vE 'rm -rf "\$tmp|rm -rf "\$tmpd' || true)"
assert_absent "$RMS_BAD" 'rm -rf' "T9 every rm -rf in the installer removes ONLY a mktemp dir it made"
assert_absent "$(grep -n 'disk-reaper.sh.*--apply' "$INST" | grep -v 'MODE_FLAG\|--apply)' || true)" "DISK_REAPER_DRY_RUN=0" \
    "T9 the arming decision is a FLAG this verb was given, never an env default"
assert_contains "$(cat "$INST")" 'MODE_FLAG="--dry-run"' "T9 the shipped default is the report-only flag"

echo
echo "──────────────────────────────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "ALL PASS ($PASS assertions)"
    exit 0
fi
echo "FAILURES: $FAIL of $PASS assertions"
exit 1
