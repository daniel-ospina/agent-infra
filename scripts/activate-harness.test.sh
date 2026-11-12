#!/usr/bin/env bash
# activate-harness.test.sh — self-check for scripts/activate-harness.sh (agent-infra#2698 arming audit).
#
# Run: bash scripts/activate-harness.test.sh    (exits 0 when every assertion passes)
#
# What each case proves, and why it exists, is in docs/ops/harness-activation.md under
# "the launcher self-check, case by case". It is kept OUT of this file on purpose: the working-tree
# guard tokenises a script text, and a prose header ahead of the code glues lines together until the
# body reads as an unverifiable heredoc, so the suite cannot be executed at all (issue 709, measured
# three times). Documentation belongs where a reader looks for it; this file stays executable, and
# this header carries no quote characters of any kind for that reason.
#
# Hermetic: HOME, the checkout, the templates, the unit metadata and BOTH scheduler CLIs are files
# under one mktemp fixture. No systemctl, no launchctl, no network, no GitHub.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ACT="$HERE/activate-harness.sh"
TIMER="$HERE/conflict-rebase-timer.sh"
[ -f "$ACT" ] || { echo "missing $ACT"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', expected '$2')"; if [ -n "${OUT:-}" ]; then echo "--- output ---" >&2; printf '%s\n' "$OUT" | sed 's/^/    /' >&2; fi; fi; }
assert_contains() { case "${1:-}" in *"$2"*) ok "$3" ;; *) bad "$3 (missing: $2)"; echo "--- output ---" >&2; printf '%s\n' "${1:-}" | sed 's/^/    /' >&2 ;; esac; }
assert_absent()   { case "${1:-}" in *"$2"*) bad "$3 (found: $2)"; printf '%s\n' "${1:-}" | sed 's/^/    /' >&2 ;; *) ok "$3" ;; esac; }
# ⛔ DEFINED, NOT ASSUMED (cycle-5 P1-2). T26 called `assert_exit`, which did not exist: the call printed
# `command not found` to stderr and contributed NOTHING to PASS/FAIL, so that case's exit-polarity claim
# never ran while the suite reported 98/98. An assertion helper that is not defined cannot fail.
assert_exit()     { assert_eq "${RC:-?}" "$1" "$2"; }
# ⛔ READ A ROW BY FIELD, NEVER BY PADDED TEXT (review P1-1/P2-6). `emit` renders the pretty table with
# `printf '  %-24s %-9s %-12s %s\n'`, so the gap between name and class depends on the NAME'S LENGTH:
# a 27-character name gets no padding at all and exactly one space, while a 22-character one gets two
# plus the format's one. A literal carrying the wrong number of spaces cannot match any row the
# program can print — including the row it was written to forbid, which is how two assertions in this
# file came to be unable to fail under ANY mutation (measured, 119/0 with the defect restored).
# `--tsv` is the machine contract (`emit` at activate-harness.sh:236): tab-separated, no field width,
# plus ONE `SUMMARY` line. So a row's class or state is asked for where it lives.
row_field() { # <tsv-output> <name> <field-number 1..4> -> the field, or empty when the row is absent
    printf '%s\n' "${1:-}" | awk -F'\t' -v n="$2" -v f="$3" '$1 == n { print $f; exit }'
}

FX="$(mktemp -d "${TMPDIR:-/tmp}/activate-harness-test.XXXXXX")" || exit 1
cleanup() { rm -rf "$FX"; }
trap cleanup EXIT

FHOME="$FX/home"
FROOT="$FX/root"
BIN="$FX/bin"
mkdir -p "$FHOME/.pi/agent/state" "$FHOME/.pi/agent/scripts" "$FHOME/Library/LaunchAgents" "$FX/logs" "$FROOT/templates/systemd" \
         "$FROOT/templates/launchd" "$FROOT/scripts" "$BIN" "$FHOME/orchestrator/state"

# ── the fixture checkout: the SHIPPED templates, so the grid derives real rows ──────────────────
cp "$REPO/templates/systemd/"*.service "$REPO/templates/systemd/"*.timer "$FROOT/templates/systemd/" 2>/dev/null
cp "$REPO/templates/launchd/"*.plist "$FROOT/templates/launchd/" 2>/dev/null
# ⛔ THE FIXTURE MUST SHIP THE INSTALLERS THE REAL TREE SHIPS, OR AN ARM CANNOT BE REACHED AT ALL (review
# cycle 11, F1). `install-launchd.sh` was missing from this list, so `do_install`'s mac gate
# (`[ -f "$ROOT/scripts/install-launchd.sh" ]` — locate it by GREP, `grep -n 'install-launchd.sh" \]'`,
# not by line: adding a row above moved it 995 → 1017 inside the very commit that cites it, cycle-12
# P2-1, and a stale anchor is how a mutant-runner edits the wrong line) was FALSE in every case and its
# whole body — the arming line and the call F2 was about — never executed. T12 then asserted an ABSENCE
# over a log that arm could not write: an assertion that could not fail under any mutation of the code
# it claimed to pin. With the stub present the arm runs, and T12's assertions are about the ARTIFACT.
for f in install-harness-apply-timer.sh install-disk-reaper-timer.sh install-runner-autoscale-timer.sh \
         install-conflict-rebase-timer.sh install-cell-timers.sh cell-self-pin.sh install-launchd.sh; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >>"$FX_INSTALL_LOG"\nexit 0\n' "$f" >"$FROOT/scripts/$f"
done
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "install-drainer-timer.sh $*" >>"$FX_INSTALL_LOG"\nexit 0\n' \
    >"$FROOT/scripts/install-drainer-timer.sh"
mkdir -p "$FROOT/scripts/orchestrator-harness"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "install-drainer-timer.sh $*" >>"$FX_INSTALL_LOG"\nexit 0\n' \
    >"$FROOT/scripts/orchestrator-harness/install-drainer-timer.sh"

# ── the fake scheduler: unit metadata lives in $FX/units/<unit> as key=value lines ─────────────
cat >"$BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
# Serves exactly the reads activate-harness.sh makes: show -p PROP --value UNIT
prop=""; unit=""; scope="system"
while [ $# -gt 0 ]; do
    case "$1" in
        --user) scope="user"; shift ;;
        show|daemon-reload|enable|start) shift ;;
        -p) prop="$2"; shift 2 ;;
        --value) shift ;;
        -*) shift ;;
        *) unit="$1"; shift ;;
    esac
done
[ -n "$prop" ] || exit 0
f="$FIXTURE_UNITS/$scope/$unit"
[ -f "$f" ] || exit 0
sed -n "s/^$prop=//p" "$f" | head -1
FAKE
chmod +x "$BIN/systemctl"
cat >"$BIN/launchctl" <<'FAKE'
#!/usr/bin/env bash
# `print` must answer the RUN COUNTER, not just "loaded": the grid reads `runs = N` to decide
# NEVER-FIRED, because a loaded job that has never run is the launchd analogue of an empty
# LastTriggerUSec. A fake that only answered 0/1 would let a never-fired job grade OK.
case "$1" in
    print)
        f="$FIXTURE_UNITS/launchd/$2"
        [ -f "$f" ] || exit 1
        cat "$f"
        exit 0 ;;
    *) exit 0 ;;
esac
FAKE
chmod +x "$BIN/launchctl"
mkdir -p "$FX/units/system" "$FX/units/user" "$FX/units/launchd"

unit() { # <scope> <unit> <key=value>...
    local scope="$1" name="$2"; shift 2
    mkdir -p "$FX/units/$scope"
    : >"$FX/units/$scope/$name"
    local kv
    for kv in "$@"; do printf '%s\n' "$kv" >>"$FX/units/$scope/$name"; done
}
NOW="$(date -u '+%a %Y-%m-%d %H:%M:%S UTC')"
# ⛔ THE STAMP'S TIMEZONE IS ITSELF A TEST AXIS. `systemctl show -p LastTriggerUSec` renders LOCAL time,
# so a fixture that only ever stamps UTC cannot tell a correct age calculation from one that silently
# treats every local stamp as UTC — which is exactly how a dead timer read OK east of UTC.
OLD="$(date -u -d '-6 days' '+%a %Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date -u -v-6d '+%a %Y-%m-%d %H:%M:%S UTC')"
# ⛔ THE ZONE CASE NEEDS A STAMP WHOSE AGE FALLS BETWEEN THE CADENCE AND THE UTC OFFSET. A `-6 days`
# stamp is LATE under both the correct (mktime) and the buggy (timegm) reading, so it cannot
# discriminate; a stamp 2 hours old is LATE correctly, and on a JST box the buggy parse makes it
# 2h - 9h = negative -> clamped 0 -> OK. That window is the false pass.
TOKYO_NOW="$(TZ=Asia/Tokyo date '+%a %Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"
TOKYO_2H="$(TZ=Asia/Tokyo date -d '-2 hours' '+%a %Y-%m-%d %H:%M:%S %Z' 2>/dev/null || TZ=Asia/Tokyo date -v-2H '+%a %Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"

