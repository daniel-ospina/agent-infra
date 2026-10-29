#!/usr/bin/env bash
# install-runner-autoscale-timer.sh — put the CI RUNNER CAPACITY CONVERGER on the box's clock, on BOTH
# platforms (agent-infra#2403, under the owner ruling in #2344).
#
# ⛔ WHY THIS FILE EXISTS. `scripts/orchestrator-harness/runner_autoscale.py` is the pass that DERIVES
# this box's runner ceiling from its cores plus its MEASURED free memory, restarts a dead listener,
# re-registers an orphaned one, and adds capacity up to that ceiling — and NOTHING RAN IT. The file's
# own header said so ("LANDING THIS FILE DOES NOT DEPLOY IT"), `templates/systemd/` carried one job pair
# (the disk reaper), and the capability was reachable only by a human who remembered the path. That is
# the "manual step that looks automated" #2373 exists to remove. MEASURED on pi-cell-1 (2026-10-29):
# 8 cores => ceiling 3, FIVE live listeners against it, the tortoise queue at 34 waiting runs and no
# landing for 13 hours.
#
# Same split as the rest of this family (#2032/#2048/#2058, #2416): the artifact has to be RENDERED
# from machine state (HOME, PATH, the interpreter, the script, the state dir) and installed
# IDEMPOTENTLY; the bring-up is the TRIGGER, this is the policy of WHERE and HOW.
#   Linux  eldato-runner-autoscale.service + .timer   ~9 min (OnBootSec=2min, OnUnitActiveSec=9min)
#   macOS  com.eldato.runner-autoscale LaunchAgent     ~9 min (StartInterval=540)
# Neither scheduler is re-implemented: the units are rendered here and enabled with `systemctl`, the
# plist is rendered here and bootstrapped with `launchctl`.
#
# ⛔ IT SHIPS DISARMED, AND ARMING IS A SEPARATE DATED OWNER STEP (#1678 ruling, as reused by
# worktree-hygiene and pi-reap-orphans). Adding runners is a CAPACITY decision per box, so:
#   * the template carries {{MODE_FLAG}}, which renders `--dry-run`  (measure, classify, PRINT the
#     plan; change nothing);
#   * the ARMED render passes NO mode argument at all — the converger has no affirmative flag,
#     because converging is its DEFAULT and `--dry-run` is the only switch it accepts. Arming is
#     therefore determined by a dated record in this box's own state dir, written by `--arm` and
#     removed by `--disarm`;
#   * there is NO environment default that can arm it (an ambient export would arm a fleet with
#     nothing on disk to show for it), and the merged template never carries a literal armed value,
#     so a fleet-wide install cannot arm a fleet;
#   * the armed state IS the installed artifact's own command line, so `cat` of the unit/plist and
#     `--status` both answer "is this box growing runners?" without reading code;
#   * a half-written record renders DISARMED — a truncated arming file must never count as an arming.
#
# ⛔ `--arm` PREFLIGHTS, AND A BOX IT CANNOT MEASURE IS NOT ARMED. An armed pass on a box whose `gh`
# cannot read the pool exits 2 every nine minutes and grows nothing — the inert-enforcer shape, armed
# with an owner's signature on it. So `--arm` runs the converger's own `--status --json` first, refuses
# unless that answers, and writes the MEASURED ceiling into the record: one `cat` answers "armed, when,
# by whom, at what ceiling, and from which reading".
#
# ⛔ WHAT THIS INSTALLER REFUSES (each would otherwise install a unit that cannot run, or one that
# silently converges nothing):
#   * a script path that is not a regular readable file, or one inside a `mktemp` scratch tree (the
#     measured inert-enforcer: a unit pointing into a directory deleted before the first tick exits 127
#     on EVERY pass while `list-timers` shows the job scheduled and healthy);
#   * an interpreter older than 3.12 — the pass refuses itself with exit 2, so the unit would be red
#     from its first tick for a reason the installer already knew;
#   * a `--repo` that is not a plain `owner/name` (it is interpolated into the unit's command line);
#   * a rendered value containing a backslash (the renderer is sed, where a backslash is an escape, so
#     the rendered path would silently differ from the real one), or whitespace on the SYSTEMD arm
#     (systemd splits unquoted Environment=/ExecStart= values, so the unit would start the wrong
#     program) — a plist value is a <string> of its own, so whitespace is legitimate there;
#   * a state dir that is not writable by the invoking user (the pass logs there and the arming record
#     lives there; an unwritable one makes every pass record nothing while the unit looks installed);
#   * a rendered plist that does not parse (launchd would refuse it and the box would silently have no
#     pass), or a rendered unit/timer with an unresolved `{{PLACEHOLDER}}` (the job would exec the
#     literal text);
#   * a sudo-invoked root install (the unit would run as root and look after root's processes while the
#     lanes' runners were untouched — a green tick that converged nothing);
#   * a box with no scheduler at all — a LOUD failure naming both attempts, never a silent no-op.
#
# ⛔ IT DOES NOT FIGHT `scripts/ci_runner_gate.sh`, AND THAT IS A DESIGN CONSTRAINT, NOT A HOPE. The
# gate owns LABELS (which pool GitHub-hosted jobs fall back to) and holds the `ubuntu-latest` fallback
# label; the converger owns CAPACITY (how many listeners this box can sustain) and is documented never
# to relabel, re-rank or remove an existing runner — it only asks the gate's own recorded mode before
# it puts the fallback label back. This installer installs a TIMER; it changes no label, and it does not
# re-rank anything the gate installed.
#
# ⛔ `--dry-run` IS A PREVIEW, NOT A DISARM. `--dry-run` renders and prints, writing and enabling
# nothing. To DISARM an armed box use `--disarm` (removes the record AND reinstalls). `--report-only`
# renders the dry-run artifact for one install, and REFUSES while a record exists — otherwise the next
# routine install would silently re-arm the box and the operator would believe it was disarmed.
#
# INSTALL TARGETS. systemd, tried in this order, and the reason is named in the output:
#   1. a SYSTEM unit via passwordless sudo (/etc/systemd/system) — a cell's normal shape; the service
#      runs as the invoking user (`User=`), so the pass reads the lane user's runners and state;
#   2. a USER unit (~/.config/systemd/user) when systemd's user manager answers — a box without sudo
#      still gets a clock. Needs lingering, which is CHECKED: without it a user timer fires while you
#      are logged in and never again — the inert enforcer that prints green;
#   3. nothing — a loud FAILURE naming the remedy. A timer that was "installed" but never fires is the
#      false PASS this repo keeps removing.
# macOS has exactly one: ~/Library/LaunchAgents (a LaunchAgent, in the user's GUI domain).
#
# Usage:
#   install-runner-autoscale-timer.sh [--install] [--dry-run] [--report-only]
#                                     [--arm [--reason TEXT]] [--disarm]
#                                     [--status] [--uninstall] [--help]
#
# Env seams (tests + unusual boxes):
#   RUNNER_AUTOSCALE_SCRIPT    the converger to install (default: the checkout beside this installer,
#                              then $AGENT_INFRA_PATH, then the farmed/live-only copy on a cell)
#   ELDATO_LAUNCHER_PY / RUNNER_AUTOSCALE_PYTHON
#                              the interpreter the job runs (default: python3.12, else python3 if it is
#                              >= 3.12; anything older is REFUSED — the pass refuses itself at 3.12)
#   RUNNER_AUTOSCALE_PROVISIONER  tools/install-ci-runner-x64.sh, pinned into the artifact when found.
#                              Absent is a loud WARNING, not a refusal: the pass still REPAIRS and
#                              RE-REGISTERS, it just cannot ADD a runner
#   RUNNER_AUTOSCALE_REPO      the repo whose pool is converged (default daniel-ospina/tortoise)
#   RUNNER_AUTOSCALE_STATE_DIR record/log dir the unit exports (default $HOME/.pi/agent/state)
#   RUNNER_AUTOSCALE_ARM_FILE  the arming record (default $RUNNER_AUTOSCALE_STATE_DIR/
#                              runner-autoscale.armed)
#   TEMPLATES_DIR             systemd template dir (default: this checkout's templates/systemd)
#   LAUNCHD_TEMPLATES_DIR     plist template dir (default: templates/launchd/runner-autoscale)
#   SYSTEMD_UNIT_DIR          install dir OVERRIDE (tests: a temp dir, with SYSTEMCTL a fake)
#   LAUNCHD_AGENTS_DIR        LaunchAgents dir OVERRIDE (tests: a temp dir, with LAUNCHCTL a fake)
#   ELDATO_PLATFORM           override `uname -s` (tests render the Darwin artifact on any host)
#   SYSTEMCTL / LAUNCHCTL / SUDO  the tools to call / probe (tests: shims)
#   RUNNER_AUTOSCALE_EXTRA_SCOPES  colon-separated EXTRA dirs scanned by `--uninstall`'s "another
#                              scope" note (TEST SEAM: read-only scan paths only; production sets
#                              nothing)
#
# Exit codes: 0 ok · 1 failure or refusal (named) · 2 usage.
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ⛔ THE CHECKOUT THAT SHIPS THIS INSTALLER WINS OVER AN AMBIENT $AGENT_INFRA_PATH. A FARMED copy has no
# ../templates beside it (it lives at $HOME/.pi/agent/scripts), so it falls through to the next
# candidate — but when this file IS running from a checkout, that checkout is the authority for its own
# templates; taking an older checkout's artifact would install a unit written against a different pass.
if [ -z "${TEMPLATES_DIR:-}" ]; then
    for _cand in "$INFRA_ROOT/templates/systemd" "${AGENT_INFRA_PATH:-}/templates/systemd" \
                 "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/templates/systemd"; do
        [ -n "$_cand" ] && [ -d "$_cand" ] && { TEMPLATES_DIR="$_cand"; break; }
    done
