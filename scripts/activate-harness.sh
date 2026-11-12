#!/usr/bin/env bash
# activate-harness.sh — ONE declaration of what must be ARMED on this box, one verb to converge it,
# and one verb to VERIFY it. The answer to "if we restart the harness, how do we not forget a process?"
#
#   bash scripts/activate-harness.sh --check     # the GRID: what is armed, what is not. Changes NOTHING.
#   bash scripts/activate-harness.sh --install   # converge every MUST-ARMED row, then verify. Idempotent.
#   bash scripts/activate-harness.sh --tsv       # --check, machine-readable (one row per line)
#   bash scripts/activate-harness.sh --help
#
# ── THE DEFECT THIS CLOSES (owner, 2026-11-07) ──────────────────────────────────────────────────
# "check whether everything we're shipping is fully wired in so the harness self-heals and is bundled
# with a launcher — or basically check what system we need so if we restart the harness we're not
# going to forget a key process from being activated."
#
# Measured that night, and every one of these read HEALTHY from inside:
#   * `scripts/conflict-rebase-timer.sh` shipped with NO installer, NO unit and NO plist: scheduled on
#     ZERO boxes while 8 PRs sat CONFLICTING and an operator hand-dispatched 8 lanes to do what a timer
#     would have done;
#   * `eldato-objective-reminder.timer` and `eldato-controller-watchdog.timer` were installed,
#     ENABLED and ACTIVE on pi-cell-1 and had **never fired once** — both templates carry
#     `OnUnitActiveSec=` with no `OnBootSec`/`OnCalendar`, so nothing ever arms the monotonic cycle.
#     `systemctl is-enabled` says `enabled`; `list-timers` shows the unit; only `LastTriggerUSec`
#     says `never`. That is an inert enforcer;
#   * `eldato-orchestrator.service` and `eldato-pr-repair.service` were `enabled` and `FAILED` for
#     14 hours (restart counter exhausted) — nothing noticed, because nothing reads the unit's state;
#   * `~/Library/LaunchAgents/com.eldato.harness-apply.plist` did not exist on the operator's Mac, so
#     every merged change under `extensions/`, `scripts/` and `skills/` was INERT there.
#
# The pattern is the same every time: a capability is written, tested and shipped WITH an installer,
# and the installer is never run — or was run on a box that has since been rebuilt. Nothing notices,
# because a timer that does not exist produces no error.
#
# ── WHAT THIS FILE IS, AND WHAT IT IS NOT ──────────────────────────────────────────────────────
# IT IS the declaration + the convergence + the verification of the ARMED layer: the scheduled jobs
# and daemon units. Adding a capability is adding a ROW here (or a template, which becomes a row by
# derivation), not remembering a step on every box.
# IT IS NOT a second liveness authority. It does not re-decide whether a PROCESS is alive — that is
# `scripts/lib/fleet-inventory.sh` (one verdict function, `docs/ops/fleet-liveness.md`), and its
# reader is `scripts/orchestrator-bringup.sh`. This file asks a DIFFERENT question — "is this
# capability SCHEDULED, ENABLED, and has it actually FIRED recently?" — and it borrows that file's
# vocabulary rather than inventing a second one.
# IT IS NOT an installer. Every row names the capability's OWN installer; this file runs it and reads
# back the artifact. Re-implementing rendering here would give the fleet two answers to "where is this
# unit" (the #2048/#2058 split, and the reason `install-*` scripts exist at all).
#
# ── THE VERDICTS (borrowed from lib/fleet-inventory.sh, one vocabulary) ────────────────────────
#   OK            armed, enabled, and its last run completed inside its own cadence
#   LATE          armed and enabled, but the last run is older than its cadence allows
#   NEVER-FIRED   installed + enabled + active, and it has NEVER run (the inert-enforcer state)
#   FAILING       the last run exited non-zero, or the unit is in `failed`
#   MISSING       not installed at all on a box where the row applies
#   UNARMED       deliberately not armed on this box, with the issue that decided it (NOT a failure)
#   UNEXPECTED    a deliberately-unarmed row that IS armed — a finding, not a pass
#   SKIPPED       the row does not apply to this platform/box
#   UNKNOWN       the read itself failed (fail closed: never a pass — the abstention doctrine)
#
# ── CLASSES, AND WHY "DELIBERATELY UNARMED" IS A ROW TYPE AND NOT A COMMENT ────────────────────
#   must       REQUIRED. A row not in OK/LATE fails the run and is named.
#   optional   armed by a dated owner decision that has not been taken on this box. `--install` never
#              arms it; `--check` reports ARMED (ok) or UNARMED (ok, with the reason).
#   unarmed    DELIBERATELY not armed, by a recorded decision. `--install` must never arm it, and an
#              armed instance is `UNEXPECTED` — a failure. `--check` also asserts the TRACKED TEMPLATE
#              still carries its disarming flag, because "the launcher did not arm it" is only half the
#              invariant: the other half is "nobody quietly edited the template to armed".
#
# ⛔ #1678 vs THIS FILE — the contradiction test, run first. The owner ruling of 2026-10-11 makes
# ARMING A DELETION TOOL a separate dated operator step, and says the tracked template must keep
# shipping `--dry-run`. So the worktree/branch/cache reapers are `unarmed` rows here: `--install`
# NEVER arms them, this file never edits a template's mode flag, and `--check` REDDENS if a tracked
# reaper template has lost its `--dry-run` (the template edit is the bypass nobody would see).
# `scripts/install-launchd.test.sh`'s assertion that the reaper ships unarmed is untouched.
#
# ── IDEMPOTENCE ───────────────────────────────────────────────────────────────────────────────
# `--install` on a fully-armed box runs each installer once (they are documented idempotent; a
# byte-identical render is a no-op apart from `daemon-reload`), re-reads every row, and exits 0 having
# changed nothing. On a fresh box it installs what is missing and NAMES what still did not come up.
#
# ── VERIFY AFTER ARMING, ALWAYS ───────────────────────────────────────────────────────────────
# A launcher that prints "armed" without reading the artifact back is the fail-open this repo keeps
# filing issues about. Every row is re-probed after `--install`, and the exit code is the grid's: 0 all
# good · 1 a must-row is not OK (or an UNEXPECTED/unarmed-row violation) · 2 a read could not be
# performed. `--install` prints `ACTIVATION COMPLETE` / `ACTIVATION INCOMPLETE — <n> row(s)`.
#
# Env seams (tests + unusual boxes):
#   INFRA_ROOT / AGENT_INFRA_PATH   the checkout the templates and installers come from
#   ELDATO_PLATFORM                 override `uname -s` (tests drive the Darwin grid on Linux)
#   SYSTEMCTL / LAUNCHCTL           the scheduler CLIs (tests: fakes)
#   ACTIVATE_SYSTEMD_TEMPLATES_DIR  systemd template dir (default <root>/templates/systemd)
#   ACTIVATE_LAUNCHD_TEMPLATES_DIR  launchd template dir (default <root>/templates/launchd)
#   ACTIVATE_SKIP_INSTALL=1         `--install` verifies only (used by the tests to drive the failure path)
#
# ⛔ EVERY SEAM ABOVE CAN ONLY MAKE THIS TOOL REPORT **MORE** TROUBLE, NEVER LESS — that is the
# property that keeps them from being bypasses, and it is why there is no `--force`, no
# `--skip-row`, and no env var that suppresses a row. ACTIVATE_SKIP_INSTALL=1 removes the ARMING
# step and still runs the full verification (so it can only surface failures); ELDATO_PLATFORM on a
# Linux box selects the Darwin grid, which probes ~/Library/LaunchAgents and reports every launchd
# row MISSING (again: failures, not silence). A real bypass — one that could make a broken box
# read green — is the one thing this file must never grow.
#   CELL_HOME / O                   a cell's home and controller state dir (as in cloud-cell-supervisor)
#
# Exit codes: 0 ok · 1 a required row is not OK · 2 usage, or a row could not be read.
set -uo pipefail

# ── where the declarations and installers come from ──────────────────────────────────────────
# ⛔ A FARMED COPY HAS NO ../templates BESIDE IT. On a cell this file lives at
# $HOME/.pi/agent/scripts/, so `$INFRA_ROOT` = $HOME/.pi/agent and a naive default would report every
# template missing on exactly the box that was just provisioned. Resolve, and REFUSE by name.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
resolve_root() {
    local cand
    for cand in "${INFRA_ROOT:-}" "${AGENT_INFRA_PATH:-}" \
                "$(cd "$SELF_DIR/.." 2>/dev/null && pwd)" \
                "${CELL_HOME:-$HOME}/agent-infra" "/tmp/cell-ai" "/tmp/cell/agent-infra"; do
        [ -n "$cand" ] || continue
        [ -d "$cand/templates/systemd" ] || continue
        [ -d "$cand/scripts" ] || continue
        ROOT="$cand"; return 0
    done
    return 1
}
ROOT=""
PLATFORM="${ELDATO_PLATFORM:-$(uname -s 2>/dev/null || printf unknown)}"
case "$PLATFORM" in
    Darwin) ACT_PLATFORM="mac" ;;
    Linux)  ACT_PLATFORM="cell" ;;
    *)      ACT_PLATFORM="unknown" ;;
esac
# ⛔ These are resolved AFTER resolve_root() runs (bottom of file, before the grid). A default that
# read $ROOT here would be EMPTY — the exact "no templates, so nothing is declared" false green.
SYS_TEMPLATES=""
LAUNCHD_TEMPLATES=""
# ⛔ THE REPO'S ONE MTIME SHIM, SOURCED — NOT A THIRD COPY OF `stat -f %m || stat -c %Y` (review F10).
# This file is a LAUNCHER run from a checkout (it is not farmed), so `scripts/lib/box.sh` is present
# wherever it runs; the cascade it replaces also leaked `stat: cannot read file system information` to
# stderr on every probe. The two-arm fallback survives ONLY for a box with no checkout at all.
BOX_LIB=""
# ⛔ THE ORDER IS `-c` THEN `-f`, AND THIS IS NOT STYLE — IT IS A MEASURED BUG (review F10's own fix
# proved it). On GNU, `stat -f %m <file>` means "FILESYSTEM status": it SUCCEEDS and prints a block
# table, so a `stat -f … || stat -c …` cascade short-circuits on Linux with garbage. (This is exactly
# what scripts/lib/box.sh's header warns about, and why it tries `-c` first on a Linux box.) BSD has no
# `-c`, so it fails cleanly and the `-f` arm answers there. The digit guard below is the second net.
box_mtime_now_fallback() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf ''; }
box_mtime_now() { # <path> -> epoch seconds on stdout, '' when unreadable
    if [ -z "$BOX_LIB" ] && [ -n "$ROOT" ] && [ -r "$ROOT/scripts/lib/box.sh" ]; then BOX_LIB="$ROOT/scripts/lib/box.sh"; fi
    if [ -n "$BOX_LIB" ]; then
        # shellcheck source=/dev/null
        [ -n "${BOX_SH_LOADED:-}" ] || { . "$BOX_LIB" && BOX_SH_LOADED=1; }
        if [ "${BOX_SH_LOADED:-}" = 1 ] && command -v box_mtime >/dev/null 2>&1; then
            box_mtime "$1" 2>/dev/null && return 0
        fi
    fi
    box_mtime_now_fallback "$1"
}
SYSTEMCTL_BIN="${SYSTEMCTL:-systemctl}"
LAUNCHCTL_BIN="${LAUNCHCTL:-launchctl}"
CELL_HOME_RES="${CELL_HOME:-$HOME}"
O_RES="${O:-$CELL_HOME_RES/orchestrator}"
SKIP_INSTALL="${ACTIVATE_SKIP_INSTALL:-0}"
TSV=0
VERB="check"

