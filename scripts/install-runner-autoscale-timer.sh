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
#   SYSTEMCTL / LAUNCHCTL / LOGINCTL / SUDO  the tools to call / probe (tests: shims)
#   RUNNER_AUTOSCALE_EXTRA_SCOPES  colon-separated EXTRA dirs scanned by `--uninstall`'s "another
#                              scope" note (TEST SEAM: read-only scan paths only; production sets
#                              nothing)
#   RUNNER_AUTOSCALE_SCOPE_SCAN  colon-separated scan list that REPLACES the other-scope defaults
#                              (TEST SEAM, used by `--install`/`--arm`/`--uninstall`; production sets
#                              nothing, so the real scopes are what gets scanned)
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
    n="$(awk '/^set -uo pipefail/ {print NR; exit}' "$0" 2>/dev/null)"
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
# xml_escape_only <text> — the XML-metacharacter half of `xml_sed_repl`, and NOT the sed half.
# ⛔ USE THIS ONLY WHERE `render` WILL APPLY THE SED LAYER ITSELF. `render` sed-escapes every
# `{{PLACEHOLDER}}` substitution, because the value lands in a sed *replacement*; a producer that ALSO
# sed-escapes is escaped TWICE, and in a replacement `\\&` is a literal backslash followed by `&`. So
# the launchd provisioner pin came out as `/…/inst\\&x.sh` — a path that does not exist — while the
# systemd arm rendered the identical path correctly (measured; the plist still parsed, nothing compared
# the value, and the pass would have found no provisioner and exited 3 on every capacity tick).
# `{{HOME}}`/`{{SCRIPT}}`/… are escaped exactly once by `render` with no producer layer; this helper is
# how the one COMPOSED value stays in that same shape.
xml_escape_only() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# repl_for <systemd|launchd> <value> — the escaper for ONE ARM, because the two artifacts are not the
# same language and the same escaping is therefore not correct for both.
# ⛔ `render` used `xml_sed_repl` — the XML-entity escape PLUS the sed-replacement escape — for every
# placeholder on BOTH arms. The sed half is required on both (the value lands in a `s|…|…|`
# replacement); the XML half is correct only where the value lands in an XML text node, i.e. the plist.
# On the systemd arm it wrote the ENTITY into the unit — `HOME=/home/a&b` rendered
# `Environment=HOME=/home/a&amp;b` — a path that is not the one the installer resolved. How that
# surfaced depended on the placeholder, and the two consequences are different:
#   * a value that reaches `ExecStart=` (SCRIPT, PYTHON) made `verify_installed_unit` compare the
#     rendered command against the real `$SCRIPT` and REFUSE the install — loud, but a false block: a
#     box whose genuine path contains `&` simply could not be installed.
#   * a value that reaches only `Environment=` (PATH, RUNNER_AUTOSCALE_STATE_DIR, and HOME when the
#     checkout lives elsewhere) is compared by NOTHING: `refuse_unusable_target` refuses only a
#     backslash, `refuse_systemd_unsafe_values` refuses only whitespace and `%`, and the drift render
#     is fed the artifact's OWN declared values, so `--status` compares the file to a render of itself
#     and reports `drift_artifact=no`. The unit installs, enables and is listed while the pass is
#     handed a state dir that is not the resolved one — its log and arming record land elsewhere and
#     `--status`, reading the REAL state dir, reports `last_tick=none`.
# The asymmetry is the fix and is asserted in both directions (T48):
# the systemd arm renders the literal value, the plist still entity-escapes it (a raw `&` there is a
# malformed XML document launchd refuses). This also makes the PLACEHOLDER family agree with the
# COMPOSED `{{PROVISIONER_ENV}}` family, which has always been sed-only on systemd (T31 pins it).
repl_for() {
    case "$1" in
        launchd) xml_sed_repl "$2" ;;
        *)       sed_escape_repl "$2" ;;
    esac
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
        main="$(sed -n 's/^gitdir: //p;q' "$gdir")"
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
    # ⛔ A NAMED PIN IS THE WHOLE LIST — the rule resolve_script and resolve_provisioner already
    # follow, and the one this function used to break in the worst direction: a pinned interpreter
    # that failed the version check was SKIPPED and the artifact silently pinned a DIFFERENT one, so
    # an operator who pinned a venv to get a specific `gh`/module set got neither their interpreter
    # nor an error. A pin that cannot be used is a refusal, never a substitution.
    if [ -n "${RUNNER_AUTOSCALE_PYTHON:-}" ]; then
        python_ok "$RUNNER_AUTOSCALE_PYTHON" || {
            err "REFUSING: RUNNER_AUTOSCALE_PYTHON is pinned to '$RUNNER_AUTOSCALE_PYTHON' and it did not pass the >= 3.12 check above — a named pin is the whole list, so it is not silently replaced by another interpreter. Point it at a 3.12+ interpreter, or unset it."
            return 1; }
        PYTHON="$RUNNER_AUTOSCALE_PYTHON"; return 0
    fi
    if [ -n "${ELDATO_LAUNCHER_PY:-}" ]; then
        python_ok "$ELDATO_LAUNCHER_PY" || {
            err "REFUSING: ELDATO_LAUNCHER_PY is pinned to '$ELDATO_LAUNCHER_PY' and it did not pass the >= 3.12 check above — a named pin is the whole list, so it is not silently replaced by another interpreter."
            return 1; }
        PYTHON="$ELDATO_LAUNCHER_PY"; return 0
    fi
    py312="$(type -P python3.12 2>/dev/null)" || py312=""
    py3="$(type -P python3 2>/dev/null)" || py3=""
    for cand in "$py312" \
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
# The FILL half of the pass creates a new install only through tools/install-ci-runner-x64.sh. The unit
# carries NO `WorkingDirectory=` — deliberately, and that is a MEASURED fix (see the service template's
# own note: `%h` is the home of the account running the SERVICE MANAGER, and this unit is normally
# installed into /etc/systemd/system, where the first install of this very pair failed `200/CHDIR`).
# With no directive systemd's cwd is `/`, which kills the pass's `$PWD/tools/…` candidate, so the
# install is the ONE moment the path can be measured (the operator is standing in a checkout that has
# it). ⛔ WARNED, NOT REFUSED: a repair-only schedule is still worth having, and refusing would
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

artifact_path_for_target() { # the single artifact this target installs (the plist, or the .service)
    if [ "$TARGET" = "launchd" ]; then printf '%s' "$UNIT_DIR/$LABEL.plist"
    else printf '%s' "$UNIT_DIR/$UNIT_NAME.service"; fi
}

# artifact_env_value <artifact> <KEY> — one Environment value, as the ARTIFACT declares it.
# ⛔ THIS IS THE ONLY HONEST INPUT FOR A COMPARISON-AFTER-THE-FACT. Every value in the rendered artifact
# is resolved from the environment of the invocation that rendered it (`$PATH`, the interpreter found on
# it, the script under INFRA_ROOT, the provisioner under `$PWD`), so re-deriving them from the READER and
# calling the difference "drift" reports the operator's shell, not the artifact. The artifact is the
# record of what was resolved at install time; this reads it back.
artifact_env_value() { # artifact_env_value <artifact> <KEY>
    local art="$1" key="$2"
    [ -f "$art" ] || return 0
    if [ "$TARGET" = "launchd" ]; then
        if command -v python3 >/dev/null 2>&1; then
            python3 -c 'import plistlib,sys
with open(sys.argv[1],"rb") as fh:
    d = plistlib.load(fh).get("EnvironmentVariables", {})
v = d.get(sys.argv[2], "")
print(v if isinstance(v, str) else "")' "$art" "$key" 2>/dev/null && return 0
        fi
        /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:$key" "$art" 2>/dev/null
        return 0
    fi
    # `Environment="KEY=value"` (both templates quote the assignment) or the unquoted form. The value is
    # everything after the FIRST `=`, so a value that itself contains `=` survives.
    awk -v want="$key" '
        /^[[:space:]]*Environment[[:space:]]*=/ {
            v = $0
            sub(/^[[:space:]]*Environment[[:space:]]*=[[:space:]]*/, "", v)
            if (substr(v, 1, 1) == "\"") v = substr(v, 2)
            if (substr(v, length(v), 1) == "\"") v = substr(v, 1, length(v) - 1)
            k = v; sub(/=.*/, "", k)
            if (k == want) { sub(/^[^=]*=/, "", v); print v; exit }
        }' "$art"
}

# artifact_repo_value <artifact> — the `--repo` value the ARTIFACT's own command line carries.
# ⛔ `--repo` IS NOT AN ENVIRONMENT KEY, SO THE ENV READ-BACK CANNOT SEE IT. Both templates carry the repo
# as a COMMAND-LINE argument (`ExecStart=… --repo "{{REPO}}"` / a `ProgramArguments` element), which is why
# `artifact_env_value … RUNNER_AUTOSCALE_REPO` returned empty on every box: `drift_inputs=repo` was dead
# code, the drift render used the READER's repo, and an untouched artifact on a non-default-repo box
# reported `drift_artifact=yes` on every read — the "a signal that always fires is a signal nobody reads"
# class this block exists to remove. The command line is the record, so the command line is read.
artifact_repo_value() { # artifact_repo_value <artifact>
    local art="$1" line
    [ -f "$art" ] || return 0
    if [ "$TARGET" = "launchd" ]; then
        line="$(plist_program_args "$art")"
    else
        line="$(unit_exec_line "$art" | tr ' ' '\n' | tr -d '"')"
    fi
    printf '%s\n' "$line" | awk 'found { print; exit } $0 == "--repo" { found = 1 }'
}

# note_repo_change — an install must not SILENTLY repoint the pool an installed artifact converges.
# ⛔ MEASURED HARM (the same class as `adopt_installed_provisioner`, one argument over): `--repo` defaults
# to agent-infra's own repo when `RUNNER_AUTOSCALE_REPO` is unset, so a routine `--install` from a shell
# that does not export it rewrites a box converged from a NON-default pool to the default — and the pass
# then grows the wrong pool every 9 minutes, with `changed=1` and exit 0. Unlike the provisioner there is
# no "unresolved" state to fall back on (a default is always resolvable), so this REPORTS rather than
# adopts: the operator may well mean it, and blocking that would be a false block.
note_repo_change() {
    local art declared
    art="$(artifact_path_for_target)"
    [ -f "$art" ] || return 0
    declared="$(artifact_repo_value "$art")"
    [ -n "$declared" ] || return 0
    [ "$declared" = "$REPO" ] && return 0
    err "note: the installed artifact converges repo '$declared' and this invocation resolves '$REPO', so THIS install repoints the capacity pass to '$REPO'."
    err "      If that is not intended, re-run with:  RUNNER_AUTOSCALE_REPO='$declared' $0 $MODE"
    return 0
}

# artifact_is_armed() — does the INSTALLED artifact actually CONVERGE? Used by `--arm`'s failure path,
# which must not keep a dated record over an artifact that does not exist or would measure only.
# ⛔ THE QUESTION IS "IS ANYTHING CONVERGING", NOT "DID THE REPORT SAY SO". The record is the only on-disk
# statement that this box converges, so it is worth keeping exactly when an armed artifact backs it.
artifact_is_armed() {
    local art line args
    art="$(artifact_path_for_target)"
    [ -f "$art" ] || return 1
    if [ "$TARGET" = "launchd" ]; then
        args="$(plist_program_args "$art")"
        args_has_line "$args" "--dry-run" && return 1
        args_has_line "$args" "--status" && return 1
        return 0
    fi
    line="$(unit_exec_line "$art")"
    [ -n "$line" ] || return 1
    case "$line" in *--dry-run*|*--status*) return 1 ;; esac
    return 0
}