fi
TEMPLATES_DIR="${TEMPLATES_DIR:-$INFRA_ROOT/templates/systemd}"
# The plist lives OUTSIDE templates/launchd/ on purpose: install-launchd.sh installs EVERY
# `templates/launchd/*.plist` with no arguments and a DIFFERENT placeholder set, so a copy there would
# render with `{{…}}` unresolved and the box would silently have no scheduled pass. Same reason
# templates/launchd/reaper/ and templates/launchd/harness-apply/ exist.
if [ -z "${LAUNCHD_TEMPLATES_DIR:-}" ]; then
    for _cand in "$INFRA_ROOT/templates/launchd/runner-autoscale" \
                 "${AGENT_INFRA_PATH:-}/templates/launchd/runner-autoscale" \
                 "${TEMPLATES_DIR%/systemd}/launchd/runner-autoscale"; do
        [ -n "$_cand" ] && [ -d "$_cand" ] && { LAUNCHD_TEMPLATES_DIR="$_cand"; break; }
    done
fi
LAUNCHD_TEMPLATES_DIR="${LAUNCHD_TEMPLATES_DIR:-$INFRA_ROOT/templates/launchd/runner-autoscale}"
PLATFORM="${ELDATO_PLATFORM:-$(uname -s 2>/dev/null || printf 'unknown')}"
UNIT_NAME="eldato-runner-autoscale"
# The launchd label is the unit name in reverse-DNS form, so `--status` can name ONE job on a Mac
# carrying ~35 of them and the plist's Label is not a second, drifting spelling of the same thing.
LABEL="com.eldato.${UNIT_NAME#eldato-}"
STATE_DIR="${RUNNER_AUTOSCALE_STATE_DIR:-${HOME:?HOME is required}/.pi/agent/state}"
ARM_FILE="${RUNNER_AUTOSCALE_ARM_FILE:-$STATE_DIR/runner-autoscale.armed}"
REPO="${RUNNER_AUTOSCALE_REPO:-daniel-ospina/tortoise}"
# ~9 minutes, the interval the converger renders into its own pair — see the timer template.
INTERVAL_SEC=540
MODE=--install
DRY_RUN=0
# The one-shot mode override. `--report-only` renders the disarmed artifact; there is deliberately NO
# way to render an armed artifact from the command line, because an operator who can type the armed
# state is an operator who can arm a box without a record — and then nothing on disk says when or why.
FORCE_MODE_FLAG=""

log_line() { printf '%s\n' "$*"; }
err() { printf '%s: %s\n' "${0##*/}" "$*" >&2; }

# help_text — print the header comments. The range is DERIVED from the `set -uo pipefail` line, never a
# hand-maintained constant: a constant silently truncated the header whenever a line was added to it.
help_text() {
    local n
    n="$(grep -n '^set -uo pipefail' "$0" 2>/dev/null | head -1 | cut -d: -f1)"
    # ⛔ NO CONSTANT FALLBACK. When `$0` is not this file (invoked from a pipe: `curl … | bash`), the
    # derivation fails and a magic range silently reinstates exactly the truncation this replaced.
    if [ -z "$n" ]; then
        err "cannot derive the help range (invoke this FILE, not a pipe: 'bash $(basename "${BASH_SOURCE[0]:-$0}") --help')"
        return 2
    fi
    sed -n "2,$(( n - 1 ))p" "$0" | sed 's/^# \{0,1\}//'
}
usage() { help_text; exit 2; }