# ⛔ HERMETIC: a shipped plist names an ABSOLUTE log path (`/tmp/fleet-cost-weekly.out.log`), so a test
# that installs the template verbatim reads the HOST's /tmp — the suite's own header promises everything
# lives under one mktemp fixture (review cycle-2 P2.6). This rewrites any Standard*Path to a fixture
# path, so the age verdict is driven only by files this suite makes.
retarget_log() { # <template> <dest>
    # ⛔ RENDER FIRST: several templates put `{{INTERVAL_SEC}}` inside `<integer>`, which plistlib
    # refuses to parse. A helper that fails on them leaves the plist uninstalled and the mac fixture
    # silently broken (a `.plist` never written simply reads MISSING).
    python3 - "$1" "$2" "$FX/logs" <<'PY'
import plistlib, re, sys
src, dst, logdir = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(src).read()
raw = re.sub(r"\{\{INTERVAL_SEC\}\}", "1800", raw)
raw = re.sub(r"<integer>\{\{[A-Z_]+\}\}</integer>", "<integer>1800</integer>", raw)
raw = re.sub(r"\{\{[A-Z_]+\}\}", "x", raw)
d = plistlib.loads(raw.encode())
for k in ("StandardOutPath", "StandardErrorPath"):
    if k in d:
        d[k] = logdir + "/" + str(d[k]).rsplit("/", 1)[-1]
plistlib.dump(d, open(dst, "wb"))
PY
}

bad_env_value() { # <installed plist> — make CONFLICT_REBASE_STATE an <array> instead of a string
    python3 - "$1" <<'PY'
import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p, "rb"))
env = d.get("EnvironmentVariables")
if isinstance(env, dict):
    env["CONFLICT_REBASE_STATE"] = ["/a", "/b"]
    plistlib.dump(d, open(p, "wb"))
PY
}

strip_calendar_key() { # <installed plist> — remove the REAL key, leave a COMMENT that names it
    python3 - "$1" <<'PY'
import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p, "rb"))
d.pop("StartCalendarInterval", None)
plistlib.dump(d, open(p, "wb"))
txt = open(p).read()
comment = "  <!-- <key>StartCalendarInterval</key><dict><key>Weekday</key><integer>0</integer></dict> -->"
open(p, "w").write(txt.replace("<dict>", "<dict>\n" + comment, 1))
PY
}

point_state_dir() { # <installed plist> <state dir>
    python3 - "$1" "$2" <<'PY'
import plistlib, sys
p, st = sys.argv[1], sys.argv[2]
d = plistlib.load(open(p, "rb"))
env = d.get("EnvironmentVariables")
if isinstance(env, dict) and "CONFLICT_REBASE_STATE" in env:
    env["CONFLICT_REBASE_STATE"] = st
    plistlib.dump(d, open(p, "wb"))
PY
}