# adopt_installed_provisioner — an install that resolves NOTHING must not STRIP a pin the artifact
# already carries.
# ⛔ MEASURED, AND IT DESTROYS THE FILL HALF SILENTLY. `resolve_provisioner` correctly treats a named pin
# as the whole list, but it resolves from THIS invocation's cwd (plus INFRA_ROOT) — and on the boxes this
# exists for the provisioner is found ONLY through `$PWD/tools/…` (agent-infra does not ship it). So a
# routine `--install` from another directory — including the very remedy `--status` prints — re-rendered
# the unit WITHOUT the `RUNNER_AUTOSCALE_PROVISIONER=` line, reported `changed=1` and exit 0 with one
# WARNING line, and the box could never ADD capacity again. The artifact is the record of what was
# resolved at install time, so it is the fallback. A declared path that is NOT a readable file is NOT
# adopted (that would bake in a path that cannot run) — that case keeps the resolve failure.
adopt_installed_provisioner() {
    [ -n "$PROVISIONER" ] && return 0
    local art declared
    art="$(artifact_path_for_target)"
    [ -f "$art" ] || return 0
    declared="$(artifact_env_value "$art" RUNNER_AUTOSCALE_PROVISIONER)"
    [ -n "$declared" ] || return 0
    if [ -f "$declared" ] && [ -r "$declared" ]; then
        PROVISIONER="$declared"; PROVISIONER_WHY="preserved from the installed artifact"
        err "note: no provisioner resolved from THIS directory, so the pin the installed artifact already carries is kept: $declared"
        err "      (a re-install that cannot resolve one must not silently drop the FILL half — the pass could never add capacity again)"
    else
        err "note: the installed artifact pins RUNNER_AUTOSCALE_PROVISIONER=$declared, which is NOT a readable file — not carrying it forward."
    fi
    return 0
}

# adopt_installed_state_dir — the ARMING RECORD and the pass log live where the ARTIFACT declares.
# ⛔ MEASURED HARM, AND IT IS THE SAME CLASS `adopt_installed_provisioner` CLOSES. `STATE_DIR` defaults
# to `$HOME/.pi/agent/state`, and BOTH `ARM_FILE` and the last-tick log are derived from it ONCE, from
# the READER's environment. The artifact, however, EXPORTS the value it was installed with
# (`Environment=RUNNER_AUTOSCALE_STATE_DIR={{STATE_DIR}}`), and the service template states the invariant
# out loud: "Exported so the scheduled pass and an operator's `--status` read ONE path, not two that look
# alike." Two consequences, both reproduced on a fixture — a box installed and armed WITH the seam, then
# read or re-installed by a routine invocation WITHOUT it:
#   * `--status` printed `mode=converge (ARMED)` beside `arm_record=absent (<the reader's dir>)` and
#     `last_tick=none`, while the record and the pass log sat in the directory the artifact declares —
#     the readiness verb telling the operator the OPPOSITE of the truth about the two facts it exists to
#     report. That is the exact contradictory pair the root guard above names, reached by its other
#     route (a routine install, not `sudo`).
#   * an `--install` (a bring-up, a sync) rendered `--dry-run` and SILENTLY DISARMED the box the owner
#     had armed, leaving the dated record orphaned on disk with no line saying so.
# So the artifact is the record of what was resolved here too, exactly as it already is for the
# provisioner pin. An EXPLICIT `RUNNER_AUTOSCALE_STATE_DIR` / `RUNNER_AUTOSCALE_ARM_FILE` from the
# operator still wins: this adopts only what nobody chose on THIS invocation, and says so.
adopt_installed_state_dir() {
    [ -n "${RUNNER_AUTOSCALE_STATE_DIR:-}" ] && return 0
    local art declared was
    art="$(artifact_path_for_target)"
    [ -f "$art" ] || return 0
    declared="$(artifact_env_value "$art" RUNNER_AUTOSCALE_STATE_DIR)"
    [ -n "$declared" ] || return 0
    [ "$declared" = "$STATE_DIR" ] && return 0
    was="$STATE_DIR"
    STATE_DIR="$declared"
    [ -n "${RUNNER_AUTOSCALE_ARM_FILE:-}" ] || ARM_FILE="$STATE_DIR/runner-autoscale.armed"
    err "note: the installed artifact declares RUNNER_AUTOSCALE_STATE_DIR=$declared, which is NOT where this shell would look ($was). Honouring the ARTIFACT: the scheduled pass writes its log and reads the arming record there, so a reader that used the other path would report the opposite of the truth about both. Set RUNNER_AUTOSCALE_STATE_DIR to override."
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
        launchd) printf '%s' "<key>RUNNER_AUTOSCALE_PROVISIONER</key><string>$(xml_escape_only "$PROVISIONER")</string>" ;;
    esac
}

render() { # render <template> <dest> <systemd|launchd>
    local tpl="$1" dest="$2" flavour="$3"
    sed -e "s|{{USER}}|$(repl_for "$flavour" "$(id -un)")|g" \
        -e "s|{{HOME}}|$(repl_for "$flavour" "$HOME")|g" \
        -e "s|{{PATH}}|$(repl_for "$flavour" "$PATH")|g" \
        -e "s|{{STATE_DIR}}|$(repl_for "$flavour" "$STATE_DIR")|g" \
        -e "s|{{PYTHON}}|$(repl_for "$flavour" "$PYTHON")|g" \
        -e "s|{{PY_BIN}}|$(repl_for "$flavour" "$PYTHON")|g" \
        -e "s|{{SCRIPT}}|$(repl_for "$flavour" "$SCRIPT")|g" \
        -e "s|{{REPO}}|$(repl_for "$flavour" "$REPO")|g" \
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
    for v in "SCRIPT=$SCRIPT" "HOME=$HOME" "STATE_DIR=$STATE_DIR" "PYTHON=$PYTHON"; do
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
    # with no `{{` left for the post-render guard to catch. `&`, `|` and `&`/`<`/`>` on a plist are
    # made literal by the escapers (`sed_escape_repl` on the systemd arm, `xml_sed_repl` on launchd —
    # see `repl_for`), so the backslash is the one left that survives escaping and is then re-consumed
    # by the SCHEDULER's own parser: systemd treats a trailing backslash as a line continuation and
    # applies C-style escapes in `Environment=`, so the value the pass sees would not be this one.
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
            # ⛔ `%` IS A SYSTEMD SPECIFIER, TWICE OVER. systemd expands it at load time (`%h`, `%i`,
            # `%n`, and `%%` for a literal), so a rendered path containing one points somewhere the
            # installer never wrote — the SAME false PASS as whitespace, one class over: the unit is
            # installed, enabled, listed and starts NOTHING (203/EXEC), and `--status` cannot see it
            # because it compares the file text, not the expansion. Measured with HOME="…/pc%h":
            # exit 0, ExecStart pointing at a path that expands to /root. A plist <string> is not
            # specifier-expanded, so this rule is systemd-only — refusing it on the Mac would be a
            # false block.
            *%*) err "REFUSING: ${v%%=*} contains '%' — systemd expands it as a specifier at load time (%h, %i, %n), so the rendered path would silently differ from the real one and every tick would fail to start"; return 1 ;;
        esac
    done
    return 0
}

# ── cross-scope scan: ONE pass, ONE schedule ────────────────────────────────────────────────
# other_scope_dirs — candidate unit dirs OTHER than $UNIT_DIR, one per line.
# ⛔ THE LIST IS A SEAM (`RUNNER_AUTOSCALE_SCOPE_SCAN`, ':'-separated) that REPLACES the defaults, so a
# suite can prove the cross-scope report without reading the host's real unit dirs — otherwise the
# suite's verdict would depend on what the box running it happens to have installed. Unset = the real
# scopes. The older `RUNNER_AUTOSCALE_EXTRA_SCOPES` seam is still appended, so it keeps working.
other_scope_dirs() {
    local d
    if [ -n "${RUNNER_AUTOSCALE_SCOPE_SCAN:-}" ]; then
        for d in $(printf '%s' "$RUNNER_AUTOSCALE_SCOPE_SCAN" | tr ':' ' '); do
            [ -n "$d" ] || continue
            [ "$d" = "$UNIT_DIR" ] && continue
            printf '%s\n' "$d"
        done
        return 0
    fi
    for d in "$HOME/.config/systemd/user" /root/.config/systemd/user /home/*/.config/systemd/user \
             /etc/systemd/system \
             $(printf '%s' "${RUNNER_AUTOSCALE_EXTRA_SCOPES:-}" | tr ':' ' '); do
        [ -n "$d" ] || continue
        [ "$d" = "$UNIT_DIR" ] && continue
        printf '%s\n' "$d"
    done
    return 0
}

# report_other_scope_installs <clause> — a LOUD note when ANOTHER scope also carries this unit pair.
# ⛔ THE MUTUAL EXCLUSION THE SERVICE TEMPLATE RELIES ON IS PER-UNIT, NOT PER-ACCOUNT. The unit's own
# comment says "systemd will not start a second instance of an active oneshot, which is the mutual
# exclusion the CLI deliberately keeps no lock for" — true for ONE unit name in ONE scope, and false
# across scopes: a user-scope install plus a system-scope install are two different units, so TWO
# `runner_autoscale.py` passes race to restart and add the same runners. `--uninstall` has always
# scanned for that; the WRITERS did not, and the second install is reachable whenever sudo availability
# changes between invocations (or an operator installs by hand and a bring-up installs again).
# ⛔ SKIPPED under TARGET=override — that target exists only so a suite can pin a temporary unit dir
# (see this file's env header), and the unit under test is not a real installation.
# ⛔ SYSTEMD ONLY. The launchd arm installs to ~/Library/LaunchAgents and this installer models no second
# launchd scope, so scanning systemd's dirs on Darwin would report a scope that cannot fire.
report_other_scope_installs() {
    local d
    [ "$TARGET" = "override" ] && return 0
    [ "$TARGET" = "launchd" ] && return 0
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        if [ -e "$d/$UNIT_NAME.service" ] || [ -e "$d/$UNIT_NAME.timer" ]; then
            err "note: $UNIT_NAME is ALSO installed in $d (another scope) — ${1:-this is a second schedule}"
            err "      that copy fires the SAME pass at the SAME pool, and the per-unit mutual exclusion"
            err "      does not reach across scopes; remove the copy you do not want"
        fi
    done < <(other_scope_dirs)
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
    # ⛔ THE PROBE IS SEAMED TOO, NOT JUST THE VERB. The line below assigns `SC` through
    # `${SYSTEMCTL:-systemctl}` while the PROBE that decides whether to reach it called the BARE binary —
    # two binaries reading one fact, the exact class `--status` was corrected for in this same file. The
    # header documents the seam as "the tools to call / probe (tests: shims)", and a probe that ignores it
    # makes the user target reachable only on a host that happens to OWN a user manager: measured,
    # this branch was a property of the machine running the suite, so the same suite was green on a box
    # without `systemctl` and red on `ubuntu-latest`, which has one.
    if ${SYSTEMCTL:-systemctl} --user show-environment >/dev/null 2>&1; then
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
unit_exec_line() { # unit_exec_line <file> — the LAST ExecStart=, normalised
    sed -E 's/^[[:space:]]+//' "$1" 2>/dev/null \
        | sed -n 's/^ExecStart[[:space:]]*=[[:space:]]*//p' | tail -1
}

# ⛔ `tail -1` ANSWERS ABOUT ONE COMMAND, AND THIS UNIT RUNS ALL OF THEM. The read-back above used to
# carry the comment "the one systemd runs" — true for the default `Type=simple`, and FALSE for the
# `Type=oneshot` this template renders: systemd.service(5) permits SEVERAL `ExecStart=` for oneshot and
# runs them SEQUENTIALLY. So a base file an operator hand-edited to try something (this file IS ordinary
# text, and that is the case the read-back exists for) carrying
#     ExecStart="<interp>" "<script>"        <- what the installer wrote
#     ExecStart="/usr/local/bin/old-converger" <- appended by hand
# read as ARMED from the last line alone, `drift_artifact=yes` was advisory only (rc unchanged), and
# `--status` exited 0 certifying a schedule whose FIRST command is a foreign binary. The drop-in arm
# cannot see this: the multiplicity is in the BASE file, which is exactly the class no reader here could
# reach. Both the arm-time verifier and the readiness verb require exactly one, below.
unit_exec_count() { # how many ExecStart= assignments the BASE file carries (a bare reset counts: it clears the list)
    sed -E 's/^[[:space:]]+//' "$1" 2>/dev/null \
        | sed -n 's/^ExecStart[[:space:]]*=.*/x/p' | wc -l | tr -d ' '
}

unit_dropin_execfiles() { # .conf drop-ins that would override ExecStart, one path per line
    # ⛔ THE BASE FILE IS NOT ALWAYS THE COMMAND. systemd merges `$UNIT.d/*.conf`, and a drop-in carrying
    # `ExecStart=` REPLACES the base one — so every read-back below is otherwise answering about a file
    # the scheduler does not run. This is not hypothetical for this unit: the base ExecStart is the thing
    # an operator would edit to arm by hand.
    # ⛔ PRESENCE, NOT NON-EMPTINESS. A drop-in carrying a bare `ExecStart=` is not "no ExecStart here"
    # — it is the RESET directive: it CLEARS the exec list, and systemd then refuses the unit with
    # "Service has no ExecStart= … Refusing" even though the base file still states one. Testing the
    # value (`unit_exec_line`) missed exactly that, so this installer enabled and ARMED a unit the
    # scheduler would refuse to start.
    local d="$UNIT_DIR/$UNIT_NAME.service.d" f
    [ -d "$d" ] || return 0
    for f in "$d"/*.conf; do
        [ -f "$f" ] || continue
        [ -n "$(sed -n 's/^[[:space:]]*ExecStart[[:space:]]*=.*/x/p' "$f")" ] && printf '%s\n' "$f"
    done
    return 0
}