# Every row the grid printed, for the summary. Parallel arrays: bash 3.2 has no associative arrays and
# macOS /bin/bash is 3.2 — a 4.x requirement here would make this file unrunnable on the Mac, which is
# one of the two boxes it exists for.
ROWS=""

# ⛔ NOT `say`. macOS ships /usr/bin/say (text-to-speech): a helper with that name that is ever missing
# from a sliced-out fragment makes the shell read the banner ALOUD — a green run that spoke, which is
# agent-infra#2910 and why tests/no-tts/run.sh scans the tree for the NAME rather than trusting a
# convention. `act_say` cannot collide with anything on either platform.
act_say() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# ── scheduler plumbing ───────────────────────────────────────────────────────────────────────
# Which manager owns a unit: a box can carry a SYSTEM unit and a USER unit for the same name, and a
# read that picked the wrong one would answer about a different unit (the installers negotiate both).
# Prints "<scope>" and sets SC_PREFIX to the argv the read must use.
SC_PREFIX=""
sc_scope_for() { # <unit>
    local u="$1" ls
    ls="$($SYSTEMCTL_BIN show -p LoadState --value "$u" 2>/dev/null || true)"
    if [ -n "$ls" ] && [ "$ls" != "not-found" ]; then SC_PREFIX="$SYSTEMCTL_BIN"; SC_SCOPE="system"; return 0; fi
    ls="$($SYSTEMCTL_BIN --user show -p LoadState --value "$u" 2>/dev/null || true)"
    if [ -n "$ls" ] && [ "$ls" != "not-found" ]; then SC_PREFIX="$SYSTEMCTL_BIN --user"; SC_SCOPE="user"; return 0; fi
    SC_PREFIX=""; SC_SCOPE="none"; return 1
}
SC_SCOPE="none"

sysd_show() { # <unit> <property>
    [ -n "$SC_PREFIX" ] || return 1
    # shellcheck disable=SC2086
    $SC_PREFIX show -p "$2" --value "$1" 2>/dev/null
}

# `LastTriggerUSec` is the ONLY field that answers "did it ever fire": `is-enabled` says enabled for a
# timer whose monotonic cycle nothing armed, and `list-timers --all` renders it with a `-` that reads
# like an idle job. Epoch is what makes the age comparable to the cadence.
age_of() { # <systemd LastTriggerUSec> -> SECONDS since that instant on stdout; 1 when unparseable
    local s="$1"
    [ -n "$s" ] || return 1
    case "$s" in n/a|never|-) return 1 ;; esac
    # ⛔ ZONE-FREE BY CONSTRUCTION, AND THE PREVIOUS VERSION OF THIS FUNCTION WAS NOT — IT WAS A FALSE
    # PASS (review F4). `systemctl show -p LastTriggerUSec` renders the stamp in the BOX'S LOCAL ZONE;
    # measured on systemd 255 on this cell: `Sat 2026-11-07 20:01:45 UTC` becomes
    # `Sun 2026-11-08 05:01:45 JST` under TZ=Asia/Tokyo. An epoch computed with `calendar.timegm`
    # (i.e. the stamp parsed AS UTC) is therefore off by the UTC offset, and on a box EAST of UTC the
    # age comes out NEGATIVE, gets clamped to 0, and a required timer that died ten hours ago reads
    # `OK` — the exact false green this file exists to remove. (The old comment asserted the opposite,
    # which is why it survived until a reviewer ran the grid under a non-UTC TZ.)
    # Two further corrections in the same line:
    #   * `%Z` is GONE. python's strptime accepts only UTC/GMT/the box's own tzname, so a systemd that
    #     prints `CET` fails the parse — and a failed parse must be a FAILED READ, never an absence.
    #   * `time.mktime` on a zone-STRIPPED stamp interprets it in the same local zone systemd rendered
    #     it in, so the subtraction is a true age on any box in any zone. Only the AGE is ever needed,
    #     so no timezone conversion is required anywhere in this file.
    python3 -c 'import sys, time, datetime
s = sys.argv[1].rsplit(" ", 1)[0]
for fmt in ("%a %Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M:%S"):
    try:
        print(max(0, int(time.time() - time.mktime(datetime.datetime.strptime(s, fmt).timetuple()))))
        break
    except ValueError:
        continue
else:
    sys.exit(1)' "$s" 2>/dev/null && return 0
    return 1
}

# ── verdict emission ────────────────────────────────────────────────────────────────────────
ROW_STATE=""
emit() { # <name> <class> <state> <detail>
    local name="$1" class="$2" state="$3" detail="$4"
    ROW_N=$(( ROW_N + 1 ))
    ROWS="${ROWS}${name}|${class}|${state}|${detail}
"
    if [ "$TSV" = 1 ]; then
        printf '%s\t%s\t%s\t%s\n' "$name" "$class" "$state" "$detail"
    else
        printf '  %-24s %-9s %-12s %s\n' "$name" "$class" "$state" "$detail"
    fi
}

# ⛔ ONE AVAILABILITY GUARD FOR EVERY SYSTEMD PROBE (review cycle-2 P1.3). The first fix put the check
# inside probe_systemd_timer only, so `SYSTEMCTL=/nonexistent/systemctl` graded the two SERVICE rows and
# the pin-actuator PAIR as `MISSING` — assertions about a box that was never read, and for
# pin-actuators a claim of a CONFLICT derived from silence. A failed read is never a fact about the box.
sc_available() { command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1; }

# ── probe: a systemd timer-backed capability ────────────────────────────────────────────────
# max_age = the cadence in seconds plus the tolerance the timer itself declares
# (RandomizedDelaySec + the pass's own runtime). Stated per row, never inferred from `list-timers`,
# which prints a NEXT time even for a timer that has never fired.
probe_systemd_timer() { # <base> <class> <max_age_s> <note> [beacon] [brake]
    # ⛔ `LastTriggerUSec` ANSWERS "DID THE TIMER TICK", NOT "DID THE PASS DO ANYTHING" — and for a row
    # with a BRAKE the two diverge permanently. `eldato-conflict-rebase` honours `pause` by exiting 0
    # without stamping its beacon, so after `pause` the timer keeps ticking every 30 min and this grid
    # kept printing `OK … fired Ns ago` forever: the brake that was just made to hold was invisible to
    # the instrument that is supposed to notice exactly this (review F16). Where a pass writes its own
    # beacon, the beacon is the liveness signal and the unit's trigger is only the plumbing.
    local base="$1" class="$2" max_age="$3" note="${4:-}" beacon="${5:-}" brake="${6:-}"
    local timer="$base.timer" svc="$base.service" en act last_raw age res bmt
    # ⛔ A MISSING BINARY IS A FAILED READ, NOT A FINDING ABOUT THE BOX (review F12). The old arm fired
    # only for the literal name `systemctl`, so `SYSTEMCTL=/nonexistent/systemctl` — a plausible mis-set
    # seam — graded every row MISSING ("not installed") instead of UNKNOWN ("could not be read"), which
    # is the difference between a claim about the machine and a claim about this run.
    if ! sc_available; then
        emit "$base" "$class" UNKNOWN "$SYSTEMCTL_BIN is not executable — the armed layer cannot be read on this box (a failed read, not an absence)"
        return 0
    fi
    if ! sc_scope_for "$timer"; then
        if [ "$class" = "unarmed" ]; then
            emit "$base" "$class" UNARMED "$note"
        elif [ "$class" = "optional" ]; then
            # ⛔ AN `optional` ROW'S NORMAL, DOCUMENTED STATE IS "NOT ARMED" — and it used to be graded
            # MISSING, with the summary then announcing "…are ARMED on this box and NOT in an OK state"
            # over a row that is not armed (review cycle-2 P1.4). The class had no way to say its own
            # healthy state. UNARMED is that state, and it is not a failure.
            emit "$base" "$class" UNARMED "$timer is not installed here — this row is armed only by a dated decision (#2403), so not-armed is its expected state${note:+ — $note}"
        else
            emit "$base" "$class" MISSING "$timer is not installed in either systemd manager${note:+ — $note}"
        fi
        return 0
    fi
    en="$(sysd_show "$timer" UnitFileState)"
    act="$(sysd_show "$timer" ActiveState)"
    res="$(sysd_show "$svc" Result)"
    if [ -z "$(sysd_show "$timer" LoadState | sed -n '1p')" ]; then
        emit "$base" "$class" UNKNOWN "the ${SC_SCOPE} manager answered nothing for $timer (read failed, not absent)"
        return 0
    fi
    # A DISABLED timer is 'installed but will not fire' — the state the audit is for.
    case "$en" in
        enabled|enabled-runtime|static|generated) ;;
        *) emit "$base" "$class" MISSING "$timer is installed but NOT ENABLED (UnitFileState=$en) — it will never fire"; return 0 ;;
    esac
    # Deliberately-unarmed rows are judged on ARMING, not on liveness: an armed reaper is the finding.
    if [ "$class" = "unarmed" ]; then
        emit "$base" "$class" UNEXPECTED "this row is deliberately UNARMED (#1678) but $timer is enabled — someone armed a deletion tool without the dated operator step${note:+ ($note)}"
        return 0
    fi
    case "$act" in
        active) ;;
        failed) emit "$base" "$class" FAILING "$timer is $act" ; return 0 ;;
        *)      emit "$base" "$class" FAILING "$timer is not active (ActiveState=$act) — enabled but not cycling"; return 0 ;;
    esac
    # The unit's LAST RUN is the liveness signal, and its RESULT is the second half.
    case "$res" in
        ''|success) ;;
        *) emit "$base" "$class" FAILING "$svc last run Result=$res — it is scheduled and failing (the restart counter may be exhausted)"; return 0 ;;
    esac
    # A brake is a DELIBERATE state, not a failure — the row says which, so "armed and stopped" can
    # never be confused with "armed and working".
    if [ -n "$brake" ] && [ -f "$brake" ]; then
        emit "$base" "$class" OK "$timer is armed but PAUSED ($brake exists) — every tick exits 0 without acting, by design; remove the brake to resume"
        return 0
    fi
    if [ -n "$beacon" ]; then
        # ⛔ THE NOTE IS DEFINED ONCE AND USED BY EVERY BEACON EMIT (cycle-7 P2). Appending it inline at
        # each site meant three of the four could lose it with the suite still green — and two of those
        # three are the states an operator actually meets (NEVER-FIRED on a freshly built box, LATE on a
        # stopped one). One definition, four uses: reverting the DEFINITION now reddens via T31/T31b/T31c.
        # The UNKNOWN-mtime arm below is the one use no test can pin — breaking `stat` portably is not a
        # thing a fixture can do — and that is stated rather than implied.
        local nsuf=""
        [ -n "$note" ] && nsuf=" —$note"
        if [ ! -f "$beacon" ]; then
            emit "$base" "$class" NEVER-FIRED "$timer is enabled and active but its beacon $beacon has never been written — no pass has ever COMPLETED (a tick that exits 0 without a beacon is not one)${nsuf}"
            return 0
        fi
        local bmt
        bmt="$(box_mtime_now "$beacon")"
        case "$bmt" in
            ''|*[!0-9]*) emit "$base" "$class" UNKNOWN "beacon $beacon exists but its mtime is unreadable — freshness unmeasurable${nsuf}" ; return 0 ;;
        esac
        age=$(( $(date +%s) - bmt )); [ "$age" -lt 0 ] && age=0
        if [ "$age" -gt "$max_age" ]; then
            emit "$base" "$class" LATE "$timer's last COMPLETED pass was ${age}s ago (beacon $beacon; cadence allows ${max_age}s)${nsuf}"
        else
            emit "$base" "$class" OK "$timer's last COMPLETED pass was ${age}s ago (beacon, cadence allows ${max_age}s)${nsuf}"
        fi
        return 0
    fi
    # ⛔ NEVER-FIRED MEANS THE FIELD WAS EMPTY — nothing else. A stamp this box cannot parse is a FAILED
    # READ (UNKNOWN, exit 2), because "I could not read it" and "it never happened" are opposite claims,
    # and the second one certifies a timer that may be perfectly healthy as permanently dead.
    last_raw="$(sysd_show "$timer" LastTriggerUSec)"
    case "$last_raw" in
        ''|n/a|never|-) last_raw="" ;;
    esac
    if [ -z "$last_raw" ]; then
        emit "$base" "$class" NEVER-FIRED "$timer is enabled and active and has NEVER TRIGGERED (no LastTriggerUSec) — the inert-enforcer state; check the template for an OnUnitActiveSec with no OnBootSec/OnCalendar to arm the cycle${note:+ — $note}"
        return 0
    fi
    age="$(age_of "$last_raw")" || age=""
    if [ -z "$age" ]; then
        emit "$base" "$class" UNKNOWN "$timer reports LastTriggerUSec='$last_raw' and this box could not parse it — a failed read, NOT an absence (a ${max_age}s cadence cannot be judged)"
        return 0
    fi
    if [ "$age" -gt "$max_age" ]; then
        emit "$base" "$class" LATE "$timer last fired ${age}s ago (cadence allows ${max_age}s)"
    else
        emit "$base" "$class" OK "$timer fired ${age}s ago (${SC_SCOPE} scope, cadence allows ${max_age}s)"
    fi
}