# A fully armed MAC: every shipped plist installed and loaded WITH a run counter.
arm_mac() {
    local f base
    mkdir -p "$FX/units/launchd/gui/$(id -u)" "$FHOME/Library/LaunchAgents"
    for f in "$FROOT"/templates/launchd/*.plist; do
        [ -f "$f" ] || continue
        base="$(basename "$f" .plist)"
        printf 'runs = 3\n' >"$FX/units/launchd/gui/$(id -u)/$base"
        retarget_log "$f" "$FHOME/Library/LaunchAgents/$base.plist"
    done
    # ⛔ THE FOUR SUBDIRECTORY PLISTS ARE NOT IN install-launchd.sh's GLOB AND ARE NOT COPIED INTO THE
    # FIXTURE TEMPLATE DIR — they live in their own subdirectories, because their own installers own
    # them. A mac fixture that only copies the top-level glob therefore leaves them MISSING and no green
    # mac grid can ever be exercised (which is how the two mac false-reds in this file went unseen).
    # ⛔ THE MAC conflict-rebase ROW READS ITS OWN BEACON (cycle-3 F7), so a fully-armed mac fixture must
    # carry one — in the state dir the INSTALLED plist declares, which retarget_log cannot know.
    mkdir -p "$FX/mac-cr-state"
    date +%s >"$FX/mac-cr-state/timer.beat"
    for sub in harness-apply reaper runner-autoscale conflict-rebase; do
        for f in "$REPO/templates/launchd/$sub"/*.plist; do
            [ -f "$f" ] || continue
            base="$(basename "$f" .plist)"
            printf 'runs = 3\n' >"$FX/units/launchd/gui/$(id -u)/$base"
            retarget_log "$f" "$FHOME/Library/LaunchAgents/$base.plist"
            point_state_dir "$FHOME/Library/LaunchAgents/$base.plist" "$FX/mac-cr-state"
        done
    done
}

# write_repair_record <decision> <reason> [epoch] [state-dir] — the PR repair loop's OWN pass record.
# ⛔ THE ROW IS GRADED ON THIS FILE (agent-infra#4010), so a fixture box only counts as ARMED when it
# carries one — exactly like the conflict-rebase beacon a few lines below. Its SHAPE is the loop's
# (`pr-repair-loop.sh::write_status`): `decision` + `reason` + `epoch` + `cap`, at
# `$O/state/pr-repair.status.json`. A helper that copied a different shape would test a file no
# producer writes.
write_repair_record() { # <decision> <reason> [epoch] [state-dir]
    local dir="${4:-$FHOME/orchestrator/state}"
    mkdir -p "$dir"
    python3 - "$dir/pr-repair.status.json" "$1" "$2" "${3:-$(date +%s)}" <<'PY'
import json, sys
dst, decision, reason, epoch = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
json.dump({"cap": 3, "decision": decision, "epoch": epoch, "reason": reason,
           "repo": "daniel-ospina/tortoise", "repo_dir": "/nonexistent/checkout",
           "ts": "2026-01-01T00:00:00Z"}, open(dst, "w"), indent=2, sort_keys=True)
PY
}

arm_all() { # [stamp] — the stamp must be rendered in the ZONE the box prints (T11)
    local base stamp="${1:-$NOW}"
    for base in "$FROOT"/templates/systemd/*.timer; do
        [ -f "$base" ] || continue
        base="$(basename "$base" .timer)"
        unit system "$base.timer" "LoadState=loaded" "UnitFileState=enabled" "ActiveState=active" "LastTriggerUSec=$stamp"
        unit system "$base.service" "LoadState=loaded" "UnitFileState=enabled" "ActiveState=active" "Result=success"
    done
    # The SHIPPED posture: harness-apply is the single pin actuator and cell-self-pin is not enabled.
    # Both enabled is a real finding (the pair is a race), so the fully-armed fixture must not have it.
    unit system "cell-self-pin.timer" "LoadState=loaded" "UnitFileState=disabled" "ActiveState=inactive" ""
    unit system "eldato-orchestrator.service" "LoadState=loaded" "UnitFileState=enabled" "ActiveState=active" "Result=success"
    # AND ITS ENVIRONMENT IS RENDERED, BECAUSE A REAL ONE IS: `install-repair-service.sh` always emits
    # `Environment=O=... REPAIR_INTERVAL_S=...`. A fixture that omitted them made this row print its
    # assumed-cadence disclosure on EVERY green grid, which reddened T31d (the sibling conflict-rebase
    # row's "no note when the period WAS read" absence pin) from a DIFFERENT capability. Cross-row
    # pollution is a fixture defect, not a finding.
    unit system "eldato-pr-repair.service" "LoadState=loaded" "UnitFileState=enabled" "ActiveState=active" \
        "Result=success" "Environment=O=$FHOME/orchestrator REPAIR_INTERVAL_S=900"
    # ⛔ AND ITS OWN PASS RECORD, because that row is graded on it and not on `ActiveState` (#4010).
    # Without this line the row correctly reads LATE ("active but has NEVER written a pass record") and
    # a fully-armed cell fixture cannot reach a green grid — the same reason the conflict-rebase beacon
    # below exists.
    write_repair_record dispatched pass-complete
    # ⛔ AND THE REPAIR POOL'S SUPPLY HALF (#2700), which has NO `.timer` — the derivation loop cannot see
    # it, so a fully-armed CELL fixture that omits it would red T1 on a row that is correctly required.
    unit system "eldato-worker-supply.service" "LoadState=loaded" "UnitFileState=enabled" "ActiveState=active" "Result=success"
    # conflict-rebase is judged on its pass BEACON (its brake makes a tick a legitimate no-op), so a
    # fully-armed fixture must carry one or the row correctly reads NEVER-FIRED.
    mkdir -p "$FHOME/.pi/agent/state/conflict-rebase"
    date +%s >"$FHOME/.pi/agent/state/conflict-rebase/timer.beat"
}
# A beacon for the controller row, and a stub portable scheduler that verifies clean.
date +%s >"$FHOME/orchestrator/heartbeat"
printf 'import sys\nprint("SCHEDULE VERIFIED - 1 job(s) live on this machine")\nsys.exit(0)\n' \
    >"$FHOME/.pi/agent/scripts/fleet-schedule.py"

RUN() { # run the launcher with the fixture environment
    OUT="$(env -u O -u INFRA_ROOT \
        HOME="$FHOME" \
        CELL_HOME="$FHOME" \
        INFRA_ROOT="$FROOT" \
        SYSTEMCTL="$BIN/systemctl" \
        LAUNCHCTL="$BIN/launchctl" \
        FIXTURE_UNITS="$FX/units" \
        FX_INSTALL_LOG="$FX/install.log" \
        ACTIVATE_SYSTEMD_TEMPLATES_DIR="$FROOT/templates/systemd" \
        ACTIVATE_LAUNCHD_TEMPLATES_DIR="$FROOT/templates/launchd" \
        ${PLATFORM_SEAM:+ELDATO_PLATFORM="$PLATFORM_SEAM"} \
        ${SKIP_SEAM:+ACTIVATE_SKIP_INSTALL=1} \
        ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
        bash "$ACT" "$@" 2>&1)"
    RC=$?
}
export FX

echo "activate-harness.test.sh"

# ── T1: a fully armed box exits 0 and every must row reads OK ─────────────────────────────────
arm_all
PLATFORM_SEAM="" SKIP_SEAM="" RUN --check
assert_eq "$RC" 0 "T1 fully armed box exits 0"
assert_contains "$OUT" 'ACTIVATION COMPLETE' "T1 summary names a complete activation"
assert_contains "$OUT" 'eldato-conflict-rebase' "T1 the newly armed capability is a derived row (a shipped template cannot be forgotten)"
assert_contains "$OUT" 'eldato-worker-supply.service' "T1 the supply half is a row on a healthy cell (it ships no .timer, so nothing derives it)"
assert_contains "$OUT" 'OK' "T1 rows carry a verdict"

# ── T2: NON-VACUITY — remove one unit and --check must name it and exit non-zero ──────────────
rm -f "$FX/units/system/eldato-harness-apply.timer" "$FX/units/system/eldato-harness-apply.service"
RUN --check
assert_eq "$RC" 1 "T2 a deliberately removed unit makes --check exit 1"
assert_contains "$OUT" 'eldato-harness-apply' "T2 the missing capability is NAMED"
assert_contains "$OUT" 'MISSING' "T2 the missing capability is graded MISSING"
assert_contains "$OUT" 'NOT ARMED: eldato-harness-apply' "T2 the summary names what did not come up"

# ── T3: NEVER-FIRED — installed, enabled, active, zero fires ─────────────────────────────────
arm_all
unit system "eldato-objective-reminder.timer" "LoadState=loaded" "UnitFileState=enabled" "ActiveState=active" "LastTriggerUSec="
RUN --check
assert_eq "$RC" 1 "T3 an installed-but-never-fired timer fails the run"
assert_contains "$OUT" 'NEVER-FIRED' "T3 the inert-enforcer state is graded NEVER-FIRED, not OK"
assert_contains "$OUT" 'eldato-objective-reminder' "T3 and it is named"

# ── T4: a shipped template with NO installer is a DECLARATION ERROR, not a silent skip ───────
arm_all
: >"$FROOT/templates/systemd/zz-orphan-capability.timer"
RUN --check
assert_eq "$RC" 2 "T4 an unmapped template makes the grid unreadable, not green"
assert_contains "$OUT" 'DECLARATION ERROR' "T4 the unmapped template is called a declaration error"
assert_contains "$OUT" 'zz-orphan-capability' "T4 and it is named"
rm -f "$FROOT/templates/systemd/zz-orphan-capability.timer"

# ── T5: an OPTIONAL row is never armed by the launcher; a MUST row is ────────────────────────
arm_all
rm -f "$FX/units/system/eldato-conflict-rebase.timer" "$FX/units/system/eldato-conflict-rebase.service"
: >"$FX/install.log"
RUN --install
assert_file_ok() { [ -f "$1" ] && ok "$2" || bad "$2 (missing $1)"; }
assert_file_ok "$FX/install.log" "T5 --install ran installers"
INSTALLS="$(cat "$FX/install.log" 2>/dev/null || true)"
# EVERY must-row's OWN installer must have run — this is what pins do_install's case to the grid's
# installer_for(), so adding a template (or renaming an installer) cannot leave one list behind.
assert_contains "$INSTALLS" 'install-harness-apply-timer.sh' "T5 the harness-apply installer ran"
assert_contains "$INSTALLS" 'install-disk-reaper-timer.sh' "T5 the disk-reaper installer ran"
assert_contains "$INSTALLS" 'install-conflict-rebase-timer.sh' "T5 the conflict-rebase installer ran (the capability this arm audit was opened for)"
assert_contains "$INSTALLS" 'install-cell-timers.sh' "T5 the cell-timers installer ran (watchdog + reminder)"
assert_contains "$INSTALLS" 'install-drainer-timer.sh' "T5 the ai-drainer installer ran"
assert_absent   "$INSTALLS" 'install-runner-autoscale-timer.sh' "T5 an OPTIONAL row is NEVER armed by the launcher (#2403 is a dated owner step)"
assert_absent   "$INSTALLS" 'cell-self-pin.sh' "T5 the exclusive pin-actor row is never installed by the launcher"

# ── T6: --install VERIFIES after arming and still exits non-zero when a row did not come up ──
arm_all
rm -f "$FX/units/system/eldato-harness-apply.timer" "$FX/units/system/eldato-harness-apply.service"
SKIP_SEAM=1 RUN --install
assert_eq "$RC" 1 "T6 --install with a capability that never came up exits 1"
assert_contains "$OUT" 'ACTIVATION INCOMPLETE' "T6 --install cannot report success without a verified grid"

# ── T7: the TRACKED reaper template must still ship disarmed (#1678), on the mac grid ────────
PLATFORM_SEAM="Darwin" SKIP_SEAM=""
cat >"$FROOT/templates/launchd/com.tortoise.worktree-reaper.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>com.tortoise.worktree-reaper</string></dict></plist>
PL
RUN --check
assert_eq "$RC" 1 "T7 a mac missing its launchd jobs fails the run"
assert_contains "$OUT" 'UNEXPECTED' "T7 a reaper template that no longer carries its disarming flag is a FINDING"
assert_contains "$OUT" 'com.tortoise.worktree-reaper' "T7 and it is named"

printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict><key>Label</key><string>com.tortoise.worktree-reaper</string>' \
    '<key>ProgramArguments</key><array><string>/bin/bash</string><string>--dry-run</string></array></dict></plist>' \
    >"$FROOT/templates/launchd/com.tortoise.worktree-reaper.plist"
RUN --check
assert_absent "$OUT" 'NO LONGER carries' "T7 a reaper template that ships its disarming flag is not reported as armed"
rm -f "$FROOT/templates/launchd/com.tortoise.worktree-reaper.plist"
# ⛔ PUT THE SHIPPED TEMPLATE BACK. Deleting it here and never restoring it silently removed the row from
# EVERY later case (T24 found it as `SKIPPED — template absent`), i.e. fixture-order pollution that made
# a platform-independent guard untestable.
cp "$REPO/templates/launchd/com.tortoise.worktree-reaper.plist" "$FROOT/templates/launchd/"

# ── T9: an ARMED optional row that is broken is NAMED, never folded into a counter ───────────
# The optional class exists so the launcher never FAILS a run over a dated owner decision (#2403).
# That is a decision about the EXIT CODE, not about visibility: a broken optional row silently
# incremented a counter nothing printed, which is the "computed and never read" shape this repo
# keeps filing. So: exit stays 0, and the row is named.
PLATFORM_SEAM="" SKIP_SEAM=""   # T7 leaves the mac grid selected; T9 is a CELL case
arm_all
unit system "eldato-runner-autoscale.timer" "LoadState=loaded" "UnitFileState=enabled" "ActiveState=active" "LastTriggerUSec=$NOW"
unit system "eldato-runner-autoscale.service" "LoadState=loaded" "UnitFileState=enabled" "ActiveState=failed" "Result=exit-code"
RUN --check
assert_eq "$RC" 0 "T9 a broken OPTIONAL row does not fail the run (the class means a dated decision, not a gate)"
assert_contains "$OUT" 'OPTIONAL NOT OK: eldato-runner-autoscale' "T9 but it IS named — an intact optional row is silent, a broken one is not"
arm_all
RUN --check
assert_absent "$OUT" 'OPTIONAL NOT OK' "T9 an intact optional row prints nothing (so the note is not just always-on)"

# ── T8: the BRAKE holds on the shape the fleet schedules (start --once, not only the loop) ───
# Hermetic: the wrapper, a STUB bot and the real bounded helper are copied into the fixture, so this
# case never reaches GitHub. A timer test that hits the API is a test that can rebase a real PR.
PLATFORM_SEAM="" SKIP_SEAM=""
FT="$FX/timer"
mkdir -p "$FT/lib" "$FX/brake-state"
cp "$TIMER" "$FT/conflict-rebase-timer.sh"
cp "$REPO/scripts/lib/bounded.sh" "$FT/lib/bounded.sh"
printf 'import sys\nprint("stub-pass-ran")\nsys.exit(0)\n' >"$FT/conflict-rebase.py"
BSTATE="$FX/brake-state"
: >"$BSTATE/PAUSED"
OUT="$(CONFLICT_REBASE_STATE="$BSTATE" bash "$FT/conflict-rebase-timer.sh" start --once 2>&1)"; RC=$?
assert_eq "$RC" 0 "T8 a paused --once pass exits 0 (a brake is not a failure)"
assert_contains "$OUT" 'PAUSED' "T8 and it SAYS it is paused"
if [ -f "$BSTATE/timer.beat" ]; then bad "T8 the beacon must NOT be stamped by a paused pass"; else ok "T8 a paused pass stamps no beacon (the beacon means a pass COMPLETED)"; fi
rm -f "$BSTATE/PAUSED"
OUT="$(CONFLICT_REBASE_STATE="$BSTATE" bash "$FT/conflict-rebase-timer.sh" start --once 2>&1)"; RC=$?
assert_eq "$RC" 0 "T8 an unpaused --once pass runs (rc 0)"
if [ -f "$BSTATE/timer.beat" ]; then ok "T8 an unpaused pass stamps the beacon"; else bad "T8 an unpaused pass did not stamp the beacon (rc=$RC)"; fi
assert_contains "$(cat "$BSTATE/timer.log" 2>/dev/null)" 'stub-pass-ran' "T8 the pass body actually ran (the brake was the only thing that stopped it)"

echo ""
# ── T10: a STALE required timer is LATE and the run FAILS — the gate's primary verdict ───────
# ⛔ NOTHING PINNED THIS BEFORE (review F8), and two mutants proved it: make age_of() return "now" for
# every stamp (staleness detection entirely destroyed) and the suite stayed 37/37 green; drop LATE from
# the failure set and the grid printed `ACTIVATION COMPLETE` over a required timer six days dead.
PLATFORM_SEAM="" SKIP_SEAM=""; EXTRA_ENV=()
arm_all
unit system "eldato-disk-reaper.timer" "LoadState=loaded" "UnitFileState=enabled" "ActiveState=active" "LastTriggerUSec=$OLD"
RUN --check
assert_eq "$RC" 1 "T10 a required timer that last fired 6 days ago FAILS the run"
assert_contains "$OUT" 'LATE' "T10 graded LATE (not OK)"
assert_contains "$OUT" 'ACTIVATION INCOMPLETE' "T10 the summary never says COMPLETE over a dead timer"
assert_absent "$OUT" 'ACTIVATION COMPLETE' "T10 specifically not the success line"

# ── T11: the age is ZONE-FREE — the defect T10 cannot see on a UTC box ────────────────────────
# systemd renders LastTriggerUSec in the BOX'S LOCAL ZONE. Parsing that as UTC makes the age NEGATIVE
# east of UTC, clamped to 0 -> a dead timer reads OK. Both halves matter: the FRESH box must stay green
# (a parser that merely refuses would red there) AND the stale timer must stay LATE.
if [ "$(TZ=Asia/Tokyo date +%Z 2>/dev/null)" = "JST" ]; then
    PLATFORM_SEAM="" SKIP_SEAM=""; EXTRA_ENV=(TZ=Asia/Tokyo)
    # A real JST box's systemd prints a JST string. Stamping the fixture in UTC and calling it "local"
    # would test the wrong thing — the fixture must speak the zone the box would actually print.
    arm_all "$TOKYO_NOW"
    RUN --check
    assert_eq "$RC" 0 "T11 a JST-stamped, freshly-fired box is green (the parser accepts a non-UTC zone)"
    unit system "eldato-disk-reaper.timer" "LoadState=loaded" "UnitFileState=enabled" "ActiveState=active" "LastTriggerUSec=$TOKYO_2H"
    RUN --check
    assert_eq "$RC" 1 "T11 a JST timer 2h old is LATE (the UTC-as-local clamp cannot make it OK)"
    assert_contains "$OUT" 'LATE' "T11 and it is graded LATE, not OK"
    assert_absent "$OUT" 'NEVER-FIRED' "T11 the non-UTC zone did not poison the parse into NEVER-FIRED"
    EXTRA_ENV=()
else
    bad "T11 could not run — this box has no Asia/Tokyo zone, so the zone-freedom property is UNPROVEN here"
fi

# ── T12: a MAC that is genuinely armed reaches ACTIVATION COMPLETE ────────────────────────────
# No test drove a GREEN mac grid (review F8), which is how two false-reds shipped: the plist was read
# with a sed whose `|` delimiter collided with its own alternation (matched nothing, every row LATE),
# and the installer was called with a `--install` verb it does not have (exit 2 every time).
PLATFORM_SEAM="Darwin" SKIP_SEAM=""; EXTRA_ENV=()
arm_mac
RUN --check
assert_eq "$RC" 0 "T12 a fully-armed Mac is green"
assert_contains "$OUT" 'ACTIVATION COMPLETE' "T12 and it says so"
# ⛔ READ BY FIELD, AND THEREFORE REACHABLE (review P1-1). The assertion this replaces searched the
# padded table for `com.eldato.runner-autoscale  must`; that name is 27 characters against a 24-column
# field, so the emitted row carries ONE space and the literal's two could never match it. Restoring F7
# — the mac sub-directory loop grading the optional `#2403` row as `must` — left the suite at 119/0.
# Its consequence is the one F7 was filed for and the fixture cannot see on its own: `arm_mac` arms
# everything, so on a Mac where the optional row is genuinely unarmed the grid reads `must`/`MISSING`,
# `--install` can never reach ACTIVATION COMPLETE, and the only way to green it is the hand-run arming
# step the class system exists to withhold. The class is now read from the machine contract.
RUN --tsv
assert_eq "$(row_field "$OUT" com.eldato.runner-autoscale 2)" "optional" \
    "T12 the optional autoscale row is graded optional on a Mac (field-read, so a revert to 'must' reddens here)"
assert_eq "$(row_field "$OUT" com.eldato.runner-autoscale 3)" "OK" \
    "T12 and that row is genuinely present and OK — an absent row cannot satisfy the assertion above"
assert_eq "$(row_field "$OUT" com.eldato.runner-autoscale 1)" "com.eldato.runner-autoscale" \
    "T12 positive control: the row this case reads is the one the grid emitted (nothing else answers to it)"
: >"$FX/install.log"
RUN --install
assert_contains "$(cat "$FX/install.log" 2>/dev/null || true)" 'install-launchd.sh' "T12 --install actually REACHED the launchd arm (the positive control the old assertion lacked)"
assert_absent   "$(cat "$FX/install.log" 2>/dev/null || true)" 'install-launchd.sh --' "T12 install-launchd.sh is never passed a verb it does not have"

# ── T13: a templates dir that exists but ships NO timers examined ZERO rows — never green ─────
PLATFORM_SEAM="" SKIP_SEAM=""; EXTRA_ENV=()
mkdir -p "$FX/empty-templates"
EXTRA_ENV=(ACTIVATE_SYSTEMD_TEMPLATES_DIR="$FX/empty-templates")
RUN --check
assert_eq "$RC" 2 "T13 an empty templates dir is an unreadable grid, not a clean box"
assert_contains "$OUT" 'examined ZERO' "T13 and it says that nothing was examined"
assert_absent "$OUT" 'ACTIVATION COMPLETE' "T13 never the success line"
EXTRA_ENV=()

# ── T14: an unsupported platform REFUSES instead of grading the macOS grid ────────────────────
PLATFORM_SEAM="FreeBSD" SKIP_SEAM=""; EXTRA_ENV=()
RUN --check
assert_eq "$RC" 2 "T14 an unknown platform is a refusal"
assert_contains "$OUT" 'unsupported platform' "T14 and it names the platform"
assert_absent "$OUT" 'ACTIVATION COMPLETE' "T14 never a green grid from a platform it cannot model"

# ── T15: an ARMED claim reaper is read from the PASS'S OWN record path ────────────────────────
# The probe read ~/.pi/agent/state/... which NOTHING writes, so an armed #1678 deletion tool graded
# UNARMED and exit 0 (review F5). The record lives at $O/state/claim-reaper.armed.
PLATFORM_SEAM="" SKIP_SEAM=""; EXTRA_ENV=()
arm_all
printf '%s\n' 'armed 2026-11-07 by the operator' >"$FHOME/orchestrator/state/claim-reaper.armed"
RUN --check
assert_contains "$OUT" 'claim-reaper' "T15 the claim reaper is on the grid"
assert_contains "$OUT" 'claim-reaper.last' "T15 an ARMED but never-stamped claim reaper is reported (not silently UNARMED)"
assert_contains "$OUT" 'ACTIVATION INCOMPLETE' "T15 and it FAILS the run"
rm -f "$FHOME/orchestrator/state/claim-reaper.armed"

# ── T16: a BRAKED timer is reported as paused, not as "fired Ns ago" ──────────────────────────
# `LastTriggerUSec` answers "did the TIMER tick", not "did the PASS do anything". conflict-rebase's
# brake makes `start --once` exit 0 before any pass, so after `pause` the timer kept ticking every
# 30 min and the grid kept printing `OK … fired Ns ago` — the brake was invisible to the instrument
# that exists to notice it (review F16). The row is now judged on the pass's own BEACON.
PLATFORM_SEAM="" SKIP_SEAM=""; EXTRA_ENV=()
arm_all
mkdir -p "$FHOME/.pi/agent/state/conflict-rebase"
rm -f "$FHOME/.pi/agent/state/conflict-rebase/PAUSED"
date +%s >"$FHOME/.pi/agent/state/conflict-rebase/timer.beat"
RUN --check
assert_contains "$OUT" "last COMPLETED pass" "T16 an armed conflict-rebase is judged on its BEACON, not on the timer tick"
: >"$FHOME/.pi/agent/state/conflict-rebase/PAUSED"
RUN --check
assert_contains "$OUT" 'PAUSED' "T16 with the brake file present the row SAYS paused"
assert_absent "$OUT" 'last COMPLETED pass' "T16 and the beacon-freshness line is replaced, not printed beside it"
rm -f "$FHOME/.pi/agent/state/conflict-rebase/PAUSED" "$FHOME/.pi/agent/state/conflict-rebase/timer.beat"

# ── T17: a launchd job with runs=0 is NEVER-FIRED (the analogue of an empty LastTriggerUSec) ──
PLATFORM_SEAM="Darwin" SKIP_SEAM=""; EXTRA_ENV=()
arm_mac
printf 'runs = 0\n' >"$FX/units/launchd/gui/$(id -u)/com.eldato.lane-liveness"
RUN --check
assert_contains "$OUT" 'NEVER-FIRED' "T17 a loaded-but-never-run launchd job is graded NEVER-FIRED"
assert_contains "$OUT" 'com.eldato.lane-liveness' "T17 and it is named"
assert_eq "$RC" 1 "T17 which fails the run"

# ── T18: a BEACON that stops advancing is LATE — the whole reason the row moved off the tick ──
PLATFORM_SEAM="" SKIP_SEAM=""; EXTRA_ENV=()
arm_all
touch -t "$(date -u -d '-3 hours' '+%Y%m%d%H%M' 2>/dev/null || date -u -v-3H '+%Y%m%d%H%M')" \
    "$FHOME/.pi/agent/state/conflict-rebase/timer.beat"
RUN --check
assert_eq "$RC" 1 "T18 a stale conflict-rebase BEACON fails the run (the timer keeps ticking; the pass does not)"
assert_contains "$OUT" 'LATE' "T18 graded LATE"
assert_contains "$OUT" 'last COMPLETED pass' "T18 and it names the beacon, not the tick"

# ── T19: the launchd LOG-AGE arm still works — a stale log is LATE, a fresh one is not ─────
PLATFORM_SEAM="Darwin" SKIP_SEAM=""; EXTRA_ENV=()
arm_mac
printf 'x\n' >"$FX/logs/fleet-cost-weekly.out.log"
touch -t "$(date -u -d '-30 days' '+%Y%m%d%H%M' 2>/dev/null || date -u -v-30d '+%Y%m%d%H%M')" "$FX/logs/fleet-cost-weekly.out.log"
RUN --check
assert_eq "$RC" 1 "T19 a weekly job whose log is 30 days old is LATE (the calendar cadence bounds it, not 24h)"
assert_contains "$OUT" 'com.eldato.fleet-cost-weekly' "T19 and it is named"
printf 'x\n' >"$FX/logs/fleet-cost-weekly.out.log"   # fresh mtime = now
RUN --check
assert_eq "$RC" 0 "T19 the same job with a fresh log is green (so the bound is a cadence, not a wall)"
# ⛔ THE 30-DAY CASE ABOVE IS LATE UNDER *BOTH* THE 8-DAY CALENDAR BOUND AND THE OLD 24 h FALLBACK, so on
# its own it cannot tell the fix from the bug (review cycle-3 F2 — the mutant survived it). The
# DISCRIMINATING window is a log older than 24 h but younger than a week: LATE on the old bound, OK now.
touch -t "$(date -u -d '-3 days' '+%Y%m%d%H%M' 2>/dev/null || date -u -v-3d '+%Y%m%d%H%M')" "$FX/logs/fleet-cost-weekly.out.log"
RUN --check
assert_eq "$RC" 0 "T19 a weekly job whose log is 3 days old is OK — inside its calendar cadence, outside a 24h one"

# ── T29: a COMMENTED-OUT calendar key must not widen the bound ────────────────────────────────
# The cycle-4 finding, and the reason a `|| grep '<key>StartCalendarInterval</key>'` fallback is not a
# harmless belt: XML comments are legal, and a substring match cannot tell `declared` from `mentioned`.
# A plist whose calendar schedule is commented out (so the real bound is the 24 h fallback) with a 3-day
# log read `OK` under the grep, certifying a dead job green — the same failure mode this file's own
# guarded_templates() rejects for `--dry-run`.
PLATFORM_SEAM="Darwin" SKIP_SEAM=""; EXTRA_ENV=()
arm_mac
strip_calendar_key "$FHOME/Library/LaunchAgents/com.eldato.fleet-cost-weekly.plist"
printf 'x\n' >"$FX/logs/fleet-cost-weekly.out.log"
touch -t "$(date -u -d '-3 days' '+%Y%m%d%H%M' 2>/dev/null || date -u -v-3d '+%Y%m%d%H%M')" "$FX/logs/fleet-cost-weekly.out.log"
RUN --check
assert_eq "$RC" 1 "T29 a 3-day log with the calendar key only COMMENTED is LATE against the 24h fallback"
assert_contains "$OUT" 'bound 86400s' "T29 and the bound says 24h, not 8 days — a comment is not a declaration"

# ── T30: a NON-STRING state value is UNREADABLE, not a path ───────────────────────────────────
# `plist_env_value` printed whatever plistlib gave it, so an `<array>` became the Python repr
# `['/a', '/b']`, the caller joined `/timer.beat` onto that, found nothing, and reported NEVER-FIRED — a
# hard claim that no pass has ever completed, derived from a malformed value. Everywhere else in this
# file the rule is "unreadable => UNKNOWN, never a claim"; this pins it for the env seam.
PLATFORM_SEAM="Darwin" SKIP_SEAM=""; EXTRA_ENV=()
arm_mac
bad_env_value "$FHOME/Library/LaunchAgents/com.eldato.conflict-rebase.plist"
RUN --check
assert_contains "$OUT" 'com.eldato.conflict-rebase' "T30 the row is still reported"
# ⛔ ASSERT ON THE DETAIL SENTENCE, NOT ON THE PADDED ROW. `%-24s %-9s` pads the name and class, so a
# literal row-shaped match silently matched NOTHING in either direction — a vacuous assertion that let the
# mutant survive (measured). The detail is the only part whose spacing cannot drift.
assert_absent "$OUT" 'pass beacon' "T30 a malformed environment value is never rendered as a claim about the pass"
assert_contains "$OUT" 'com.eldato.conflict-rebase' "T30 (and the row is still reported, so this case cannot go vacuous on a rename)"

# ── T20: rows whose freshness could not be read are COUNTED and SAID OUT LOUD ─────────────────
PLATFORM_SEAM="Darwin" SKIP_SEAM=""; EXTRA_ENV=()
arm_mac
RUN --check
assert_contains "$OUT" 'AGE UNMEASURED' "T20 a plist with no readable log says so on the row"
assert_contains "$OUT" 'FRESHNESS was unmeasurable' "T20 and the summary counts them — a green grid must not imply everything was measured"

# ── T21: the conflict-rebase STATE comes from the UNIT, read in the UNIT'S OWN SCOPE ───────────
# ⛔ TWO DEFECTS IN ONE ROW, both measured before this test existed: (a) `sysd_show` is only valid while
# SC_PREFIX matches the unit, and the Environment read happened BEFORE the probe resolved this unit's
# scope — so it went through whatever manager the PREVIOUS row resolved in, and a healthy box read
# NEVER-FIRED; (b) a non-default CONFLICT_REBASE_STATE was ignored entirely. This fixture separates the
# two scopes and installs the beacon only in the custom directory.
PLATFORM_SEAM="" SKIP_SEAM=""; EXTRA_ENV=()
arm_all
mkdir -p "$FX/custom-state"
date +%s >"$FX/custom-state/timer.beat"
# ⛔ REMOVE THE DEFAULT BEACON (cycle-4 F4). `arm_all` stamps one at the DEFAULT state dir, so the
# buggy path (wrong scope, or the hardcoded dir) still found a FRESH beacon and read `OK … 0s ago` —
# both half-reverts stayed 85/85. With the default beacon gone, only the correct read can be green.
rm -f "$FHOME/.pi/agent/state/conflict-rebase/timer.beat"
# move ONE timer to the user manager so the *previous* row's scope differs from this row's
rm -f "$FX/units/system/eldato-ai-drainer.timer"
unit user "eldato-ai-drainer.timer" "LoadState=loaded" "UnitFileState=enabled" "ActiveState=active" "LastTriggerUSec=$NOW"
unit user "eldato-ai-drainer.service" "LoadState=loaded" "UnitFileState=enabled" "ActiveState=active" "Result=success"
# and give the (system-scope) conflict-rebase unit a non-default state dir
unit system "eldato-conflict-rebase.service" "LoadState=loaded" "UnitFileState=enabled" "ActiveState=active" "Result=success" \
    "Environment=HOME=$FHOME CONFLICT_REBASE_STATE=$FX/custom-state"
RUN --check
assert_contains "$OUT" "last COMPLETED pass" "T21 the state dir is read from the UNIT, in the UNIT'S scope (not the previous row's)"
assert_absent "$OUT" 'eldato-conflict-rebase   must      NEVER-FIRED' "T21 and a beacon in the custom dir is found, not missed"

# ── T25: a MAC row honours the brake and the beacon, exactly as a cell does ─────────────────
# The mac row was a pure `runs`/log-age read, so `PAUSED` + a 5-day-stale beacon read
# `OK … AGE UNMEASURED` on the Mac while the same state on a cell read LATE. Two operators, two
# verdicts, one truth. These cases pin both halves.
PLATFORM_SEAM=Darwin; SKIP_SEAM=""; EXTRA_ENV=()
arm_all
: >"$FX/mac-cr-state/PAUSED"
RUN --check
assert_contains "$OUT" 'com.eldato.conflict-rebase' "T25 the mac conflict-rebase row is present"
assert_contains "$OUT" 'PAUSED' "T25 a brake is HONOURED on the Mac too (not silently an OK row)"
rm -f "$FX/mac-cr-state/PAUSED"
# and a beacon older than the bound is LATE, not "OK, age unmeasured"
# ⛔ AGE A BEACON BY ITS MTIME. Writing an epoch NUMBER into the file leaves the mtime at "now", so the
# row reads OK and the case proves nothing (measured — this bit me here).
python3 -c 'import sys,os,time;os.utime(sys.argv[1],(time.time()-86400*5,)*2)' "$FX/mac-cr-state/timer.beat"
PLATFORM_SEAM=Darwin; SKIP_SEAM=""; EXTRA_ENV=()
RUN --check
assert_contains "$OUT" 'LATE' "T26 a STALE mac beacon is LATE, not OK"
assert_exit 1 "T26 and it fails the run"

# ── T27/T28: the LATE bound comes from the timer's OWN declared period ──────────────────────
# Two defects, one axis. (a) the bound was a constant 7200 s while the installer accepts a cadence of
# 1..1440 min, so a box at a long period read LATE forever; (b) reading `INTERVAL_MIN` out of the
# SERVICE's Environment found nothing (no shipped unit exports it), so the constant always won. And
# (c) `08` passed the digit guard, then `$(( 08 * 60 ))` aborted the arithmetic, so the probe was never
# called: the row VANISHED while `timer_rows` was already incremented and summarise — which walks
# EMITTED rows — printed `ACTIVATION COMPLETE`, exit 0, over a required capability never examined.
mkdir -p "$FX/frag"
cr_frag() { # <OnUnitActiveSec value>
    printf 'Unit=eldato-conflict-rebase.service\nOnUnitActiveSec=%s\n' "$1" >"$FX/frag/cr.timer"
    printf 'FragmentPath=%s\n' "$FX/frag/cr.timer" >>"$FX/units/system/eldato-conflict-rebase.timer"
}
# (a) a LONG cadence: a beacon 5 h old is well inside 2 x 120 min + 4800, and LATE under the old 7200.
PLATFORM_SEAM="" SKIP_SEAM=""; EXTRA_ENV=()
arm_all
cr_frag 120min
python3 -c 'import sys,os,time;os.utime(sys.argv[1],(time.time()-18000,)*2)' \
    "$FHOME/.pi/agent/state/conflict-rebase/timer.beat"
RUN --check
assert_contains "$OUT" 'eldato-conflict-rebase' "T27 a long-cadence box still has a row"
assert_contains "$OUT" 'cadence allows 19200s' "T28 the bound follows the timer's period (2 x 120 min + 4800; the old constant 7200 would have called 5 h LATE)"
# ⛔ FIELD-READ, AND PAIRED WITH A CONTROL THAT PROVES IT CAN FLIP (review P2-6). The literal this
# replaces was `'eldato-conflict-rebase must LATE'`: that name is 22 characters, so `%-24s` pads two and
# the format adds one — the real row carries THREE spaces — so it could not match, and it read as
# "the 5-hour case is proven not-LATE" over nothing at all. The sibling `cadence allows 19200s` could
# not cover for it either: that string is in the LATE detail too, so the pair passed together whatever
# the state was. Now the STATE is the assertion, and the control below ages the same beacon past the
# same bound and demands LATE — so the pair distinguishes the two outcomes instead of coinciding.
RUN --tsv
assert_eq "$(row_field "$OUT" eldato-conflict-rebase 3)" "OK" \
    "T28 a 5-hour-old beacon is inside a 120-minute cadence (state field, not padded text)"
python3 -c 'import sys,os,time;os.utime(sys.argv[1],(time.time()-20000,)*2)' \
    "$FHOME/.pi/agent/state/conflict-rebase/timer.beat"
RUN --tsv
assert_eq "$(row_field "$OUT" eldato-conflict-rebase 3)" "LATE" \
    "T28 control: 20000s is past the 19200s bound, and the same field says LATE — so the assertion above is reachable"
# (b) a leading-zero period must still produce a row, and must never read as a complete grid
PLATFORM_SEAM="" SKIP_SEAM=""; EXTRA_ENV=()
arm_all
cr_frag 08min
RUN --check
assert_contains "$OUT" 'eldato-conflict-rebase' "T27 a leading-zero period still produces a ROW"
assert_contains "$OUT" 'cadence allows 5760s' "T27 and the leading zero is parsed as DECIMAL 8 minutes (2 x 480 + 4800), not as octal or an abort"

# ── T31: an ASSUMED bound says so, and never changes the exit code ─────────────────────────────
# The disclosure was computed and passed as probe_systemd_timer's `$4` and rendered by NONE of the four
# beacon emits — the only branch a conflict-rebase row ever reaches. So a unit whose period could not be
# read printed `cadence allows 8400s` identically to a measured 30-minute one, and on a long-cadence box
# that is a FALSE LATE with no indication the bound was assumed (cycle-6 P1). A disclosure no state
# renders is not a disclosure, and nothing pinned the text: `grep 'cadence UNREADABLE'` matched zero
# lines in this file.
PLATFORM_SEAM="" SKIP_SEAM=""; EXTRA_ENV=()
arm_all
rm -f "$FX/frag/cr.timer"          # no readable FragmentPath ⇒ the period cannot be measured
date +%s >"$FHOME/.pi/agent/state/conflict-rebase/timer.beat"
RUN --check
assert_contains "$OUT" 'cadence UNREADABLE' "T31 an unreadable unit period is DISCLOSED on the row that depends on it"
assert_contains "$OUT" 'assumed 1800 s' "T31 and it names the assumption rather than implying a measurement"
assert_eq "$RC" 0 "T31 a disclosed assumption is a NOTE, not a failure — the beacon is fresh"

# ── T31b–T31d: the disclosed bound is rendered in EVERY state a row reaches, and ONLY when assumed ──
# Cycle 6 fixed the OK arm; cycle 7 measured that reverting the NEVER-FIRED or the LATE arm left the
# suite green — and those are the two states an operator actually meets (a freshly built box, a stopped
# one). The note is now defined once and used at each emit, so one revert reddens this whole group.
PLATFORM_SEAM="" SKIP_SEAM=""; EXTRA_ENV=()
arm_all
rm -f "$FX/frag/cr.timer"
rm -f "$FHOME/.pi/agent/state/conflict-rebase/timer.beat"
RUN --check
assert_contains "$OUT" 'no pass has ever COMPLETED' "T31b an unreadable period is disclosed on the NEVER-FIRED row too"
assert_contains "$OUT" 'cadence UNREADABLE' "T31b (note present)"
assert_eq "$RC" 1 "T31b which is a failure either way — the note is a disclosure, not a severity"
# and LATE: a beacon older than even the ASSUMED bound
date +%s >"$FHOME/.pi/agent/state/conflict-rebase/timer.beat"
python3 -c 'import sys,os,time;os.utime(sys.argv[1],(time.time()-86400,)*2)' \
    "$FHOME/.pi/agent/state/conflict-rebase/timer.beat"
RUN --check
assert_contains "$OUT" 'last COMPLETED pass' "T31c a stale beacon is graded on its age"
assert_contains "$OUT" 'cadence UNREADABLE' "T31c and the LATE row carries the disclosure too"
# ⛔ AND THE NEGATIVE DIRECTION: a MEASURED period must never wear the disclosure. Without this case the
# note could be forced on unconditionally and the suite would stay green (measured) — a disclosure that
# appears always is as useless as one that never does.
cr_frag 30min
RUN --check
assert_contains "$OUT" 'cadence allows 8400s' "T31d a measured 30-minute period yields the same bound as the assumption"
assert_absent "$OUT" 'cadence UNREADABLE' "T31d but it is NOT dressed as an assumption"
rm -f "$FX/frag/cr.timer"

# ── T22: an unusable scheduler binary is UNKNOWN for EVERY probe, not just the timer one ─────
# A guard on one probe out of three turned `SYSTEMCTL=/nonexistent` into claims about the box
# ("not installed", "NEITHER pin actuator is enabled") and exit 1 — a failed read reported as a fact.
PLATFORM_SEAM="" SKIP_SEAM=""; EXTRA_ENV=(SYSTEMCTL=/nonexistent/systemctl)
arm_all
RUN --check
assert_eq "$RC" 2 "T22 an unusable scheduler binary makes the grid unreadable, not wrong"
assert_contains "$OUT" 'eldato-orchestrator.service must      UNKNOWN' "T22 a SERVICE row is UNKNOWN (a failed read, not an absence)"
assert_contains "$OUT" 'pin-actuators            must      UNKNOWN' "T22 and the pin PAIR is UNKNOWN — never a conflict inferred from silence"
assert_absent "$OUT" 'NEITHER pin actuator' "T22 specifically not the claim derived from an empty read"
EXTRA_ENV=()

# ── T23: an `optional` row that is simply NOT ARMED reports UNARMED, not MISSING ─────────────
PLATFORM_SEAM="" SKIP_SEAM=""; EXTRA_ENV=()
arm_all
rm -f "$FX/units/system/eldato-runner-autoscale.timer" "$FX/units/system/eldato-runner-autoscale.service"
RUN --check
assert_contains "$OUT" 'eldato-runner-autoscale  optional  UNARMED' "T23 the optional row's NORMAL state is UNARMED (it is armed only by a dated decision)"
assert_eq "$RC" 0 "T23 and that is not a failure"
assert_absent "$OUT" 'OPTIONAL NOT OK' "T23 nor a complaint"

# ── T24: the #1678 template guard runs on a CELL too (the templates are tracked everywhere) ──
PLATFORM_SEAM="" SKIP_SEAM=""; EXTRA_ENV=()
arm_all
RUN --check
assert_contains "$OUT" 'com.tortoise.worktree-reaper unarmed   UNARMED' "T24 a CELL checks the tracked reaper template too"
python3 - "$FROOT/templates/launchd/com.tortoise.worktree-reaper.plist" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read().replace("<string>--dry-run</string>", "<string>--act</string>")
open(p, "w").write(s)
PY
RUN --check
assert_eq "$RC" 1 "T24 an armed-in-the-repo reaper template FAILS a cell's run"
assert_contains "$OUT" 'UNEXPECTED' "T24 and it is called out"
# ⛔ RESTORE THE FIXTURE CHECKOUT: every later case runs against it, so leaving the reaper template
# mutated made every subsequent `--check` red on T24's own finding — a suite whose cases only pass in
# this file's order. (Found while adding T32, which needs a clean fixture to assert a GREEN box.)
cp "$REPO/templates/launchd/com.tortoise.worktree-reaper.plist" "$FROOT/templates/launchd/"

# ── T32: the repair pool's SUPPLY HALF is a row — an unarmed supervisor is never COMPLETE ────
# `templates/systemd/eldato-worker-supply.service` ships here with its own Linux installer
# (`scripts/install-worker-supply.sh`) and carries NO `.timer`, so the derivation loop could not see it
# AND it was in no explicit list: a cell whose supervisor was never installed, was disabled, or had given
# up printed `ACTIVATION COMPLETE` at rc 0 (review cycle 11, F2). ⛔ NON-VACUITY: deleting the row from
# the cell branch takes the first case below to rc 0 with no named row, so this case is the row's only pin.
PLATFORM_SEAM="" SKIP_SEAM=""; EXTRA_ENV=()
arm_all
rm -f "$FX/units/system/eldato-worker-supply.service"
RUN --check
assert_eq "$RC" 1 "T32 a cell with no worker-supply supervisor FAILS the run"
assert_contains "$OUT" 'NOT ARMED: eldato-worker-supply.service' "T32 and the summary names the supply half"
assert_absent "$OUT" 'ACTIVATION COMPLETE' "T32 never the success line"
# The other two states the finding names, on the SAME row: installed-but-disabled, and — the shape a
# crash-looping `Type=simple` unit converges to — enabled but FAILED.
arm_all
unit system "eldato-worker-supply.service" "LoadState=loaded" "UnitFileState=disabled" "ActiveState=inactive"
RUN --check
assert_eq "$RC" 1 "T32 an installed but DISABLED supervisor fails the run"
assert_contains "$OUT" 'eldato-worker-supply.service is installed but NOT ENABLED' "T32 and it says which half is wrong"
arm_all
unit system "eldato-worker-supply.service" "LoadState=loaded" "UnitFileState=enabled" "ActiveState=failed"
RUN --check
assert_eq "$RC" 1 "T32 an ENABLED but FAILED supervisor fails the run"
assert_contains "$OUT" 'eldato-worker-supply.service must      FAILING' "T32 graded FAILING, not merely named"
arm_all
RUN --check
assert_eq "$RC" 0 "T32 and a supervisor that is enabled+active is green (the row is a gate, not a wall)"

# ── T33: `--status` RENDERS THE BEACON AS A DATE, ON A BOX THAT ONLY HAS THE BSD MECHANISM ─────
# ⛔ REVIEW P1-3. `conflict-rebase-timer.sh`'s `status` renders the last pass with `$(_iso "$beat")`.
# The defect that replaced — `date -u -d "@$beat" … || echo '?'`, which prints `-> ?` on every Mac,
# because `-d` is coreutils and BSD's equivalent is `-r` — could be restored VERBATIM and the suite
# stayed at 119/0: T8 is the only case that runs the real wrapper and it never invokes `status`, and
# `conflict-rebase.test.sh` "pins" status with a text grep over the source, which cannot see `_iso` at
# all. Worse, the portable replacement makes the two arms indistinguishable on a LINUX host, where the
# GNU arm succeeds — so the pin has to drive the BSD shape explicitly, which is what the stub below is.
# The contract under test is `_iso`'s own: degrade to the RAW EPOCH when no mechanism can render it,
# never to `?` — a missing formatter may cost a format, never the datum.
ISO_EPOCH=1700000000                     # 2023-11-14T22:13:20Z, fixed so the assertion is a constant
ISO_WANT='2023-11-14T22:13:20Z'
mkdir -p "$FX/bsd-date" "$FX/no-date" "$FX/iso-state"
printf '%s\n' "$ISO_EPOCH" >"$FX/iso-state/timer.beat"
cat >"$FX/bsd-date/date" <<'FAKEDATE'
#!/usr/bin/env bash
# A BSD-shaped `date`: `-r <epoch>` exists, `-d @<epoch>` does NOT (that arm is coreutils only), and the
# clock is pinned. This is how `_iso`'s second mechanism is exercised on a Linux CI host, and it is the
# shape a Mac actually has.
# ⛔ NO `sed -i` TO FILL IN THE CLOCK, and no placeholder at all: the heredoc is QUOTED, so the numbers
# below are literal text, and `sed -i` is exactly the GNU-only in-place form this repo's portability gate
# refuses (baseline 0 for this file — the first draft of this case took it to 1).
while [ "${1:-}" = "-u" ]; do shift; done
case "${1:-}" in
  -d) exit 1 ;;
  -r) e="$2"; shift 2
      case "${1:-}" in
        +%s) printf '%s\n' "$e" ;;
        +%Y-%m-%dT%H:%M:%SZ) python3 -c 'import sys,time;print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(sys.argv[1]))))' "$e" ;;
        *) exit 1 ;;
      esac ;;
  +%s) printf '%s\n' 1700000100 ;;
  *) exit 1 ;;
esac
FAKEDATE
chmod +x "$FX/bsd-date/date"
cat >"$FX/no-date/date" <<'NODATE'
#!/usr/bin/env bash
# Neither mechanism exists: every rendering arm must FAIL, and the caller must degrade to the datum.
while [ "${1:-}" = "-u" ]; do shift; done
case "${1:-}" in +%s) printf '%s\n' 1700000100 ;; *) exit 1 ;; esac
NODATE
chmod +x "$FX/no-date/date"
# ⛔ NEUTRALISE THE INSTALLED-UNIT LOOKUP, OR THIS CASE IS BOX-DEPENDENT (cycle 13, measured). The wrapper
# gained a divergence guard: an ambient `CONFLICT_REBASE_STATE` that disagrees with what the INSTALLED unit
# exports is REFUSED (rc 2) rather than written, which is right — and it made T33 green on ubuntu-latest
# (no unit installed, nothing to disagree with) and RED on any box where the timer is armed, i.e. exactly
# the "verdict depends on the box, not the tree" defect this suite's own T11/T12 exist to prevent. This
# fixture state dir is deliberately not the installed one, so the guard fires here and every assertion
# below fails at `rc 2`. `CONFLICT_REBASE_SYSTEMCTL`/`CONFLICT_REBASE_PLIST` are the wrapper's own seams:
# point them at a scheduler that answers nothing and a plist that does not exist.
printf '#!/usr/bin/env bash\nexit 0\n' >"$FX/no-systemctl"; chmod +x "$FX/no-systemctl"
ISOLATE="CONFLICT_REBASE_SYSTEMCTL=$FX/no-systemctl CONFLICT_REBASE_PLIST=$FX/absent.plist"
# and PROVE the guard is real, from the other side: with the real scheduler visible, the same fixture dir
# must be REFUSED. A guard that no test can make fire is a comment (T22's lesson).
OUT="$(CONFLICT_REBASE_STATE="$FX/iso-state" bash "$TIMER" status 2>&1)"; RC=$?
case "$RC:$OUT" in
    2:*REFUSING*) ok "T33 the divergence guard REFUSES a fixture state dir when a real unit is installed (rc 2)" ;;
    *) if command -v systemctl >/dev/null 2>&1 && systemctl show -p Environment eldato-conflict-rebase.service 2>/dev/null | grep -q CONFLICT_REBASE_STATE; then
           bad "T33 the divergence guard did not fire on a box whose unit exports the state dir (rc=$RC)"
       else
           ok "T33 no installed unit on this box, so there is nothing for the guard to refuse (not a failure)"
       fi ;;
esac
OUT="$(env $ISOLATE CONFLICT_REBASE_STATE="$FX/iso-state" PATH="$FX/bsd-date:$PATH" bash "$TIMER" status 2>&1)"; RC=$?
assert_eq "$RC" 0 "T33 --status runs against a fixture state dir (rc 0)"
assert_contains "$OUT" "-> $ISO_WANT" "T33 the beacon is RENDERED through the BSD arm (-r), not left as an epoch and not '?'"
assert_absent   "$OUT" '-> ?' "T33 and never the '?' the old fallback printed on every Mac"
OUT="$(env $ISOLATE CONFLICT_REBASE_STATE="$FX/iso-state" PATH="$FX/no-date:$PATH" bash "$TIMER" status 2>&1)"; RC=$?
assert_eq "$RC" 0 "T33 --status still exits 0 when NO date mechanism works (a format is not the datum)"
assert_contains "$OUT" "-> $ISO_EPOCH" "T33 with no mechanism at all it degrades to the RAW EPOCH — never to '?' and never to silence"
assert_absent   "$OUT" '-> ?' "T33 and the degraded form is the datum, not the question mark"

# ── T34: the REVIEW STAGE is graded on its own last pass, not on ActiveState (#4010) ─────────
# ⛔ THE DEFECT THIS PINS, MEASURED on a cloud cell 2026-11-12: `eldato-pr-repair.service` read
# `active (running)` for three days while EVERY pass wrote `decision: refusing` with
# `reason: env-file-unreadable:/tmp/cell-home/keys.env`, and this grid printed `OK … active` over it.
# That is a false PASS on the one row that decides whether the pipeline has a reviewer at all — the
# epic whose child this is advertises "deployed AND activated" on exactly this signal.
# ⛔ WHY `ActiveState` CANNOT SEE IT: `pr-repair-loop.sh --loop` CONTINUES on a refusal (it does not
# exit), so a configuration fault never converges to `failed` and the restart policy never speaks.
# ⛔ NON-VACUITY: restoring `probe_systemd_service "eldato-pr-repair.service" "must" "-" 0` at the call
# site takes every non-green case below back to rc 0 with the row reading OK, so these cases are the
# row's only pin (measured: the refusing case is the one that discriminates).
arm_all
PLATFORM_SEAM="" SKIP_SEAM=""; EXTRA_ENV=()
RUN --check
assert_eq "$RC" 0 "T34 a cell whose repair loop is DISPATCHING is green"
assert_contains "$OUT" 'last pass dispatched' "T34 and the row names the PASS, not just ActiveState"

# (a) the measured shape: enabled + active + permanently refusing.
write_repair_record refusing 'env-file-unreadable:/tmp/cell-home/keys.env'
RUN --check
assert_eq "$RC" 1 "T34 a unit that is ACTIVE while every pass REFUSES fails the run"
# ⛔ READ THE STATE BY FIELD, RUNNING THE MACHINE CONTRACT (`--tsv`). The pretty table pads by NAME
# LENGTH, so a literal carrying the wrong number of spaces cannot match any row the program can print —
# the trap this suite's own `row_field` header records (two assertions once could not fail under ANY
# mutation). `--tsv` is the contract: tab-separated, plus one SUMMARY line.
RUN --check --tsv
assert_eq "$(row_field "$OUT" eldato-pr-repair.service 3)" FAILING "T34 graded FAILING — not OK-on-ActiveState"
RUN --check
assert_contains "$OUT" 'env-file-unreadable:/tmp/cell-home/keys.env' "T34 and it names the loop's OWN reason"
assert_contains "$OUT" 'install-repair-service.sh --install' "T34 with a remedy an operator can paste"
assert_contains "$OUT" 'pass record this row read is' "T34 the remedy names the artifact the row ACTUALLY read"
# ⛔ AND IT MUST NOT PROMISE A DIAGNOSTIC THAT DOES NOT EXIST (review round 1, P2).
# `install-repair-service.sh::readback()` reads `is-active`/`is-enabled`/`KillMode`/`ExecStart` and
# never the installed unit's `Environment=`, so on the very box this row exists for (a pre-#3453
# render with HOME/ENV_FILE/O/PR_DOCTOR_REPO_DIR pointing at `/tmp/cell-home`) ALL FOUR it checks
# agree and `--status` names no disagreement. The old sentence promised the opposite, and an operator
# who follows a promise that cannot be kept concludes a correct `FAILING` row is spurious — the same
# false reassurance this PR removes from the grid, relocated into its own remedy. ABSENCE is the pin.
assert_absent "$OUT" 'names the rendered directives it disagrees with' "T34 the remedy makes no claim --status cannot keep"
assert_contains "$OUT" 'NOT ARMED: eldato-pr-repair.service' "T34 and the summary names the row"

# (b) enabled + active + NEVER PASSED: running proves the loop was started, not that a pass ran.
rm -f "$FHOME/orchestrator/state/pr-repair.status.json"
RUN --check
assert_eq "$RC" 1 "T34 an active loop that has never written a pass record fails the run"
assert_contains "$OUT" 'NEVER written a pass record' "T34 and it says which fact is missing"

# (c) the freshness axis: a green record that stopped moving is LATE, and the bound is the
# EFFECTIVE cadence (review round 2, F1): 2 x cadence + 2 x the pass's own runtime budget
# (`REPAIR_DOCTOR_TIMEOUT_S`, default 1800). A row that only read the DECISION would call a dead
# loop green for ever; a row that read only `3 x REPAIR_INTERVAL_S` redsin a HEALTHY one, because
# the producer's worst legitimate gap is cadence + pass runtime (900 + 1800 = 2700 = the old bound).
write_repair_record dispatched pass-complete "$(( $(date +%s) - 100000 ))"
RUN --check
assert_eq "$RC" 1 "T34 a STALE dispatched record fails the run"
assert_contains "$OUT" 'bound 5400s' "T34 the bound is 2 x 900 + 2 x 1800 (the shipped runtime budget), not 3 x 900"

# (d) the state dir is the UNIT's, never this launcher's default. A box rendered with O= elsewhere
# writes its record there; reading $O_RES instead would red a HEALTHY box for ever (the two-paths
# defect the conflict-rebase row already carries a fix for). The unit's OWN cadence must also be
# what the bound is built from, so a value far from the 900 default is used here — a shared default
# would make this case unable to discriminate.
rm -f "$FHOME/orchestrator/state/pr-repair.status.json"
unit system "eldato-pr-repair.service" "LoadState=loaded" "UnitFileState=enabled" "ActiveState=active" \
    "Result=success" "Environment=O=$FX/alt-o REPAIR_INTERVAL_S=3000"
write_repair_record dispatched pass-complete "" "$FX/alt-o/state"
RUN --check
assert_eq "$RC" 0 "T34 a record in the unit's OWN O= directory is read from there"
assert_contains "$OUT" 'bound 9600s' "T34 and the bound uses the unit's REPAIR_INTERVAL_S=3000 (2 x 3000 + 2 x 1800)"

# (e) TRIGGER MODE makes REPAIR_INTERVAL_S INERT (review round 2, F1 #2). The unit renders
# `--trigger`, whose front end schedules on REPAIR_TRIGGER_BACKSTOP_S; a bound built from the
# interval reds a healthy trigger-mode box for part of every window. The discriminator is that
# 2400 (backstop) and 900 (interval) give different bounds, so only the backstop can produce 8400.
unit system "eldato-pr-repair.service" "LoadState=loaded" "UnitFileState=enabled" "ActiveState=active" \
    "Result=success" "ExecStart={ path=/x/pr-repair-loop.sh ; argv[]=/x/pr-repair-loop.sh --trigger ; }" \
    "Environment=O=$FX/alt-o REPAIR_INTERVAL_S=900 REPAIR_TRIGGER_BACKSTOP_S=2400"
write_repair_record dispatched pass-complete "" "$FX/alt-o/state"
RUN --check
assert_eq "$RC" 0 "T34 a trigger-mode unit is graded on its backstop, not on the inert interval"
assert_contains "$OUT" 'bound 8400s' "T34 the bound is 2 x REPAIR_TRIGGER_BACKSTOP_S=2400 + 2 x 1800 (not the 900 interval)"
assert_contains "$OUT" 'REPAIR_TRIGGER_BACKSTOP_S=2400' "T34 and the row says WHICH cadence it read"

# (f) a unit that declares NO Environment= at all: BOTH fallbacks must be DISCLOSED — the record path
# falls back to this launcher's $O_RES and the cadence to 900 s. An assumed bound printed identically
# to a measured one is the defect the sibling row's T31/T31d pair exists to prevent one capability
# over, so the same discipline is applied here rather than taken on trust.
unit system "eldato-pr-repair.service" "LoadState=loaded" "UnitFileState=enabled" "ActiveState=active" "Result=success"
write_repair_record dispatched pass-complete
RUN --check
assert_eq "$RC" 0 "T34 a unit that declares no Environment= is still gradeable"
# ⛔ THE ASSERTION MUST CARRY A SUFFIX ONLY THIS ROW CAN PRODUCE (review round 3, P2). A bare
# `cadence UNREADABLE` is satisfied by the CONFLICT-REBASE row on every `arm_all` grid (`unit()`
# truncates the unit file, so `FragmentPath` is gone and that row correctly discloses `assumed 1800 s`),
# which made this assertion unable to fail even with the repair row's disclosure deleted — the exact
# defect class this suite's own `row_field` header names, committed inside a test written to prevent
# it. The two rows differ in the suffix: this probe prints `assumed 900s` (no space, the value it
# applied) and the sibling prints `assumed 1800 s`. Pin the repair row's own spelling.
assert_contains "$OUT" 'cadence UNREADABLE from the unit — assumed 900s' "T34 an assumed cadence is DISCLOSED on THIS row, not inherited from the sibling"
assert_contains "$OUT" 'declares no O=' "T34 and so is the fallback state directory"

arm_all
RUN --check
assert_eq "$RC" 0 "T34 and the fixture is restored healthy for anything after this case"

echo "activate-harness.test.sh — passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