unit_dropin_timerfiles() { # .conf drop-ins that would override the timer's CADENCE, one path per line
    # ⛔ THE SAME RULE AS `unit_dropin_execfiles`, ONE UNIT OVER. systemd merges `$UNIT.d/*.conf` for EVERY
    # unit type, and the TIMER is where the cadence lives: `OnBootSec=`, `OnUnitActiveSec=`, `OnCalendar=`,
    # `Persistent=` (and `Unit=`, which decides what it fires). So a `$UNIT_NAME.timer.d/*.conf` carrying
    # `OnUnitActiveSec=1h` makes this pass fire hourly with the base artifact untouched — and the drift
    # `cmp` cannot see it, because the base file really IS what this installer would write. Without this
    # arm the readiness verb answered `drift_artifact=no` and exited 0 over exactly the wrong-cadence box
    # the drift comparison exists for: the false PASS would have moved from the base file into a drop-in.
    # ⛔ NAMED KEYS, NOT "any file here". A drop-in in this directory can only affect THIS timer, but one
    # touching `[Unit] Description=` or `[Install] WantedBy=` changes no cadence, and red-ing it would be
    # a false block — the control in the suite pins that.
    local d="$UNIT_DIR/$UNIT_NAME.timer.d" f
    [ -d "$d" ] || return 0
    for f in "$d"/*.conf; do
        [ -f "$f" ] || continue
        # ⛔ EVERY `On*` ELAPSE KEY COUNTS, AND THAT INCLUDES THE ONES WITHOUT A `Sec` SUFFIX. systemd
        # fires a timer at EVERY elapse point it finds, and a drop-in assignment ADDS one (`OnActiveSec=`,
        # `OnStartupSec=`, `OnUnitInactiveSec=`, `OnCalendar=`, `OnClockChange=`, `OnTimezoneChange=` are
        # all independent of `OnBootSec=`/`OnUnitActiveSec=`), so a list of the base template's own keys let
        # `OnActiveSec=1min` fire the pass every minute and still report a clean box. `RandomizedDelaySec=`
        # moves every fire, and `Unit=` decides what it fires.
        # ⛔ `OnCalendar=` IS ITS OWN KEY, NOT AN `…Sec`, so the first version of this list missed it while
        # its comment claimed "EVERY `On*` ELAPSE KEY". A `…timer.d/*.conf` carrying `OnCalendar=hourly`
        # adds an hourly fire, leaves the base timer byte-identical, and both the readiness verb AND the
        # writers certified a 9-minute cadence the box does not have — the same false PASS, the one key
        # the timer template names as a deliberate design property (it carries no `OnCalendar=`).
        # ⛔ AND `Persistent=` IS NOT IN THE LIST: it applies to `OnCalendar=` only, this unit deliberately
        # carries none (see the timer template's own comment), so flagging it would be a false block.
        [ -n "$(sed -n -E 's/^[[:space:]]*(On[A-Za-z]*Sec|OnCalendar|OnClockChange|OnTimezoneChange|RandomizedDelaySec|Unit)[[:space:]]*=.*/x/p' "$f")" ] && printf '%s\n' "$f"
    done
    return 0
}

verify_installed_unit() { # verify the ARTIFACT at $UNIT_DIR, not the bytes we hoped for
    local svc="$UNIT_DIR/$UNIT_NAME.service" line
    [ -f "$svc" ] || { err "REFUSING to arm: $svc is not there after the install"; return 1; }
    local dropins
    dropins="$(unit_dropin_execfiles)"
    [ -z "$dropins" ] || {
        err "REFUSING: this unit has an ExecStart= DROP-IN that overrides what this installer wrote, so the mode verified below is not the mode systemd runs: $(printf '%s ' $dropins). Remove it (or move its content into the unit) and re-install."
        return 1
    }
    # ⛔ THE CADENCE HAS THE SAME DROP-IN ROUTE, AND THIS IS THE PATH THAT CREATES THE SCHEDULE. The
    # `--status` arm alone left the guard unreachable at the moment the box is installed and ARMED: a
    # `…timer.d/*.conf` retuning the interval let `--install` print `cadence=9min` and `--arm` sign a dated
    # record for a box that fires hourly. Same refusal, one unit over.
    dropins="$(unit_dropin_timerfiles)"
    [ -z "$dropins" ] || {
        err "REFUSING: this timer has a DROP-IN that overrides the cadence this installer wrote, so the schedule it would verify is not the schedule systemd runs: $(printf '%s ' $dropins). Remove it (or move its content into the template) and re-install."
        return 1
    }
    # ⛔ EXACTLY ONE, BECAUSE Type=oneshot RUNS THEM ALL (see `unit_exec_count`). Checked before the mode
    # read below, so an armed install over a two-command base cannot verify as armed while two run.
    local exec_count
    exec_count="$(unit_exec_count "$svc")"
    [ "$exec_count" = "1" ] || {
        err "REFUSING to arm: the installed $svc carries $exec_count ExecStart= directives. This unit is Type=oneshot, and systemd runs EVERY ExecStart= of a oneshot unit IN SEQUENCE — so the mode verified here would not be the only mode the scheduler runs. Leave exactly the one ExecStart= this installer renders, then re-install."
        return 1
    }
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
            # ⛔ AND `--status` IS THE SAME STATE BY ANOTHER NAME. The pass builds its run as
            # `dry_run=opts.status or opts.dry_run`, so an armed artifact carrying `--status` measures and
            # repairs nothing on every tick — the `--apply` class, in a word the pass DOES accept.
            *--status*) err "REFUSING: the installed ExecStart carries --status although this install is ARMED. The pass runs with dry_run=opts.status or opts.dry_run, so --status makes every tick MEASURE AND CHANGE NOTHING — the record and the artifact disagree: $line"; return 1 ;;
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

# plist_start_interval — the CADENCE THE PLIST ACTUALLY DECLARES.
# ⛔ `StartInterval` IS WHERE THE LAUNCHD CADENCE LIVES, so it has to be READ BACK, not restated. The
# status arm printed `cadence=StartInterval=$INTERVAL_SEC` — the value this installer WOULD write — and
# derived `next_run=… fires every ${INTERVAL_SEC}s` from the same constant. On a box whose plist had a
# hand-edited or foreign interval (measured: `540` edited to `3600`) the readiness gate printed
# `cadence=StartInterval=540` over an hourly job, in the same output that flagged `drift_artifact=yes`,
# and exited 0. The systemd arm has never had this defect — its `next_run` comes from `list-timers`.
# Same class as T37/T39 ("the timer is where the cadence lives"): report the artifact, not the intent.
plist_start_interval() {
    local f="$1"
    [ -f "$f" ] || return 0
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import plistlib,sys
with open(sys.argv[1],"rb") as fh:
    v = plistlib.load(fh).get("StartInterval")
print(v if isinstance(v,(int,float)) else "")' "$f" 2>/dev/null && return 0
    fi
    /usr/libexec/PlistBuddy -c 'Print :StartInterval' "$f" 2>/dev/null
}

# ⛔ LINE MATCHING WITHOUT A PIPELINE, BECAUSE THE PIPELINE FORM IS A FALSE-BLOCK FACTORY.
# `printf '%s\n' "$args" | grep -Fxq "$x"` looks safe and is not: `grep -q` exits on the FIRST match and
# closes the pipe, the writer dies of SIGPIPE (141), and `set -o pipefail` (line 115) promotes that 141
# over grep's 0 — so a SUCCESSFUL match is reported as a failure. Measured on this box: PIPESTATUS
# (141 0) in 100 of 3000 iterations, i.e. ~3% per call, and the launchd install makes three such calls,
# which is why a correct plist was refused roughly one run in ten. These helpers read a here-string:
# grep is not in the picture and no process of ours can take SIGPIPE.
args_has_line() { # args_has_line <newline-separated values> <exact line>
    # ⛔ PURE BASH: no grep, no pipe, no here-string. Each of those was tried and each is a hazard:
    # the pipeline dies of SIGPIPE when the last stage exits early (measured: 83 of 3000 iterations
    # reported a SUCCESSFUL match as a failure), and a `<<<` here-string is flagged unverifiable by the
    # repo's own working-tree guard, which then refuses to execute the installer at all.
    [[ $'\n'"$1"$'\n' == *$'\n'"$2"$'\n'* ]]
}

args_first() { # args_first <newline-separated values>
    printf '%s' "${1%%$'\n'*}"
}

args_first_matching() { # args_first_matching <newline-separated values> <GLOB pattern>
    local pat="$2" rest="$1" l
    while [ -n "$rest" ]; do
        l="${rest%%$'\n'*}"
        case "$l" in $pat) printf '%s' "$l"; return 0 ;; esac
        case "$rest" in
            *$'\n'*) rest="${rest#*$'\n'}" ;;
            *) rest="" ;;
        esac
    done
    return 0
}

classify_exec_args() { # classify_exec_args <newline-separated args AFTER interpreter/script/repo>
    # ⛔ "NOT --dry-run" IS NOT THE SAME AS "NOT A MODE". The pass's own switches (`--json`, `--want N`,
    # `--root P`) are legitimate and change nothing about whether a tick CONVERGES, so a readiness verb
    # that reds on them reports a working schedule as broken — with a stated consequence ("every tick
    # exits 2") that is simply false. Only arguments outside that vocabulary are red, and anything left
    # over is named, never assumed.
    # ⛔ AND `--status` IS **NOT** ONE OF THE BENIGN ONES — IT IS A MODE, AND IT DOWNGRADES EVERY TICK TO A
    # MEASURE. `runner_autoscale.py` builds the run with `dry_run=opts.status or opts.dry_run`, so a unit
    # whose ExecStart carries `--status` reports and changes nothing, for ever. Classified benign, it left
    # `mode=converge (ARMED)` and exit 0 over exactly the class this PR exists to remove (`--apply`): a
    # schedule that never converges, certified by the verb callers gate on. It is grouped with `--dry-run`
    # because it IS a dry run in every way that matters here.
    local rest="$1" l out="" disarmed=0 skipnext=0 lastflag="" measure=0
    while [ -n "$rest" ]; do
        l="${rest%%$'\n'*}"
        case "$rest" in *$'\n'*) rest="${rest#*$'\n'}" ;; *) rest="" ;; esac
        if [ "$skipnext" = 1 ]; then skipnext=0; continue; fi
        case "$l" in
            '')                : ;;
            --dry-run)         disarmed=1 ;;
            --status)          disarmed=1; measure=1 ;;
            --json)            : ;;
            --want|--root)
                # ⛔ PEEK: a flag after a value-taking flag is a MISSING VALUE, not a value. The pass
                # exits 2 on `--want --json`, so swallowing `--json` as the value made `--status`
                # report ARMED exit 0 for a schedule that fails every tick (the T19 class, narrowed).
                lastflag="$l"
                if [ -z "$rest" ]; then out="$out $l"
                else case "${rest%%$'\n'*}" in
                         ''|-*) out="$out $l" ;;
                         *)     skipnext=1 ;;
                     esac
                fi ;;
            # ⛔ THE INLINE SPELLING IS THE SAME ARGUMENT. argparse accepts `--want=3`, `--root=/opt/x`
            # and `--repo=o/r` exactly as it accepts the space form, so classifying ONLY the space form
            # reported a schedule the pass runs happily as "arguments this installer did not render",
            # with the false consequence "every tick exits 2" — a readiness verb reddening a working
            # unit and handing the operator a remedy (strip the argument) that removes a legitimate
            # switch. `--want=` IS the exit-2 case (the int conversion fails) and `--root=` leaves the
            # pass nothing to measure, so an EMPTY value stays reported; a non-empty one does not.
            # ⛔ AND `--repo=` IS THE SAME RULE, NOT AN EXCEPTION TO IT. An empty slug is not
            # configuration: `--repo=` reaches the pass as the empty string, its pool read becomes
            # `repos//actions/runners` and it exits 2 UNMEASURABLE on every tick (measured at this
            # head: `rc=2`, "gh api repos//actions/runners exited 1: gh: Not Found (HTTP 404)").
            # Dropping it unconditionally certified exactly the state this verb exists to refuse —
            # ARMED exit 0 over a schedule that is RED every nine minutes — so it follows the
            # `--want=`/`--root=` rule: an EMPTY value is reported, a real slug is configuration.
            --want=*|--root=*|--repo=*) [ -n "${l#*=}" ] || out="$out $l" ;;
            *)                 out="$out $l" ;;
        esac
    done
    # ⛔ A VALUE-TAKING SWITCH WITH NO VALUE IS NOT SATISFIED — the pass exits 2 on `--want` alone, so it
    # is an argument this installer did not render, and it must be reported rather than swallowed.
    [ "$skipnext" = 1 ] && out="$out $lastflag"
    out="${out# }"
    if [ -n "$out" ]; then printf 'other:%s' "$out"
    elif [ "$measure" = 1 ]; then printf 'measure'
    elif [ "$disarmed" = 1 ]; then printf 'disarmed'
    else printf 'armed'; fi
}

