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
  *is-enabled*)
      case "${SYSTEMCTL_ENABLED:-enabled}" in
        # REAL systemd prints `disabled` AND exits 1 (an always-0 shim is precisely why the
        # double-line `enabled=` defect was invisible to this suite).
        disabled) echo disabled; exit 1 ;;
        *)        echo "${SYSTEMCTL_ENABLED:-enabled}" ;;
      esac ;;
  *is-active*) echo "${SYSTEMCTL_ACTIVE:-active}" ;;
  *list-timers*) echo "Mon 2026-10-19 00:30:00 UTC 1h left Sun 2026-10-18 23:30:00 UTC 3h ago eldato-disk-reaper.timer eldato-disk-reaper.service" ;;
  *show-environment*) [ "${SYSTEMCTL_USER_MANAGER:-yes}" = yes ] || exit 1 ;;
  *show*) echo "${FAKE_EXEC_STATUS:-0}" ;;
  # `*cat *`, not `cat *`: the user-manager SC is a MULTI-WORD command (`systemctl --user`), so the
  # verb is not at the start of "$*". A start-anchored arm answered NOTHING for `--user cat <unit>`,
  # which read as "already gone" — the shim was hiding the very question the read-back asks.
  *cat\ *) f="${SYSTEMCTL_UNITS:-}/$(printf '%s' "$*" | sed 's/^.*cat //')"
           [ -f "$f" ] || exit 1; cat "$f" ;;
esac
exit 0
SC
chmod +x "$T/bin/systemctl"

# launchctl shim: keeps a LOADED-STATE file, so the installer's "is it loaded?" question has a real
# answer without touching the live GUI domain. `print` FAILS for an unloaded job, as real launchctl
# does — a shim that exited 0 for both states made "is it loaded?" unassertable.
cat >"$T/bin/launchctl" <<LC
#!/usr/bin/env bash
STATE="${T}/launchctl.state"
printf '%s\n' "\$*" >>"${T}/launchctl.log"
case "\${1:-}" in
  bootstrap) mkdir -p "\$STATE"; exit 0 ;;
  bootout)   [ -n "\${LAUNCHCTL_BOOTOUT_IGNORE:-}" ] && exit 0; rm -rf "\$STATE"; exit 0 ;;
  enable)    exit 0 ;;
  print)     [ -d "\$STATE" ] || exit 1
             printf '\tstate = %s\n\truns = 2\n\tlast exit code = %s\n' "\${LAUNCHCTL_STATE:-not running}" "\${FAKE_LAST_EXIT:-0}"
             exit 0 ;;
esac
exit 0
LC
chmod +x "$T/bin/launchctl"

# A passwd probe for the #446 guard: on Linux the real `getent` answers; on macOS the real `dscl` does.
# These stubs let ONE assertion run on BOTH platforms (`getent` answering, `dscl` silent = the Linux
# shape), which is the only way a macOS dev box can see what ubuntu-latest sees.
# ⛔ THE STUB EMITS A REAL SEVEN-FIELD passwd LINE, GECOS INCLUDED (#2048 review, P1): the first version
# wrote an EMPTY GECOS through a `%s` placeholder, so a field-index bug in the installer (reading GECOS
# instead of home) fell through to the `~user` arm and the assertion passed without ever exercising
# `getent`. A non-empty GECOS is what makes this stub able to fail.
mkdir -p "$T/bin/probe"
printf '#!/usr/bin/env bash\n[ "${1:-}" = passwd ] || exit 2\necho "runner:x:501:20:Real Name:${REAL_HOME_STUB}:/bin/sh"\n' >"$T/bin/probe/getent"
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin/probe/dscl"
chmod +x "$T/bin/probe/getent" "$T/bin/probe/dscl"
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
for k in platform scheduler job job_path installed enabled active armed next_run interval_seconds last_exit repos runner; do
    assert_contains "$ST_LIN" "$k=" "T5 Linux answers '$k'"
    assert_contains "$ST_MAC" "$k=" "T5 Darwin answers '$k'"