# ── probe: a systemd service (a daemon, not a clock) ────────────────────────────────────────
probe_systemd_service() { # <unit> <class> <beacon-path|-> <max_age_s> <note>
    local unit="$1" class="$2" beacon="$3" max_age="$4" note="${5:-}"
    local en act now age beat
    if ! sc_available; then
        emit "$unit" "$class" UNKNOWN "$SYSTEMCTL_BIN is not executable — this service cannot be read on this box (a failed read, not an absence)"
        return 0
    fi
    if ! sc_scope_for "$unit"; then
        if [ "$class" = "unarmed" ]; then emit "$unit" "$class" UNARMED "$note"; else emit "$unit" "$class" MISSING "$unit is not installed in either systemd manager${note:+ — $note}"; fi
        return 0
    fi
    en="$(sysd_show "$unit" UnitFileState)"
    act="$(sysd_show "$unit" ActiveState)"
    if [ "$class" = "unarmed" ]; then
        case "$en" in
            enabled|enabled-runtime) emit "$unit" "$class" UNEXPECTED "deliberately UNARMED but $unit is enabled${note:+ ($note)}" ;;
            *) emit "$unit" "$class" UNARMED "$note" ;;
        esac
        return 0
    fi
    case "$en" in
        enabled|enabled-runtime) ;;
        *) emit "$unit" "$class" MISSING "$unit is installed but NOT ENABLED (UnitFileState=$en)"; return 0 ;;
    esac
    case "$act" in
        active|activating) ;;
        failed) emit "$unit" "$class" FAILING "$unit is FAILED — the restart policy gave up; nothing is watching it"; return 0 ;;
        *) emit "$unit" "$class" FAILING "$unit is ${act:-unknown} — enabled but not running"; return 0 ;;
    esac
    if [ "$beacon" != "-" ]; then
        if [ ! -f "$beacon" ]; then
            emit "$unit" "$class" LATE "$unit is active but its beacon $beacon does not exist yet"
            return 0
        fi
        beat="$(cat "$beacon" 2>/dev/null || echo 0)"
        case "$beat" in ''|*[!0-9]*) beat=0 ;; esac
        now="$(date +%s)"; age=$(( now - beat ))
        [ "$age" -lt 0 ] && age=0
        if [ "$age" -gt "$max_age" ]; then
            emit "$unit" "$class" LATE "$unit is active but its beacon is ${age}s old (bound ${max_age}s)"; return 0
        fi
        emit "$unit" "$class" OK "$unit active, beacon ${age}s old"
        return 0
    fi
    emit "$unit" "$class" OK "$unit active"
}

# ── probe: the PR repair loop, graded on its OWN last pass (agent-infra#4010) ────────────────
# ⛔ `ActiveState=active` IS NOT "the review stage is running", AND THIS ROW USED TO BELIEVE IT WAS.
# MEASURED on a cloud cell 2026-11-12: `eldato-pr-repair.service` had read `active (running)` for three
# days while EVERY pass wrote
#     {"decision": "refusing", "reason": "env-file-unreadable:/tmp/cell-home/keys.env"}
# and journalled `REFUSING: ENV_FILE=… could not be read` every 15 minutes. This grid printed
#     eldato-pr-repair.service   must   OK   eldato-pr-repair.service active
# over it — so the fleet's own activation instrument certified the review stage on a box that had never
# reviewed a pull request, which is precisely the claim #4010 exists to stop making (“no cell has ever
# run a review”). A row that cannot fail is not a gate; it is a caption.
#
# ⛔ WHY `ActiveState` CAN NEVER SEE THIS ONE. `pr-repair-loop.sh --loop` treats a REFUSAL as a
# CONTINUE, not an exit ("a loop that exits on a single rc=3 is a supply path that stops about the first
# refusal it meets"), so a pure configuration fault — here, a credential path rendered for a home this
# box does not have — never converges to `failed` and the restart policy never speaks. The unit is alive
# BY DESIGN while doing nothing BY MEASUREMENT: the ALIVE / REFUSING state `docs/ops/harness-activation.md`
# §2 names, and no `ActiveState` read can distinguish it from a working pass.
#
# The artifact that answers it is the loop's OWN record, `$O/state/pr-repair.status.json`, written by
# `write_status` on every pass, whose `decision` is one of dispatched | idle | deferred | refusing |
# placed-undelivered | pass-failed | skipped and whose `reason` names why. So this row grades THAT, and
# the three install / enable / active arms are kept because they are still facts that must be reported
# in their own words rather than folded into one verdict.
probe_repair_service() { # <unit> <class> <note>
    local unit="$1" class="$2" note="${3:-}"
    local en act env_str exec_str o_dir bound rec py_out decision reason ep cap now age assumed remedy cadence cad_src cad_note runtime
    if ! sc_available; then
        emit "$unit" "$class" UNKNOWN "$SYSTEMCTL_BIN is not executable — this service cannot be read on this box (a failed read, not an absence)"
        return 0
    fi
    if ! sc_scope_for "$unit"; then
        emit "$unit" "$class" MISSING "$unit is not installed in either systemd manager${note:+ — $note}"
        return 0
    fi
    en="$(sysd_show "$unit" UnitFileState)"
    act="$(sysd_show "$unit" ActiveState)"
    case "$en" in
        enabled|enabled-runtime) ;;
        *) emit "$unit" "$class" MISSING "$unit is installed but NOT ENABLED (UnitFileState=$en)"; return 0 ;;
    esac
    case "$act" in
        active|activating) ;;
        failed) emit "$unit" "$class" FAILING "$unit is FAILED — the restart policy gave up; nothing is watching it"; return 0 ;;
        *) emit "$unit" "$class" FAILING "$unit is ${act:-unknown} — enabled but not running"; return 0 ;;
    esac
    # ⛔ THE STATE DIR IS THE UNIT'S, NOT THIS LAUNCHER'S DEFAULT (the same rule `cr_state` follows
    # above). A box rendered with a non-default `O=` writes its record there, and reading `$O_RES`
    # instead would grade a HEALTHY box LATE for ever — two paths that look alike, one of them wrong.
    # An unreadable Environment is not evidence of the default, so the fallback SAYS it fell back.
    env_str="$(sysd_show "$unit" Environment 2>/dev/null)"
    exec_str="$(sysd_show "$unit" ExecStart 2>/dev/null)"
    # ⛔ NO HELPER FUNCTION FOR THE THREE READS BELOW, AND THAT IS DELIBERATE: a nested `fn() { … }` in
    # bash defines a GLOBAL, so a helper here would be a shared name in a 1300-line file that already
    # has one of everything. Three inline reads cost three pipes and cannot collide.
    o_dir="$(printf '%s' "$env_str" | tr ' ' '\n' | sed -n 's/^O=//p' | head -1)"
    assumed=""
    if [ -z "$o_dir" ]; then o_dir="$O_RES"; assumed=" (the unit declares no O=, so the record was read from this launcher's $O_RES)"; fi
    # ── THE FRESHNESS BOUND, FROM THE EFFECTIVE CADENCE (review round 2, F1) ────────────────────────
    # ⛔ `REPAIR_INTERVAL_S` IS NOT THE PASS CADENCE IN THREE SHIPPED SHAPES, and a bound built on it
    # reds a HEALTHY box — this file's own "a check that reddens a healthy box is its own failure"
    # rule, and the same class the conflict-rebase row already fixed one row up (`cr_period * 2 + 4800`
    # exists precisely so "a legitimately slow pass is not its own red", :996-1000):
    #   1. THE PASS'S OWN RUNTIME IS NOT BUDGETED. `pr-repair-loop.sh:475` dispatches through
    #      `timeout "${REPAIR_DOCTOR_TIMEOUT_S:-1800}" python3 "$doctor" --max "$cap"` and
    #      `write_status` runs only AFTER it returns; the loop arm then `sleep "$INTERVAL_S"` (:671).
    #      Worst legitimate gap between two records = cadence + pass runtime = 900 + 1800 = 2700 s,
    #      which was exactly the old `3 x interval` bound — so a pass that ran to its own timeout, or
    #      an interval raised above 900, read LATE with nothing wrong at all.
    #   2. `REPAIR_MODE=trigger` MAKES `REPAIR_INTERVAL_S` INERT. The unit then renders
    #      `pr-repair-loop.sh --trigger`, whose front end schedules on `REPAIR_TRIGGER_BACKSTOP_S`
    #      (`pr-doctor-trigger.py` gates a backstop pass on `now - last_pass >= backstop`); the
    #      installer defaults that to 1800 s and renders it unvalidated, so any backstop above the
    #      bound reddened a healthy trigger-mode box for part of every window.
    #   3. `keys.env` IS AUTHORITATIVE OVER THE UNIT FOR TUNABLES and this grid cannot source it
    #      (`pr-repair-loop.sh:594` re-derives `INTERVAL_S` AFTER the source). So the row DISCLOSES
    #      the cadence it read and that an override is not consulted, rather than presenting a
    #      possibly-overridden default as a measurement.
    # The shape is the sibling's: 2 x cadence (one completed pass, then one missed slot) + 2 x the
    # pass's own runtime budget. Floored at 1800 s so a sub-minute cadence is not an instant red.
    local cadence cad_src runtime
    cadence=""; cad_src=""
    runtime="$(printf '%s' "$env_str" | tr ' ' '\n' | sed -n 's/^REPAIR_DOCTOR_TIMEOUT_S=//p' | head -1)"
    case "$exec_str" in
        *--trigger*)
            cad_src="REPAIR_TRIGGER_BACKSTOP_S"
            cadence="$(printf '%s' "$env_str" | tr ' ' '\n' | sed -n 's/^REPAIR_TRIGGER_BACKSTOP_S=//p' | head -1)" ;;
    esac
    if [ -z "$cad_src" ]; then
        cad_src="REPAIR_INTERVAL_S"
        cadence="$(printf '%s' "$env_str" | tr ' ' '\n' | sed -n 's/^REPAIR_INTERVAL_S=//p' | head -1)"
    fi
    cad_note=""
    case "$cadence" in
        ''|*[!0-9]*) cadence=900; cad_note=" (cadence UNREADABLE from the unit — assumed ${cadence}s)" ;;
    esac
    [ "$cadence" -ge 1 ] || { cadence=900; cad_note=" (cadence UNREADABLE from the unit — assumed 900s)"; }
    case "$runtime" in ''|*[!0-9]*) runtime=1800 ;; esac
    [ "$runtime" -ge 1 ] || runtime=1800
    bound=$(( cadence * 2 + runtime * 2 )); [ "$bound" -ge 1800 ] || bound=1800
    cad_note="$cad_note; bound ${bound}s = 2 x ${cad_src}=${cadence} + 2 x REPAIR_DOCTOR_TIMEOUT_S=${runtime} (keys.env overrides the loop's tunables and is NOT read here)"
    rec="$o_dir/state/pr-repair.status.json"
    if [ ! -f "$rec" ]; then
        emit "$unit" "$class" LATE "$unit is active but has NEVER written a pass record at $rec — enabled and running proves the loop was STARTED, not that a pass ever ran$assumed"
        return 0
    fi
    # A record this launcher cannot parse is CANNOT-VERIFY, never a pass — the rule the whole file follows.
    py_out="$(python3 -c 'import calendar, json, sys, time
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
dec = str(d.get("decision") or "")
if not dec:
    sys.exit(1)