verify_installed_artifact_plist() {
    local plist="$UNIT_DIR/$LABEL.plist" args
    [ -f "$plist" ] || { err "REFUSING to load: $plist is not there after the install"; return 1; }
    plist_is_valid "$plist" || { err "REFUSING to load: the installed plist does not parse"; return 1; }
    args="$(plist_program_args "$plist")"
    args_has_line "$args" "$SCRIPT" || {
        err "REFUSING to load: the installed plist's ProgramArguments do not name the converger ($SCRIPT): $args"
        return 1
    }
    if [ "$(mode_flag)" = "--dry-run" ]; then
        args_has_line "$args" "--dry-run" || {
            err "REFUSING to load: the installed plist's ProgramArguments do not carry the DISARMED flag this install decided: $args"
            return 1
        }
    elif args_has_line "$args" "--dry-run"; then
        err "REFUSING: the installed plist still carries --dry-run although this install is ARMED — the record and the artifact disagree: $(printf '%s ' $args)"
        return 1
    elif args_has_line "$args" "--status"; then
        # ⛔ THE SAME STATE BY ANOTHER NAME, ON THE OTHER PLATFORM. `dry_run=opts.status or opts.dry_run`
        # is platform-independent, so an armed plist carrying `--status` measures and repairs nothing.
        err "REFUSING: the installed plist carries --status although this install is ARMED. The pass runs with dry_run=opts.status or opts.dry_run, so --status makes every tick MEASURE AND CHANGE NOTHING — the record and the artifact disagree: $(printf '%s ' $args)"
        return 1
    fi
    return 0
}

# ── actions ─────────────────────────────────────────────────────────────────────────────────
# ⛔ A ROOT INVOCATION LOOKS AFTER ROOT'S RUNNERS, NOT THE LANES' — AND IT MUST BE REFUSED BY EVERY
# VERB THAT WRITES, NOT JUST BY --install. {{USER}} is `id -un` and {{HOME}} is $HOME, so
# `sudo bash install-runner-autoscale-timer.sh` renders `User=root` with `Environment=HOME=/root`; the
# pass then measures root's process tree, where no runner exists, and reports `under-target` every nine
# minutes while the real pool sits over its ceiling. It was guarded in do_install ONLY, so
# `sudo … --arm` wrote a dated record in /root AND installed an ARMEd `User=root` unit over the correct
# one (measured: exit 0, "ARMED"), and `sudo … --disarm` reported DISARMED while removing root's record
# and leaving the user's intact. One guard, called from every writer — including the re-render helper,
# so a verb added later cannot miss it.
# WHAT THIS REFUSES, EXACTLY: an invocation that arrived through sudo (`SUDO_USER` set). A genuine root
# shell (`sudo -i`, root in a container) has no SUDO_USER and is NOT refused.
refuse_root_invocation() {
    [ "$(id -u)" = "0" ] || return 0
    [ -n "${SUDO_USER:-}" ] || return 0
    err "REFUSING to run as root (SUDO_USER=$SUDO_USER): the unit would run as root and converge root's"
    err "process tree, not $SUDO_USER's — a green tick that measures nothing, and an arming record in"
    err "/root that $SUDO_USER cannot find."
    err "Run it as the user that owns the runners:  sudo -u $SUDO_USER -H bash $0 $MODE"
    return 1
}

do_install() {
    # ⛔ THE GUARD STAYS ON EVERY WRITER, THIS ONE INCLUDED. It was briefly dropped here while the
    # cross-scope note was added, which would have made `--install` the ONE writer that skipped it:
    # under `sudo` HOME is /root, so the artifact's absolute paths would be the user's while the
    # arming record and last-tick log land in /root. `--reinstall-only` (the arm/disarm re-render)
    # already refused that state, so the two install routes disagreed about it.
    refuse_root_invocation || return 1
    resolve_script || return 1
    resolve_python || return 1
    resolve_provisioner
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
    adopt_installed_state_dir
    refuse_systemd_unsafe_values || return 1
    adopt_installed_provisioner
    note_repo_change

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
        # ⛔ THROUGH THE SEAM, like the reader that gates it. `--status` reads this same fact through
        # `${LOGINCTL:-loginctl}` (see the linger gate below); the install path called the bare binary, so
        # the two readers of one fact resolved it differently under a pinned/seamed loginctl — and on a
        # test host the real `loginctl enable-linger` was invoked instead of the fixture's shim.
        linger="$(${LOGINCTL:-loginctl} show-user "$(id -un)" -p Linger --value 2>/dev/null || true)"
        if [ "$linger" != "yes" ]; then
            ${LOGINCTL:-loginctl} enable-linger "$(id -un)" >/dev/null 2>&1 || true
            linger="$(${LOGINCTL:-loginctl} show-user "$(id -un)" -p Linger --value 2>/dev/null || true)"
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
    # ⛔ THE WRITERS REPORT THE SECOND SCOPE TOO. `--uninstall` has always scanned for a copy in
    # another scope; `--install`, `--arm` and `--disarm` did not, and they are the verbs that CREATE
    # the second copy. The note is advisory (this exits 0), because the box and the operator may
    # legitimately intend both — what must not happen is a second schedule arriving in silence.
    report_other_scope_installs "this installed into $UNIT_DIR"
    return 0
}

do_install_launchd() {
    local src_plist="$LAUNCHD_TEMPLATES_DIR/$LABEL.plist"
    local tmpd changed=0 loaded=0
    [ -f "$src_plist" ] || { err "plist template missing: $src_plist (set LAUNCHD_TEMPLATES_DIR)"; return 1; }
    choose_target || { err "no scheduler available"; return 1; }
    adopt_installed_state_dir
    adopt_installed_provisioner
    note_repo_change
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
        # ⛔ NO `;q` HERE: the record's FIRST line is `armed-by=`, so a quit-on-first-line sed printed an
        # EMPTY date in the one summary that exists to answer "when was this armed?" (measured).
        *)         printf '%s' "  (ARMED by $(sed -n 's/^armed-date=//p' "$ARM_FILE" 2>/dev/null) — repairs dead runners and grows toward the measured ceiling)" ;;
    esac
}

# ── arm / disarm ─────────────────────────────────────────────────────────────────────────────
# ⛔ THE PREFLIGHT IS NOT DECORATION. An armed pass on a box whose pool cannot be read exits 2 every nine
# minutes and grows nothing — armed, signed by an owner, and inert. So arming runs the converger's own
# read-only verb and refuses when it cannot answer. The measured reading goes INTO the record, so the
# arming is auditable without re-running anything.
do_arm() {
    local reason="${1:-<none given>}" json rc ceiling ncpu mem rec_tmp dp
    # ⛔ FIRST STATEMENT, BEFORE THE PREFLIGHT AND BEFORE THE RECORD IS WRITTEN. This verb's first write
    # is the arming record, not the artifact, so a guard that only ran inside the re-render refused the
    # UNIT while leaving an `armed-by=root` record behind — the operator was told the record-in-/root was
    # refused while it was written, and the next `--install` by the real user would then arm from a
    # record that names root. A writer's guard goes ahead of its first write.
    refuse_root_invocation || return 1
    resolve_script || return 1
    resolve_python || return 1
    # ⛔ A DROP-IN OVERRIDE IS A PREFLIGHT FACT, SO IT IS REFUSED BEFORE THE RECORD EXISTS. Verified only
    # inside the re-render, it wrote the record, then failed both renders (the drop-in breaks the armed
    # AND the forced-disarmed verification), which correctly lands in "STILL ARMED — the record was KEPT"
    # for a refusal a retry cannot clear: a record left behind by a refusal of the OPERATOR'S override.
    # ⛔ AND THE PREFLIGHT BELONGS HERE, BEFORE THE RECORD, NOT ONLY INSIDE THE RE-RENDER. Every input
    # `refuse_unusable_target` judges (SCRIPT/HOME/STATE_DIR/PYTHON, and whether any of them is transient
    # scratch) is fixed by THIS invocation — the same test this verb already applied to drop-ins and to the
    # ExecStart multiplicity, for the same reason. Run only from the re-render, a refusal (measured: HOME,
    # SCRIPT and STATE_DIR under a mktemp tree, `SUDO=true`) wrote the dated record first, then failed both
    # renders, and landed in "STILL ARMED — the record was KEPT" for a box with NO artifact at all. The
    # next routine `--install` then armed it from that record: a per-box capacity decision taken silently.
    # Same order as `do_install`, which runs this guard BEFORE target selection so a transient-scratch box
    # is told THAT rather than "no scheduler available".
    refuse_unusable_target scheduled || return 1
    choose_target || { err "no scheduler available: no passwordless sudo for a system unit, and no systemd user manager. NOT silently skipping — a converger that never runs is the failure this exists to remove."; return 1; }
    # ⛔ BEFORE THE RECORD IS READ OR WRITTEN, because the record's location is a fact about the
    # ARTIFACT. Do_arm writes it, and the re-render it triggers reads it; the two must agree or the verb
    # reports the label of one path against the state of the other.
    adopt_installed_state_dir
    if [ "$TARGET" = "system" ] || [ "$TARGET" = "user" ]; then
        # Once the target is known: a value the scheduler would corrupt (`%` specifiers, a stray backslash)
        # is a preflight fact too, and the re-render is where it used to be found.
        refuse_systemd_unsafe_values || return 1
    fi
    if [ "$TARGET" != "launchd" ]; then
        dp="$(unit_dropin_execfiles)"
        [ -z "$dp" ] || {
            err "REFUSING to arm: an ExecStart= DROP-IN overrides the unit this installer manages, so the command it would verify is not the command systemd runs: $(printf '%s ' $dp)"
            err "  Remove that drop-in (or move its content into the unit) and re-run --arm. Nothing was armed."
            return 1
        }
        # The same preflight fact for the CADENCE: a record signed under a drop-in-tuned interval would
        # attest a schedule nothing verified.
        dp="$(unit_dropin_timerfiles)"
        [ -z "$dp" ] || {
            err "REFUSING to arm: a [Timer] DROP-IN overrides the cadence this installer manages, so the schedule it would attest is not the schedule systemd runs: $(printf '%s ' $dp)"
            err "  Remove that drop-in (or move its content into the template) and re-run --arm. Nothing was armed."
            return 1
        }
        # ⛔ AND THE BASE FILE'S MULTIPLICITY, FOR THE SAME REASON: this is a fact about the artifact on
        # disk, so it belongs AHEAD of the first write. Checked only in the post-render verifier it left an
        # arming record behind for a box whose artifact had already been refused — the operator is then
        # 'ARMED' with no working schedule, which is the state this whole installer exists to remove.
        # ⛔ ONLY WHEN AN ARTIFACT EXISTS: `--arm` on a box that was never installed is the legitimate
        # first install (the render creates the file, and the post-render verifier reads it back). A miss
        # here is "nothing to judge yet", which is not the same as "zero commands", and refusing it would
        # break the fresh-box arm path that T16 exercises.
        if [ -f "$UNIT_DIR/$UNIT_NAME.service" ]; then
            dp="$(unit_exec_count "$UNIT_DIR/$UNIT_NAME.service")"
            [ "$dp" = "1" ] || {
                err "REFUSING to arm: the installed unit carries $dp ExecStart= directives. It is Type=oneshot, so systemd runs ALL of them IN SEQUENCE and the mode this would attest is the last command only. Leave exactly one ExecStart= (re-run --install to converge it) and re-run --arm. Nothing was armed."
                return 1
            }
        fi
    fi
    if arm_record_valid; then
        log_line "  runner-autoscale: ALREADY ARMED — $(sed -n 's/^armed-date=/since /p' "$ARM_FILE")"
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
    # ⛔ READ TO EOF, NOT `;q`/`head -1`: an early-exiting reader SIGPIPEs the writer and `pipefail`
    # turns a SUCCESSFUL parse into a failed one (the class that refused correct artifacts elsewhere in
    # this file). `found` makes the awk take the first match without closing the pipe.
    ceiling="$(printf '%s' "$json" | awk '!f && match($0, /"ceiling": *[0-9]+/) { v = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", v); print v; f = 1 }')"
    ncpu="$(printf '%s' "$json" | awk '!f && match($0, /"ncpu": *[0-9]+/) { v = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", v); print v; f = 1 }')"
    mem="$(printf '%s' "$json" | awk '!f && match($0, /"mem_available_mb": *[0-9]+/) { v = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", v); print v; f = 1 }')"
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
    # ⛔ RE-RENDER, DO NOT PATCH THE FLAG. The artifact is rewritten from scratch with the mode the
    # record now implies (armed = NO mode argument, because converging is the pass's default and the
    # only switch it accepts is --dry-run). Patching the existing artifact is how the two copies drift
    # while both look right.
    # ⛔ AND IF THE RE-RENDER FAILS, THE RECORD GOES WITH IT. A record that outlives a failed `--arm`
    # is an armed box the operator was told was not armed: the verb exits 1, the artifact still reads
    # --dry-run, and the NEXT routine `--install` (a bring-up, a sync, setup.sh) re-renders ARMED from
    # that record — silently. That is the same hazard `--report-only` is hardened against, so a failed
    # arm fails CLOSED: drop the record, put the artifact back to disarmed, and say so.
    if ! do_install_reinstall_only; then
        # The ORDER is do_disarm's, and for the same reason: prove the artifact is DISARMED before the
        # record goes. Deleting first (as this used to) can leave an armed artifact with NO record —
        # the one state the design forbids — whenever the forced disarmed render fails too (a full
        # disk, a permission change, a broken template).
        if FORCE_MODE_FLAG="--dry-run" do_install_reinstall_only; then
            rm -f "$ARM_FILE" || {
                err "the artifact is back to --dry-run BUT the record REMAINS ($ARM_FILE) — the next routine --install would arm from it, so this is NOT a clean disarm. Remove it by hand or fix the permissions."
                return 1; }
            err "NOT ARMED: the armed re-render failed, and the artifact is back to --dry-run, so the record was removed — the box is NOT converging"
        else
            # ⛔ THE RECORD IS ONLY DEFENSIBLE IF AN ARMED ARTIFACT ACTUALLY EXISTS. This branch asserted
            # "it is the only on-disk statement that this box is converging" unconditionally — FALSE in the
            # measured case, where the refusal (transient scratch) fired before any artifact was written, so
            # nothing was converging at all and the record existed only to arm the box on the next routine
            # `--install`. Kept when an armed artifact really backs it; dropped otherwise, fail-closed.
            if artifact_is_armed; then
                err "STILL ARMED: the armed re-render failed AND the disarmed re-render failed, so the record was KEPT on purpose — it is the only on-disk statement that this box is converging. Fix the refusal above, then re-run --disarm."
            else
                rm -f "$ARM_FILE" || {
                    err "the artifact is NOT armed but the record REMAINS ($ARM_FILE) — the next routine --install would arm from it. Remove it by hand or fix the permissions."
                    return 1; }
                err "NOT ARMED: the armed re-render failed, the disarmed re-render failed, and the installed artifact is not an armed one — so nothing was converging, and the record was REMOVED. The next routine --install cannot arm this box."
            fi
        fi
        return 1
    fi
    log_line "  runner-autoscale: ARMED ($ARM_FILE) — ceiling=$ceiling from ncpu=$ncpu mem_available_mb=$mem"
    return 0
}