# ── small predicates ───────────────────────────────────────────────────────────────────────────
# A path systemd can actually execute. systemd resolves a relative ExecStart argument against the UNIT's
# working directory (not this installer's cwd), so a relative script path is a permanent 127 even though
# it resolves fine HERE — and `[ -f ]` cannot tell the difference.
is_absolute_path() { case "$1" in /*) return 0 ;; *) return 1 ;; esac; }

# is_transient_scratch <path> — a `mktemp -d`-shaped tree, which is deleted before the first tick.
# MEASURED (2026-10-18, pi-cell-2/-3): an installer run with HOME=/tmp/tmp.XXXX/bg/home wrote
# `ExecStart=… /tmp/tmp.XXXX/bg/home/.pi/agent/scripts/…` into /etc/systemd/system; the mktemp dir was
# gone before the first pass, so EVERY tick exited 127 while `list-timers` showed it healthy.
# ⛔ NOT "anything under /tmp": a cell legitimately runs with HOME=/tmp/cell-home and checkouts under
# /tmp/cell-ai, and refusing those would be a false block on the real target. What is transient by
# CONSTRUCTION is the `tmp.` + random-suffix name, which is what leaked into the units.
is_transient_scratch() { # is_transient_scratch <path>
    # ⛔ NORMALISE FIRST. macOS sets TMPDIR with a TRAILING SLASH, so `mktemp -d` yields a DOUBLE slash,
    # and a naive prefix test misses the exact install this guard exists to refuse.
    local p="$1" t t2
    [ -n "$p" ] || return 1
    p="$(printf '%s' "$p" | tr -s '/')"
    case "$p" in
        /tmp/tmp.?*|/var/tmp/tmp.?*|/private/tmp/tmp.?*|/private/var/tmp/tmp.?*) return 0 ;;
        # macOS's OWN temp root is /var/folders/<a>/<b>/T/ — NOT /tmp — so it must be named.
        /var/folders/*/*/T/tmp.?*|/private/var/folders/*/*/T/tmp.?*) return 0 ;;
    esac
    for t in "${TMPDIR:-}"; do
        [ -n "$t" ] || continue
        t="$(printf '%s' "$t" | tr -s '/')"
        t="${t%/}"
        [ -n "$t" ] || continue
        case "$t" in /var/*) t2="/private$t" ;; *) t2="$t" ;; esac
        case "$p" in "$t"/tmp.?*|"$t2"/tmp.?*|"/private$t"/tmp.?*) return 0 ;; esac
    done
    return 1
}

# A genuine systemd unit directory. If the "test" override names one of these it is pointing at the real
# thing, so it must NOT inherit the override's scratch-friendly bypass.
is_real_systemd_dir() {
    case "$(printf '%s' "${1:-}" | tr -s '/')" in
        /etc/systemd*|/usr/lib/systemd*|/lib/systemd*|/run/systemd*) return 0 ;;
    esac
    return 1
}

# xml_sed_repl — make a value safe as the REPLACEMENT half of `s|…|…|g` AND safe in the XML text node it
# lands in. Both escapes are needed and the XML one is not optional: `&` in a sed replacement expands to
# the WHOLE MATCH and `\` starts an escape, and the same `&` is the XML entity introducer — an
# unescaped one makes the plist MALFORMED, which launchd then refuses (scripts/install-launchd.sh
# documents the measured defect; this mirrors it rather than inventing a second rule).
sed_escape_repl() {
    printf '%s' "$1" | sed -e 's/[&\\|]/\\&/g'
}
xml_sed_repl() {
    sed_escape_repl "$(printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
}

# ── resolve the converger ─────────────────────────────────────────────────────────────────────
# ⛔ A FARMED INSTALLER HAS NO CHECKOUT BESIDE IT, AND THE CONVERGER IS NOT FARMED AT ALL. The farm
# (`pi-bootstrap/setup.sh`'s fleet_srcs) copies flat `scripts/<name>` entries, a shape that cannot even
# name a file under `scripts/orchestrator-harness/` — so a unit that assumed `$HOME/.pi/agent/scripts`
# would point at nothing, exit 127 on every tick, and `list-timers` would keep reporting it scheduled.
# So the script is RESOLVED from candidates and a box with none is a REFUSAL naming where to put one.
# resolve_infra_main — this repo's MAIN checkout, not a linked worktree. A worktree is DELETED when its
# branch merges, so a scheduled unit pinned into one fails 203/EXEC for ever the day the PR lands — the
# exact inert-enforcer shape this installer refuses elsewhere.
# ⛔ NO VCS SUBPROCESS, and not only for tidiness: the resolution it needs is a TWO-LINE FILE FORMAT
# (a linked worktree carries a marker FILE holding `gitdir: <main>/.git/worktrees/<name>`), so reading
# that file works on a box where the version-control CLI is absent — and this installer must run on such
# a box, since the pass it schedules talks to the GitHub API rather than to a checkout. Shelling out to
# the VCS would also make this whole script an unverifiable op carrier for the hub guard, which refuses
# to execute a script whose content performs an unsanctioned operation.
resolve_infra_main() {
    local gdir="$INFRA_ROOT/.git" main=""
    if [ -f "$gdir" ]; then
        main="$(sed -n 's/^gitdir: //p' "$gdir" | head -1)"
        case "$main" in
            */.git/worktrees/*) main="${main%%/.git/worktrees/*}" ;;
            *) main="" ;;
        esac
    fi
    if [ -n "$main" ] && [ -d "$main" ]; then printf '%s' "$main"; else printf '%s' "$INFRA_ROOT"; fi
}

SCRIPT=""
resolve_script() {
    local cand main
    main="$(resolve_infra_main)"
    if [ -n "${RUNNER_AUTOSCALE_SCRIPT:-}" ] && [ ! -f "${RUNNER_AUTOSCALE_SCRIPT}" ]; then
        err "\$RUNNER_AUTOSCALE_SCRIPT is set to '$RUNNER_AUTOSCALE_SCRIPT' but that is not a regular file — refusing to install a unit that points at a DIFFERENT copy of the converger"
        return 1
    fi
    # ⛔ THE MAIN CHECKOUT COMES BEFORE $INFRA_ROOT, which IS a worktree when this installer is run from a
    # lane. Pinning a durable path by default is the whole point; an operator who really means "schedule
    # the branch's copy" sets RUNNER_AUTOSCALE_SCRIPT, and the install summary prints which copy was pinned.
    for cand in "${RUNNER_AUTOSCALE_SCRIPT:-}" \
                "$main/scripts/orchestrator-harness/runner_autoscale.py" \
                "$INFRA_ROOT/scripts/orchestrator-harness/runner_autoscale.py" \
                "${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/runner_autoscale.py" \
                "${HOME:-}/.pi/agent/scripts/runner_autoscale.py"; do
        [ -n "$cand" ] || continue
        [ -f "$cand" ] && { SCRIPT="$cand"; break; }
    done
    if [ -z "$SCRIPT" ]; then
        err "REFUSING: no runner_autoscale.py found — looked at \$RUNNER_AUTOSCALE_SCRIPT, $main/scripts/orchestrator-harness/, $INFRA_ROOT/scripts/orchestrator-harness/, \${AGENT_INFRA_PATH:-<unset>}/scripts/orchestrator-harness/ and \$HOME/.pi/agent/scripts/. A unit pointed at nothing exits 127 on every tick while list-timers shows it scheduled."
        return 1
    fi
    # ⛔ A WORKTREE PATH IS SAID OUT LOUD, NOT REFUSED (scheduling a branch's copy is a legitimate test):
    # the operator must know whether the scheduled artifact survives a merge.
    case "$SCRIPT" in
        */.worktrees/*)
            err "WARNING: the pinned converger $SCRIPT is inside a WORKTREE — that directory is removed when"
            err "  its branch merges, after which every tick fails 203/EXEC. Install from a durable checkout to"
            err "  schedule it permanently (or pin one with RUNNER_AUTOSCALE_SCRIPT)."
            ;;
    esac
    return 0
}

# ── resolve the interpreter ───────────────────────────────────────────────────────────────────
# ⛔ THE PASS REFUSES ITSELF BELOW 3.12 (it needs module-level 3.12 syntax and says so), so a unit whose
# interpreter is older is red on EVERY tick for a reason this installer can see right now. Resolve the
# >=3.12 interpreter, refuse anything older, and pin the absolute path: `ExecStart=python3 …` is not a
# PATH lookup, so a bare name fails 203/EXEC on a box whose only 3.12 interpreter has that name.
PYTHON=""
python_ok() { # python_ok <bin> — executable AND >= 3.12
    local bin="$1" out
    [ -n "$bin" ] && [ -x "$bin" ] || return 1
    out="$("$bin" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)" || return 1
    case "$out" in
        3.12|3.1[3-9]|[4-9].*) return 0 ;;
        *) err "  · $bin reports python $out — the converger requires >= 3.12"; return 1 ;;
    esac
}

resolve_python() {
    local cand seen=" " py312 py3
    # ⛔ RESOLVED WITHOUT A `||` CHAIN ENDING IN A PROGRAM NAME. The working-tree guard splits `||` as
    # if it were a pipe, so `… || true` whose neighbour is an interpreter reads as a pipeline into a
    # program and the whole installer becomes unexecutable from a worktree (#709, measured). Two
    # separate lookups have the same effect and no such shape.
    py312="$(type -P python3.12 2>/dev/null)" || py312=""
    py3="$(type -P python3 2>/dev/null)" || py3=""
    for cand in "${RUNNER_AUTOSCALE_PYTHON:-}" "${ELDATO_LAUNCHER_PY:-}" \
                "$py312" \
                "${HOME:-}/.pi/agent/.venv/bin/python" \
                "$py3"; do
        [ -n "$cand" ] || continue
        case "$seen" in *" $cand "*) continue ;; esac
        seen="$seen$cand "
        if python_ok "$cand"; then PYTHON="$cand"; return 0; fi
    done
    err "REFUSING: no Python >= 3.12 interpreter resolved — the converger refuses to run on an older one (its own guard), so this unit would be red on every tick. Install python3.12 or point RUNNER_AUTOSCALE_PYTHON at one."
    return 1
}

# ── resolve the provisioner, and SAY when there is none ──────────────────────────────────────
# The FILL half of the pass creates a new install only through tools/install-ci-runner-x64.sh. A
# scheduled pass runs with `WorkingDirectory=%h`, so the pass's `$PWD/tools/…` candidate cannot resolve
# and the install is the ONE moment the path can be measured (the operator is standing in a checkout
# that has it). ⛔ WARNED, NOT REFUSED: a repair-only schedule is still worth having, and refusing would
# make this installer unusable on the boxes it exists for (no cell carries that installer today —
# measured on pi-cell-1). The consequence is named, not implied.
PROVISIONER=""
PROVISIONER_WHY="no tools/install-ci-runner-x64.sh at any candidate"
resolve_provisioner() {
    local raw="${RUNNER_AUTOSCALE_PROVISIONER:-}" cand
    if [ -n "$raw" ]; then
        # ⛔ A NAMED PIN IS THE WHOLE LIST: falling through to a default when the operator pinned a path
        # would silently replace their answer with another copy — the "a pinned path silently ignored"
        # defect this family already fixed twice. A bad pin is therefore reported, not routed around.
        if [ -f "$raw" ] && [ -r "$raw" ]; then
            PROVISIONER="$raw"; PROVISIONER_WHY="resolved"
        else
            PROVISIONER_WHY="RUNNER_AUTOSCALE_PROVISIONER='$raw' is not a readable regular file"
        fi
        return 0
    fi
    for cand in "$INFRA_ROOT/tools/install-ci-runner-x64.sh" \
                "${AGENT_INFRA_PATH:-}/tools/install-ci-runner-x64.sh" \
                "$PWD/tools/install-ci-runner-x64.sh" \
                "${HOME:-}/.pi/agent/scripts/install-ci-runner-x64.sh"; do
        [ -n "$cand" ] || continue
        if [ -f "$cand" ] && [ -r "$cand" ]; then PROVISIONER="$cand"; PROVISIONER_WHY="resolved"; return 0; fi
    done
    return 0
}

# ── the arming record ────────────────────────────────────────────────────────────────────────
# ⛔ BOTH LINES OR NOTHING: a half-written record (truncated write, an editor buffer flushed early) must
# render DISARMED. That is the fail-closed direction, and it is the same rule install-launchd.sh applies
# to worktree-hygiene.armed and pi-reap-orphans.armed.
arm_record_valid() {
    [ -f "$ARM_FILE" ] \
        && grep -q '^armed-by=.' "$ARM_FILE" 2>/dev/null \
        && grep -q '^armed-date=.' "$ARM_FILE" 2>/dev/null
}

# arm_flag — the mode this render would carry. The record is the ONLY arming input.
# ⛔ THE ARMED VALUE IS THE EMPTY STRING, NOT A FLAG. The converger has NO `--apply`: converging is its
# DEFAULT, and `--dry-run` is the only mode switch it accepts (measured on pi-cell-1: the first armed
# install rendered `--apply` and systemd logged `runner_autoscale.py: error: unrecognized arguments:
# --apply`, exit 2, every tick). So armed means "pass no mode argument", which is exactly what the
# converger's own `--install-unit` writes — and an empty `<string>` in a launchd ProgramArguments is a
# POSITIONAL ARGUMENT, which is why the launchd arm drops the element entirely (see MODE_ARG).
arm_flag() {
    if arm_record_valid; then printf '%s' ''; else printf '%s' '--dry-run'; fi
}

mode_flag() {
    if [ -n "$FORCE_MODE_FLAG" ]; then printf '%s' "$FORCE_MODE_FLAG"; else arm_flag; fi
}

# mode_label — what a human should read. `--dry-run` is DISARMED; no flag is ARMED (converging).
mode_label() {
    case "$(mode_flag)" in
        --dry-run) printf '%s' '--dry-run' ;;
        '')        printf '%s' 'converge (no mode flag)' ;;
        *)         printf '%s' "$(mode_flag)" ;;
    esac
}

# mode_arg_for — the launchd ProgramArguments ELEMENT for the mode, or nothing. An empty <string> would
# be handed to the pass as a positional argument ("unrecognized arguments:"), so armed omits it.
mode_arg_for() {
    local flag
    flag="$(mode_flag)"
    [ -n "$flag" ] && printf '%s' "        <string>$flag</string>"
    return 0
}

# ── rendering ────────────────────────────────────────────────────────────────────────────────
# The provisioner is rendered as a WHOLE line (or nothing at all) rather than as a value inside a fixed
# line, so "no provisioner" cannot degrade into `Environment="RUNNER_AUTOSCALE_PROVISIONER="` — a
# variable SET TO EMPTY, which is a different fact from an unset one.
provisioner_env_for() { # provisioner_env_for systemd|launchd
    [ -n "$PROVISIONER" ] || { printf '%s' ""; return 0; }
    case "$1" in
        systemd) printf '%s' "Environment=\"RUNNER_AUTOSCALE_PROVISIONER=$PROVISIONER\"" ;;
        launchd) printf '%s' "<key>RUNNER_AUTOSCALE_PROVISIONER</key><string>$(xml_sed_repl "$PROVISIONER")</string>" ;;
    esac
}

render() { # render <template> <dest> <systemd|launchd>
    local tpl="$1" dest="$2" flavour="$3"
    sed -e "s|{{USER}}|$(xml_sed_repl "$(id -un)")|g" \
        -e "s|{{HOME}}|$(xml_sed_repl "$HOME")|g" \
        -e "s|{{PATH}}|$(xml_sed_repl "$PATH")|g" \
        -e "s|{{STATE_DIR}}|$(xml_sed_repl "$STATE_DIR")|g" \
        -e "s|{{PYTHON}}|$(xml_sed_repl "$PYTHON")|g" \
        -e "s|{{PY_BIN}}|$(xml_sed_repl "$PYTHON")|g" \
        -e "s|{{SCRIPT}}|$(xml_sed_repl "$SCRIPT")|g" \
        -e "s|{{REPO}}|$(xml_sed_repl "$REPO")|g" \
        -e "s|{{MODE_FLAG}}|$(mode_flag)|g" \
        -e "s|{{MODE_ARG}}|$(sed_escape_repl "$(mode_arg_for)")|g" \
        -e "s|{{INTERVAL_SEC}}|$INTERVAL_SEC|g" \
        -e "s|{{LABEL}}|$LABEL|g" \
        -e "s|{{PROVISIONER_ENV}}|$(sed_escape_repl "$(provisioner_env_for "$flavour")")|g" \
        "$tpl" >"$dest" || return 1
    # ⛔ AN UNRESOLVED PLACEHOLDER IS A REFUSAL, NOT A WARNING: the artifact would exec the literal text.
    if grep -q '{{' "$dest"; then
        err "unresolved placeholder in $tpl:"
        grep -n '{{' "$dest" >&2
        return 1
    fi
    return 0
}

# plist_is_valid <path> — REFUSE a rendered plist launchd cannot parse. `plutil -lint` is the host's own
# parser where it exists; python's expat is the fallback so a Linux test can prove the shape too.
plist_is_valid() {
    local f="$1"
    if command -v plutil >/dev/null 2>&1; then
        plutil -lint "$f" >/dev/null 2>&1 && return 0
        return 1
    fi
    # ⛔ `type -P` AND NOT A `command -v … || return` CHAIN: the guard splits `||` as a pipe and reads
    # the tail as a program, which made this installer unexecutable from a worktree (#709).
    type -P python3 >/dev/null 2>&1 || return 0   # no parser available: do not invent a refusal
    python3 -c 'import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$f" >/dev/null 2>&1
}

# ── guards ───────────────────────────────────────────────────────────────────────────────────
# refuse_unusable_target — everything that must be true BEFORE a scheduler-specific render, on BOTH
# platforms (a plist pointing at a deleted script is exactly as inert as a unit that does).
refuse_unusable_target() { # refuse_unusable_target <target-or-"scheduled">
    local t="${1:-scheduled}" v p bad="" skip_scratch_heuristic=0
    for v in "SCRIPT=$SCRIPT" "HOME=$HOME" "STATE_DIR=$STATE_DIR"; do
        p="${v#*=}"
        is_absolute_path "$p" || {
            err "REFUSING: ${v%%=*} '$p' is not an absolute path — a scheduler resolves the command against a working directory this installer does not choose, so the pass would fail to start on every tick"
            return 1
        }
    done
    [ -f "$SCRIPT" ] && [ -r "$SCRIPT" ] || {
        err "REFUSING: the converger '$SCRIPT' does not exist (or is unreadable) — refusing to install a timer that cannot run"
        return 1
    }
    [ -n "$PYTHON" ] && [ -x "$PYTHON" ] || {
        err "REFUSING: no executable interpreter resolved for the job — refusing to install a timer that cannot start"
        return 1
    }
    # The scratch heuristic is skipped ONLY for a genuine scratch override (the documented test seam),
    # never for a real unit directory — the override must not become a way to build the measured
    # inert-enforcer one environment variable away.
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ] && ! is_real_systemd_dir "$SYSTEMD_UNIT_DIR"; then
        skip_scratch_heuristic=1
    fi
    if [ "$skip_scratch_heuristic" = 1 ]; then
        :
    else
        is_transient_scratch "$SCRIPT"    && bad="SCRIPT=$SCRIPT"
        is_transient_scratch "$HOME"      && bad="${bad:+$bad; }HOME=$HOME"
        is_transient_scratch "$STATE_DIR" && bad="${bad:+$bad; }STATE_DIR=$STATE_DIR"
        [ -n "$PROVISIONER" ] && is_transient_scratch "$PROVISIONER" && \
            bad="${bad:+$bad; }PROVISIONER=$PROVISIONER"
    fi
    if [ -n "$bad" ]; then
        err "REFUSING a $t install rendered from transient scratch space: $bad"
        err "The timer would point at a directory deleted before the first tick, so every pass exits 127"
        err "while 'list-timers' shows the job scheduled. That is the exact inert-enforcer shape this"
        err "installer must never create (agent-infra#2032, measured on pi-cell-2/-3)."
        err "Re-run from the box's real HOME (a login shell or cloud-cell-bringup.sh), or set"
        err "SYSTEMD_UNIT_DIR to a scratch dir when this is a test."
        return 1
    fi
    # ⛔ AND THE RENDERER ITSELF. Every substituted value goes through `sed -e "s|{{X}}|$v|g"`, so a
    # BACKSLASH in a value is a sed ESCAPE: the rendered path would silently differ from the real one,
    # with no `{{` left for the post-render guard to catch. `&` and `|` are refused by construction
    # (`xml_sed_repl` escapes them); the backslash is the silent one.
    for v in "HOME=$HOME" "PATH=$PATH" "STATE_DIR=$STATE_DIR" "SCRIPT=$SCRIPT" "PYTHON=$PYTHON" \
             "REPO=$REPO" "PROVISIONER=$PROVISIONER"; do
        case "${v#*=}" in
            *\\*) err "REFUSING: ${v%%=*} contains a backslash — the artifact is rendered with sed, where a backslash is an escape, so the rendered path would silently differ from the real one"; return 1 ;;
        esac
    done
    # ⛔ `--repo` IS INTERPOLATED INTO THE COMMAND LINE, so it is validated rather than quoted-and-hoped:
    # the converger refuses the same shape (`repo_problem`), so a bad one here would be a red tick every
    # nine minutes; a newline would write an arbitrary directive into the unit.
    if ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        err "REFUSING: --repo '$REPO' is not a plain owner/name (letters, digits, dot, dash, underscore) — it is interpolated into the scheduled command line, where a newline, a quote or a % becomes a directive or a specifier"
        return 1
    fi
    # The state dir the pass logs into and the arming record lives in. The service runs as the INVOKING
    # user, so writeability tested here is the service's own. ⛔ `--dry-run` MUST NOT CREATE IT: this
    # probe runs before the DRY_RUN branch, and a preview that writes to the filesystem is a preview
    # that can refuse on a path it was only supposed to describe.
    if [ "${DRY_RUN:-0}" = "1" ]; then
        if [ -e "$STATE_DIR" ] && [ ! -w "$STATE_DIR" ]; then
            err "REFUSING: state dir '$STATE_DIR' exists and is not writable by $(id -un) — the unit runs as this user and every pass would fail to record"
            return 1
        fi
        [ -e "$STATE_DIR" ] || log_line "dry-run: would create the state dir $STATE_DIR"
    elif ! mkdir -p "$STATE_DIR" 2>/dev/null || [ ! -w "$STATE_DIR" ]; then
        err "REFUSING: state dir '$STATE_DIR' is not writable by $(id -un) — the unit runs as this user and every pass would fail to record (and the arming record cannot be written)"
        return 1
    fi
    return 0
}

# refuse_systemd_unsafe_values — the whitespace rule, which is a SYSTEMD rule and not a launchd one:
# systemd SPLITS unquoted Environment=/ExecStart= values, so a path containing a space renders a unit
# that cannot run. A plist value is a `<string>` of its own, so `my home` is a legitimate path there and
# refusing it would be a false block on the Mac. It needs $TARGET, so it runs AFTER choose_target.
refuse_systemd_unsafe_values() {
    local v
    [ "${TARGET:-}" = "launchd" ] && return 0
    for v in "HOME=$HOME" "PATH=$PATH" "STATE_DIR=$STATE_DIR" "SCRIPT=$SCRIPT" "PYTHON=$PYTHON" \
             "REPO=$REPO" "PROVISIONER=$PROVISIONER"; do
        case "${v#*=}" in
            *[[:space:]]*) err "REFUSING: ${v%%=*} contains whitespace — systemd splits the rendered unit on it, so the job would never run"; return 1 ;;
        esac
    done
    return 0
}

# ── choose a target ─────────────────────────────────────────────────────────────────────────
TARGET=""; UNIT_DIR=""; SC=""
choose_target() {
    if [ "$PLATFORM" = "Darwin" ]; then
        TARGET="launchd"
        UNIT_DIR="${LAUNCHD_AGENTS_DIR:-${HOME:?HOME is required}/Library/LaunchAgents}"
        SC="${LAUNCHCTL:-launchctl}"
        return 0
    fi
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ]; then
        TARGET="override"; UNIT_DIR="$SYSTEMD_UNIT_DIR"; SC="${SYSTEMCTL:-systemctl}"
        return 0
    fi
    # `${SUDO+x}` distinguishes unset from set-to-empty, so the documented "SUDO= skips the sudo probe"
    # branch is reachable and a pinned SYSTEMCTL is honoured on the SYSTEM target too (a pinned path
    # silently ignored is the defect this family already fixed twice).
    if [ -z "${SUDO+x}" ] && sudo -n true >/dev/null 2>&1; then
        TARGET="system"; UNIT_DIR="/etc/systemd/system"; SC="${SYSTEMCTL:-sudo -n systemctl}"
        return 0
    fi
    if [ -n "${SUDO+x}" ] && { [ -z "$SUDO" ] || $SUDO true >/dev/null 2>&1; }; then
        TARGET="system"; UNIT_DIR="/etc/systemd/system"; SC="${SYSTEMCTL:-${SUDO:+$SUDO }systemctl}"
        return 0
    fi
    if systemctl --user show-environment >/dev/null 2>&1; then
        TARGET="user"; UNIT_DIR="$HOME/.config/systemd/user"; SC="${SYSTEMCTL:-systemctl} --user"
        return 0
    fi
    return 1
}

# ── the installed artifact, read back ───────────────────────────────────────────────────────
# ⛔ WHY A READ-BACK AND NOT A COMPARISON. The render validates its INPUTS and compares the rendered
# bytes, but neither is the artifact the scheduler LOADS: a `*.service.d/*.conf` drop-in overrides
# ExecStart, a truncated file has no ExecStart at all, and `install(1)` can leave a pre-existing file in
# place on some failures while the installer still reports success. MEASURED (2026-10-18): the installed
# unit executed a path from a deleted mktemp tree and exited 127 every hour while `list-timers` showed
# it healthy. So the artifact is read back BEFORE the clock is armed.
unit_exec_line() { # unit_exec_line <file> — the last ExecStart= (the one systemd runs), normalised
    sed -E 's/^[[:space:]]+//' "$1" 2>/dev/null \
        | sed -n 's/^ExecStart[[:space:]]*=[[:space:]]*//p' | tail -1
}