why = str(d.get("reason") or "")
cap = str(d.get("cap"))
ep = d.get("epoch")
if not isinstance(ep, (int, float)):
    try:
        ep = calendar.timegm(time.strptime(str(d.get("ts")), "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        ep = 0
print("%s\t%s\t%d\t%s" % (dec, why.replace("\t", " "), int(ep), cap))' "$rec" 2>/dev/null)" || py_out=""
    if [ -z "$py_out" ]; then
        emit "$unit" "$class" UNKNOWN "$unit is active but its pass record $rec carries no readable decision (or is not the JSON the loop writes) — cannot verify, which is never a pass$assumed"
        return 0
    fi
    decision="$(printf '%s' "$py_out" | cut -f1)"
    reason="$(printf '%s' "$py_out" | cut -f2)"
    ep="$(printf '%s' "$py_out" | cut -f3)"
    cap="$(printf '%s' "$py_out" | cut -f4)"
    case "$ep" in ''|*[!0-9]*) ep=0 ;; esac
    now="$(date +%s)"; age=$(( now - ep )); [ "$age" -lt 0 ] && age=0
    [ -n "$reason" ] || reason="(the record names no reason)"
    # ⛔ THE REMEDY NAMES ONLY WHAT THE INSTRUMENTS ACTUALLY PRINT (review round 1, P2). An earlier
    # version said `--status` "names the rendered directives it disagrees with", which is FALSE and was
    # the one unverifiable promise in an otherwise measured row: `install-repair-service.sh::readback()`
    # reads `is-active`, `is-enabled`, `KillMode` and `ExecStart` and NEVER the installed unit's
    # `Environment=` — so on the very box this row exists for (a pre-#3453 render with
    # `HOME=/tmp/cell-home`, `ENV_FILE=/tmp/cell-home/keys.env`, `O=/tmp/cell-home/orchestrator`,
    # `PR_DOCTOR_REPO_DIR=/tmp/cell-t3`) all four things it checks AGREE and `--status` names no
    # disagreement at all. Worse, the `--status` it delegates to shells `pr-repair-loop.sh --status`
    # with the OPERATOR's `O` (`O="${O:-$CELL_HOME/orchestrator}"`), not the unit's `Environment=O=`,
    # so it can print "no pass has been recorded yet" beneath a row that just quoted a refusing record.
    # So the remedy points at the RECORD PATH this row actually read — an operator can `cat` it — plus
    # the one verb that fixes the measured class. Naming a diagnostic that does not exist is how a
    # correct FAILING row gets waved away as spurious.
    remedy="The pass record this row read is $rec — re-render the unit with 'bash scripts/install-repair-service.sh --install' (it rewrites every rendered directive from THIS box's state) and confirm with '--status', which reads is-active/is-enabled/KillMode/ExecStart"
    case "$decision" in
        dispatched|ok)
            if [ "$age" -gt "$bound" ]; then
                emit "$unit" "$class" LATE "$unit is active but its last pass DISPATCHED ${age}s ago$cad_note — the review stage has stopped passing$assumed"
            else
                emit "$unit" "$class" OK "$unit active; last pass dispatched ${age}s ago, cap=${cap:-?}$cad_note$assumed"
            fi ;;
        refusing)
            # ⛔ FAILING, NOT LATE: a refusal does NOT clear by waiting. The loop continues on it, so the
            # unit stays `active` for ever and only a re-render (or a fix) changes the verdict.
            emit "$unit" "$class" FAILING "$unit is ACTIVE while EVERY pass REFUSES — reason=$reason. A refusal is not a transient: the loop treats it as a continue, so the unit never converges to failed and nothing else will notice. $remedy$assumed" ;;
        placed-undelivered)
            emit "$unit" "$class" FAILING "$unit is ACTIVE but its last pass was UNDELIVERED — reason=$reason: the queue was classified and NO worker took an order. This is the state the epic's own audit reports as 0 of N dispatched. $remedy$assumed" ;;
        pass-failed)
            emit "$unit" "$class" FAILING "$unit is ACTIVE but its last pass FAILED — reason=$reason (a dispatcher crash does not clear by waiting). $remedy$assumed" ;;
        deferred)
            emit "$unit" "$class" LATE "$unit is ACTIVE but its last pass DEFERRED — reason=$reason: the box measured itself unable to afford a pass, so no review happens while it holds$assumed" ;;
        idle)
            emit "$unit" "$class" LATE "$unit is ACTIVE but its last pass was a DRY RUN — reason=$reason: nothing is dispatched while the unit is armed this way$assumed" ;;
        skipped)
            # ⛔ DEFENSIVE, AND SAID SO RATHER THAN LEFT TO BE REDISCOVERED. The shipped producer writes
            # `skipped` to a SEPARATE file (`pr-repair.skip.json`, written by `write_skip_row` by a
            # process that does NOT hold the pass lock), so this arm is unreachable from the shipped
            # code — but `pr-repair-loop.sh`'s own decision comment lists `skipped(own file)` as a value
            # of THIS record, so a future producer that writes it here must not fall through to
            # UNKNOWN-and-therefore-unreadable.
            emit "$unit" "$class" LATE "$unit is ACTIVE but its last pass skipped itself — reason=$reason$assumed" ;;
        *)
            emit "$unit" "$class" UNKNOWN "$unit is active and its last pass reported an UNRECOGNISED decision '$decision' — cannot verify, which is never a pass$assumed" ;;
    esac
}

# ── probe: the fleet-schedule loop (a cell's portable scheduler) ────────────────────────────
# ⛔ NOT a pid read: `pgrep -f fleet-schedule.py` matches the shell running it. The runtime's own
# `--verify` is the authority, and its `tick` file is the beacon. `--verify` is used rather than
# `--status` because it is the gate (it refuses an empty set, a never-run job, an overdue job).
probe_fleet_schedule() {
    local py="$1" out rc
    if [ ! -f "$py" ]; then
        emit "fleet-schedule" "must" MISSING "fleet-schedule.py is not farmed here ($py) — a cell with no scheduler runs no reaper, no liveness report and no canary"
        return 0
    fi
    out="$(python3 "$py" --verify 2>&1)"; rc=$?
    case "$rc" in
        0) emit "fleet-schedule" "must" OK "$(printf '%s' "$out" | sed -n 's/^SCHEDULE VERIFIED/SCHEDULE VERIFIED/p' | head -1 | cut -c1-160)" ;;
        3) emit "fleet-schedule" "must" MISSING "no declarations found — this box was never installed (fleet-schedule.py --verify rc=3)" ;;
        2) emit "fleet-schedule" "must" UNKNOWN "fleet-schedule.py --verify could not determine the state: $(printf '%s' "$out" | tail -1 | cut -c1-160)" ;;
        # ⛔ THE FAILURE LINES ARE NOT TRUNCATED (cycle-5 observation). A `cut -c1-90` sliced a
        # remediation path mid-token (`…/scripts/fleet-schedul`), so the one thing an operator needs from
        # this row — a path they can paste — was unreadable. Only the COUNT of failures is bounded.
        *) emit "fleet-schedule" "must" FAILING "fleet-schedule.py --verify rc=$rc — $(printf '%s' "$out" | grep -E '^(SCHEDULE NOT VERIFIED|[0-9]+ problem)' | head -1); first failures: $(printf '%s' "$out" | grep -E '^  FAIL' | head -3 | sed 's/^  FAIL *//' | tr '\n' ';')" ;;
    esac
    return 0
}

# ── probe: a launchd job ────────────────────────────────────────────────────────────────────
# `launchctl list` alone is not the answer either: a loaded job that never runs reads the same as one
# that works. The freshness signal is the job's OWN log/state file, and its bound is the plist's own
# StartInterval — a 6h reaper must not be judged by a 20-minute one's clock.
unit_cadence_s() { # <timer-unit> -> the seconds its `OnUnitActiveSec=` declares; 1 when unreadable
    # ⛔ THE PERIOD IS IN THE TIMER, NOT IN THE SERVICE ENVIRONMENT (cycle-4 F2). The first attempt read
    # `CONFLICT_REBASE_INTERVAL_MIN` out of the service's Environment — a key no shipped unit exports —
    # so `cr_min` was always the 30-minute default and a box installed at a longer cadence (the
    # installer accepts 1..1440) read LATE forever. `OnUnitActiveSec={{INTERVAL_MIN}}min` is where the
    # number actually lives, and `FragmentPath` is where the rendered unit actually is.
    local u="$1" fp raw num unit_s
    fp="$(sysd_show "$u" FragmentPath 2>/dev/null)"
    [ -n "$fp" ] && [ -r "$fp" ] || return 1
    raw="$(sed -n 's/^OnUnitActiveSec=//p' "$fp" 2>/dev/null | head -1)"
    [ -n "$raw" ] || return 1
    case "$raw" in
        *min) num="${raw%min}"; unit_s=60 ;;
        *h)   num="${raw%h}";   unit_s=3600 ;;
        *s)   num="${raw%s}";   unit_s=1 ;;
        *)    num="$raw";       unit_s=1 ;;
    esac
    case "$num" in ''|*[!0-9]*) return 1 ;; esac
    # `10#` so a leading zero (`08`) is DECIMAL, not an octal parse error that aborts the arithmetic.
    printf '%s' "$(( 10#$num * unit_s ))"
}

plist_env_value() { # <plist> <env-key> -> the EnvironmentVariables[<key>] value; 1 when absent
    python3 -c 'import sys, plistlib
try:
    d = plistlib.load(open(sys.argv[1], "rb"))
except Exception:
    sys.exit(1)
v = (d.get("EnvironmentVariables") or {}).get(sys.argv[2])
# ⛔ A NON-STRING VALUE IS NOT A PATH (cycle-4 P2). `print(v)` on a list produced a Python repr
# (`['/a', '/b']`), which the caller joined with `/timer.beat`, found missing, and reported as
# NEVER-FIRED — a hard claim about the pass, derived from a malformed value. Unreadable is UNKNOWN.
if not isinstance(v, str) or v == "" or "\n" in v or "\r" in v:
    sys.exit(1)
print(v)' "$1" "$2" 2>/dev/null
}

plist_field() { # <plist> <key> -> the string value on stdout; 1 when absent or unreadable
    python3 -c 'import sys, plistlib
try:
    d = plistlib.load(open(sys.argv[1], "rb"))
except Exception:
    sys.exit(1)
v = d.get(sys.argv[2])
if v is None or v == "":
    sys.exit(1)
print(v)' "$1" "$2" 2>/dev/null
}