do_disarm() {
    refuse_root_invocation || return 1
    # ⛔ THE RECORD'S LOCATION IS A FACT ABOUT THE ARTIFACT, SO IT IS RESOLVED BEFORE ANY LINE READS IT —
    # including the preview below, which otherwise says "not armed" about a record that exists in the
    # directory the artifact declares. ⛔ BUT A PREVIEW MUST NOT DEPEND ON A SCHEDULER: `choose_target`
    # failing here is not this verb's refusal (the real path refuses through the re-render, with its own
    # message), so it only means "no artifact path to resolve" and the reader's default stands.
    choose_target >/dev/null 2>&1 && adopt_installed_state_dir
    # ⛔ NOTHING IS MUTATED BEFORE A DRY RUN RETURNS, AND NOTHING IS DELETED BEFORE THE ARTIFACT
    # PROVES IT IS DISARMED. Both orders were wrong here once, and the failure is the one state the
    # whole design forbids — an ARMED box with no record on disk:
    #   * `--disarm --dry-run` used to `rm` the record and then return at the DRY_RUN check: the
    #     operator was told DISARMED, the artifact still converged, and the audit datum (armed-by,
    #     armed-date, ceiling, reading, reason) was gone for good.
    #   * a failed re-render deleted the record FIRST, leaving the same state with exit 1.
    # So: preview prints and exits; a real disarm re-renders DISARMED FIRST (forced, so it does not
    # depend on the record being gone), and only a render that the verification step accepted earns
    # the record's removal.
    if [ "${DRY_RUN:-0}" = "1" ]; then
        if [ -f "$ARM_FILE" ]; then
            log_line "  runner-autoscale: dry-run — WOULD disarm; the record being kept:"
            sed 's/^/    /' "$ARM_FILE"
            log_line "  runner-autoscale: dry-run — nothing was changed (no record removed, no artifact rewritten)"
        else
            log_line "  runner-autoscale: dry-run — not armed (no $ARM_FILE); nothing to do"
        fi
        return 0
    fi
    if [ -f "$ARM_FILE" ]; then
        log_line "  runner-autoscale: disarming — re-rendering the artifact DISARMED first; the record being removed:"
        sed 's/^/    /' "$ARM_FILE"
        if ! FORCE_MODE_FLAG="--dry-run" do_install_reinstall_only; then
            err "STILL ARMED: the artifact could not be re-rendered disarmed, so the record was NOT removed — fix the refusal above and re-run"
            return 1
        fi
        rm -f "$ARM_FILE" || { err "cannot remove $ARM_FILE — the artifact IS disarmed but the record remains, so a later --install would re-arm it"; return 1; }
        log_line "  runner-autoscale: DISARMED — the artifact is --dry-run and the record is gone"
        return 0
    fi
    log_line "  runner-autoscale: not armed (no $ARM_FILE) — re-rendering the DISARMED artifact anyway"
    FORCE_MODE_FLAG="--dry-run" do_install_reinstall_only || return 1
    return 0
}