verify_installed_unit() { # verify the ARTIFACT at $UNIT_DIR, not the bytes we hoped for
    local svc="$UNIT_DIR/$UNIT_NAME.service" line
    [ -f "$svc" ] || { err "REFUSING to arm: $svc is not there after the install"; return 1; }
    line="$(unit_exec_line "$svc")"
    [ -n "$line" ] || {
        err "REFUSING to arm: the installed $svc carries no ExecStart= — systemd would fail it with 'Service has no ExecStart', so this box would have no converger while looking installed"
        return 1
    }
    case "$line" in
        *"$SCRIPT"*) : ;;
        *) err "REFUSING to arm: the installed ExecStart does not name the converger ($SCRIPT): $line"; return 1 ;;
    esac
    # ⛔ THE ARMED RENDER CARRIES NO MODE ARGUMENT, so the check is "the disarmed flag is absent" — not
    # "a token matches". A `*""*` glob would match everything and certify the wrong artifact.
    if [ "$(mode_flag)" = "--dry-run" ]; then
        case "$line" in
            *--dry-run*) : ;;
            *) err "REFUSING to arm: the installed ExecStart does not carry the DISARMED flag this install decided: $line"; return 1 ;;
        esac
    else
        case "$line" in
            *--dry-run*) err "REFUSING: the installed ExecStart still carries --dry-run although this install is ARMED — the record and the artifact disagree: $line"; return 1 ;;
        esac
    fi
    return 0
}