done
assert_contains "$ST_LIN" "scheduler=systemd" "T5 Linux names systemd"
assert_contains "$ST_MAC" "scheduler=launchd" "T5 Darwin names launchd"
assert_contains "$ST_MAC" "job=com.eldato.disk-reaper" "T5 Darwin names the job label"
assert_contains "$ST_LIN" "job=eldato-disk-reaper.timer" "T5 Linux names the unit"
# `repos=` answers "which repos does the SCHEDULED job scan?", read off the artifact — not "what did the
# installing shell happen to export" (the P1 shape: a Mac exporting only $AGENT_INFRA_PATH ran the
# tortoise venv against agent-infra, and one non-empty repo made the empty-list refusal not fire).
assert_contains "$ST_LIN" "repos=$REPO" "T5 Linux reports the repos the JOB scans (off the installed unit)"
assert_contains "$ST_MAC" "repos=$REPO" "T5 Darwin reports the same, off the installed plist"
# `runner=` is the TCC seam on a Mac and `/bin/bash` on a cell — the single most likely reason a pass
# fails closed, read off the artifact (it used to be printed by --install only, while the comment above
# resolve_python promised --status answered it — #2048 review, P2).
assert_contains "$ST_LIN" "runner=/bin/bash" "T5 Linux reports the runner the timer actually starts"
assert_contains "$ST_MAC" "runner=$T/bin/fakepython" "T5 Darwin reports the interpreter+launcher the job starts"
assert_contains "$ST_MAC" "pi-reap-worktrees-launchd.py" "T5 and names the farmed launcher, not just the interpreter"
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
OUT="$(HOME="$T/home-tmp" DISK_REAPER="$PASSFILE" DISK_REAPER_PLATFORM=darwin \
    DISK_REAPER_AGENTS_DIR="$T/agents-446" LAUNCHCTL="$T/bin/launchctl" \
    DISK_REAPER_PYTHON="$T/bin/fakepython" DISK_REAPER_STATE_DIR="$T/state-x" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "3" "T6 a temp-HOME launchd run is DECLINED (#446, exit 3 — not a failure of the box)"
assert_contains "$OUT" "is not the real home" "T6 and names the real home it compared against"
assert_nofile "$T/agents-446/com.eldato.disk-reaper.plist" "T6 nothing was registered in that domain"
# ⛔ THE #446 GUARD MUST FIRE ON LINUX TOO (#2048 review, P1). The probe was `dscl`, which is macOS-only,
# so on the ubuntu-latest gate this refusal silently did nothing — and the breakage could not be
# reproduced on a Mac, where dscl answers. Same assertion forced onto the LINUX shape (getent answers,
# dscl silent), so one dev box can see what CI sees.
GETENT_STUB='#!/usr/bin/env bash\n[ "${1:-}" = passwd ] || exit 2\necho "%s:x:501:20::${REAL_HOME_STUB}:/bin/sh" "${2:-}"\n'
printf "$GETENT_STUB" >"$T/bin/probe/getent"; chmod +x "$T/bin/probe/getent"
OUT="$(PATH="$T/bin/probe:$PATH" REAL_HOME_STUB="$T/real-home" HOME="$T/home-tmp2" \
    DISK_REAPER="$PASSFILE" DISK_REAPER_PLATFORM=darwin DISK_REAPER_AGENTS_DIR="$T/agents-446b" \
    LAUNCHCTL="$T/bin/launchctl" DISK_REAPER_PYTHON="$T/bin/fakepython" \
    DISK_REAPER_STATE_DIR="$T/state-x" bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "3" "T6 the temp-HOME decline fires on the LINUX probe too (getent, no dscl) — the CI shape"
assert_contains "$OUT" "is not the real home" "T6 and names the home it compared against"
assert_nofile "$T/agents-446b/com.eldato.disk-reaper.plist" "T6 and registers nothing there either"
# …and an answer NO probe can give is a REFUSAL, not a pass: "cannot tell" must never mean "fine".
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin/probe/getent"
printf '#!/usr/bin/env bash\necho nosuchuser\n' >"$T/bin/probe/id"; chmod +x "$T/bin/probe/id" "$T/bin/probe/getent"
OUT="$(PATH="$T/bin/probe:$PATH" HOME="$T/home-tmp3" DISK_REAPER="$PASSFILE" \
    DISK_REAPER_PLATFORM=darwin DISK_REAPER_AGENTS_DIR="$T/agents-446c" LAUNCHCTL="$T/bin/launchctl" \
    DISK_REAPER_PYTHON="$T/bin/fakepython" DISK_REAPER_STATE_DIR="$T/state-x" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "4" "T6 an UNDETERMINABLE real home is a FAILURE (4), never a decline (fail-closed)"
assert_contains "$OUT" "cannot determine the real home" "T6 and names the probe it could not answer with"
assert_contains "$OUT" "NOT a decline" "T6 and says out loud that this is not the 'not this box' code (setup.sh reports it)"
assert_nofile "$T/agents-446c/com.eldato.disk-reaper.plist" "T6 and registers nothing"
printf "$GETENT_STUB" >"$T/bin/probe/getent"; chmod +x "$T/bin/probe/getent"; rm -f "$T/bin/probe/id"
# …and a HOME that differs only in SPELLING is the same home (#2048 review, P2): a trailing slash used
# to decline a correctly-configured Mac, which setup.sh turns into SKIPPED + a green exit.
mkdir -p "$T/real-home"
OUT="$(PATH="$T/bin/probe:$PATH" REAL_HOME_STUB="$T/real-home" HOME="$T/real-home/" \
    DISK_REAPER="$PASSFILE" DISK_REAPER_PLATFORM=darwin DISK_REAPER_AGENTS_DIR="$T/agents-norm" \
    DISK_REAPER_REPOS="$REPO" LAUNCHCTL="$T/bin/launchctl" LAUNCHD_DOMAIN="gui/999" \
    DISK_REAPER_PYTHON="$T/bin/fakepython" DISK_REAPER_STATE_DIR="$T/state-x" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T6 HOME with a trailing slash is the SAME home (not declined)"
assert_file "$T/agents-norm/com.eldato.disk-reaper.plist" "T6 and the job was installed for it"
"$T/bin/launchctl" bootout gui/999/com.eldato.disk-reaper >/dev/null 2>&1 || true
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
# NOT gated on `plutil`: CI is ubuntu-latest, where plutil does not exist, so a plutil-gated refusal is
# a refusal that never runs on the platform the gate lives on (#2048 review). Any linter is enough.
if command -v plutil >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
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
# ⛔ AN UNINSTALL THAT DID NOT TAKE MUST NOT REPORT SUCCESS (#2048 review, P2). A denied `rm` used to
# print "uninstalled" and exit 0, and systemd reloads the surviving unit at the next boot.
RO="$T/units-ro"; mkdir -p "$RO"
cmp -s "$SVC" "$RO/eldato-disk-reaper.service" 2>/dev/null || inst_lin --install >/dev/null 2>&1
cp -f "$UNIT_DIR/eldato-disk-reaper.service" "$UNIT_DIR/eldato-disk-reaper.timer" "$RO/"
chmod 500 "$RO"
OUT="$(HOME="$home_lin" DISK_REAPER="$PASSFILE" DISK_REAPER_REPOS="$REPO" DISK_REAPER_PLATFORM=linux \
    DISK_REAPER_STATE_DIR="$T/state-lin" SYSTEMD_UNIT_DIR="$RO" SYSTEMCTL="$T/bin/systemctl" \
    SYSTEMCTL_CALLS="$T/systemctl.log" bash "$INST" --uninstall 2>&1)"; RC=$?
chmod 700 "$RO"
assert_eq "$RC" "1" "T8 an uninstall whose rm was DENIED exits 1 (never 'uninstalled')"
assert_contains "$OUT" "INCOMPLETE" "T8 and says the removal is incomplete"
assert_absent "$OUT" "uninstalled eldato-disk-reaper" "T8 and does NOT claim it uninstalled anything"
# The launchd equivalent: a bootout that did not take leaves a job launchd re-loads at the next login.
inst_mac --install >/dev/null 2>&1
OUT="$(LAUNCHCTL_BOOTOUT_IGNORE=1 inst_mac --uninstall 2>&1)"; RC=$?
assert_eq "$RC" "1" "T8 a bootout that did NOT take exits 1 (the job would come back at login)"
assert_contains "$OUT" "INCOMPLETE" "T8 and names it"
# ⛔ …AND A PROBE FLIP BETWEEN INSTALL AND UNINSTALL IS THE SAME FALSE PASS (#2048 review, P2). The
# install target is RE-DERIVED on every run from the sudo probe and the user-manager answer, so a unit
# installed as root and uninstalled by a sudo-less user (or the reverse) used to be removed from — and
# read back in — a directory the install never wrote, printing "uninstalled" while the real unit stayed
# ENABLED and kept deleting hourly. The stamp now records where the install actually went.
SYS_DIR="$T/sys-units"; mkdir -p "$SYS_DIR"
OUT="$(HOME="$home_lin" DISK_REAPER="$PASSFILE" DISK_REAPER_REPOS="$REPO" DISK_REAPER_PLATFORM=linux \
    DISK_REAPER_STATE_DIR="$T/state-flip" SYSTEMD_SYSTEM_DIR="$SYS_DIR" SUDO="" \
    SYSTEMCTL="$T/bin/systemctl" SYSTEMCTL_CALLS="$T/systemctl.log" bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8b installed into the SYSTEM dir (sudo available at install time)"
assert_file "$SYS_DIR/eldato-disk-reaper.service" "T8b the unit really is in the system dir"
# Now flip the probe: sudo answers NOTHING and a user manager answers instead, so `--uninstall` derives
# the user dir. The recorded location must win.
NO_SUDO="$T/bin/no-sudo"; printf '#!/bin/bash\nexit 1\n' >"$NO_SUDO"; chmod +x "$NO_SUDO"
OUT="$(HOME="$home_lin" DISK_REAPER="$PASSFILE" DISK_REAPER_REPOS="$REPO" DISK_REAPER_PLATFORM=linux \
    DISK_REAPER_STATE_DIR="$T/state-flip" SYSTEMD_SYSTEM_DIR="$SYS_DIR" SUDO="$NO_SUDO" \
    SYSTEMCTL_USER="$T/bin/systemctl --user" SYSTEMCTL="$T/bin/systemctl" \
    SYSTEMCTL_CALLS="$T/systemctl.log" bash "$INST" --uninstall 2>&1)"; RC=$?
if [ -f "$SYS_DIR/eldato-disk-reaper.service" ] || [ -f "$SYS_DIR/eldato-disk-reaper.timer" ]; then
    bad "T8b the recorded install dir was NOT removed (a probe flip left the unit behind)"
    assert_eq "$RC" "1" "T8b …and the uninstall must NOT claim success over a surviving unit"
else
    ok "T8b the uninstall removed the unit from the RECORDED dir, not the re-derived one"
    assert_eq "$RC" "0" "T8b …and exits 0 only because the unit is really gone"
fi
# The mirrored false NEGATIVE: `--status` must not call a scheduled box uninstalled because the probe
# moved. Re-install to the system dir, then read status with the flipped probe.
OUT="$(HOME="$home_lin" DISK_REAPER="$PASSFILE" DISK_REAPER_REPOS="$REPO" DISK_REAPER_PLATFORM=linux \
    DISK_REAPER_STATE_DIR="$T/state-flip" SYSTEMD_SYSTEM_DIR="$SYS_DIR" SUDO="" \
    SYSTEMCTL="$T/bin/systemctl" SYSTEMCTL_CALLS="$T/systemctl.log" bash "$INST" --install 2>&1)"
OUT="$(HOME="$home_lin" DISK_REAPER="$PASSFILE" DISK_REAPER_REPOS="$REPO" DISK_REAPER_PLATFORM=linux \
    DISK_REAPER_STATE_DIR="$T/state-flip" SYSTEMD_SYSTEM_DIR="$SYS_DIR" SUDO="$NO_SUDO" \
    SYSTEMCTL_USER="$T/bin/systemctl --user" SYSTEMCTL="$T/bin/systemctl" \
    SYSTEMCTL_CALLS="$T/systemctl.log" bash "$INST" --status 2>&1)"; RC=$?
assert_contains "$OUT" "installed=yes" "T8b --status finds the job at the RECORDED location despite a probe flip"
# ⛔ AND THE EXIT CODE, which is the contract `cloud-cell-bringup.sh` gates on: reading is-enabled /
# is-active off the re-derived manager answered `disabled inactive` for a unit that is installed,
# enabled and armed — exit 1 on a correctly scheduled box, and the bring-up dies on it.
assert_eq "$RC" "0" "T8b --status exits 0 for a scheduled box even when the sudo probe flipped"
assert_contains "$OUT" "job_path=$SYS_DIR/" "T8b …and reports the RECORDED job path, not the empty derived one"
HOME="$home_lin" DISK_REAPER="$PASSFILE" DISK_REAPER_REPOS="$REPO" DISK_REAPER_PLATFORM=linux \
    DISK_REAPER_STATE_DIR="$T/state-flip" SYSTEMD_SYSTEM_DIR="$SYS_DIR" SUDO="" \
    SYSTEMCTL="$T/bin/systemctl" SYSTEMCTL_CALLS="$T/systemctl.log" bash "$INST" --uninstall >/dev/null 2>&1
# ⛔ A FAILED UNINSTALL MUST NOT DESTROY THE ARMING RECORD (#2048 review, P2). The stamp is the only
# memory that the box was armed; deleting it before the removal is verified means the next no-flag
# install (exactly what setup.sh / sync.sh runs) adopts nothing and silently re-installs REPORT-ONLY on
# a box the owner had armed.
inst_mac --install --apply >/dev/null 2>&1
assert_contains "$(cat "$PLIST")" "<string>--apply</string>" "T8d the box is armed before the failed uninstall"
OUT="$(LAUNCHCTL_BOOTOUT_IGNORE=1 inst_mac --uninstall 2>&1)"; RC=$?
assert_eq "$RC" "1" "T8d a bootout that did not take fails the uninstall"
[ -f "$T/state-mac/disk-reaper.schedule" ] && ok "T8d …and the ARMED stamp SURVIVES the failure (the arming is not forfeited)" \
    || bad "T8d the stamp was deleted by a FAILED uninstall — the next sync would silently disarm the box"
inst_mac --install >/dev/null 2>&1
assert_contains "$(cat "$PLIST")" "<string>--apply</string>" \
    "T8d …so the next no-flag install is still ARMED (no silent downgrade to report-only)"
rm -rf "$T/launchctl.state"
inst_mac --uninstall >/dev/null 2>&1 || true
rm -rf "$T/launchctl.state"   # settle: the shim's loaded-state is global to this suite

echo "── T8c. the TWO templates are TWO languages: XML entities for the plist, NONE for the unit ──"
# systemd does not decode XML entities, so routing the unit through the plist escaper rendered a PATH
# carrying `&` as `…/rd&amp;d` — a directory that does not exist, inside the scheduled job's PATH.
AMP_DIR="$T/rd&d"; mkdir -p "$AMP_DIR"
OUT="$(PATH="$T/bin:$AMP_DIR:$PATH" HOME="$home_lin" DISK_REAPER="$PASSFILE" DISK_REAPER_REPOS="$REPO" \
    DISK_REAPER_PLATFORM=linux DISK_REAPER_STATE_DIR="$T/state-amp" SYSTEMD_UNIT_DIR="$T/units-amp" \
    SYSTEMCTL="$T/bin/systemctl" SYSTEMCTL_CALLS="$T/systemctl.log" bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T8c installs a unit while PATH carries an ampersand"
assert_contains "$(cat "$T/units-amp/eldato-disk-reaper.service")" "$AMP_DIR" \
    "T8c the systemd unit carries the RAW path (systemd does not decode entities)"
assert_absent "$(cat "$T/units-amp/eldato-disk-reaper.service")" "&amp;" \
    "T8c …and NOT an XML entity (a literal ampersand belongs in a unit as itself)"
# The plist is XML: there the entity is REQUIRED, and the result must still parse.
OUT="$(PATH="$T/bin:$AMP_DIR:$PATH" inst_mac --install 2>&1)"
assert_contains "$(cat "$PLIST")" "&amp;" "T8c the launchd plist DOES escape the ampersand (XML)"
if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$PLIST" >/dev/null 2>&1 && ok "T8c …and the plist still lints" || bad "T8c the plist must lint with an ampersand in PATH"
else
    python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "$PLIST" >/dev/null 2>&1 \
        && ok "T8c …and the plist still parses (python plistlib)" || bad "T8c the plist must parse with an ampersand in PATH"
fi
inst_mac --uninstall >/dev/null 2>&1

echo "── T9. static pins: no deletion rule here, and no sysadm-only shortcut ──"
# Every recursive delete must be of a MKTEMP dir this script created ($tmp/$tmpd), never a path it was
# pointed at — an installer that cleans up its own scratch space is fine; one that deletes a unit dir or
# a state dir is the #7795 shape.
RMS_BAD="$(grep -nE '(^|[^a-zA-Z_])rm -rf' "$INST" | grep -vE 'rm -rf "\$tmp|rm -rf "\$tmpd' || true)"
assert_absent "$RMS_BAD" 'rm -rf' "T9 every rm -rf in the installer removes ONLY a mktemp dir it made"
assert_absent "$(grep -n 'disk-reaper.sh.*--apply' "$INST" | grep -v 'MODE_FLAG\|--apply)' || true)" "DISK_REAPER_DRY_RUN=0" \
    "T9 the arming decision is a FLAG this verb was given, never an env default"
assert_contains "$(cat "$INST")" 'MODE_FLAG="--dry-run"' "T9 the shipped default is the report-only flag"

echo "── T10. --status: the EXIT CODE is the contract (a present file is not a scheduled job) ──"
# `cloud-cell-bringup.sh` gates on this code, and the old code returned 0 whenever the unit/plist FILE
# existed — so a disabled timer, or a job left behind by `launchctl bootout`, certified a box whose
# reaper never fires (#2048 review, P1).
inst_lin --install >/dev/null 2>&1
ST="$(inst_lin --status 2>&1)"; RC=$?
assert_eq "$RC" "0" "T10 a genuinely scheduled+loaded Linux box exits 0"
OUT="$(SYSTEMCTL_ENABLED=disabled inst_lin --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T10 a PRESENT but DISABLED timer exits 1 (it will not fire unattended)"
assert_contains "$OUT" "NOT scheduled" "T10 and says which state it read"
assert_eq "$(grep -c '^enabled=' <<<"$OUT")" "1" \
    "T10 enabled= is ONE line even when systemctl prints 'disabled' AND exits 1"
OUT="$(SYSTEMCTL_ACTIVE=inactive inst_lin --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T10 a loaded-but-INACTIVE timer is not 'scheduled' either"
# launchd: a plist on disk that the domain does NOT hold. A bootout leaves exactly this state.
inst_mac --install >/dev/null 2>&1
ST="$(inst_mac --status 2>&1)"; RC=$?
assert_eq "$RC" "0" "T10 a genuinely loaded Darwin job exits 0"
"$T/bin/launchctl" bootout gui/999/com.eldato.disk-reaper >/dev/null 2>&1
OUT="$(inst_mac --status 2>&1)"; RC=$?
assert_eq "$RC" "1" "T10 a plist left after a BOOTOUT exits 1 (installed is not scheduled)"
assert_contains "$OUT" "NOT loaded" "T10 and names it"
assert_contains "$OUT" "enabled=disabled" "T10 and reports the job as disabled, not as healthy"
# A token that means "until reboot" (or "never pulled in at boot") must NOT read as scheduled: the only
# enabled-ish state this installer's own `enable --now` can create is `enabled` (#2048 review, P2).
for tok in enabled-runtime static indirect transient alias generated; do
  OUT="$(SYSTEMCTL_ENABLED=$tok inst_lin --status 2>&1)"; RC=$?
  assert_eq "$RC" "1" "T10 enabled=$tok is NOT scheduled (it would vanish at the next reboot)"
done
# A diagnostic line BEFORE the state token must not become the value: select the token, not the line.
printf '#!/usr/bin/env bash\ncase "$*" in\n *is-enabled*) echo "Failed to get unit file state: x"; echo enabled ;;\n *is-active*) echo active ;;\n *list-timers*) echo "" ;;\n *) exit 0 ;;\nesac\n' >"$T/bin/systemctl-noisy"
chmod +x "$T/bin/systemctl-noisy"
OUT="$(HOME="$home_lin" DISK_REAPER="$PASSFILE" DISK_REAPER_REPOS="$REPO" DISK_REAPER_PLATFORM=linux \
    DISK_REAPER_STATE_DIR="$T/state-noisy" SYSTEMD_UNIT_DIR="$T/units-noisy" \
    SYSTEMCTL="$T/bin/systemctl-noisy" bash "$INST" --status 2>&1)"; RC=$?
assert_eq "$RC" "0" "T10 a diagnostic line before the state token does not flip a scheduled box to NOT scheduled"
assert_contains "$OUT" "enabled=enabled" "T10 and enabled= carries the TOKEN, not the warning line"
# An INSTALLED job whose repo list is legitimately empty is not "not installed" (#2048 review, P2).
inst_lin --install >/dev/null 2>&1
NONREPO="$T/not-a-repo"; mkdir -p "$NONREPO"
OUT="$(HOME="$home_lin" DISK_REAPER="$PASSFILE" DISK_REAPER_REPOS="$NONREPO" DISK_REAPER_PLATFORM=linux \
    DISK_REAPER_STATE_DIR="$T/state-norepo" SYSTEMD_UNIT_DIR="$T/units-norepo" \
    SYSTEMCTL="$T/bin/systemctl" SYSTEMCTL_CALLS="$T/systemctl.log" bash "$INST" --install 2>&1)"
OUT="$(HOME="$home_lin" DISK_REAPER="$PASSFILE" DISK_REAPER_REPOS="$NONREPO" DISK_REAPER_PLATFORM=linux \
    DISK_REAPER_STATE_DIR="$T/state-norepo" SYSTEMD_UNIT_DIR="$T/units-norepo" \
    SYSTEMCTL="$T/bin/systemctl" SYSTEMCTL_CALLS="$T/systemctl.log" bash "$INST" --status 2>&1)"; RC=$?
assert_contains "$OUT" "repos=<none> (the installed job scans no repo" \
    "T10 an installed job with an EMPTY repo list is described as installed, not as 'not installed'"
assert_absent "$OUT" "not installed — this is what a fresh install WOULD scan" \
    "T10 and does not claim the job is missing"
# The stamp is an optimisation, never the install: an unwritable state dir must NOT fail a job that was
# installed, enabled and read back — that falsely told setup.sh "this Mac has NO schedule" (#2048 review).
ROSTATE="$T/state-ro"; mkdir -p "$ROSTATE"; chmod 500 "$ROSTATE"
OUT="$(HOME="$home_lin" DISK_REAPER="$PASSFILE" DISK_REAPER_REPOS="$REPO" DISK_REAPER_PLATFORM=linux \
    DISK_REAPER_STATE_DIR="$ROSTATE/nested" SYSTEMD_UNIT_DIR="$T/units-rostate" \
    SYSTEMCTL="$T/bin/systemctl" SYSTEMCTL_CALLS="$T/systemctl.log" bash "$INST" --install 2>&1)"; RC=$?
chmod 700 "$ROSTATE"
assert_eq "$RC" "0" "T10 an UNWRITABLE state dir does not fail an install that succeeded"
assert_contains "$OUT" "could not be written" "T10 and the degradation is named out loud"
assert_contains "$OUT" "every later install" "T10 and says what it costs (a reload every install, not 'no reload')"
assert_file "$T/units-rostate/eldato-disk-reaper.timer" "T10 while the timer really was installed"
# …and `--status` names the REAL cause of the missing stamp instead of prescribing the remedy that just
# failed ("re-run --install" loops forever on an unwritable state dir — #2048 review).
OUT="$(HOME="$home_lin" DISK_REAPER="$PASSFILE" DISK_REAPER_REPOS="$REPO" DISK_REAPER_PLATFORM=linux \
    DISK_REAPER_STATE_DIR="$ROSTATE/nested" SYSTEMD_UNIT_DIR="$T/units-rostate" \
    SYSTEMCTL="$T/bin/systemctl" SYSTEMCTL_CALLS="$T/systemctl.log" bash "$INST" --status 2>&1)"
assert_contains "$OUT" "cannot write" "T10 --status names the unwritable state dir as the cause"
assert_absent "$OUT" "older installer" "T10 and does not blame an older installer that was never involved"
# `active=` is the launchd momentary signal, and it MUST be read: the shim's default state ("not running")
# is exactly what hid a call to a renamed function (a `command not found` yielding inactive forever).
"$T/bin/launchctl" bootout gui/999/com.eldato.disk-reaper >/dev/null 2>&1 || true
inst_mac --install >/dev/null 2>&1
OUT="$(LAUNCHCTL_STATE=running inst_mac --status 2>&1)"; RC=$?
assert_eq "$RC" "0" "T10 a loaded Darwin job whose pass is RUNNING still exits 0"
assert_contains "$OUT" "active=active" "T10 and active= reports the pass as running (not a constant inactive)"
assert_absent "$OUT" "command not found" "T10 and --status emits no shell error into its own output"

inst_lin --install >/dev/null 2>&1
echo "── T11. both systemd targets, including the two arms no test could reach ──"
# (a) the SYSTEM unit with `SUDO=""` — the "already root / container" arm. The system unit dir is a
# seam now, so this branch is executable without real sudo writing to /etc/systemd/system.
SYS="$T/etc-units"; : >"$T/systemctl.log"
OUT="$(HOME="$home_lin" DISK_REAPER="$PASSFILE" DISK_REAPER_REPOS="$REPO" DISK_REAPER_PLATFORM=linux \
    DISK_REAPER_STATE_DIR="$T/state-sys" SUDO= SYSTEMD_SYSTEM_DIR="$SYS" \
    SYSTEMCTL="$T/bin/systemctl" SYSTEMCTL_CALLS="$T/systemctl.log" bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T11 the SYSTEM target installs (SUDO empty = already root)"
assert_contains "$OUT" "target=system" "T11 and reports the system target"
assert_file "$SYS/eldato-disk-reaper.service" "T11 the unit landed in the SYSTEM dir"
assert_contains "$(cat "$SYS/eldato-disk-reaper.service")" "User=" \
    "T11 a SYSTEM unit keeps User= (it does not run as root)"
# (b) the USER unit: no sudo, but a working user manager. `User=` MUST be dropped (systemd rejects it in
# a user unit) and every call must go through `systemctl --user`.
OUT="$(HOME="$home_lin" DISK_REAPER="$PASSFILE" DISK_REAPER_REPOS="$REPO" DISK_REAPER_PLATFORM=linux \
    DISK_REAPER_STATE_DIR="$T/state-usr" SUDO=false SYSTEMCTL="$T/bin/systemctl" \
    SYSTEMCTL_USER="$T/bin/systemctl --user" SYSTEMCTL_CALLS="$T/systemctl.log" \
    bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T11 the USER target installs when there is no sudo but a user manager"
assert_contains "$OUT" "target=user" "T11 and reports the user target"
USR="$home_lin/.config/systemd/user"
assert_file "$USR/eldato-disk-reaper.service" "T11 the unit landed in the USER dir"
assert_absent "$(cat "$USR/eldato-disk-reaper.service")" "User=" \
    "T11 a USER unit carries no User= (systemd rejects it)"
assert_contains "$(cat "$T/systemctl.log")" "--user enable --now eldato-disk-reaper.timer" \
    "T11 and it drives the USER manager, not the system one"
# A host with neither an armable system unit nor a user manager is still a LOUD failure, not a skip.
OUT="$(HOME="$home_lin" DISK_REAPER="$PASSFILE" DISK_REAPER_REPOS="$REPO" DISK_REAPER_PLATFORM=linux \
    DISK_REAPER_STATE_DIR="$T/state-non" SUDO=false SYSTEMCTL="$T/bin/systemctl" \
    SYSTEMCTL_USER="$T/bin/systemctl --user" SYSTEMCTL_USER_MANAGER=no \
    SYSTEMCTL_CALLS="$T/systemctl.log" bash "$INST" --install 2>&1)"; RC=$?
assert_eq "$RC" "1" "T11 no system unit and no user manager exits 1"
assert_contains "$OUT" "no scheduler available" "T11 and names the reason"
inst_lin --install >/dev/null 2>&1

echo "── T12. an owner's arming survives a NO-FLAG re-install (the setup.sh / sync.sh path) ──"
# `pi-bootstrap/setup.sh` re-installs with `--install` and NO mode flag on every run, and `sync.sh`
# runs setup.sh — so an arming that lived only in the invocation was silently reverted to report-only,
# and the job rebootstrapped. The Mac could never STAY armed (#2048 review, P1).
inst_lin --install --apply >/dev/null 2>&1
assert_contains "$(cat "$SVC")" "disk-reaper.sh --apply" "T12 armed explicitly"
OUT="$(inst_lin --install 2>&1)"; RC=$?
assert_eq "$RC" "0" "T12 a NO-FLAG re-install (exactly what setup.sh does) exits 0"
assert_contains "$(cat "$SVC")" "disk-reaper.sh --apply" "T12 …and does NOT revert the owner's arming"
assert_contains "$(inst_lin --status 2>&1)" "armed=apply" "T12 --status agrees the installed job is still armed"
inst_mac --install --apply >/dev/null 2>&1
inst_mac --install >/dev/null 2>&1
assert_contains "$(cat "$PLIST")" "<string>--apply</string>" \
    "T12 Darwin: the same rule (a no-flag re-install keeps the arming)"
# An EXPLICIT flag still wins, and the REVERSAL is durable too.
inst_lin --install --dry-run >/dev/null 2>&1
inst_lin --install >/dev/null 2>&1
assert_contains "$(cat "$SVC")" "disk-reaper.sh --dry-run" \
    "T12 an explicit --dry-run is not undone by the next no-flag install"
# …and a fresh install after --uninstall starts REPORT-ONLY again: the stamp is the only memory.
inst_lin --uninstall >/dev/null 2>&1
inst_lin --install >/dev/null 2>&1
assert_contains "$(cat "$SVC")" "disk-reaper.sh --dry-run" \
    "T12 after --uninstall a fresh install is report-only again (the stamp was the memory)"

# ── T12b: the ARMING has a date, and a sync does not move it (#2048 review, P3) ──────────────────
# `installed_at=` is re-dated by EVERY install, so it cannot answer "since when has this box been
# DELETING?". The docs call arming a dated owner step; without armed_at= the only dated artifact on
# the box re-dates itself at each sync and the claim is prose. This discriminates: the arming date
# must be PRESENT, must SURVIVE a no-flag re-install unchanged, and must differ from installed_at=
# (which does move) — otherwise the field is just installed_at under another name.
LIN_STAMP="$T/state-lin/disk-reaper.schedule"
inst_lin --install --apply >/dev/null 2>&1
ARMED_AT_1="$(sed -n 's/^armed_at=//p' "$LIN_STAMP")"
ARMED_BY_1="$(sed -n 's/^armed_by=//p' "$LIN_STAMP")"
[ -n "$ARMED_AT_1" ] && ok "T12b an explicit arming is DATED on the box (armed_at=)" \
    || bad "T12b an explicit arming records when it was made (armed_at= was empty)"
[ -n "$ARMED_BY_1" ] && ok "T12b …and ATTRIBUTED (armed_by=), so 'who armed this' is answerable" \
    || bad "T12b an explicit arming records who made it (armed_by= was empty)"
sleep 1.1   # a second of wall clock, so a re-date is visible rather than a same-second tie
inst_lin --install >/dev/null 2>&1   # exactly what setup.sh / sync.sh does
assert_eq "$(sed -n 's/^armed_at=//p' "$LIN_STAMP")" "$ARMED_AT_1" \
    "T12b a NO-FLAG re-install ADOPTS the arming date — a sync does not re-date the deletion decision"
[ "$(sed -n 's/^installed_at=//p' "$LIN_STAMP")" != "$ARMED_AT_1" ] \
    && ok "T12b …while installed_at= DID move (so armed_at= is not just installed_at renamed)" \
    || bad "T12b installed_at= should move on a re-install; armed_at= must not"
assert_contains "$(inst_lin --status 2>&1)" "armed_at=$ARMED_AT_1" \
    "T12b --status publishes the arming date (the question an operator actually asks)"
assert_contains "$(inst_lin --status 2>&1)" "armed_by=" "T12b --status publishes the arming's attribution"
# An EXPLICIT reversal is a NEW decision, so it re-dates (the date belongs to the current stance).
inst_lin --install --dry-run >/dev/null 2>&1
assert_eq "$(sed -n 's/^armed=//p' "$LIN_STAMP")" "dry-run" "T12b an explicit reversal rewrites the stance"
[ "$(sed -n 's/^armed_at=//p' "$LIN_STAMP")" != "$ARMED_AT_1" ] \
    && ok "T12b …and re-dates it (a reversal is a decision, not a drift)" \
    || bad "T12b an explicit reversal should re-date the arming"

echo
echo "──────────────────────────────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
    echo "ALL PASS ($PASS assertions)"
    exit 0
fi
echo "FAILURES: $FAIL of $PASS assertions"
exit 1