launchd_runs() { # <label> -> launchd's run COUNT on stdout; 1 when the job is not loaded/readable
    # ⛔ `runs` IS THE LAUNCHD EQUIVALENT OF `LastTriggerUSec`, AND IT EXISTS FOR EVERY JOB. Chasing a
    # log mtime instead was a FALSE PASS: the sed that read `StandardOutPath` used `|` as its s-command
    # delimiter while the pattern contained an alternation written `\|`, so the pattern terminated at
    # the alternation and matched NOTHING on any sed (review F1) — every launchd row read LATE forever,
    # the Mac grid could never be green, and `--install` could never converge. Fourteen of the
    # twenty-three shipped plists declare no `Standard*Path` at all, which that read could not have
    # handled either. `runs` needs no log path and no template convention, and answers the question the
    # row actually asks: has it EVER fired?
    $LAUNCHCTL_BIN print "gui/$(id -u)/$1" 2>/dev/null \
        | sed -n 's/^[[:space:]]*runs = \([0-9][0-9]*\)[[:space:]]*$/\1/p' | head -1 | grep . || return 1
}

probe_launchd() { # <label> <class> <max_age_s|auto> <template-path|-> <note>
    local label="$1" class="$2" max_age="$3" tpl="$4" note="${5:-}"
    local dir="$HOME/Library/LaunchAgents" plist loaded out_path age now mt interval runs
    plist="${LAUNCHD_AGENTS_DIR:-$dir}/$label.plist"
    # ⛔ THE TEMPLATE ARGUMENT IS NOT DECORATION (review F17). Without this arm a row whose template is
    # not shipped on this box becomes a permanent `must`/MISSING that no installer can ever satisfy —
    # a red that teaches the operator to stop reading the grid.
    if [ "$tpl" != "-" ] && [ ! -f "$tpl" ]; then
        emit "$label" "$class" SKIPPED "template not shipped on this box ($tpl) — nothing to require here"
        return 0
    fi
    if [ "$class" = "unarmed" ]; then
        if [ -f "$plist" ]; then
            emit "$label" "$class" UNEXPECTED "deliberately UNARMED (#1678) but $plist is installed${note:+ ($note)}"
        else
            emit "$label" "$class" UNARMED "$note"
        fi
        return 0
    fi
    if [ ! -f "$plist" ]; then
        emit "$label" "$class" MISSING "no $plist — the job is not installed on this box"
        return 0
    fi
    if ! command -v "$LAUNCHCTL_BIN" >/dev/null 2>&1; then
        emit "$label" "$class" UNKNOWN "launchctl is not on PATH — installed state read, loaded state unknown"
        return 0
    fi
    if ! $LAUNCHCTL_BIN print "gui/$(id -u)/$label" >/dev/null 2>&1 && ! $LAUNCHCTL_BIN list 2>/dev/null | grep -q "[[:space:]]$label\$"; then
        emit "$label" "$class" FAILING "$plist exists but the job is NOT LOADED — it will never run"
        return 0
    fi
    [ -n "$max_age" ] && [ "$max_age" = "auto" ] && max_age=""
    if [ -z "$max_age" ]; then
        interval="$(plist_field "$plist" StartInterval || echo '')"
        case "$interval" in
            ''|*[!0-9]*)
                # ⛔ `StartInterval` IS NOT THE ONLY CADENCE (review cycle-2 P1.1). A
                # `StartCalendarInterval` job (com.eldato.fleet-cost-weekly — Sundays, and the one
                # top-level plist that DOES declare a log) has no StartInterval, so the old fallback
                # gave it a 24 h bound and its own weekly log made it `LATE` six days out of seven —
                # making `ACTIVATION COMPLETE` unreachable on a healthy Mac, the exact red-that-teaches-
                # you-to-ignore-the-grid that F17's comment warns about. If a calendar schedule is
                # declared, the honest bound is at least a week plus slack.
                # ⛔ PARSED, NOT GREPPED (review cycle-3 F5). A raw substring match also fires on an
                # XML COMMENT — the very shape guarded_templates() rejects for `--dry-run` two hundred
                # lines below. A commented-out key would widen the bound from 24 h to 8 days and let a
                # dead log-declaring job read OK. `plist_field` returns non-empty for a dict, which is
                # all this test needs.
                # ⛔ NO `|| grep` FALLBACK — the fallback WAS the defect (cycle-4 F1). A raw substring
                # match fires on an XML COMMENT, so a plist with a commented-out key widened the bound
                # 24 h -> 8 d and a dead log-declaring job certified `OK` (measured). Every shipped
                # template parses through plistlib, so the fallback bought nothing and cost the property.
                if [ -n "$(plist_field "$plist" StartCalendarInterval || true)" ]; then
                    max_age="$(( 8 * 86400 ))"
                else
                    max_age="86400"     # neither key: the loosest honest bound
                fi ;;
            *) max_age=$(( interval * 2 + 300 )) ;;
        esac
    fi
    # NEVER-FIRED, from launchd's own run counter — the one datum EVERY job has.
    runs="$(launchd_runs "$label" || echo '')"
    case "$runs" in
        ''|*[!0-9]*)
            emit "$label" "$class" UNKNOWN "loaded, but launchctl printed no run count — 'has it ever fired' is unreadable here (not absent)"
            return 0 ;;
        0)
            emit "$label" "$class" NEVER-FIRED "loaded and has NEVER RUN (launchd runs=0) — the launchd analogue of an empty LastTriggerUSec"
            return 0 ;;
    esac
    # ⛔ THE BRAKE AND THE BEACON APPLY ON THE MAC TOO (review cycle-3 F7). The plist exports
    # CONFLICT_REBASE_STATE and CONFlict-rebase's pass writes its own beacon, but this probe looked only
    # at `runs` and a log — so a PAUSED, five-day-stale conflict-rebase read `OK … AGE UNMEASURED` on a
    # Mac while the SAME state read LATE on a cell. That is the F16 defect surviving on the other
    # platform the owner armed. Any plist that exports a `*_STATE` used this way opts into the check.
    local st_dir st_brake st_beat st_age st_mt
    if st_dir="$(plist_env_value "$plist" CONFLICT_REBASE_STATE 2>/dev/null)" && [ -n "$st_dir" ]; then
        st_brake="$st_dir/PAUSED"; st_beat="$st_dir/timer.beat"
        if [ -f "$st_brake" ]; then
            emit "$label" "$class" OK "loaded (runs=$runs) but PAUSED ($st_brake exists) — every tick exits 0 without acting, by design"
            return 0
        fi
        if [ ! -f "$st_beat" ]; then
            emit "$label" "$class" NEVER-FIRED "loaded (runs=$runs) but its pass beacon $st_beat has never been written — no pass has ever COMPLETED"
            return 0
        fi
        st_mt="$(box_mtime_now "$st_beat")"
        case "$st_mt" in
            ''|*[!0-9]*) emit "$label" "$class" UNKNOWN "beacon $st_beat exists but its mtime is unreadable — freshness unmeasurable" ; return 0 ;;
        esac
        st_age=$(( $(date +%s) - st_mt )); [ "$st_age" -lt 0 ] && st_age=0
        if [ "$st_age" -gt "$max_age" ]; then
            emit "$label" "$class" LATE "loaded (runs=$runs), but its last COMPLETED pass was ${st_age}s ago (beacon, cadence allows ${max_age}s)"
        else
            emit "$label" "$class" OK "loaded (runs=$runs), last COMPLETED pass ${st_age}s ago (beacon, cadence allows ${max_age}s)"
        fi
        return 0
    fi
    # AGE, when the plist declares a log and that log exists. Declaring none is NOT a failure: most
    # shipped plists legitimately have nothing to log to, and grading that LATE was the false red that
    # made this grid unusable on a Mac. The row states which half of the verdict it could read.
    out_path="$(plist_field "$plist" StandardOutPath || plist_field "$plist" StandardErrorPath || echo '')"
    now="$(date +%s)"
    if [ -n "$out_path" ] && [ -e "$out_path" ]; then
        mt="$(box_mtime_now "$out_path")"
        case "$mt" in
            ''|*[!0-9]*) emit "$label" "$class" UNKNOWN "log $out_path exists but its mtime is unreadable — freshness unmeasurable" ;;
            *) age=$(( now - mt )); [ "$age" -lt 0 ] && age=0
               if [ "$age" -gt "$max_age" ]; then
                   emit "$label" "$class" LATE "loaded (runs=$runs), but its log $out_path is ${age}s old (bound ${max_age}s)"
               else
                   emit "$label" "$class" OK "loaded (runs=$runs), log written ${age}s ago (bound ${max_age}s)"
               fi ;;
        esac
    else
        # NEITHER LATE NOR SILENTLY GREEN: the count is printed in the summary, so a Mac can never be
        # certified "fully armed and fresh" while most of its rows had their freshness unread.
        UNMEASURED_ROWS=$((UNMEASURED_ROWS + 1))
        emit "$label" "$class" OK "loaded and has run (runs=$runs); AGE UNMEASURED — the plist declares no readable StandardOutPath, so 'still firing' cannot be answered from this box"
    fi
}

# ── probe: an arming RECORD (a capability armed by a dated file, not by an installer) ───────
# #1678's own mechanism: `state/<name>.armed` is the dated decision. Absent record = deliberately
# unarmed (a PASS); a present record means the pass must be live and fresh.
probe_recorded() { # <name> <record-path> <beacon> <max_age_s> <reason>
    local name="$1" rec="$2" beacon="$3" max_age="$4" reason="$5"
    local now age beat
    if [ ! -f "$rec" ]; then
        emit "$name" "optional" UNARMED "no arming record at $rec — $reason"
        return 0
    fi
    if [ ! -f "$beacon" ]; then
        emit "$name" "must" NEVER-FIRED "armed ($rec) but the stamp $beacon has never been written"
        return 0
    fi
    beat="$(cat "$beacon" 2>/dev/null || echo 0)"
    case "$beat" in ''|*[!0-9]*) beat="$(box_mtime_now "$beacon")"; case "$beat" in ''|*[!0-9]*) beat=0 ;; esac ;; esac
    now="$(date +%s)"; age=$(( now - beat )); [ "$age" -lt 0 ] && age=0
    if [ "$age" -gt "$max_age" ]; then
        emit "$name" "must" LATE "armed, but the stamp is ${age}s old (bound ${max_age}s)"
    else
        emit "$name" "must" OK "armed, stamp ${age}s old"
    fi
}

# ── installer map: ONE place that says which installer owns which template ──────────────────
# A template that is not in this map is a DECLARATION ERROR, not a silent skip: that is exactly how
# conflict-rebase shipped for weeks with an installer nobody could name.
installer_for() { # <base> -> "<installer path>\t<args>"
    case "$1" in
        eldato-harness-apply)     printf '%s|--install' "$ROOT/scripts/install-harness-apply-timer.sh" ;;
        eldato-disk-reaper)       printf '%s|--install' "$ROOT/scripts/install-disk-reaper-timer.sh" ;;
        eldato-runner-autoscale)  printf '%s|--install' "$ROOT/scripts/install-runner-autoscale-timer.sh" ;;
        eldato-conflict-rebase)   printf '%s|--install' "$ROOT/scripts/install-conflict-rebase-timer.sh" ;;
        eldato-controller-watchdog|eldato-objective-reminder)
                                  printf '%s|--install' "$ROOT/scripts/install-cell-timers.sh" ;;
        # ⛔ INTENTIONALLY ABSENT: cell-self-pin. It is an `exclusive` row (row_meta), and build_grid
        # `continue`s before this lookup, so an entry here would be a DEAD arm that reads as if the
        # launcher might install it. Choosing a pin actuator is an operator migration
        # (`cell-self-pin.sh --install --takeover`), never a convergence step.
        eldato-ai-drainer)        printf '%s|--install' "$ROOT/scripts/orchestrator-harness/install-drainer-timer.sh" ;;
        *) return 1 ;;
    esac
}