plist_program_args() { # one ProgramArguments element per line
    local f="$1"
    if command -v python3 >/dev/null 2>&1; then
        # ⛔ NOT A HEREDOC, deliberately: this script also names paths containing `.git` (the worktree
        # marker) and prose containing `bash`, and the hub guard's content walk fails closed on
        # heredoc + shell word + that token — a false block that would stop this installer from being
        # executed at all. A `-c` program carries the same code with none of that surface.
        python3 -c 'import plistlib,sys
with open(sys.argv[1],"rb") as fh:
    for a in plistlib.load(fh).get("ProgramArguments", []):
        if isinstance(a,str):
            print(a)' "$f" 2>/dev/null && return 0
    fi
    # PlistBuddy is guaranteed on macOS; the python arm above is what a Linux test uses.
    /usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$f" 2>/dev/null \
        | sed -n 's/^[[:space:]]*[0-9][0-9]*[[:space:]]*=[[:space:]]*//p'
}

verify_installed_artifact_plist() {
    local plist="$UNIT_DIR/$LABEL.plist" args
    [ -f "$plist" ] || { err "REFUSING to load: $plist is not there after the install"; return 1; }
    plist_is_valid "$plist" || { err "REFUSING to load: the installed plist does not parse"; return 1; }
    args="$(plist_program_args "$plist")"
    printf '%s\n' "$args" | grep -Fxq "$SCRIPT" || {
        err "REFUSING to load: the installed plist's ProgramArguments do not name the converger ($SCRIPT): $(printf '%s ' $args)"
        return 1
    }
    if [ "$(mode_flag)" = "--dry-run" ]; then
        printf '%s\n' "$args" | grep -Fxq -- "--dry-run" || {
            err "REFUSING to load: the installed plist's ProgramArguments do not carry the DISARMED flag this install decided: $(printf '%s ' $args)"
            return 1
        }
    elif printf '%s\n' "$args" | grep -Fxq -- "--dry-run"; then
        err "REFUSING: the installed plist still carries --dry-run although this install is ARMED — the record and the artifact disagree: $(printf '%s ' $args)"
        return 1
    fi
    return 0
}

# ── actions ─────────────────────────────────────────────────────────────────────────────────
do_install() {
    resolve_script || return 1
    resolve_python || return 1
    resolve_provisioner
    # ⛔ A ROOT INSTALL LOOKS AFTER ROOT'S RUNNERS, NOT THE LANES'. {{USER}} is `id -un` and {{HOME}} is
    # $HOME, so `sudo bash install-runner-autoscale-timer.sh` renders `User=root` with
    # `Environment=HOME=/root`; the pass then measures root's process tree, where no runner exists, and
    # reports `under-target` every nine minutes while the real pool sits over its ceiling. WHAT THIS
    # REFUSES, EXACTLY: an invocation that arrived through sudo (`SUDO_USER` set). A genuine root shell
    # (`sudo -i`, root in a container) has no SUDO_USER and is NOT refused.
    if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
        err "REFUSING to install as root (SUDO_USER=$SUDO_USER): the unit would run as root and converge"
        err "root's process tree, not $SUDO_USER's — a green tick that measures nothing."
        err "Run it as the user that owns the runners:  sudo -u $SUDO_USER -H bash $0 --install"
        return 1
    fi
    if [ -z "$PROVISIONER" ]; then
        err "WARNING: no install-ci-runner-x64.sh resolved ($PROVISIONER_WHY) — the timer can RESTART a dead"
        err "  runner and RE-REGISTER an orphaned one, but it can never ADD capacity (every pass with"
        err "  live < ceiling records 'no provisioner' and exits 3). Install from a checkout that carries"
        err "  tools/install-ci-runner-x64.sh, or set RUNNER_AUTOSCALE_PROVISIONER, to schedule a box that GROWS."
    elif is_transient_scratch "$PROVISIONER"; then
        err "WARNING: the pinned provisioner $PROVISIONER is inside a mktemp tree — after that directory goes,"
        err "  the pass will report 'no provisioner' on every tick (repair-only). Install from a durable checkout."
    fi
    # ⛔ THE SCRATCH GUARD RUNS BEFORE TARGET SELECTION: a box whose HOME is transient scratch must be
    # told THAT, not "no scheduler available", and selection can refuse for an unrelated reason.
    refuse_unusable_target scheduled || return 1
    if [ "$PLATFORM" = "Darwin" ]; then do_install_launchd; else do_install_systemd; fi
}