# Re-render + install without re-running the resolution/guards preamble (it already ran).
do_install_reinstall_only() {
    refuse_root_invocation || return 1
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

# refuse_transient_installed_artifact <artifact> — the readiness verb's half of the scratch gate.
# ⛔ `is_transient_scratch` is reachable only from the three WRITING verbs (via `refuse_unusable_target`),
# so an artifact whose declared paths sit in a mktemp tree was refused by `--install`/`--arm` and then
# CERTIFIED by `--status`: the drift render is fed the ARTIFACT's own values, so it compares the file to a
# render of itself, reports `drift_artifact=no`, and exits 0 — green over a unit that exits 127 on every
# tick the moment that tree is removed, i.e. exactly during the window an operator is looking at it.
# Measured: the writer exits 1 with "REFUSING … transient scratch space" on the same paths the reader
# called clean. This is the one-fact-two-readers split T29-T36 closed for `enabled`, `linger`, the
# provisioner pin, `python_ok` and the root guard, so both verbs consult ONE predicate. The writers
# refuse to CREATE this artifact; a hand-edited, foreign or pre-fix one is how the state is actually
# reached, which is when a readiness gate earns its keep.
refuse_transient_installed_artifact() { # rc belongs to the CALLER: return 1 and let it set rc
    local art="$1" bad="" v
    for v in "SCRIPT=${installed_script:-}" \
             "HOME=$(artifact_env_value "$art" HOME)" \
             "STATE_DIR=$(artifact_env_value "$art" RUNNER_AUTOSCALE_STATE_DIR)" \
             "PROVISIONER=$(artifact_env_value "$art" RUNNER_AUTOSCALE_PROVISIONER)"; do
        is_transient_scratch "${v#*=}" && bad="${bad:+$bad; }$v"
    done
    [ -n "$bad" ] || return 0
    err "the installed artifact points into TRANSIENT SCRATCH SPACE: $bad"
    err "That tree is removed before the first tick, so every pass exits 127 while the scheduler lists the"
    err "job as scheduled — the inert-enforcer shape the writing verbs REFUSE TO CREATE. Re-install from"
    err "the box's real HOME (a login shell or cloud-cell-bringup.sh)."
    return 1
}

do_status() {
    local installed_mode installed_script drift_artifact enabled active next last linger
    local installed_args installed_rest installed_kind installed_dropins installed_timer_dropins installed_exec_count
    local drift_service drift_timer
    local rc=0 installed_path
    # ⛔ `--status` IS THE FIFTH READER OF THE SAME RECORD, AND IT WAS THE ONE VERB THAT SKIPPED THIS
    # GUARD. Under `sudo` HOME resolves to /root, so the ARMING RECORD and the pass's LAST-TICK log are
    # read from /root's state dir while the ARTIFACT (whose paths are absolute) is the user's: measured,
    # an armed and ticking box reported `mode=converge (ARMED)` from the artifact next to
    # `arm_record=absent (/root/…)` and `last_tick=none` — the readiness gate telling an operator the
    # opposite of the truth about the two facts it exists to report. This function's own refusal message
    # already names that consequence ("an arming record in /root that $SUDO_USER cannot find").
    refuse_root_invocation || return 1
    resolve_script || return 1
    resolve_python || { rc=1; }
    # ⛔ THE DRIFT RENDER IS ONLY MEANINGFUL IF IT RESOLVES WHAT THE INSTALL PATH RESOLVED. The provisioner
    # is baked into the artifact as a whole line (`{{PROVISIONER_ENV}}`, present in BOTH templates), and
    # `resolve_provisioner` is what decides between a pin and nothing — `do_install` (and
    # `do_install_reinstall_only`) call it, and `--status` did NOT, so `PROVISIONER` stayed empty and the
    # status render emitted `Environment=""` while the installed file carried the resolved pin. On every
    # box that HAS `tools/install-ci-runner-x64.sh` — i.e. exactly the boxes the FILL half exists for — the
    # two files could never match: `--status` printed `drift_artifact=yes` on an untouched artifact and
    # handed out `--install` as the remedy, and that `--install` printed `changed=0` and left the verdict
    # unchanged. A signal that fires always is a signal nobody reads (the class the `User=` arm below was
    # fixed for), and here it was worse than noise: it hid REAL drift on those boxes.
    resolve_provisioner
    choose_target || { err "no scheduler available"; return 1; }
    # ⛔ BEFORE ANYTHING READS THE RECORD OR THE PASS LOG, AND BEFORE THE TARGET LINE BELOW NAMES A
    # DIRECTORY. `--status` reports `arm_record=`, `last_tick=` and the scope scan, and every one of those
    # is a claim about the ARTIFACT's directory, not about this shell's default.
    adopt_installed_state_dir
    log_line "target=$TARGET dir=$UNIT_DIR"
    # The pin is part of what the artifact carries, so the readiness report names it (or says why not).
    log_line "provisioner=${PROVISIONER:-absent} ($PROVISIONER_WHY)"
    # ⛔ THE READINESS VERB WAS THE ONE READER THAT NEVER SCANNED THE SECOND SCOPE, AND IT MADE A
    # BOX-LEVEL CLAIM FROM A SCOPE-LEVEL READ. `choose_target` resolves the scope from SUDO AVAILABILITY
    # AT THIS INVOCATION, so a box installed into /etc/systemd/system by the bring-up answers a later
    # `--status` run where `sudo -n` fails from the USER scope — and printed "installed=no" plus "this box
    # has NO scheduled converger" over a box that IS converging. The remedy it hands out (`--install`) is
    # the one action that creates the duplicate schedule the writers warn about only AFTER creating it.
    # `--install`, `--arm` and `--uninstall` have always scanned; `--status` — the verb an operator runs
    # FIRST and the verb `cloud-cell-bringup.sh --check`-shaped callers gate on — did not. Advisory, not
    # fatal, exactly like the writers: a second scope can be legitimate and removing it is the operator's
    # call. The scan list is the pinned (`RUNNER_AUTOSCALE_SCOPE_SCAN`) seam, and the helper no-ops under
    # TARGET=override and on the launchd arm, so no case reads the host's real unit dirs.
    report_other_scope_installs "both fire the SAME pass at the SAME pool"
    if [ "$TARGET" = "launchd" ]; then installed_path="$UNIT_DIR/$LABEL.plist"; else installed_path="$UNIT_DIR/$UNIT_NAME.service"; fi
    if [ ! -f "$installed_path" ]; then
        log_line "installed=no"
        # ⛔ THE CLAIM IS SCOPED TO WHAT WAS ACTUALLY READ. The scan above can have just named a converger
        # in another scope, so an unscoped "this box has NO scheduled converger" is false on exactly the
        # box this verb is asked about — and the operator would install a SECOND schedule to fix it.
        log_line "note=no artifact at $installed_path — no scheduled converger in THIS scope ($TARGET)"
        log_line "remedy=bash $(basename "$0") --install   (installs it into THIS scope, $TARGET, DISARMED when no arming record exists; --arm is a separate dated step, and an existing record is honoured — run --disarm to revoke it. If the scan above named another scope, remove the copy you do not want FIRST — installing here does not replace it)"
        return 1
    fi
    log_line "installed=yes artifact=$installed_path"
    # The artifact's OWN mode, read out of the file the scheduler loads — not from the record, which can
    # disagree with it after a hand-edit or an install from another checkout.
    # ⛔ THE MODE IS THE WHOLE REMAINDER OF THE COMMAND LINE, NOT A SEARCH FOR ONE LITERAL. This used to
    # grep for `--dry-run` alone, which made the unrecognised-argument arm below UNREACHABLE: an
    # artifact carrying `--apply` (exactly the pi-cell-1 artifact that made every tick exit 2) matched
    # neither `--dry-run` nor anything else, fell into the empty case, and was reported
    # `mode=converge (ARMED)` with exit 0 — a readiness gate keying on this verb called a schedule that
    # fails every tick healthy. Everything after the script argument is now classified.
    if [ "$TARGET" = "launchd" ]; then
        installed_args="$(plist_program_args "$installed_path")"
    else
        installed_args="$(unit_exec_line "$installed_path" | tr ' ' '\n' | tr -d '"')"
        # ⛔ THE MULTIPLICITY IS IN THE BASE FILE, AND Type=oneshot RUNS EVERY ONE OF THEM. The read above
        # answers about the LAST ExecStart=; for this `Type=oneshot` unit that is not "the command systemd
        # runs" but "one of them". A base file a hand-edit left carrying two read as ARMED from the last
        # line, `drift_artifact=yes` is advisory (rc unchanged), and this verb exited 0 over a schedule
        # whose FIRST command was a foreign binary. Reported here, where the mode is certified.
        installed_exec_count="$(unit_exec_count "$installed_path")"
        if [ "$installed_exec_count" != "1" ]; then
            log_line "exec_start_count=$installed_exec_count"
            err "the installed unit carries $installed_exec_count ExecStart= directives. It is Type=oneshot, so systemd runs ALL of them IN SEQUENCE — the mode reported above is the LAST command only, not the whole schedule. Leave exactly the one ExecStart= this installer renders, then re-install."
            rc=1
        fi
    fi
    # Drop the leading interpreter + script, then the `--repo <value>` pair (that is configuration, not
    # a mode), and what remains is the mode the pass is actually invoked with.
    # ⛔ THE INTERPRETER AND SCRIPT ARE DROPPED BY POSITION — up to and including the first `*.py` — NOT
    # by `starts with /`. The old rule deleted ANY absolute token, which deletes the VALUE of a
    # legitimate `--root /opt` (its own default is absolute): the orphaned `--root` then swallowed the
    # NEXT argument, so `--root /opt --apply` classified as ARMED exit 0 (the pass exits 2) and
    # `--root /opt/x --dry-run` classified as ARMED (the unit is disarmed).
    installed_rest="$(printf '%s\n' "$installed_args" | awk '
        { if (NF == 0) next
          if (++pos <= 2) next          # token 1 = interpreter, token 2 = the converger script
          if (skip) { skip = 0; next }
          if ($0 == "--repo") { skip = 1; next }
          print }')"
    installed_kind="$(classify_exec_args "$installed_rest")"
    case "$installed_kind" in
        armed)     log_line "mode=converge (ARMED — no mode argument; the pass repairs and grows toward the ceiling)" ;;
        disarmed)  log_line "mode=--dry-run (DISARMED — the pass measures and prints its plan only)" ;;
        # ⛔ NOT A THIRD FLAVOUR OF DISARMED: this installer NEVER renders `--status` into ExecStart, so an
        # artifact that carries it was hand-edited or foreign — and the pass runs it as
        # `dry_run=opts.status or opts.dry_run`, so the box converges nothing on any tick. Reporting it as
        # ARMED (the old classification, which treated `--status` as a benign switch) was a false PASS on
        # a recognised argument; reporting it as DISARMED would understate it. It is red and it says why.
        measure)   log_line "mode=--status (MEASURE ONLY — never converges)"
                   err "the installed artifact carries --status, which this installer never renders. The pass runs with dry_run=opts.status or opts.dry_run, so EVERY tick measures and changes nothing: this box never repairs a dead runner and never grows toward its ceiling. Re-install with this installer (arm renders no mode argument; disarm renders --dry-run)."
                   rc=1 ;;
        other:*)   installed_mode="${installed_kind#other:}"
                   log_line "mode=$installed_mode"
                   err "the installed artifact carries arguments this installer did not render ('$installed_mode'). The pass accepts --repo, --root <path>, --want <n>, --status, --dry-run, --json, --install-unit, --check-units and --workdir <path>; anything OUTSIDE that set makes every tick exit 2 (unrecognized arguments). Re-install with this installer, or remove those arguments by hand."
                   # ⛔ ONE OF THOSE OUTSIDE-THE-SET CASES IS A RECOGNISED FLAG WITH AN EMPTY VALUE
                   # (`--want=`, `--root=`, `--repo=`), which reaches this arm because the classifier
                   # refuses the empty value rather than the flag — so say THAT, or the operator is told
                   # an argument the pass plainly accepts is unrecognised.
                   case " $installed_mode " in
                       *" --want= "*|*" --root= "*|*" --repo= "*) err "  one of $installed_mode is a recognised switch with an EMPTY value (--want= / --root= / --repo=). argparse accepts the flag and then the pass fails on the value: --want= and --repo= exit 2 on every tick, and --root= leaves the pass nothing to measure. Give it a value or remove the argument." ;;
                   esac
                   # ⛔ AND A RECOGNISED ACTION IS NOT AN UNKNOWN ONE — SAY WHAT IT ACTUALLY DOES. The
                   # switches above are accepted, so the "exit 2" reason is FALSE for them, and their real
                   # consequences are different from each other: --install-unit writes and enables a
                   # COMPETING unit pair and then exits (converging nothing), --check-units audits and
                   # exits 5 on an unusable unit, --workdir only parameterises --install-unit. Folding
                   # them into the unknown-argument text sent the operator hunting a failure that never
                   # appears, and hid the consequence that matters: each tick installs a second unit pair.
                   case " $installed_mode " in
                       *" --install-unit "*) err "  --install-unit: every tick WRITES AND ENABLES this tool's own unit pair instead of converging, and exits — so the pool is never repaired, while a second unit pair competes with the one this installer manages." ;;
                       *" --check-units "*)  err "  --check-units: every tick AUDITS the installed units and exits (5 when one is unusable) instead of converging — a schedule that reports on the pool and never repairs it." ;;
                       *" --workdir "*|*" --workdir="*) err "  --workdir only parameterises --install-unit; on its own it changes no tick and is refused by the pass when it has no value." ;;
                   esac
                   rc=1 ;;
    esac
    # ⛔ AND THE MODE ABOVE IS THE BASE FILE'S. A `$UNIT.d/*.conf` carrying ExecStart= silently replaces
    # it, so the answer above can be `DISARMED` about a unit that is converging.
    if [ "$TARGET" != "launchd" ]; then
        installed_dropins="$(unit_dropin_execfiles | tr '\n' ' ')"
        installed_dropins="${installed_dropins% }"
        if [ -n "$installed_dropins" ]; then
            log_line "dropin_override=$installed_dropins"
            err "an ExecStart= DROP-IN overrides this unit's command, so the mode reported above is NOT what systemd runs: $installed_dropins — read it (systemctl cat $UNIT_NAME.service) and re-install once it is gone"
            rc=1
        fi
        # ⛔ THE CADENCE HAS A DROP-IN ROUTE TOO, and the drift `cmp` cannot see it: a timer drop-in leaves
        # the base artifact byte-identical to what this installer would write while changing when it fires.
        installed_timer_dropins="$(unit_dropin_timerfiles | tr '\n' ' ')"
        installed_timer_dropins="${installed_timer_dropins% }"
        if [ -n "$installed_timer_dropins" ]; then
            log_line "timer_dropin=$installed_timer_dropins"
            err "a [Timer] DROP-IN overrides this unit's CADENCE, so the schedule reported above is NOT what systemd runs: $installed_timer_dropins — read it (systemctl cat $UNIT_NAME.timer) and re-install once it is gone"
            rc=1
        fi
    fi
    # ⛔ THE RECORD'S EXISTENCE IS NOT THE RECORD'S AUTHORITY. Every writer (arm_flag, do_arm, the
    # --report-only guard, report_surviving_arm_record) asks `arm_record_valid`, which needs BOTH
    # `armed-by=` and `armed-date=`; this line asked `[ -f ]` and nothing else. So a half-written record —
    # the exact state the file's own rule calls fail-closed ("BOTH LINES OR NOTHING") — was reported
    # `arm_record=present` by the readiness verb while the very next `--install` rendered DISARMED, and
    # with a DISARMED artifact it read "present" over a box that is not armed at all. Both directions are
    # a false PASS over a fact the writers gate on.
    case "$([ -f "$ARM_FILE" ] && printf exists)" in
        '') log_line "arm_record=absent ($ARM_FILE)" ;;
        *)
            if arm_record_valid; then
                log_line "arm_record=present ($ARM_FILE)"
            else
                log_line "arm_record=INVALID (present but missing armed-by=/armed-date=) ($ARM_FILE)"
                err "the arming record exists but is NOT a valid arming: it is missing $(grep -q '^armed-by=.' "$ARM_FILE" 2>/dev/null || printf 'armed-by= ')or $(grep -q '^armed-date=.' "$ARM_FILE" 2>/dev/null || printf 'armed-date= ')— every writer reads this as NOT ARMED, so the artifact is the LAST word and the next --install will render it DISARMED. Re-run --arm, or --disarm to revoke it cleanly."
                rc=1
            fi ;;
    esac
    # ⛔ THE TARGET IS PART OF THE ANSWER. An artifact whose script is gone starts nothing (203/EXEC on
    # every tick) while the scheduler still lists it as scheduled and healthy.
    # The script is the first ABSOLUTE `.py` argument — not a hard-coded basename. A basename match
    # reported `script=unreadable` for any converger installed under another name (measured with a
    # fixture), which turned a perfectly good artifact into a reported failure.
    if [ "$TARGET" = "launchd" ]; then
        installed_args="$(plist_program_args "$installed_path")"
    else
        installed_args="$(unit_exec_line "$installed_path" | tr ' ' '\n' | tr -d '"')"
    fi
    # ⛔ THE SCRIPT IS TOKEN 2, NOT "the first argument ending in .py". Both templates render
    # `<interpreter> <script> …` and `resolve_script` accepts any executable regular file, so a
    # suffix rule discarded EVERY argument (and every mode answer) for a wrapper or a console-script
    # without the suffix — measured: a valid install reported `script=unreadable` and `mode=converge
    # (ARMED)` over a DISARMED artifact, and `--status` exited 1 on a working schedule.
    installed_script="$(printf '%s\n' "$installed_args" | awk 'NF { if (++pos == 2) { print; exit } }')"
    # ⛔ THE INTERPRETER IS PART OF THE ANSWER TOO, AND IT WAS THE HOLE. The pass runs as
    # `<interpreter> <script> …`, so an artifact whose pinned interpreter is gone starts nothing —
    # exactly like a missing script — while `script_present=yes` and the scheduler still lists the job
    # as scheduled. This is not hypothetical: the installer pins an ABSOLUTE interpreter path
    # precisely so a login-shell change cannot move it, which is also what makes a Python upgrade that
    # retires `python3.12` turn every tick into 203/EXEC. `--status` is the verb that exists to say so.
    installed_python="$(args_first "$installed_args")"
    case "$installed_python" in
        /*) : ;;
        *) installed_python="" ;;
    esac
    if [ -n "$installed_python" ] && [ -x "$installed_python" ]; then
        log_line "python=${installed_python}"
        # ⛔ EXECUTABLE IS NOT USABLE. The pass refuses ITSELF below 3.12 (`raise SystemExit(2)`), and the
        # install path refuses that interpreter (`python_ok`); this arm checked only presence, so the
        # readiness verb was green over a schedule that exits 2 on every tick. The realistic trigger is
        # not exotic: the installer pins an ABSOLUTE path, and the resolver's own candidate list includes
        # a per-lane venv — a venv recreated on an older interpreter, or a replaced binary at the pinned
        # path, is exactly how the version changes under a unit that never moved.
        # ONE reader of the version rule: `python_ok` is the SAME predicate the install path uses, so
        # the two verbs cannot disagree about which interpreters are usable.
        if python_ok "$installed_python"; then
            log_line "python_present=yes"
        else
            log_line "python_present=yes"
            log_line "python_usable=no"
            err "the artifact's interpreter ${installed_python} is present but TOO OLD for the pass (it refuses itself below 3.12, so every tick exits 2) while the scheduler still lists the job as scheduled"
            rc=1
        fi
    else
        log_line "python=${installed_python:-unreadable}"
        log_line "python_present=no"
        err "the artifact's interpreter ${installed_python:-is unreadable} is absent or not executable — every tick would fail to start (203/EXEC) while the scheduler still lists the job as scheduled"
        rc=1
    fi
    log_line "script=${installed_script:-unreadable}"
    if [ -n "$installed_script" ] && [ -f "$installed_script" ] && [ -r "$installed_script" ]; then
        log_line "script_present=yes"
    else
        log_line "script_present=no"
        err "the artifact names ${installed_script:-an unreadable script} which is absent or unreadable — every tick would fail to start (the scheduler still lists it as scheduled)"
        rc=1
    fi
    # ⛔ THE READINESS VERB IS THE OTHER HALF OF THE SCRATCH GATE. `is_transient_scratch` (and the
    # refusal it drives, `refuse_unusable_target`) is reachable only from the three WRITING verbs, so an
    # artifact whose declared paths sit in a mktemp tree was refused by `--install`/`--arm` and then
    # CERTIFIED by `--status`: the drift render is fed the ARTIFACT's own values, so it compares the file
    # to a render of itself, reports `drift_artifact=no`, and exits 0 — green over a unit that exits 127
    # on every tick the moment that tree is removed, i.e. exactly during the window an operator is
    # looking at it. Measured: the writer exits 1 with "REFUSING … transient scratch space" on the same
    # paths the reader called clean. This is the same one-fact-two-readers split T29-T36 closed for
    # `enabled`, `linger`, the provisioner pin, `python_ok` and the root guard, so both verbs consult ONE
    # predicate. The writers refuse to CREATE this artifact; a hand-edited, foreign or pre-fix one is how
    # the state is actually reached, which is when a readiness gate earns its keep.
    refuse_transient_installed_artifact "$installed_path" || rc=1
    # ── drift, both directions, REPORTED (issue #2403 clause 5) ──────────────────────────────
    # artifact drift: the installed file is not what THIS installer would write (a changed interval, repo
    # or mode, or a hand-edit). Not fatal: it is information, and the next `--install` converges it.
    # ⛔ THE RENDER BELOW IS DRIVEN BY THE VALUES THE ARTIFACT DECLARES, NOT BY THE READER'S ENVIRONMENT.
    # Every substituted value — `{{PATH}}`, `{{PYTHON}}` (found ON that PATH), `{{SCRIPT}}` (resolved from
    # INFRA_ROOT), `{{PROVISIONER_ENV}}` (resolved from `$PWD`), `{{REPO}}`, `{{HOME}}`, `{{STATE_DIR}}` —
    # is an input of the invocation that rendered the artifact. Re-deriving them from the `--status`
    # process and calling the difference "drift" reports the OPERATOR'S SHELL, not the file: measured, an
    # untouched artifact reported `drift_artifact=yes` when `--status` ran from a login shell with a
    # different PATH, or from any other directory (the provisioner resolves through `$PWD` alone on the
    # boxes this exists for). The artifact is the record of what was resolved at install time, so the
    # comparison reads those values back out of it — the verdict is then about the FILE (hand-edits,
    # foreign artifacts, a record/artifact mode disagreement), which is what the word means.
    # ⛔ AND WHERE THEY DIFFER, THAT IS STILL REPORTED — as `drift_inputs=`, named, not as drift and not
    # silently: "a re-install from here would rewrite these" is the actionable fact, and the `--install`
    # remedy must not be run to "fix" a file that is already right.
    if [ -n "$installed_script" ]; then
        local tmpd
        local save_home save_path save_state save_repo save_prov save_py save_script
        local inputs_differ=""
        drift_artifact="unknown"
        drift_service="unknown"
        drift_timer="unknown"
        tmpd="$(mktemp -d "${TMPDIR:-/tmp}/runner-autoscale-drift.XXXXXX")" 2>/dev/null || tmpd=""
        if [ -n "$tmpd" ]; then
            save_home="$HOME"; save_path="$PATH"; save_state="$STATE_DIR"; save_repo="$REPO"
            save_prov="$PROVISIONER"; save_py="$PYTHON"; save_script="$SCRIPT"
            local d_home d_path d_state d_repo d_prov dv
            d_home="$(artifact_env_value "$installed_path" HOME)"
            d_path="$(artifact_env_value "$installed_path" PATH)"
            d_state="$(artifact_env_value "$installed_path" RUNNER_AUTOSCALE_STATE_DIR)"
            # ⛔ READ FROM THE COMMAND LINE, NOT THE ENVIRONMENT — `--repo` is an ARGUMENT in both
            # templates, so the env read-back was empty on every box and this line did nothing.
            d_repo="$(artifact_repo_value "$installed_path")"
            d_prov="$(artifact_env_value "$installed_path" RUNNER_AUTOSCALE_PROVISIONER)"
            # ⛔ THE READINESS VERB MUST APPLY THE WRITERS' VALUE GUARDS TO WHAT IT READS BACK. The writers
            # REFUSE a `--repo` that is not a plain `owner/name` (in `refuse_unusable_target`) and refuse a
            # `%` or whitespace in any rendered value on the systemd arm (in `refuse_systemd_unsafe_values`);
            # `--status` judged NONE of them — and the drift `cmp` structurally CANNOT catch it, because the
            # render is fed the artifact's OWN declared values, so it reproduces the bad value exactly and
            # reports `drift_artifact=no`. Measured: an artifact hand-edited to `--repo "o/%h"` printed
            # `mode=converge (ARMED)`, `drift_artifact=no` and exit 0, over a unit whose repo systemd expands
            # to something else at load time — every tick then exits 2. The T49 class, one key over: the
            # writers refuse to create this state, so a hand-edited or foreign artifact is HOW it is reached.
            for dv in "HOME=$d_home" "STATE_DIR=$d_state" "REPO=$d_repo" "PROVISIONER=$d_prov"; do
                [ -n "${dv#*=}" ] || continue
                case "${dv#*=}" in
                    *\\*) err "the installed artifact declares ${dv%%=*} with a BACKSLASH, which no render here can reproduce (the artifact is rendered with sed, where a backslash is an escape) — the artifact is not the one this installer would write"; rc=1 ;;
                esac
                if [ "$TARGET" != "launchd" ]; then
                    case "${dv#*=}" in
                        *[[:space:]]*) err "the installed artifact declares ${dv%%=*} containing WHITESPACE — systemd splits the rendered unit on it, so the job does not run as written"; rc=1 ;;
                        *%*) err "the installed artifact declares ${dv%%=*} containing '%', which systemd expands as a SPECIFIER at load time (%h, %i, %n) — the job is handed a value that is not the one on disk, and `last_tick` then stays silent in the path the pass actually logs to"; rc=1 ;;
                    esac
                fi
            done
            if [ -n "$d_repo" ] && ! [[ "$d_repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
                err "the installed artifact declares --repo '$d_repo', which is not a plain owner/name (letters, digits, dot, dash, underscore). The writers REFUSE to render this, so the artifact is hand-edited or foreign; the pass would read a pool that is not the one on disk."
                rc=1
            fi
            # A key the artifact does not declare keeps the reader's value: the render must not be fed an
            # EMPTY path to make the comparison match (that would bless the missing line). Reporting the
            # difference is what surfaces it.
            [ -n "$d_home" ]  && HOME="$d_home"
            [ -n "$d_path" ]  && PATH="$d_path"
            [ -n "$d_state" ] && STATE_DIR="$d_state"
            [ -n "$d_repo" ]  && REPO="$d_repo"
            [ -n "$d_prov" ]  && PROVISIONER="$d_prov"
            [ -n "$installed_python" ] && PYTHON="$installed_python"
            [ -n "$installed_script" ] && SCRIPT="$installed_script"
            # ⛔ ONLY A VALUE THE ARTIFACT ACTUALLY DECLARES CAN DISAGREE. The template carries `HOME`, `PATH`,
            # `RUNNER_AUTOSCALE_STATE_DIR`, the whole-line `RUNNER_AUTOSCALE_PROVISIONER` pin and the
            # `--repo` argument; a value it does not carry must not read as "the reader resolves something
            # else" (that would print a permanent `drift_inputs=` on every box).
            [ -n "$d_home" ] && [ "$save_home" != "$d_home" ] && inputs_differ="${inputs_differ:+$inputs_differ }home"
            [ -n "$d_path" ] && [ "$save_path" != "$d_path" ] && inputs_differ="${inputs_differ:+$inputs_differ }path"
            [ -n "$d_state" ] && [ "$save_state" != "$d_state" ] && inputs_differ="${inputs_differ:+$inputs_differ }state_dir"
            [ -n "$d_repo" ] && [ "$save_repo" != "$d_repo" ] && inputs_differ="${inputs_differ:+$inputs_differ }repo"
            [ -n "$d_prov" ] && [ "$save_prov" != "$d_prov" ] && inputs_differ="${inputs_differ:+$inputs_differ }provisioner"
            [ "$save_py" != "$installed_python" ] && inputs_differ="${inputs_differ:+$inputs_differ }python"
            [ "$save_script" != "$installed_script" ] && inputs_differ="${inputs_differ:+$inputs_differ }script"
            if [ "$TARGET" = "launchd" ]; then
                if render "$LAUNCHD_TEMPLATES_DIR/$LABEL.plist" "$tmpd/$LABEL.plist" launchd 2>/dev/null; then
                    cmp -s "$tmpd/$LABEL.plist" "$installed_path" && drift_artifact=no || drift_artifact=yes
                fi
            else
                if render "$TEMPLATES_DIR/$UNIT_NAME.service" "$tmpd/$UNIT_NAME.service" systemd 2>/dev/null; then
                    # ⛔ THE DRIFT COMPARISON MUST COMPARE THE ARTIFACT THE INSTALL PATH WOULD WRITE, AND
                    # FOR A USER TARGET THAT ARTIFACT HAS NO `User=` LINE. The install path drops it
                    # (systemd rejects `User=` in a user unit); this render did not, so the two files
                    # could never match and `drift_artifact=yes` was reported on a freshly installed,
                    # untouched artifact — a signal that fires always is a signal nobody reads. Reported
                    # on the very `--status` the install hands the operator as its remedy.
                    if [ "$TARGET" = "user" ]; then
                        sed -i.bak '/^User=/d' "$tmpd/$UNIT_NAME.service" && rm -f "$tmpd/$UNIT_NAME.service.bak"
                    fi
                    cmp -s "$tmpd/$UNIT_NAME.service" "$installed_path" && drift_service=no || drift_service=yes
                fi
                # ⛔ THE INSTALL PATH WRITES TWO ARTIFACTS AND THE DRIFT CHECK COMPARED ONE. `--install`
                # writes `$UNIT_NAME.service` AND `$UNIT_NAME.timer` (do_install_systemd renders both), and
                # the systemd TIMER is the artifact that carries the CADENCE: `OnBootSec=`/`OnUnitActiveSec=`
                # live there, and `{{INTERVAL_SEC}}` is rendered into the plist ONLY, so the timer template
                # is static text with nothing else comparing it. A hand-edited, foreign, or older-cadence
                # timer therefore fired at the wrong interval while the verb whose own comment promises to
                # catch "a changed interval" printed `drift_artifact=no` and exited 0 — an artifact that
                # fires hourly instead of every 9 minutes, certified healthy by the readiness gate. Same
                # class the `User=` arm above fixed: compare everything the install path would write.
                # ⛔ AND A MISSING TIMER IS DRIFT, NOT AN ERROR: a service installed without its timer fires
                # nothing, so `cmp` against an absent file must read `yes` (that is the useful signal here,
                # and `is-enabled`/`is-active` on the absent timer red the same box independently).
                if render "$TEMPLATES_DIR/$UNIT_NAME.timer" "$tmpd/$UNIT_NAME.timer" systemd 2>/dev/null; then
                    cmp -s "$tmpd/$UNIT_NAME.timer" "$UNIT_DIR/$UNIT_NAME.timer" && drift_timer=no || drift_timer=yes
                fi
                # One verdict, no attribution lost: `yes` if EITHER artifact drifted, `no` only when BOTH
                # were compared and matched, `unknown` when a render failed for one of them (a render
                # failure is not evidence of drift, and it is not evidence of cleanliness either).
                if [ "$drift_service" = "yes" ] || [ "$drift_timer" = "yes" ]; then drift_artifact=yes
                elif [ "$drift_service" = "no" ] && [ "$drift_timer" = "no" ]; then drift_artifact=no
                else drift_artifact=unknown; fi
            fi
            # ⛔ RESTORED BEFORE ANYTHING ELSE READS THEM. The values above are the ARTIFACT's, and every
            # later line of this verb (`last_tick`, the repo-copy digest, the message text) must speak in
            # the reader's own paths again.
            HOME="$save_home"; PATH="$save_path"; STATE_DIR="$save_state"; REPO="$save_repo"
            PROVISIONER="$save_prov"; PYTHON="$save_py"; SCRIPT="$save_script"
            rm -rf "$tmpd"
        fi
        log_line "drift_artifact=$drift_artifact"
        # Which artifact drifted, so an operator re-rendering by hand does not have to guess. Omitted on
        # the launchd arm, which installs one file.
        if [ "$TARGET" != "launchd" ]; then
            log_line "drift_parts=service=${drift_service:-unknown} timer=${drift_timer:-unknown}"
        fi
        # Reported, not drifted: the artifact is not what a re-install from HERE would write, because THIS
        # invocation resolved different inputs. Named so the operator knows an install would rewrite them
        # (and, with `adopt_installed_provisioner`, that it will not silently drop a pin it cannot resolve).
        if [ -n "$inputs_differ" ]; then
            log_line "drift_inputs=$inputs_differ (this invocation resolves different values than the artifact was written with — informational: an --install from here would rewrite these, and the artifact itself is not hand-edited)"
        fi
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
            # 4 (STARVATION) is RED for the same reason as the systemd arm below — see that comment.
            case "${last:-}" in
                ''|-|0) : ;;
                4) err "the last pass exited 4 (STARVATION) — the pass completed and reported a queue that cannot reach this pool with no busy runner; that verdict is the alarm, not a clean tick; see $(last_tick_line "$STATE_DIR/runner-autoscale.log")"; rc=1 ;;
                *) err "the last pass exited $last — the converger is not completing; see $(last_tick_line "$STATE_DIR/runner-autoscale.log")"; rc=1 ;;
            esac
            log_line "pid=$($SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {print $1; exit}' | sed 's/^-$/not-running/')"
            # ⛔ READ BACK FROM THE PLIST, NEVER RESTATED FROM `$INTERVAL_SEC`. See plist_start_interval.
            local d_interval
            d_interval="$(plist_start_interval "$installed_path")"
            log_line "cadence=StartInterval=${d_interval:-unknown}"
            log_line "next_run=not reported by launchd (fires every ${d_interval:-unknown}s from load)"
        else
            log_line "loaded=no"
            err "the agent is NOT loaded — the artifact is on disk but nothing fires it"
            rc=1
        fi
    else
        enabled="$($SC is-enabled "$UNIT_NAME.timer" 2>/dev/null || echo no)"
        active="$($SC is-active "$UNIT_NAME.timer" 2>/dev/null || echo no)"
        log_line "enabled=$enabled"
        # ⛔ ENABLED IS GATED, NOT JUST PRINTED — and `static` fails it too. A timer that is active NOW
        # but not enabled does not come back at the next boot, so the box stops converging at the first
        # restart. The INSTALL path already refuses this state ("timer is NOT enabled after install — the
        # converger will not run unattended"); the STATUS path — the verb an operator and the health
        # sweep call LATER, when a reboot or an operator edit can have changed it — did not, so the
        # readiness gate was the lenient of the two readers of one fact. `static` means the unit has no
        # `[Install]` section, so nothing links it into `timers.target`: the same inert-after-reboot
        # state, reachable only on a hand-edited or foreign unit, which is when a gate earns its keep.
        # (Same rule the sibling installer records at install-harness-apply-timer.sh's status arm.)
        case "${enabled:-no}" in
            enabled) : ;;
            *) err "the timer is '${enabled:-no}', not enabled — it will not survive a reboot, so this box stops converging at the next restart"; rc=1 ;;
        esac
        # ⛔ A USER TIMER WITHOUT LINGER DIES WITH THE LAST SESSION, so the status verb re-checks what the
        # install path checked (lingering can be cleared later by an operator or an image rebuild). The
        # install path refuses a non-lingering user install outright; without this arm `--status` printed
        # a green readiness verdict over a timer that stops firing at logout.
        if [ "$TARGET" = "user" ]; then
            linger="$(${LOGINCTL:-loginctl} show-user "$(id -un)" -p Linger --value 2>/dev/null || true)"
            log_line "linger=${linger:-unknown}"
            [ "$linger" = "yes" ] || { err "the user timer will NOT fire after this session ends (linger=${linger:-unknown}) — it stops converging at logout; enable it: sudo loginctl enable-linger $(id -un)"; rc=1; }
        fi
        log_line "timer_active=$active"
        next="$($SC list-timers --all --no-pager 2>/dev/null | awk -v u="$UNIT_NAME.timer" '$0 ~ u {print $1" "$2" "$3; exit}')"
        log_line "next_run=${next:-unknown}"
        last="$($SC show -p ExecMainStatus --value "$UNIT_NAME.service" 2>/dev/null || echo unknown)"
        log_line "last_run=${last:-unknown}"
        case "${active:-}" in
            active|activating) : ;;
            *) err "the timer is '${active:-unknown}', not active — the converger will NOT run unattended"; rc=1 ;;
        esac
        # ⛔ 4 (STARVATION) IS NOT GREEN HERE EITHER. The service unit renders 2/3/4 RED and its own exit
        # table says "0 is the ONLY green … greening 4 would silently retire the alarm #2875 exists for".
        # This gate had `4` in the green set, so the readiness verb reported healthy over the one state
        # the unit is best placed to catch: a queue that cannot reach this pool. It is a DIFFERENT
        # message from "not completing" (the pass ran and reported), which is why it has its own arm.
        case "${last:-}" in
            ''|-|0) : ;;
            unknown) err "cannot read the timer's last run (systemctl show refused) — cannot determine whether the pass is completing"; rc=1 ;;
            4) err "the timer's last run exited 4 (STARVATION) — the pass completed and reported a queue that cannot reach this pool with no busy runner. The converger's own verdict is the alarm, not a clean tick; see the pass log below"; rc=1 ;;
            *) err "the timer's last run exited $last — the pass is not completing; see the pass log below"; rc=1 ;;
        esac
    fi
    log_line "last_tick=$(last_tick_line "$STATE_DIR/runner-autoscale.log")"
    return "$rc"
}

# ── uninstall ───────────────────────────────────────────────────────────────────────────────
report_surviving_arm_record() { # ⛔ an uninstall that leaves the record RE-ARMS on the next --install
    # Measured: `--arm` → `--uninstall` → `--install` re-rendered the box ARMED from a record the operator
    # believed the uninstall had cleared, printing the pre-uninstall date — and the `--status` remedy they
    # are handed says "installs it DISARMED", i.e. the opposite. The record is NOT deleted here: it is the
    # operator's dated decision, and revoking it silently is exactly what `--arm`'s own step forbids.
    if [ -f "$ARM_FILE" ] && arm_record_valid; then
        err "note: the arming record at $ARM_FILE SURVIVES this uninstall, so the NEXT --install will render an ARMED unit (by $(sed -n 's/^armed-by=//p' "$ARM_FILE" || true), $(sed -n 's/^armed-date=//p' "$ARM_FILE" || true))."
        err "      the box has no scheduled converger until then; to revoke the decision first, run --disarm, or delete that file."
    fi
    return 0
}

do_uninstall() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_line "dry-run: would disable and remove the installed schedule (nothing was changed)"
        return 0
    fi
    # ⛔ A WRITER LIKE THE OTHER THREE. Under `sudo`, HOME resolves to /root, so the removal runs against
    # root's unit dir while `report_surviving_arm_record` reads /root's (absent) record and says nothing —
    # the operator is told the box is uninstalled, the user's dated record survives, and the next routine
    # `--install` re-arms from it. Measured: every other verb refused, this one exited 0 unguarded.
    refuse_root_invocation || return 1
    choose_target || { err "no scheduler available"; return 1; }
    # ⛔ THE RECORD'S LOCATION IS A FACT ABOUT THE ARTIFACT (see `adopt_installed_state_dir`). Without
    # this, `--uninstall` reads the reader's path, finds no record, says nothing about a surviving arming
    # decision — and the next `--install` re-arms the box from the orphaned one.
    adopt_installed_state_dir
    if [ "$TARGET" = "launchd" ]; then
        # ⛔ A DISARM IS NOT DONE BECAUSE `bootout` RETURNED. The plist can be gone while the LOADED job
        # keeps firing until logout, and `--status` would then answer `installed=no` about a job that is
        # still converging. Prove the label is gone (the same read the install path uses).
        $SC bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || $SC unload "$UNIT_DIR/$LABEL.plist" >/dev/null 2>&1 || true
        rm -f "$UNIT_DIR/$LABEL.plist"
        # ⛔ THE REMOVAL IS VERIFIED TOO, not just the label. launchd reloads a plist that survives in
        # LaunchAgents at the next login, so a `rm` that failed (a permission change, an immutable file)
        # reported `uninstalled (not loaded)` while the job came back — and a "not loaded" answer is also
        # what a FAILED `launchctl list` produces. The systemd arm has had this check all along.
        if [ -e "$UNIT_DIR/$LABEL.plist" ]; then
            err "NOT reporting this as uninstalled — $UNIT_DIR/$LABEL.plist is STILL PRESENT (the removal failed); launchd would load it again at the next login"
            return 1
        fi
        if $SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {found=1} END{exit !found}'; then
            err "$LABEL is STILL LOADED after bootout — it will keep firing; log out or reboot, or bootout gui/$(id -u)/$LABEL by hand"
            return 1
        fi
        log_line "uninstalled $LABEL from $UNIT_DIR (not loaded)"
        report_surviving_arm_record
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
    # the only way to remove the other. The shared helper keeps the scan list in ONE place.
    report_other_scope_installs "this removed $UNIT_DIR only"
    log_line "uninstalled $UNIT_NAME from $UNIT_DIR (target=$TARGET)"
    report_surviving_arm_record
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
# ⛔ AND IT IS ONLY A RENDER FLAG FOR `--install`. On any other verb it used to be silently ignored by
# the verb's own logic and honoured by the render inside it, which produced two measured lies:
#   * `--arm --report-only` minted a dated arming record, then rendered the FORCED disarmed artifact,
#     verified it AS the forced mode (so the check passed) and printed `ARMED` over a `--dry-run` unit —
#     after which the next routine `--install` armed from that record with no dated step at that moment;
#   * `--uninstall --report-only` performed a real removal.
# A preview flag that a writer ignores is worse than no flag.
if [ -n "$FORCE_MODE_FLAG" ] && [ "$MODE" != "--install" ]; then
    err "REFUSING --report-only with $MODE: it is a render flag for --install only. On $MODE it would either"
    err "be ignored by the verb while its render honoured it (a record written and 'ARMED' printed over a"
    err "disarmed artifact) or let a real removal run under a preview flag."
    exit 1
fi
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