# Per-row class and cadence. Declared, not inferred: the cadence a row must keep is a decision, and
# `list-timers` prints a NEXT time for a timer that has never fired, so it cannot answer this.
row_meta() { # <base> -> "<class>|<max_age_s>"
    case "$1" in
        eldato-harness-apply)     printf 'must|1200' ;;    # 10 min + RandomizedDelaySec=60 + slack
        eldato-disk-reaper)       printf 'must|5400' ;;    # hourly + pass runtime
        eldato-ai-drainer)        printf 'must|2400' ;;    # 20 min
        eldato-controller-watchdog) printf 'must|1200' ;;  # 5 min
        eldato-objective-reminder)  printf 'must|1800' ;;  # 10 min
        # 2 x the unit's `TimeoutStartSec=2400` plus the 1800 s period: a legitimately long pass must
        # not read LATE for its own duration (the row is judged on the BEACON, so the bound covers the
        # gap between two COMPLETED passes, not one tick).
        eldato-conflict-rebase)     printf 'must|7200' ;;
        eldato-runner-autoscale|com.eldato.runner-autoscale) printf 'optional|1800' ;;
        # ⛔ THE MAC ROWS ARE KEYED BY THEIR LAUNCHD LABEL, which is NOT the systemd base name. Without
        # these four the mac sub-directory rows all fell through to the `must` default below, which made
        # `com.eldato.runner-autoscale` a REQUIRED row the launcher is forbidden to arm (#2403) — so a
        # Mac could never reach ACTIVATION COMPLETE and the only way to green it was the hand-run arming
        # step the class system exists to withhold (review F7).
        com.eldato.harness-apply)   printf 'must|1200' ;;
        com.eldato.disk-reaper)     printf 'must|5400' ;;
        com.eldato.conflict-rebase) printf 'must|3000' ;;
        # ⛔ NOT `unarmed` AND NOT A #1678 ROW: cell-self-pin is the ALTERNATIVE pin actuator, and the
        # invariant is one-actuator-per-pin. It is reported by probe_pin_actuators() below, as a pair.
        cell-self-pin)              printf 'exclusive|0' ;;
        *) printf 'must|3600' ;;
    esac
}

# ── probe: the mutually-exclusive pin actuators ─────────────────────────────────────────────
# One row, judged from BOTH units. The launcher never installs either (`--install` skips this class):
# choosing an actuator is an operator decision (`--takeover`), not a convergence step.
probe_pin_actuators() {
    # ⛔ WITHOUT THIS THE PAIR ASSERTED A CONFLICT FROM SILENCE (review cycle-2 P1.3): with no scheduler
    # binary both "is it enabled" reads answer nothing, and the row reported "NEITHER actuator is
    # enabled", exit 1 — a claim about the box derived from a read that never happened.
    if ! sc_available; then
        emit "pin-actuators" "must" UNKNOWN "$SYSTEMCTL_BIN is not executable — the pin actuators cannot be read on this box (a failed read, not an absence)"
        return 0
    fi
    local a b a_en a_act b_en b_act
    sc_scope_for "cell-self-pin.timer"; a_en="$(sysd_show cell-self-pin.timer UnitFileState)"; a_act="$(sysd_show cell-self-pin.timer ActiveState)"
    sc_scope_for "eldato-harness-apply.timer"; b_en="$(sysd_show eldato-harness-apply.timer UnitFileState)"; b_act="$(sysd_show eldato-harness-apply.timer ActiveState)"
    a=no; b=no
    case "$a_en" in enabled|enabled-runtime) a=yes ;; esac
    case "$b_en" in enabled|enabled-runtime) b=yes ;; esac
    if [ "$a" = yes ] && [ "$b" = yes ]; then
        emit "pin-actuators" "must" FAILING "TWO pin actuators are enabled at once — cell-self-pin($a_act) AND eldato-harness-apply($b_act). Two mutating actors on one pin is a race, and bring-up re-arms eldato-harness-apply so this state returns by itself; retire one deliberately (cell-self-pin.sh --install --takeover) and make the bring-up respect it"
    elif [ "$a" = yes ]; then
        emit "pin-actuators" "must" OK "cell-self-pin is the single actuator (eldato-harness-apply not enabled)"
    elif [ "$b" = yes ]; then
        emit "pin-actuators" "must" OK "eldato-harness-apply is the single actuator (cell-self-pin not enabled — the shipped default)"
    else
        emit "pin-actuators" "must" MISSING "NEITHER pin actuator is enabled — nothing advances this box's harness pin, so merged fixes never reach it and every signal still reads 'auto'"
    fi
}

# ── the guarded templates: the invariant is that NOBODY armed these ─────────────────────────
# ⛔ THIS IS THE HALF OF #1678 A LAUNCHER WOULD OTHERWISE BREAK. "The launcher does not arm it" is not
# the invariant; the invariant is "the tracked template still ships disarmed". A well-meaning edit that
# drops `--dry-run` from a template arms it on EVERY box on the next install, with no dated decision
# and nothing in the log — so `--check` reads the template and reddens when the flag is gone.
guarded_templates() { # <template-path> <argv-item-as-xml>
    local tpl="$1" flag="$2"
    if [ ! -f "$tpl" ]; then
        emit "$(basename "$tpl" .plist)" "unarmed" SKIPPED "template absent on this box (not shipped here)"
        return 0
    fi
    # ⛔ THE FLAG MUST BE A `<string>` ARGV ITEM, NOT A MERE SUBSTRING (review F9). A bare
    # `grep --dry-run` also passes on a comment, on `--dry-run=0`, and on the flag sitting in an
    # EnvironmentVariables value — none of which disarm anything. The call site passes the XML spelling,
    # so this guard means what the comment above it claims.
    if grep -qF -- "$flag" "$tpl"; then
        emit "$(basename "$tpl" .plist)" "unarmed" UNARMED "template still ships '$flag' (#1678) — the launcher never arms it"
    else
        emit "$(basename "$tpl" .plist)" "unarmed" UNEXPECTED "the tracked template NO LONGER carries '$flag' — it has been armed in the repo, so the next install arms it on every box with no dated decision (#1678)"
    fi
}