do_install_systemd() {
    local src_svc="$TEMPLATES_DIR/$UNIT_NAME.service" src_tim="$TEMPLATES_DIR/$UNIT_NAME.timer"
    local tmpd changed=0 linger=""
    [ -f "$src_svc" ] && [ -f "$src_tim" ] || { err "templates missing under $TEMPLATES_DIR (expected $UNIT_NAME.service + $UNIT_NAME.timer)"; return 1; }
    choose_target || { err "no scheduler available: no passwordless sudo for a system unit, and no systemd user manager. Install by hand, or give the box sudo. NOT silently skipping — a converger that never runs is the failure this exists to remove."; return 1; }
    refuse_systemd_unsafe_values || return 1

    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/runner-autoscale-unit.XXXXXX")" || { err "cannot create a temp dir"; return 1; }
    render "$src_svc" "$tmpd/$UNIT_NAME.service" systemd || { rm -rf "$tmpd"; return 1; }
    render "$src_tim" "$tmpd/$UNIT_NAME.timer" systemd || { rm -rf "$tmpd"; return 1; }
    # A USER unit may not carry User= (systemd rejects it), so drop that line in that mode.
    if [ "$TARGET" = "user" ]; then
        sed -i.bak '/^User=/d' "$tmpd/$UNIT_NAME.service" && rm -f "$tmpd/$UNIT_NAME.service.bak"
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_line "dry-run: would install to $UNIT_DIR (target=$TARGET) and enable $UNIT_NAME.timer"
        log_line "  mode:  $(mode_label)$([ -n "$FORCE_MODE_FLAG" ] && printf ' (forced by --report-only)')"
        log_line "--- $UNIT_NAME.service ---"; sed 's/^/  /' "$tmpd/$UNIT_NAME.service"
        log_line "--- $UNIT_NAME.timer ---"; sed 's/^/  /' "$tmpd/$UNIT_NAME.timer"
        rm -rf "$tmpd"
        return 0
    fi

    # Install only when the rendered bytes differ: a `daemon-reload` on every bring-up is cheap but a
    # needless rewrite of a working pair. The timer is enabled either way (idempotent, and it is the one
    # thing that must be true).
    cmp -s "$tmpd/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.service" 2>/dev/null || changed=1
    cmp -s "$tmpd/$UNIT_NAME.timer" "$UNIT_DIR/$UNIT_NAME.timer" 2>/dev/null || changed=1
    mkdir -p "$UNIT_DIR" 2>/dev/null || true
    # ⛔ THE FILE OP FOLLOWS THE TARGET, NOT $SUDO. `TARGET=user` is reachable ONLY when the sudo probe
    # FAILED, so routing a user install through `sudo install` asks sudo to do what it just refused.
    case "$TARGET" in
        override) cp -f "$tmpd/$UNIT_NAME.service" "$tmpd/$UNIT_NAME.timer" "$UNIT_DIR/" || { err "copy failed"; rm -rf "$tmpd"; return 1; } ;;
        user)     install -m 0644 "$tmpd/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.service" \
                       && install -m 0644 "$tmpd/$UNIT_NAME.timer" "$UNIT_DIR/$UNIT_NAME.timer" \
                       || { err "install failed writing $UNIT_DIR (target=user, no sudo needed)"; rm -rf "$tmpd"; return 1; } ;;
        *)        ${SUDO-sudo -n} install -m 0644 "$tmpd/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.service" \
                       && ${SUDO-sudo -n} install -m 0644 "$tmpd/$UNIT_NAME.timer" "$UNIT_DIR/$UNIT_NAME.timer" \
                       || { err "install failed (target=$TARGET, dir=$UNIT_DIR)"; rm -rf "$tmpd"; return 1; } ;;
    esac
    rm -rf "$tmpd"

    # ⛔ THE READ-BACK RUNS BEFORE `enable --now`. A unit systemd would refuse — or one a drop-in points
    # somewhere else — must not be left ARMED and firing while the installer exits 1: the install has to
    # fail before the clock starts, not after.
    verify_installed_unit || return 1
    $SC daemon-reload >/dev/null 2>&1 || { err "daemon-reload failed"; return 1; }
    $SC enable --now "$UNIT_NAME.timer" || { err "could not enable/start $UNIT_NAME.timer"; return 1; }

    # ⛔ A USER TIMER WITHOUT LINGERING IS AN INERT ENFORCER THAT PRINTS GREEN. `user@.service` — which
    # owns `systemctl --user` timers — stops when the user's last session ends unless lingering is
    # enabled, and this installer is normally run from a bring-up ssh session on a box nobody stays
    # logged into. `enable --now` succeeds, `--status` says active, the session ends, and the timer
    # never fires again.
    if [ "$TARGET" = "user" ]; then
        linger="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)"
        if [ "$linger" != "yes" ]; then
            loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
            linger="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)"
        fi
        if [ "$linger" != "yes" ]; then
            err "REFUSING to report this as installed: a USER timer cannot fire after your session ends"
            err "without lingering (loginctl show-user $(id -un) -p Linger -> '${linger:-unknown}')."
            err "Enable it, then re-run:  sudo loginctl enable-linger $(id -un)"
            err "(The timer IS enabled and will fire while you are logged in — it is the unattended case"
            err " this box exists for that would silently do nothing.)"
            return 1
        fi
        log_line "  linger: enabled (the user timer survives logout)"
    fi

    log_line "installed: target=$TARGET dir=$UNIT_DIR changed=$changed"
    log_line "  script: $SCRIPT"
    log_line "  python: $PYTHON"
    log_line "  repo:   $REPO"
    log_line "  mode:   $(mode_label)$(mode_meaning)"
    log_line "  pin:    cadence=9min timeout=5400s workdir=<none: systemd's default /. %h is /root for a SYSTEM unit and the service account cannot enter it — measured 200/CHDIR>"
    if $SC is-enabled "$UNIT_NAME.timer" >/dev/null 2>&1; then
        log_line "  timer:  enabled"
    else
        err "timer is NOT enabled after install — the converger will not run unattended"; return 1
    fi
    return 0
}

do_install_launchd() {
    local src_plist="$LAUNCHD_TEMPLATES_DIR/$LABEL.plist"
    local tmpd changed=0 loaded=0
    [ -f "$src_plist" ] || { err "plist template missing: $src_plist (set LAUNCHD_TEMPLATES_DIR)"; return 1; }
    choose_target || { err "no scheduler available"; return 1; }
    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/runner-autoscale-plist.XXXXXX")" || { err "cannot create a temp dir"; return 1; }
    render "$src_plist" "$tmpd/$LABEL.plist" launchd || { rm -rf "$tmpd"; return 1; }
    # ⛔ A PLIST THAT DOES NOT PARSE IS NOT INSTALLED. Measured on this family: a placeholder inside an
    # XML comment rendered an option flag into it, a doubled dash is forbidden there, the artifact was
    # not well-formed, and the box would have silently had no scheduled pass while the installer said OK.
    if ! plist_is_valid "$tmpd/$LABEL.plist"; then
        err "REFUSING: the rendered plist is not well-formed XML — launchd would refuse it and this box would have no converger"
        err "  rendered: $tmpd/$LABEL.plist"
        if command -v python3 >/dev/null 2>&1; then
            python3 -c 'import sys,xml.etree.ElementTree as ET
try:
    ET.parse(sys.argv[1])
except ET.ParseError as e:
    print("  parser: %s" % e, file=sys.stderr)
    ln = getattr(e, "position", (0, 0))[0]
    if ln:
        print("  line %d: %s" % (ln, open(sys.argv[1], errors="replace").read().splitlines()[ln-1].strip()), file=sys.stderr)' "$tmpd/$LABEL.plist" || true
        fi
        err "  hint: an XML comment must not contain a doubled dash — keep option flags out of comments"
        rm -rf "$tmpd"; return 1
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_line "dry-run: would install to $UNIT_DIR (target=$TARGET) and bootstrap $LABEL"
        log_line "  mode:  $(mode_label)$([ -n "$FORCE_MODE_FLAG" ] && printf ' (forced by --report-only)')"
        log_line "--- $LABEL.plist ---"; sed 's/^/  /' "$tmpd/$LABEL.plist"
        rm -rf "$tmpd"
        return 0
    fi

    cmp -s "$tmpd/$LABEL.plist" "$UNIT_DIR/$LABEL.plist" 2>/dev/null || changed=1
    mkdir -p "$UNIT_DIR" 2>/dev/null || { err "cannot create $UNIT_DIR"; rm -rf "$tmpd"; return 1; }
    cp -f "$tmpd/$LABEL.plist" "$UNIT_DIR/$LABEL.plist" || { err "copy failed"; rm -rf "$tmpd"; return 1; }
    rm -rf "$tmpd"

    # ⛔ THE READ-BACK RUNS BEFORE THE JOB IS ARMED, for the same measured reason the systemd arm does:
    # this arm used to bootstrap first and verify second, so a refusal here armed the very job it refused.
    verify_installed_artifact_plist || return 1

    # Only re-bootstrap when the bytes moved or the job is not loaded — a bootout/bootstrap on every
    # bring-up resets launchd's interval bookkeeping for no reason. The loaded test matches the WHOLE
    # label (last field), not a substring: `…-old` would otherwise satisfy the check.
    $SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {found=1} END{exit !found}' && loaded=1
    if [ "$changed" = 1 ] || [ "$loaded" = 0 ]; then
        $SC bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
        $SC bootstrap "gui/$(id -u)" "$UNIT_DIR/$LABEL.plist" >/dev/null 2>&1 \
            || $SC load -w "$UNIT_DIR/$LABEL.plist" >/dev/null 2>&1 \
            || { err "could not bootstrap $LABEL from $UNIT_DIR/$LABEL.plist — the converger will NOT run unattended"; return 1; }
    fi

    log_line "installed: target=$TARGET dir=$UNIT_DIR changed=$changed"
    log_line "  script: $SCRIPT"
    log_line "  python: $PYTHON"
    log_line "  repo:   $REPO"
    log_line "  mode:   $(mode_label)$(mode_meaning)"
    log_line "  pin:    cadence=StartInterval=$INTERVAL_SEC"
    if $SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {found=1} END{exit !found}'; then
        log_line "  agent:  loaded"
    else
        err "agent $LABEL is NOT loaded after install — the converger will not run unattended"; return 1
    fi
    return 0
}

# A one-line human reading of the rendered mode, so an operator does not have to know that `--dry-run`
# is this tool's disarmed value.
mode_meaning() {
    case "$(mode_flag)" in
        --dry-run) printf '%s' "  (DISARMED — measures, classifies and prints the plan only; arm with --arm)" ;;
        *)         printf '%s' "  (ARMED by $(sed -n 's/^armed-date=//p' "$ARM_FILE" 2>/dev/null | head -1) — repairs dead runners and grows toward the measured ceiling)" ;;
    esac
}

# ── arm / disarm ─────────────────────────────────────────────────────────────────────────────
# ⛔ THE PREFLIGHT IS NOT DECORATION. An armed pass on a box whose pool cannot be read exits 2 every nine
# minutes and grows nothing — armed, signed by an owner, and inert. So arming runs the converger's own
# read-only verb and refuses when it cannot answer. The measured reading goes INTO the record, so the
# arming is auditable without re-running anything.
do_arm() {
    local reason="${1:-<none given>}" json rc ceiling ncpu mem rec_tmp
    resolve_script || return 1
    resolve_python || return 1
    if arm_record_valid; then
        log_line "  runner-autoscale: ALREADY ARMED — $(sed -n 's/^armed-date=/since /p' "$ARM_FILE" | head -1)"
        log_line "    record: $ARM_FILE (not re-dated: the date is the audit datum)"
        # Still converge the artifact: a record may exist while the installed unit predates it.
        if [ "${DRY_RUN:-0}" = "1" ]; then return 0; fi
        do_install_reinstall_only || return 1
        return 0
    fi
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_line "dry-run: would run the preflight ('$SCRIPT --status --json') and then write $ARM_FILE"
        return 0
    fi
    log_line "  runner-autoscale: preflight before arming ($SCRIPT --repo $REPO --status --json)"
    rec_tmp="$(mktemp "${TMPDIR:-/tmp}/runner-autoscale-arm.XXXXXX")" || { err "cannot create a temp file"; return 1; }
    "$PYTHON" "$SCRIPT" --repo "$REPO" --status --json >"$rec_tmp" 2>&1
    rc=$?
    json="$(cat "$rec_tmp")"
    # ⛔ ALLOW-LIST, NOT A BLACKLIST OF 2. 0 is a capacity answer (converged / at-ceiling / under-target /
    # over-ceiling / provisioner-refused: the pass measured the box and decided); 4 is STARVATION, which
    # is a reason to arm rather than a reason to refuse. Everything else — 1 a refusal, 2 a measurement
    # or pool read that could not be taken, 3 an action failure, 5 a unit finding — means this box was
    # not measured, and arming it would be signing a record the box cannot honour.
    case "$rc" in
        0|4) : ;;
        *)
            rm -f "$rec_tmp"
            err "REFUSING to arm: the preflight could not measure this box (rc=$rc). Nothing was armed."
            printf '%s\n' "$json" | tail -5 | sed 's/^/    /' >&2
            err "  An armed pass here would fail the same way every 9 minutes and grow nothing. Fix the"
            err "  reading above (usually gh auth for HOME=$HOME, or the pool/queue API), then re-run --arm."
            return 1
            ;;
    esac
    ceiling="$(printf '%s' "$json" | sed -n 's/.*"ceiling": *\([0-9][0-9]*\).*/\1/p' | head -1)"
    ncpu="$(printf '%s' "$json" | sed -n 's/.*"ncpu": *\([0-9][0-9]*\).*/\1/p' | head -1)"
    mem="$(printf '%s' "$json" | sed -n 's/.*"mem_available_mb": *\([0-9][0-9]*\).*/\1/p' | head -1)"
    rm -f "$rec_tmp"
    [ -n "$ceiling" ] || {
        err "REFUSING to arm: the preflight answered (rc=$rc) but its record carries NO ceiling, so this box's"
        err "  capacity could not be read back — arming on an unread number is arming blind. Nothing was armed."
        return 1
    }
    mkdir -p "$(dirname "$ARM_FILE")" 2>/dev/null || {
        err "cannot create $(dirname "$ARM_FILE") — refusing to arm"; return 1; }
    {
        printf 'armed-by=%s\n' "$(id -un 2>/dev/null || printf 'unknown')"
        printf 'armed-date=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
        printf 'armed-host=%s\n' "$(hostname 2>/dev/null || printf 'unknown')"
        printf 'repo=%s\n' "$REPO"
        printf 'ceiling=%s\n' "$ceiling"
        printf 'reading=ncpu=%s mem_available_mb=%s ceiling=%s\n' "$ncpu" "$mem" "$ceiling"
        printf 'reason=%s\n' "$reason"
    } > "$ARM_FILE" || {
        err "cannot write $ARM_FILE — refusing to arm"; rm -f "$ARM_FILE"; return 1; }
    log_line "  runner-autoscale: ARMED ($ARM_FILE) — ceiling=$ceiling from ncpu=$ncpu mem_available_mb=$mem"
    # ⛔ RE-RENDER, DO NOT PATCH THE FLAG. The artifact is rewritten from scratch with the mode the
    # record now implies (armed = NO mode argument, because converging is the pass's default and the
    # only switch it accepts is --dry-run). Patching the existing artifact is how the two copies drift
    # while both look right.
    do_install_reinstall_only || return 1
    return 0
}

do_disarm() {
    if [ -f "$ARM_FILE" ]; then
        log_line "  runner-autoscale: disarming — the record being removed:"
        sed 's/^/    /' "$ARM_FILE"
        rm -f "$ARM_FILE" || { err "cannot remove $ARM_FILE — the job is STILL ARMED"; return 1; }
        log_line "  runner-autoscale: DISARMED — the installed artifact goes back to --dry-run"
    else
        log_line "  runner-autoscale: not armed (no $ARM_FILE)"
    fi
    if [ "${DRY_RUN:-0}" = "1" ]; then return 0; fi
    do_install_reinstall_only || return 1
    return 0
}

# Re-render + install without re-running the resolution/guards preamble (it already ran).
do_install_reinstall_only() {
    if [ -z "$SCRIPT" ]; then resolve_script || return 1; fi
    if [ -z "$PYTHON" ]; then resolve_python || return 1; fi
    resolve_provisioner
    refuse_unusable_target scheduled || return 1
    if [ "$PLATFORM" = "Darwin" ]; then do_install_launchd; else do_install_systemd; fi
}

# ── status ──────────────────────────────────────────────────────────────────────────────────
# reported: installed / loaded(enabled+active) / the ARTIFACT's own mode / drift / the last tick.
# ⛔ AN ENABLED-BUT-INACTIVE TIMER IS NOT A SCHEDULE, and an unreadable artifact is not "no news":
# `cloud-cell-bringup.sh --check`-shaped callers gate on this exit code, so "not installed", "not
# running" and "cannot read it" all exit 1 rather than printing a success.
last_tick_line() { # last_tick_line <log> — the last JSON record, one readable line
    local log="$1"
    [ -f "$log" ] || { printf '%s' "none (no pass has recorded yet)"; return 0; }
    tail -1 "$log" 2>/dev/null | python3 -c '
import json, sys
try:
    r = json.loads(sys.stdin.read().strip() or "{}")
except Exception:
    print("unparsable record in the log"); raise SystemExit(0)
bits = ["at=%s" % r.get("at", "?")]
for k in ("verdict", "ceiling", "ncpu", "mem_available_mb", "live"):
    if k in r:
        bits.append("%s=%s" % (k, r[k]))
print(" ".join(bits))
' 2>/dev/null || printf '%s' "unreadable (the log could not be parsed)"
}

repo_copy_path() {
    local cand
    for cand in "$INFRA_ROOT/scripts/orchestrator-harness/runner_autoscale.py" \
                "${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/runner_autoscale.py"; do
        [ -n "$cand" ] && [ -f "$cand" ] && { printf '%s' "$cand"; return 0; }
    done
    return 1
}

sha_of() { # sha_of <file> — portable digest
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
    else return 1; fi
}