# ── the grid ────────────────────────────────────────────────────────────────────────────────
build_grid() {
    local base meta meta_recon class maxage tpl line inst args cr_state cr_period cr_note row_before
    ROWS=""
    ROW_N=0
    if [ "$TSV" = 0 ]; then
        act_say "harness activation — platform=$ACT_PLATFORM host=$(hostname 2>/dev/null || echo '?') root=${ROOT:-<unresolved>}"
        act_say ""
        printf '  %-24s %-9s %-12s %s\n' CAPABILITY CLASS STATE DETAIL
    fi
    if [ -z "$ROOT" ]; then
        emit "declarations" "must" UNKNOWN "no agent-infra checkout with templates/ found (\$INFRA_ROOT, \$AGENT_INFRA_PATH, \$CELL_HOME/agent-infra, /tmp/cell-ai) — nothing can be verified, which is not the same as nothing being wrong"
        return 0
    fi

    if [ "$ACT_PLATFORM" = "cell" ]; then
        # 1. the portable scheduler + the two daemons that have no template of their own
        probe_fleet_schedule "${CELL_HOME_RES}/.pi/agent/scripts/fleet-schedule.py"
        probe_systemd_service "eldato-orchestrator.service" "must" "$O_RES/heartbeat" 2400 \
            "the controller; without it a cell dispatches nothing and the only signal is a quiet queue"
        # ⛔ NOT `probe_systemd_service`: `ActiveState` cannot fail for this unit (#4010). The loop
        # continues on a refusal, so an enabled, active, permanently-refusing repair loop reads green —
        # measured for three days on a real cell. `probe_repair_service` grades the loop's own pass
        # record instead, and keeps these same three arms underneath it.
        probe_repair_service "eldato-pr-repair.service" "must" "the PR repair loop"
        # ⛔ #2700's SUPPLY HALF HAD NO ROW AT ALL (review cycle 11, F2), and it is the clearest
        # instance of this file's own defect class: `templates/systemd/eldato-worker-supply.service`
        # SHIPS here, `scripts/install-worker-supply.sh` renders and installs it on Linux, and it
        # carries no `.timer` — so the derivation loop below (`for tpl in "$SYS_TEMPLATES"/*.timer`)
        # could not see it, and it was in neither of the two explicit lists (the services at :766/:768,
        # `probe_recorded "claim-reaper"`, `probe_pin_actuators`). A cell whose supervisor was never
        # installed, was disabled, or had given up printed `ACTIVATION COMPLETE` and exited 0 while the
        # repair pool had no supply half: `pr-doctor` then classifies the queue and REFUSES every order
        # (`16 order(s) no worker accepted and nothing was dispatched`, measured 2026-10-27 on the
        # operator's Mac) with no row anywhere saying why.
        # ⛔ WHY NO BEACON, when the supervisor does write a per-pass record at
        # `$O/state/worker-supply.state` (`worker-supply.sh:134,445`): that record is `ts=`-keyed, and
        # `probe_systemd_service`'s beacon arm reads the file's CONTENT as an epoch and coerces a
        # non-numeric read to 0 — which would grade this row LATE for ever, the permanent false red this
        # suite exists to prevent. A future author who wants the freshness axis must make that arm fall
        # back to the file's mtime the way `probe_recorded` does; until then this row grades the three
        # states the finding names. `ActiveState` is not a weak read here in the way `Type=simple`
        # normally makes it one: the unit ships `Restart=always` with `StartLimitIntervalSec=300` /
        # `StartLimitBurst=3` (its own header explains why those two live in `[Unit]`), so a start that
        # can never succeed CONVERGES to `failed` inside ~5 min, which this probe grades FAILING.
        probe_systemd_service "eldato-worker-supply.service" "must" "-" 0 \
            "the repair pool's SUPPLY half (#2700): without it pr-doctor classifies the queue and refuses every order"
        # ⛔ THE PATHS ARE THE PASS'S OWN PATHS (review F5), and reading the wrong ones was a FALSE PASS
        # over the one class this file must never wave through: the arming record is
        # `$O/state/claim-reaper.armed` (`claim-reaper-pass.sh:63`, `CRP_STATE=$O/state`), and its pass
        # record is `$O/state/claim-reaper.last` (`:64`, written on every pass at `:267`). This probe
        # read `~/.pi/agent/state/...`, which NOTHING writes — so a box where the claim reaper IS armed
        # (a #1678 deletion tool) graded `UNARMED`, exit 0. The message also pointed an operator at a
        # file that arms nothing.
        probe_recorded "claim-reaper" "$O_RES/state/claim-reaper.armed" \
            "$O_RES/state/claim-reaper.last" 7200 \
            "the claim reaper ships disarmed (#2094 decision (e), #1678); arm it by writing $O_RES/state/claim-reaper.armed"

        # 2. every systemd timer this repo SHIPS becomes a row — derived, so a new template cannot be
        #    forgotten here (the defect: conflict-rebase shipped with none of this).
        if [ -d "$SYS_TEMPLATES" ]; then
            timer_rows=0
            for tpl in "$SYS_TEMPLATES"/*.timer; do
                [ -f "$tpl" ] || continue
                base="$(basename "$tpl" .timer)"
                meta="$(row_meta "$base")"
                class="${meta%%|*}"; maxage="${meta#*|}"
                # `exclusive` rows are reported as a PAIR (probe_pin_actuators), never alone.
                [ "$class" = "exclusive" ] && continue
                if ! inst="$(installer_for "$base")"; then
                    emit "$base" "must" UNKNOWN "DECLARATION ERROR: $tpl ships a timer and NO installer is mapped to it — the capability is written, tested and inert on every box. Add it to installer_for() in this file (this is literally how conflict-rebase shipped unscheduled)"
                    continue
                fi
                timer_rows=$((timer_rows + 1))
                row_before="$ROW_N"
                case "$base" in
                    # The one shipped timer whose tick can legitimately do nothing (its brake makes
                    # `start --once` exit 0 before any pass), so it is judged on its own BEACON.
                    eldato-conflict-rebase)
                        # ⛔ RESOLVE THE SCOPE FIRST (review cycle-3 F1). `sysd_show` is only valid
                        # while SC_PREFIX matches the unit, and SC_PREFIX is set by the most recent
                        # sc_scope_for() call — which for this row would happen LATER, inside
                        # probe_systemd_timer. So the Environment below was read through whatever
                        # manager the PREVIOUS row happened to resolve in: with ai-drainer in the user
                        # manager and this unit in the system manager, the beacon was looked for in the
                        # default directory and a HEALTHY box read NEVER-FIRED (measured). probe_*_timer
                        # re-resolves the scope afterwards, so this call has no side effect.
                        sc_scope_for "$base.service" >/dev/null 2>&1 || true
                        #
                        # ⛔ THE STATE DIR IS THE UNIT'S, NOT THIS FILE'S DEFAULT (review cycle-2 P2.7).
                        # The installer and the unit both export CONFLICT_REBASE_STATE; a box installed
                        # with a non-default value writes its beacon there, and a hardcoded
                        # `~/.pi/agent/state/...` would read NEVER-FIRED forever — the exact
                        # two-paths-that-look-alike defect F5/F16 exist to remove. Read the unit's env.
                        cr_state="$(sysd_show "$base.service" Environment 2>/dev/null \
                            | tr ' ' '\n' | sed -n 's/^CONFLICT_REBASE_STATE=//p' | head -1)"
                        [ -n "$cr_state" ] || cr_state="$HOME/.pi/agent/state/conflict-rebase"
                        # ⛔ AND THE CADENCE IS THE UNIT'S TOO (review cycle-3 F6). The installer accepts
                        # `CONFLICT_REBASE_INTERVAL_MIN` 1..1440, while the bound here was a constant: a
                        # box installed at a long cadence would read LATE forever (exit 1) with nothing
                        # wrong. Derive it: 2 x period (a completed pass, then the next one) plus 2 x the
                        # unit's TimeoutStartSec=2400, so a legitimately slow pass is not its own red.
                        # ⛔ AN UNREADABLE CADENCE IS SAID OUT LOUD, NOT ABSORBED (cycle-5 P1-1). The
                        # old `|| cr_period=1800` turned a failed read into a confident bound — the row
                        # then printed "cadence allows 8400s" as if it had been measured, which is the
                        # make-it-work shape this whole file exists to refuse. The default stays (a
                        # generated unit legitimately has no readable period and must not read UNKNOWN
                        # for it), but the row carries the assumption in its DETAIL — appended by every
                        # beacon emit, which is the only branch this row reaches (cycle-6 P1: the note
                        # was passed and rendered by nothing, so an ASSUMED bound read exactly like a
                        # measured one. Defined once (`nsuf`) so one revert reddens every arm; the
                        # OK, NEVER-FIRED and LATE arms are pinned by T31/T31b/T31c, and the negative
                        # direction (no note when the period WAS read) by T31d.
                        cr_note=""
                        cr_period="$(unit_cadence_s "$base.timer" 2>/dev/null)" || cr_period=""
                        case "$cr_period" in
                            ''|*[!0-9]*) cr_period=1800
                                         cr_note=" (cadence UNREADABLE from the unit — assumed 1800 s)" ;;
                        esac
                        [ "$cr_period" -ge 1 ] || { cr_period=1800; cr_note=" (cadence UNREADABLE from the unit — assumed 1800 s)"; }
                        probe_systemd_timer "$base" "$class" "$(( 10#$cr_period * 2 + 4800 ))" "$cr_note" \
                            "$cr_state/timer.beat" "$cr_state/PAUSED" || true ;;
                    *)  probe_systemd_timer "$base" "$class" "$maxage" "" ;;
                esac
                # ⛔ THE RECONCILIATION (cycle-4 F3). A leading-zero interval (`08`) made the arithmetic
                # abort, so probe_systemd_timer was never called: the row VANISHED, `timer_rows` had
                # already been incremented, the "examined ZERO" guard could not fire, and summarise —
                # which iterates EMITTED rows only — printed `ACTIVATION COMPLETE` with exit 0. A
                # template that produced no row is a failed read, by construction.
                # ⛔ PINNED BY MUTATION, NOT BY A FIXTURE, AND THAT IS STATED RATHER THAN FAKED. No
                # input this launcher can be given makes a probe return without emitting — the bug this
                # guards was an ARITHMETIC ABORT at the call site, which no longer exists. So the test
                # that proves this fires is `: ;;` on the conflict-rebase arm (measured: rc 2, UNKNOWN,
                # broadly RED), recorded in docs/ops/harness-activation.md §7. The class follows the
                # row's own declaration, so a vanished OPTIONAL template is not relabelled `must`.
                if [ "$ROW_N" -le "$row_before" ]; then
                    meta_recon="$(row_meta "$base")"
                    emit "$base" "${meta_recon%%|*}" UNKNOWN "the probe for $tpl emitted NO row — a failed read, not a satisfied requirement"
                fi
            done
            # ⛔ A DIRECTORY THAT EXISTS AND HOLDS NO TIMERS USED TO PRODUCE ZERO ROWS AND THEREFORE
            # `ACTIVATION COMPLETE — 0 row(s)` WITH EXIT 0 (review F6): every shipped timer unexamined,
            # and a pass. "I examined nothing" is never green — same rule as the unmapped-template
            # DECLARATION ERROR above, applied to the SET rather than to one member.
            if [ "$timer_rows" -eq 0 ]; then
                emit "templates" "must" UNKNOWN "no *.timer under $SYS_TEMPLATES — this grid examined ZERO shipped timers, which is a declaration error, not a clean box"
            fi
            # 2b. the PIN ACTUATORS are a MUTUAL-EXCLUSION pair, not two independent clocks.
            # ⛔ WHY THIS NEEDS ITS OWN ROW. `cell-self-pin` and `eldato-harness-apply` are two
            # scheduled MUTATING actors on ONE pin (`cloud-cell-supervisor.sh apply --pin-only`).
            # cell-self-pin's own header (`:78-95`) says `--install` REFUSES while the other timer is
            # enabled, and `--install --takeover` is the one-actor migration. Two actuators is a race,
            # not redundancy — and it REAPPEARS by itself, because bring-up re-arms harness-apply on
            # every run, so a completed `--takeover` is silently undone on the next bring-up.
            # MEASURED 2026-11-07 on pi-cell-1: BOTH enabled in the system manager.
            # This is not a #1678 deletion tool and must never be labelled one — the invariant is the
            # PAIR, and it is checked from the pair's state, not from the file's presence.
            # ⛔ ALWAYS EMITTED, even when `cell-self-pin.timer` is not shipped here (review F6): the
            # pair row answers "is exactly ONE mutating actor on this pin", and skipping it when one
            # template is absent made the whole invariant disappear from the grid exactly on the boxes
            # where `eldato-harness-apply` is the only candidate — and a MISSING pair row reads as
            # nothing to worry about.
            probe_pin_actuators
        else
            emit "templates" "must" UNKNOWN "no systemd templates at $SYS_TEMPLATES"
        fi

        # 3. units that exist on the box but are NOT shipped by this repo: reported, never required.
        #    A hand-installed timer is not a gap in the repo, but a reader must not think it is shipped.
        for base in cell-reclaim box-cache-guard; do
            if sc_scope_for "$base.timer"; then
                emit "$base" "extra" OK "present on this box and NOT shipped by this repo — hand-installed; not part of the declaration"
            fi
        done
    elif [ "$ACT_PLATFORM" != "mac" ]; then
        # ⛔ REFUSE, DO NOT GUESS (review F13). The old `else` sent every non-Linux platform down the
        # macOS arm, so a FreeBSD box (or one where `uname -s` returned something unexpected) would be
        # graded against 23 launchd `must` rows that cannot exist there. A platform this tool does not
        # understand is a reason to say so, not a licence to pick a grid.
        emit "platform" "must" UNKNOWN "unsupported platform '$PLATFORM' (from \`uname -s\`) — this launcher knows Linux cells and macOS; it will not grade a box it cannot model"
    else
        # macOS: one row per shipped plist, and the installer is the repo's ONE launchd installer.
        if [ -d "$LAUNCHD_TEMPLATES" ]; then
            for tpl in "$LAUNCHD_TEMPLATES"/*.plist; do
                [ -f "$tpl" ] || continue
                base="$(basename "$tpl" .plist)"
                # ⛔ EVERY top-level plist is a `must` row: `install-launchd.sh` loads them all, so a
                # Mac missing one is a Mac running a partial schedule. The DELIBERATELY-UNARMED axis
                # (#1678) is about a template's ACTION FLAG, not about whether the job is scheduled —
                # so it is asserted by guarded_templates() below, where the row means "this template
                # still ships its disarming flag" and an edit that drops it is the finding.
                probe_launchd "$base" "must" "auto" "$tpl" ""
            done
            # The plists in SUBDIRECTORIES belong to their own installers (they are deliberately out of
            # install-launchd.sh's glob) — they are rows too, or a Mac would report itself fully armed
            # while missing the three passes the cells run on timers.
            # ⛔ THE CLASS COMES FROM row_meta, NOT FROM THIS LINE (review F7). Hardcoding `must` here
            # made `com.eldato.runner-autoscale` a REQUIRED row while `do_install` — correctly — never
            # arms it (#2403 is a dated owner decision), so on a Mac `--install` could NEVER reach
            # ACTIVATION COMPLETE, and the only way to green it was to hand-run the arming step the
            # class system exists to withhold. `optional` now means optional on both platforms.
            for base in com.eldato.harness-apply com.eldato.disk-reaper com.eldato.runner-autoscale com.eldato.conflict-rebase; do
                meta="$(row_meta "$base")"
                class="${meta%%|*}"
                probe_launchd "$base" "$class" "auto" "-" ""
            done
        else
            emit "templates" "must" UNKNOWN "no launchd templates at $LAUNCHD_TEMPLATES"
        fi
    fi
    # ⛔ THE ROWS THAT KEEP #1678 TRUE, ON EVERY PLATFORM (review cycle-2 P2.10). Only the templates that
    # pass the flag IN ARGV are guarded, and that set is MEASURED (`grep -c '<string>--dry-run</string>'`
    # over templates/launchd): com.tortoise.worktree-reaper and com.eldato.pi-cache-reap. A template that
    # merely mentions a dry run in a COMMENT does not ship one, and listing it here would be a guard that
    # can never fire — the vacuous-check shape this file exists to remove. These are TRACKED files present
    # in every checkout, so a CELL must be able to notice "somebody edited the template to armed" just as
    # a Mac can; keeping the call inside the mac branch made that half of the invariant invisible on the
    # four boxes that actually run install-launchd.sh least often.
    guarded_templates "$LAUNCHD_TEMPLATES/com.tortoise.worktree-reaper.plist" '<string>--dry-run</string>'
    guarded_templates "$LAUNCHD_TEMPLATES/com.eldato.pi-cache-reap.plist" '<string>--dry-run</string>' 
}

# ── convergence ─────────────────────────────────────────────────────────────────────────────
# ⛔ INSTALL ONLY `must` ROWS. An `optional` row (runner autoscale) is a dated capacity decision per
# box; an `unarmed` row (the reapers) is a recorded owner ruling. A launcher that armed either would be
# the bypass #1678 exists to prevent — and it would do it on every box at once, silently.
do_install() {
    local base meta class maxage inst args rc failed=0 ran=0 tmpl
    if [ -z "$ROOT" ]; then
        warn "activate-harness: no checkout resolved — nothing to install from"
        return 1
    fi
    if [ "$ACT_PLATFORM" = "cell" ] && [ -d "$SYS_TEMPLATES" ]; then
        for tmpl in "$SYS_TEMPLATES"/*.timer; do
            [ -f "$tmpl" ] || continue
            base="$(basename "$tmpl" .timer)"
            meta="$(row_meta "$base")"
            class="${meta%%|*}"
            [ "$class" = "must" ] || continue
            # ⛔ EVERY OPERAND BELOW IS A LITERAL PATH WITH A LITERAL BASENAME, and that is a hard
            # requirement rather than style: `bash "$inst" --install` makes the script operand
            # unresolvable to extensions/main-worktree-guard's #1484 content walk, which then refuses
            # to execute this launcher AT ALL (measured 2026-11-07 — `--check` ran, `--install` was
            # blocked, and the only difference was the argument). A launcher that cannot be run on the
            # operator's own box is the defect this file exists to remove.
            # ⛔ THE TWO LISTS MUST NOT DRIFT: installer_for() above answers "does this template have an
            # installer?" for the GRID, and this case is the one that RUNS it. They are pinned
            # together by activate-harness.test.sh T5, which asserts that EVERY must row's installer
            # actually ran.
            case "$base" in
                eldato-harness-apply)
                    act_say "arming $base via scripts/install-harness-apply-timer.sh"
                    bash "$ROOT/scripts/install-harness-apply-timer.sh" --install || { warn "activate-harness: $base installer FAILED"; failed=1; } ;;
                eldato-disk-reaper)
                    act_say "arming $base via scripts/install-disk-reaper-timer.sh"
                    bash "$ROOT/scripts/install-disk-reaper-timer.sh" --install || { warn "activate-harness: $base installer FAILED"; failed=1; } ;;
                eldato-conflict-rebase)
                    act_say "arming $base via scripts/install-conflict-rebase-timer.sh"
                    bash "$ROOT/scripts/install-conflict-rebase-timer.sh" --install || { warn "activate-harness: $base installer FAILED"; failed=1; } ;;
                eldato-controller-watchdog|eldato-objective-reminder)
                    act_say "arming $base via scripts/install-cell-timers.sh"
                    bash "$ROOT/scripts/install-cell-timers.sh" --install || { warn "activate-harness: $base installer FAILED"; failed=1; } ;;
                eldato-ai-drainer)
                    act_say "arming $base via scripts/orchestrator-harness/install-drainer-timer.sh"
                    bash "$ROOT/scripts/orchestrator-harness/install-drainer-timer.sh" --install || { warn "activate-harness: $base installer FAILED"; failed=1; } ;;
                *)
                    warn "activate-harness: $base is a MUST row with no runnable installer in this launcher — refusing to call this box armed"
                    failed=1; continue ;;
            esac
            ran=$((ran + 1))
        done
    elif [ "$ACT_PLATFORM" = "mac" ]; then
        if [ -f "$ROOT/scripts/install-launchd.sh" ]; then
            ran=$((ran + 1))
            # ⛔ NO ARGUMENT. `install-launchd.sh` installs on NO argument; its verb list is
            # `--status | --uninstall | --arm-* | --disarm-*`, and `--install` falls to the `*)` arm
            # which prints "ERROR: unknown argument" and exits 2 (verified — scripts/install-launchd.sh:1710).
            # So this call FAILED on every Mac, `failed=1` was set, and NOTHING in the launchd set was
            # ever armed through this launcher while the run printed an arming line (review F2).
            act_say "arming the launchd set via scripts/install-launchd.sh (no argument = install)"
            bash "$ROOT/scripts/install-launchd.sh" || { warn "activate-harness: install-launchd.sh FAILED"; failed=1; }
        fi
        # The plists in SUBDIRECTORIES are out of install-launchd.sh's glob on purpose; their own
        # installers own them. runner-autoscale is NOT here: it is an `optional` row (#2403).
        for base in harness-apply disk-reaper conflict-rebase; do
            case "$base" in
                harness-apply)
                    act_say "arming com.eldato.harness-apply via scripts/install-harness-apply-timer.sh"
                    bash "$ROOT/scripts/install-harness-apply-timer.sh" --install || { warn "activate-harness: harness-apply installer FAILED"; failed=1; } ;;
                disk-reaper)
                    act_say "arming com.eldato.disk-reaper via scripts/install-disk-reaper-timer.sh"
                    bash "$ROOT/scripts/install-disk-reaper-timer.sh" --install || { warn "activate-harness: disk-reaper installer FAILED"; failed=1; } ;;
                conflict-rebase)
                    act_say "arming com.eldato.conflict-rebase via scripts/install-conflict-rebase-timer.sh"
                    bash "$ROOT/scripts/install-conflict-rebase-timer.sh" --install || { warn "activate-harness: conflict-rebase installer FAILED"; failed=1; } ;;
            esac
            ran=$((ran + 1))
        done
    fi
    [ "$ran" -gt 0 ] || { warn "activate-harness: nothing was armed (no applicable rows) — that is a refusal, not a success"; return 1; }
    return "$failed"
}

# ── verdict ─────────────────────────────────────────────────────────────────────────────────
summarise() {
    local name class state detail n_fail=0 n_unknown=0 n_ok=0 n_armed_optional=0
    # ROWS is newline-separated; iterate without a subshell so the counters survive.
    local IFS='
'
    for line in $ROWS; do
        [ -n "$line" ] || continue
        class="$(printf '%s' "$line" | cut -d'|' -f2)"
        state="$(printf '%s' "$line" | cut -d'|' -f3)"
        name="$(printf '%s' "$line" | cut -d'|' -f1)"
        case "$state" in
            UNKNOWN) n_unknown=$((n_unknown + 1)) ;;
            OK) n_ok=$((n_ok + 1)) ;;
            MISSING|NEVER-FIRED|FAILING|LATE)
                case "$class" in
                    must) n_fail=$((n_fail + 1)) ;;
                    optional) n_armed_optional=$((n_armed_optional + 1)) ;;
                    *) : ;;
                esac ;;
            UNEXPECTED) n_fail=$((n_fail + 1)) ;;
            UNARMED|SKIPPED) : ;;
        esac
    done
    unset IFS
    FAILED_ROWS="$n_fail"; UNKNOWN_ROWS="$n_unknown"; OK_ROWS="$n_ok"

    if [ "$TSV" = 1 ]; then
        printf 'SUMMARY\tfail=%s\tunknown=%s\tok=%s\tunmeasured=%s\n' "$n_fail" "$n_unknown" "$n_ok" "$UNMEASURED_ROWS"
    else
        act_say ""
        if [ "$n_fail" -gt 0 ]; then
            act_say "ACTIVATION INCOMPLETE — $n_fail row(s) not armed and not optional; $n_ok ok, $n_unknown unreadable."
            # Name them. A launcher that reports a count and no names is the fail-open shape.
            local IFS='
'
            for line in $ROWS; do
                case "$line" in
                    *'|MISSING|'*|*'|NEVER-FIRED|'*|*'|FAILING|'*|*'|LATE|'*|*'|UNEXPECTED|'*)
                        printf '  NOT ARMED: %s — %s\n' "$(printf '%s' "$line" | cut -d'|' -f1)" "$(printf '%s' "$line" | cut -d'|' -f4)" ;;
                esac
            done
            unset IFS
        elif [ "$n_unknown" -gt 0 ]; then
            act_say "ACTIVATION UNVERIFIED — $n_unknown row(s) could not be read (that is never a pass); $n_ok ok."
        else
            act_say "ACTIVATION COMPLETE — $n_ok row(s) armed and fresh."
        fi
        # ⛔ A GREEN GRID IS NOT A CLAIM THAT EVERYTHING WAS MEASURED. This is the honest half of the
        # launchd freshness read: those rows are loaded and have run, but their AGE could not be read,
        # so "still firing" is unanswered. Printed rather than absorbed — a success line with no
        # qualifier is how a half-read grid becomes a certification.
        if [ "$UNMEASURED_ROWS" -gt 0 ]; then
            act_say "NOTE: $UNMEASURED_ROWS row(s) are loaded and have run, but their FRESHNESS was unmeasurable (no readable log path in the plist) — 'still firing' is NOT certified for them."
        fi
        # ⛔ AN `optional` ROW IS NOT A ROW NOBODY READS. It does not fail the run (that is what the
        # class MEANS: armed here only by a dated owner decision — #2403's runner autoscale), but a
        # BROKEN optional row that is silently folded into a counter nothing prints is the same
        # "computed and never read" shape this repo keeps filing. It is named, not failed.
        if [ "$n_armed_optional" -gt 0 ]; then
            act_say "NOTE: $n_armed_optional optional row(s) are NOT in an OK state (they are not required here, so this does not fail the run):"
            local IFS='
'
            for line in $ROWS; do
                case "$line" in
                    *'|optional|'*)
                        case "$line" in
                            *'|OK|'*|*'|UNARMED|'*|*'|SKIPPED|'*|*'|UNKNOWN|'*) ;;
                            *) printf '  OPTIONAL NOT OK: %s — %s\n' "$(printf '%s' "$line" | cut -d'|' -f1)" "$(printf '%s' "$line" | cut -d'|' -f4)" ;;
                        esac ;;
                esac
            done
            unset IFS
        fi
    fi
    [ "$n_fail" -gt 0 ] && return 1
    [ "$n_unknown" -gt 0 ] && return 2
    return 0
}

FAILED_ROWS=0; UNKNOWN_ROWS=0; OK_ROWS=0
# Rows whose LOADED state was verified but whose freshness could not be measured (a launchd plist
# with no readable log). Counted so "ACTIVATION COMPLETE" can never be printed over a grid in which
# most rows had half their verdict unread.
UNMEASURED_ROWS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --check)   VERB="check" ;;
        --install|--activate) VERB="install" ;;
        --tsv)     TSV=1; VERB="check" ;;
        --json)    TSV=1; VERB="check" ;;   # one line per row is the machine contract; no second shape
        -h|--help)
            # ⛔ A BUILTIN READ LOOP, NOT `sed -n '2,Np' "$0"`. A static discard guard cannot resolve
            # that producer, fails closed, and refuses the whole invocation — which makes the file
            # unrunnable by the very lanes it must not disturb (measured twice, recorded in
            # install-harness-apply-timer.sh's help_text). The header ends at its own sentinel, so
            # adding a line cannot truncate `--help`.
            _n=0
            while IFS= read -r _l; do
                _n=$((_n + 1)); [ "$_n" = 1 ] && continue
                case "$_l" in
                    'set -uo pipefail'*) break ;;
                    '#'*) printf '%s\n' "${_l#\# }" ;;
                    '') printf '\n' ;;
                    *) break ;;
                esac
            done <"$0"
            exit 0 ;;
        *) warn "activate-harness: unknown argument '$1'"; exit 2 ;;
    esac
    shift
done

resolve_root || ROOT=""
SYS_TEMPLATES="${ACTIVATE_SYSTEMD_TEMPLATES_DIR:-${ROOT:+$ROOT/templates/systemd}}"
LAUNCHD_TEMPLATES="${ACTIVATE_LAUNCHD_TEMPLATES_DIR:-${ROOT:+$ROOT/templates/launchd}}"

if [ "$VERB" = "install" ] && [ "$SKIP_INSTALL" != "1" ]; then
    do_install; install_rc=$?
    act_say ""
    act_say "verifying after arming…"
else
    install_rc=0
fi

build_grid
summarise; verdict=$?
[ "$VERB" = "install" ] && [ "$install_rc" -ne 0 ] && verdict=1
exit "$verdict"