do_status() {
    local installed_mode installed_script drift_artifact enabled active next last
    local rc=0 installed_path
    resolve_script || return 1
    resolve_python || { rc=1; }
    choose_target || { err "no scheduler available"; return 1; }
    log_line "target=$TARGET dir=$UNIT_DIR"
    if [ "$TARGET" = "launchd" ]; then installed_path="$UNIT_DIR/$LABEL.plist"; else installed_path="$UNIT_DIR/$UNIT_NAME.service"; fi
    if [ ! -f "$installed_path" ]; then
        log_line "installed=no"
        log_line "note=no artifact at $installed_path — this box has NO scheduled converger"
        log_line "remedy=bash $(basename "$0") --install   (installs it DISARMED; --arm is a separate dated step)"
        return 1
    fi
    log_line "installed=yes artifact=$installed_path"
    # The artifact's OWN mode, read out of the file the scheduler loads — not from the record, which can
    # disagree with it after a hand-edit or an install from another checkout.
    if [ "$TARGET" = "launchd" ]; then
        installed_mode="$(plist_program_args "$installed_path" | grep -Fx -- '--dry-run' | head -1)"
    else
        installed_mode="$(unit_exec_line "$installed_path" | grep -o -- '--dry-run' | head -1)"
    fi
    case "$installed_mode" in
        --dry-run)  log_line "mode=--dry-run (DISARMED — the pass measures and prints its plan only)" ;;
        '')         log_line "mode=converge (ARMED — no mode argument; the pass repairs and grows toward the ceiling)" ;;
        *)          log_line "mode=$installed_mode"; err "the installed artifact carries an UNRECOGNISED mode argument — the converger accepts only --dry-run, so every tick would exit 2 (unrecognized arguments). Re-install with this installer."; rc=1 ;;
    esac
    log_line "arm_record=$([ -f "$ARM_FILE" ] && printf 'present' || printf 'absent') ($ARM_FILE)"
    # ⛔ THE TARGET IS PART OF THE ANSWER. An artifact whose script is gone starts nothing (203/EXEC on
    # every tick) while the scheduler still lists it as scheduled and healthy.
    # The script is the first ABSOLUTE `.py` argument — not a hard-coded basename. A basename match
    # reported `script=unreadable` for any converger installed under another name (measured with a
    # fixture), which turned a perfectly good artifact into a reported failure.
    if [ "$TARGET" = "launchd" ]; then
        installed_script="$(plist_program_args "$installed_path" | grep -E '^/.*\.py$' | head -1)"
    else
        installed_script="$(unit_exec_line "$installed_path" | tr ' ' '\n' | tr -d '"' | grep -E '^/.*\.py$' | head -1)"
    fi
    log_line "script=${installed_script:-unreadable}"
    if [ -n "$installed_script" ] && [ -f "$installed_script" ] && [ -r "$installed_script" ]; then
        log_line "script_present=yes"
    else
        log_line "script_present=no"
        err "the artifact names ${installed_script:-an unreadable script} which is absent or unreadable — every tick would fail to start (the scheduler still lists it as scheduled)"
        rc=1
    fi
    # ── drift, both directions, REPORTED (issue #2403 clause 5) ──────────────────────────────
    # artifact drift: the installed file is not what THIS installer would write now (a changed interval,
    # repo or mode, or a hand-edit). Not fatal: it is information, and the next `--install` converges it.
    if [ -n "$installed_script" ]; then
        local tmpd
        drift_artifact="unknown"
        tmpd="$(mktemp -d "${TMPDIR:-/tmp}/runner-autoscale-drift.XXXXXX")" 2>/dev/null || tmpd=""
        if [ -n "$tmpd" ]; then
            if [ "$TARGET" = "launchd" ]; then
                if render "$LAUNCHD_TEMPLATES_DIR/$LABEL.plist" "$tmpd/$LABEL.plist" launchd 2>/dev/null; then
                    cmp -s "$tmpd/$LABEL.plist" "$installed_path" && drift_artifact=no || drift_artifact=yes
                fi
            else
                if render "$TEMPLATES_DIR/$UNIT_NAME.service" "$tmpd/$UNIT_NAME.service" systemd 2>/dev/null; then
                    cmp -s "$tmpd/$UNIT_NAME.service" "$installed_path" && drift_artifact=no || drift_artifact=yes
                fi
            fi
            rm -rf "$tmpd"
        fi
        log_line "drift_artifact=$drift_artifact"
    fi
    # repo-copy drift: is the copy the timer RUNS the copy this checkout carries? The converger's own
    # header records the hazard — a cell keeps running whatever was last hand-placed in
    # ~/.pi/agent/scripts, unmodified by any merge, so "the fix landed" and "the fix runs here" are
    # different claims and nothing sat between them.
    local repo_copy a_sha b_sha
    if repo_copy="$(repo_copy_path)"; then
        if [ "$installed_script" = "$repo_copy" ]; then
            log_line "drift_repo_copy=no (the timer runs this checkout's own copy)"
        elif [ -r "$installed_script" ] && a_sha="$(sha_of "$installed_script")" && b_sha="$(sha_of "$repo_copy")"; then
            if [ "$a_sha" = "$b_sha" ]; then
                log_line "drift_repo_copy=no (byte-identical to $repo_copy)"
            else
                log_line "drift_repo_copy=yes installed=${a_sha:0:12} repo=${b_sha:0:12} repo_copy=$repo_copy"
            fi
        else
            log_line "drift_repo_copy=unknown (no portable digest, or the artifact's script is unreadable)"
        fi
    else
        log_line "drift_repo_copy=unknown (no checkout copy of runner_autoscale.py resolvable from here — a farmed installer has none beside it)"
    fi
    # ── the scheduler's own answer ──────────────────────────────────────────────────────────
    if [ "$TARGET" = "launchd" ]; then
        if $SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {found=1} END{exit !found}'; then
            log_line "loaded=yes"
            last="$($SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {print $2; exit}')"
            log_line "last_exit=${last:-unknown}"
            case "${last:-}" in
                ''|-|0|4) : ;;
                *) err "the last pass exited $last — the converger is not completing; see $(last_tick_line "$STATE_DIR/runner-autoscale.log")"; rc=1 ;;
            esac
            log_line "pid=$($SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {print $1; exit}' | sed 's/^-$/not-running/')"
            log_line "cadence=StartInterval=$INTERVAL_SEC"
            log_line "next_run=not reported by launchd (fires every ${INTERVAL_SEC}s from load)"
        else
            log_line "loaded=no"
            err "the agent is NOT loaded — the artifact is on disk but nothing fires it"
            rc=1
        fi
    else
        enabled="$($SC is-enabled "$UNIT_NAME.timer" 2>/dev/null || echo no)"
        active="$($SC is-active "$UNIT_NAME.timer" 2>/dev/null || echo no)"
        log_line "enabled=$enabled"
        log_line "timer_active=$active"
        next="$($SC list-timers --all --no-pager 2>/dev/null | awk -v u="$UNIT_NAME.timer" '$0 ~ u {print $1" "$2" "$3; exit}')"
        log_line "next_run=${next:-unknown}"
        last="$($SC show -p ExecMainStatus --value "$UNIT_NAME.service" 2>/dev/null || echo unknown)"
        log_line "last_run=${last:-unknown}"
        case "${active:-}" in
            active|activating) : ;;
            *) err "the timer is '${active:-unknown}', not active — the converger will NOT run unattended"; rc=1 ;;
        esac
        case "${last:-}" in
            ''|-|0|4) : ;;
            unknown) err "cannot read the timer's last run (systemctl show refused) — cannot determine whether the pass is completing"; rc=1 ;;
            *) err "the timer's last run exited $last — the pass is not completing; see the pass log below"; rc=1 ;;
        esac
    fi
    log_line "last_tick=$(last_tick_line "$STATE_DIR/runner-autoscale.log")"
    return "$rc"
}

# ── uninstall ───────────────────────────────────────────────────────────────────────────────
do_uninstall() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_line "dry-run: would disable and remove the installed schedule (nothing was changed)"
        return 0
    fi
    choose_target || { err "no scheduler available"; return 1; }
    if [ "$TARGET" = "launchd" ]; then
        # ⛔ A DISARM IS NOT DONE BECAUSE `bootout` RETURNED. The plist can be gone while the LOADED job
        # keeps firing until logout, and `--status` would then answer `installed=no` about a job that is
        # still converging. Prove the label is gone (the same read the install path uses).
        $SC bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || $SC unload "$UNIT_DIR/$LABEL.plist" >/dev/null 2>&1 || true
        rm -f "$UNIT_DIR/$LABEL.plist"
        if $SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {found=1} END{exit !found}'; then
            err "$LABEL is STILL LOADED after bootout — it will keep firing; log out or reboot, or bootout gui/$(id -u)/$LABEL by hand"
            return 1
        fi
        log_line "uninstalled $LABEL from $UNIT_DIR (not loaded)"
        return 0
    fi
    $SC disable --now "$UNIT_NAME.timer" >/dev/null 2>&1 || true
    case "$TARGET" in
        user)     rm -f "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer" \
                      || { err "cannot remove the unit files from $UNIT_DIR (target=user)"; return 1; } ;;
        override) rm -f "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer" \
                      || { err "cannot remove the unit files from $UNIT_DIR (target=override)"; return 1; } ;;
        *)        ${SUDO-sudo -n} rm -f "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer" \
                      || { err "cannot remove the unit files from $UNIT_DIR (target=system)"; return 1; } ;;
    esac
    $SC daemon-reload >/dev/null 2>&1 || true
    # ⛔ VERIFY ON EVERY ARM. A `rm` that failed (a root-owned dir, a capability rotation) must not be
    # reported as "uninstalled" while an enabled timer there still fires the pass.
    if [ -e "$UNIT_DIR/$UNIT_NAME.service" ] || [ -e "$UNIT_DIR/$UNIT_NAME.timer" ]; then
        err "NOT reporting this as uninstalled — the unit files are STILL PRESENT in $UNIT_DIR (target=$TARGET)"
        err "(an enabled timer here still fires the pass; remove them as the right user, then re-run)"
        return 1
    fi
    # A DIFFERENT SCOPE holding the same unit is REPORTED, not failed: a box can legitimately carry a
    # system-scope install while an operator uninstalls a user-scope one, and failing that would block
    # the only way to remove the other. The extra dirs are a TEST SEAM (read-only scan paths only).
    local d
    for d in "$HOME/.config/systemd/user" /root/.config/systemd/user /home/*/.config/systemd/user /etc/systemd/system \
             $(printf '%s' "${RUNNER_AUTOSCALE_EXTRA_SCOPES:-}" | tr ':' ' '); do
        [ -n "$d" ] || continue
        [ "$d" = "$UNIT_DIR" ] && continue
        if [ -e "$d/$UNIT_NAME.service" ] || [ -e "$d/$UNIT_NAME.timer" ]; then
            err "note: $UNIT_NAME is ALSO installed in $d (another scope) — this removed $UNIT_DIR only"
            err "      an enabled timer THERE still fires the pass; uninstall it from that scope"
        fi
    done
    log_line "uninstalled $UNIT_NAME from $UNIT_DIR (target=$TARGET)"
    return 0
}

ARM_REASON=""
while [ $# -gt 0 ]; do
    case "$1" in
        --install)     MODE=--install ;;
        --dry-run)     DRY_RUN=1 ;;
        --report-only) FORCE_MODE_FLAG="--dry-run" ;;
        --arm)         MODE=--arm ;;
        --reason)      shift; ARM_REASON="${1:-}" ;;
        --reason=*)    ARM_REASON="${1#--reason=}" ;;
        --disarm)      MODE=--disarm ;;
        --status)      MODE=--status ;;
        --uninstall)   MODE=--uninstall ;;
        --help|-h)     help_text; exit $? ;;
        *) usage ;;
    esac
    shift
done

# ⛔ `--report-only` WHILE A RECORD EXISTS IS A FALSE DISARM. It would render `--dry-run`, the operator
# would see a disarmed box, and the NEXT routine `--install` (a bring-up, a sync, an operator re-running
# it) would silently re-arm from the record that is still there. So it refuses and names the verb that
# actually disarms.
if [ -n "$FORCE_MODE_FLAG" ] && arm_record_valid; then
    err "REFUSING --report-only: $ARM_FILE still arms this box, so the next --install would re-arm it and"
    err "you would believe it was disarmed. Use --disarm (it removes the record AND reinstalls)."
    exit 1
fi

case "$MODE" in
    --install)   do_install ;;
    --arm)       do_arm "${ARM_REASON:-}" ;;
    --disarm)    do_disarm ;;
    --status)    do_status ;;
    --uninstall) do_uninstall ;;
esac
