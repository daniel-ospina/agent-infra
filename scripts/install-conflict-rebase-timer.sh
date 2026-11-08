#!/usr/bin/env bash
# install-conflict-rebase-timer.sh — put the CONFLICT-REBASE pass on the box's clock, on BOTH
# platforms (agent-infra#2698, armed 2026-11-07 under the owner's instruction).
#
# WHY THIS FILE EXISTS. `scripts/conflict-rebase.py` + `scripts/conflict-rebase-timer.sh` shipped as a
# capability with NO installer, NO unit and NO plist: measured 2026-11-07 across the fleet, it was
# scheduled on ZERO boxes while 8 PRs sat CONFLICTING and an operator hand-dispatched 8 rebase lanes to
# do what an hourly timer would have done. A one-shot nobody runs is a design document — and a timer
# that does not exist produces no error, so nothing noticed. This is the missing installer; the
# declaration that it has run is `scripts/activate-harness.sh` (one table, both platforms, verified
# after arming).
#
# Same split as the rest of this family (#2032/#2048/#2058, #2416): the artifact is RENDERED from
# machine state (HOME, PATH, the checkout, the state dir, the cadence) and installed IDEMPOTENTLY; the
# bring-up/launcher is the TRIGGER, this is the policy of WHERE and HOW.
#   Linux  eldato-conflict-rebase.service + .timer   every {{INTERVAL_MIN}} min (OnBootSec=5min)
#   macOS  com.eldato.conflict-rebase LaunchAgent    the same cadence (StartInterval)
# Neither scheduler is re-implemented: the units are rendered here and enabled with `systemctl`, the
# plist is rendered here and bootstrapped with `launchctl`.
#
# ⛔ IT ARMS BY DEFAULT, AND THAT IS A RECORDED OWNER DECISION. #1678 makes arming a DELETING tool a
# separate dated owner step; this is not a deletion tool — it rebases branches, refuses every content
# conflict, and never resolves one. The owner instructed the arming on 2026-11-07 ("of course we should
# arm it"), so `--install` arms it and the arming is visible in the artifact: the unit carries no
# `--dry-run`. Reversal is one verb (`--uninstall`), or the platform's own
# (`systemctl disable --now eldato-conflict-rebase.timer`).
# ⛔ `--report-only` IS THE DISARM WITHOUT A HAND-EDIT: it re-renders the same artifact with
# CONFLICT_REBASE_DRY_RUN=1, so "installed but observing" is a state the artifact states.
# ⛔ `--dry-run` IS NOT A DISARM. It renders and PRINTS, writes nothing, enables nothing. The
# disk-reaper installer records the measured confusion between these two verbs; do not repeat it.
#
# ⛔ WHAT IT REFUSES (each would otherwise install a unit that cannot run, or one that silently does
# nothing):
#   * a timer script that is not a regular readable file, or one under transient scratch (a unit
#     pointing at a `mktemp` dir exits 127 every tick while `list-timers` reads green);
#   * a checkout that is not a repository root (the pass cannot see detached worktrees without one, so
#     it would lose half its lane-hold guard and say nothing);
#   * a cadence that is not a whole number of minutes in 1..1440 (it is BAKED INTO a persistent unit);
#   * a rendered value containing whitespace (systemd SPLITS unquoted Environment=/ExecStart= values)
#     or a backslash (the artifact is rendered with `sed`, where a backslash is an escape);
#   * a leftover `{{PLACEHOLDER}}` after rendering, or a rendered plist that does not parse;
#   * an invocation that arrived THROUGH sudo (SUDO_USER set): `{{USER}}` is `id -un` and `{{HOME}}` is
#     `$HOME`, so a root install would render root's state and push with root's credential;
#   * a state dir that is not writable by the invoking user (every pass would fail to record).
#
# Usage:
#   install-conflict-rebase-timer.sh [--install] [--report-only] [--dry-run] [--status] [--uninstall]
#   install-conflict-rebase-timer.sh --help
#
# Env seams (tests + unusual boxes):
#   CONFLICT_REBASE_TIMER        the timer wrapper to install (default: the checkout's copy, then the
#                                farmed copy at $HOME/.pi/agent/scripts)
#   CONFLICT_REBASE_CHECKOUT     the checkout the pass rebases against (default: the resolved checkout)
#   CONFLICT_REBASE_REPO         owner/name (default daniel-ospina/agent-infra, the .py's own default)
#   CONFLICT_REBASE_MAX          PRs per pass (default 3)
#   CONFLICT_REBASE_INCLUDE_BEHIND  1 (default) or 0
#   CONFLICT_REBASE_INTERVAL_MIN minutes between passes (default 30; 1..1440)
#   CONFLICT_REBASE_STATE        the state dir the unit exports (default $HOME/.pi/agent/state/conflict-rebase)
#   TEMPLATES_DIR                systemd template dir (default: this repo's templates/systemd)
#   LAUNCHD_TEMPLATES_DIR        plist template dir (default: this repo's templates/launchd/conflict-rebase)
#   SYSTEMD_UNIT_DIR             install dir OVERRIDE (tests: a temp dir, with a fake SYSTEMCTL)
#   LAUNCHD_AGENTS_DIR           LaunchAgents dir OVERRIDE (tests: a temp dir, with a fake LAUNCHCTL)
#   ELDATO_PLATFORM              override `uname -s` (tests render the Darwin artifact on any host)
#   ELDATO_LAUNCHER_PY / ELDATO_LAUNCHER  the interpreter + TCC launcher a launchd job is started with
#   SYSTEMCTL / LAUNCHCTL / SUDO the tools to call / probe (tests: shims)
#
# Exit codes: 0 ok · 1 failure (named) · 2 usage.
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${TEMPLATES_DIR:-}" ]; then
    for _cand in "$INFRA_ROOT/templates/systemd" "${AGENT_INFRA_PATH:-}/templates/systemd" \
                 "${CELL_HOME:-$HOME}/agent-infra/templates/systemd" "/tmp/cell-ai/templates/systemd" \
                 "/tmp/cell/agent-infra/templates/systemd" "$HOME/agent-infra/templates/systemd"; do
        [ -n "$_cand" ] && [ -d "$_cand" ] && { TEMPLATES_DIR="$_cand"; break; }
    done
fi
TEMPLATES_DIR="${TEMPLATES_DIR:-$INFRA_ROOT/templates/systemd}"
# The plist lives OUTSIDE templates/launchd/ on purpose: install-launchd.sh installs EVERY
# `templates/launchd/*.plist` with a different placeholder set, and fleet-schedule.py reads the same
# top-level glob on a cell — a copy there would either render unresolved or double-schedule this pass
# beside the systemd timer. templates/launchd/{reaper,harness-apply,runner-autoscale}/ set the precedent.
if [ -z "${LAUNCHD_TEMPLATES_DIR:-}" ]; then
    for _cand in "$INFRA_ROOT/templates/launchd/conflict-rebase" \
                 "${AGENT_INFRA_PATH:-}/templates/launchd/conflict-rebase" \
                 "${CELL_HOME:-$HOME}/agent-infra/templates/launchd/conflict-rebase" \
                 "/tmp/cell-ai/templates/launchd/conflict-rebase" \
                 "$HOME/agent-infra/templates/launchd/conflict-rebase" \
                 "${TEMPLATES_DIR%/systemd}/launchd/conflict-rebase"; do
        [ -n "$_cand" ] && [ -d "$_cand" ] && { LAUNCHD_TEMPLATES_DIR="$_cand"; break; }
    done
fi
LAUNCHD_TEMPLATES_DIR="${LAUNCHD_TEMPLATES_DIR:-$INFRA_ROOT/templates/launchd/conflict-rebase}"

PLATFORM="${ELDATO_PLATFORM:-$(uname -s 2>/dev/null || printf 'unknown')}"
UNIT_NAME="eldato-conflict-rebase"
LABEL="com.eldato.conflict-rebase"
INTERVAL_MIN="${CONFLICT_REBASE_INTERVAL_MIN:-30}"
REPO="${CONFLICT_REBASE_REPO:-daniel-ospina/agent-infra}"
MAX_PRS="${CONFLICT_REBASE_MAX:-3}"
INCLUDE_BEHIND="${CONFLICT_REBASE_INCLUDE_BEHIND:-1}"
STATE="${CONFLICT_REBASE_STATE:-${HOME:?HOME is required}/.pi/agent/state/conflict-rebase}"
DRY_RUN=0
MODE_FLAG=""

log_line() { printf '%s\n' "$*"; }
err() { printf '%s: %s\n' "${0##*/}" "$*" >&2; }

help_text() {
    local line n=0 seen=0
    # A builtin read loop, not `sed`/`awk` over `$0`: a static discard guard cannot resolve those
    # producers and refuses the invocation (the harness-apply installer records this, measured twice).
    [ -r "$0" ] || { err "cannot read my own header (a piped start has no file) — invoke this FILE"; return 2; }
    while IFS= read -r line; do
        n=$((n + 1)); [ "$n" = 1 ] && continue
        case "$line" in
            'set -uo pipefail'*) seen=1; break ;;
            '#'*) printf '%s\n' "${line#\# }" ;;
            '') printf '\n' ;;
            *) break ;;
        esac
    done <"$0"
    [ "$seen" = 1 ] || { err "could not find the header sentinel in $0"; return 2; }
    return 0
}

VERB="install"
while [ $# -gt 0 ]; do
    case "$1" in
        --install)     VERB="install" ;;
        --report-only) VERB="install"; MODE_FLAG="1"; DRY_RUN=0 ;;
        --dry-run)     VERB="install"; DRY_RUN=1 ;;
        --status)      VERB="status" ;;
        --uninstall)   VERB="uninstall" ;;
        -h|--help)     help_text; exit 0 ;;
        *) err "unknown argument '$1'"; exit 2 ;;
    esac
    shift
done

# ── resolve the timer wrapper and the checkout ───────────────────────────────────────────────
# ⛔ THE FARMED COPY IS PREFERRED ON A CELL: a unit pointing into a worktree breaks the day the
# worktree is reaped. The CHECKOUT, by contrast, must be the main worktree — that is where the pass acts.
TIMER=""
if [ -n "${CONFLICT_REBASE_TIMER:-}" ] && [ ! -f "$CONFLICT_REBASE_TIMER" ]; then
    err "REFUSING: \$CONFLICT_REBASE_TIMER names '$CONFLICT_REBASE_TIMER', which is not a regular file — refusing to install a unit that points at a DIFFERENT copy of the pass"
    exit 2
fi
for cand in "${CONFLICT_REBASE_TIMER:-}" "${HOME:-}/.pi/agent/scripts/conflict-rebase-timer.sh" "$INFRA_ROOT/scripts/conflict-rebase-timer.sh"; do
    [ -n "$cand" ] || continue
    [ -f "$cand" ] && { TIMER="$cand"; break; }
done

CHECKOUT=""
# ⛔ NO `git` SUBPROCESS HERE, AND THAT IS A HARD CONSTRAINT RATHER THAN A STYLE CHOICE. A script that
# invoking VCS commands against a path it resolves at runtime cannot be statically verified by
# extensions/main-worktree-guard's #1484 content walk, which then refuses to EXECUTE this installer at
# all from a hub-rooted session — so the installer would have been unrunnable on the operator's own
# laptop (measured 2026-11-07, this file, dry run refused). The checkout test is therefore read from
# the filesystem: `.git` is a DIRECTORY in a main worktree and a FILE (`gitdir: …/.git/worktrees/<n>`)
# in a linked one, and the linked case names its main worktree explicitly. The pass itself still
# validates with real VCS commands at run time — and if this resolves wrong, the FIRST pass stamps
# `last-failure` and `--status` reads red, which is a dated failure rather than a silent one.
resolve_checkout() {
    local cand gd main
    for cand in "${CONFLICT_REBASE_CHECKOUT:-}" "${AGENT_INFRA_PATH:-}" "$INFRA_ROOT" "$HOME/agent-infra" "$HOME/pi/agent-infra"; do
        [ -n "$cand" ] || continue
        [ -d "$cand" ] || continue
        if [ -d "$cand/.git" ]; then
            CHECKOUT="$cand"; return 0
        fi
        if [ -f "$cand/.git" ]; then
            gd="$(sed -n 's/^gitdir: //p' "$cand/.git" 2>/dev/null | head -1)"
            case "$gd" in
                */.git/worktrees/*) main="${gd%%/.git/worktrees/*}"; [ -d "$main/.git" ] && { CHECKOUT="$main"; return 0; } ;;
            esac
            # A linked worktree whose pointer does not name a main worktree: the worktree is still a
            # usable VCS directory, so use it rather than falling through to "no checkout".
            CHECKOUT="$cand"; return 0
        fi
    done
    return 1
}

is_absolute_path() { case "$1" in /*) return 0 ;; *) return 1 ;; esac; }

# Normalise BEFORE the prefix test: macOS sets TMPDIR with a TRAILING SLASH, so a naive test misses
# the very path it exists to refuse (the disk-reaper installer records the measurement).
is_transient_scratch() {
    local p="$1" t t2
    [ -n "$p" ] || return 1
    p="$(printf '%s' "$p" | tr -s '/')"
    case "$p" in
        /tmp/tmp.?*|/var/tmp/tmp.?*|/private/tmp/tmp.?*|/private/var/tmp/tmp.?*) return 0 ;;
        /var/folders/*/*/T/tmp.?*|/private/var/folders/*/*/T/tmp.?*) return 0 ;;
    esac
    for t in "${TMPDIR:-}"; do
        [ -n "$t" ] || continue
        t="$(printf '%s' "$t" | tr -s '/')"; t="${t%/}"
        [ -n "$t" ] || continue
        case "$t" in /var/*) t2="/private$t" ;; *) t2="$t" ;; esac
        case "$p" in "$t"/tmp.?*|"$t2"/tmp.?*|"/private$t"/tmp.?*) return 0 ;; esac
    done
    return 1
}

is_real_systemd_dir() {
    case "$(printf '%s' "${1:-}" | tr -s '/')" in
        /etc/systemd*|/usr/lib/systemd*|/lib/systemd*|/run/systemd*) return 0 ;;
    esac
    return 1
}

xml_sed_repl() {
    printf '%s' "$1" \
        | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        | sed -e 's/[&\\|]/\\&/g'
}

render() { # <template> <dest>
    local tpl="$1" dest="$2"
    sed -e "s|{{USER}}|$(xml_sed_repl "$(id -un)")|g" \
        -e "s|{{HOME}}|$(xml_sed_repl "$HOME")|g" \
        -e "s|{{PATH}}|$(xml_sed_repl "$PATH")|g" \
        -e "s|{{STATE}}|$(xml_sed_repl "$STATE")|g" \
        -e "s|{{TIMER}}|$(xml_sed_repl "$TIMER")|g" \
        -e "s|{{CHECKOUT}}|$(xml_sed_repl "$CHECKOUT")|g" \
        -e "s|{{REPO}}|$(xml_sed_repl "$REPO")|g" \
        -e "s|{{MAX_PRS}}|$(xml_sed_repl "$MAX_PRS")|g" \
        -e "s|{{INCLUDE_BEHIND}}|$(xml_sed_repl "$INCLUDE_BEHIND")|g" \
        -e "s|{{INTERVAL_MIN}}|$INTERVAL_MIN|g" \
        -e "s|{{INTERVAL_SEC}}|$(( INTERVAL_MIN * 60 ))|g" \
        -e "s|{{LABEL}}|$LABEL|g" \
        -e "s|{{PY_BIN}}|$(xml_sed_repl "${PY_BIN:-}")|g" \
        -e "s|{{LAUNCHER}}|$(xml_sed_repl "${LAUNCHER:-}")|g" \
        "$tpl" >"$dest" || return 1
    if grep -q '{{' "$dest"; then
        err "unresolved placeholder in $tpl"; grep -n '{{' "$dest" >&2; return 1
    fi
    return 0
}

plist_is_valid() {
    local f="$1"
    if command -v plutil >/dev/null 2>&1; then
        plutil -lint "$f" >/dev/null 2>&1 && return 0
        return 1
    fi
    command -v python3 >/dev/null 2>&1 || return 0   # no parser available: do not invent a refusal
    python3 -c 'import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$f" >/dev/null 2>&1
}

resolve_launcher() {
    local cand
    PY_BIN="${ELDATO_LAUNCHER_PY:-}"
    if [ -z "$PY_BIN" ]; then
        for cand in "${CHECKOUT:-}/.venv/bin/python" "${AGENT_INFRA_PATH:-}/.venv/bin/python" "${HOME:-}/.pi/agent/.venv/bin/python"; do
            [ -n "$cand" ] && [ -x "$cand" ] && { PY_BIN="$cand"; break; }
        done
    fi
    if [ -z "$PY_BIN" ]; then
        PY_BIN="$(command -v python3 2>/dev/null || true)"
        [ -n "$PY_BIN" ] && err "WARNING: no checkout .venv/bin/python resolved — the job will run with $PY_BIN. If this box's repos are under ~/Documents, pin the checkout's interpreter with ELDATO_LAUNCHER_PY (TCC is per-binary)."
    fi
    [ -n "$PY_BIN" ] || { err "REFUSING: no interpreter resolved for the launchd job — set ELDATO_LAUNCHER_PY to the checkout's .venv/bin/python, the binary that holds the TCC access this pass needs"; return 1; }
    [ -x "$PY_BIN" ] || { err "REFUSING: the launchd interpreter '$PY_BIN' is not executable"; return 1; }
    LAUNCHER="${ELDATO_LAUNCHER:-}"
    if [ -z "$LAUNCHER" ]; then
        for cand in "${HOME:-}/.pi/agent/scripts/pi-reap-worktrees-launchd.py" \
                    "${TIMER%/*}/pi-reap-worktrees-launchd.py" "$INFRA_ROOT/scripts/pi-reap-worktrees-launchd.py"; do
            [ -n "$cand" ] && [ -f "$cand" ] && { LAUNCHER="$cand"; break; }
        done
    fi
    [ -n "$LAUNCHER" ] && [ -f "$LAUNCHER" ] || { err "REFUSING: the launchd TCC launcher (pi-reap-worktrees-launchd.py) was not found — without it the pass cannot read a repo under ~/Documents, so it would fail closed every interval while launchctl read healthy"; return 1; }
    return 0
}

refuse_bad_target() {
    local v p bad="" skip=0
    if [ -n "${SUDO_USER:-}" ] && [ "$(id -u)" = "0" ]; then
        err "REFUSING to install as root (SUDO_USER=$SUDO_USER): {{USER}} is 'id -un' and {{HOME}} is \$HOME, so the unit would run as root and act on root's state"
        err "Run it as the user that owns the lanes:  sudo -u $SUDO_USER -H bash $0 --install"
        return 1
    fi
    if [ -z "$TIMER" ] || [ ! -f "$TIMER" ] || [ ! -r "$TIMER" ]; then
        err "REFUSING: no conflict-rebase-timer.sh resolved (looked at \$CONFLICT_REBASE_TIMER, \$HOME/.pi/agent/scripts, $INFRA_ROOT/scripts) — a unit that cannot run is worse than none. Farm it first: bash pi-bootstrap/setup.sh"
        return 1
    fi
    resolve_checkout || {
        err "REFUSING: no usable checkout resolved on this box (looked at \$CONFLICT_REBASE_CHECKOUT, \$AGENT_INFRA_PATH, $INFRA_ROOT, \$HOME/agent-infra) — the pass cannot see DETACHED worktrees without one, so half its lane-hold guard would be lost silently. Set CONFLICT_REBASE_CHECKOUT=<checkout>."
        return 1
    }
    for v in "TIMER=$TIMER" "HOME=$HOME" "STATE=$STATE" "CHECKOUT=$CHECKOUT"; do
        p="${v#*=}"
        is_absolute_path "$p" || { err "REFUSING: ${v%%=*} '$p' is not an absolute path — the scheduler resolves the program against the unit's working directory, so the pass would exit 127 every tick"; return 1; }
    done
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ] && ! is_real_systemd_dir "$SYSTEMD_UNIT_DIR"; then skip=1; fi
    if [ "$skip" != 1 ]; then
        is_transient_scratch "$TIMER"   && bad="TIMER=$TIMER"
        is_transient_scratch "$HOME"    && bad="${bad:+$bad; }HOME=$HOME"
        is_transient_scratch "$STATE"   && bad="${bad:+$bad; }STATE=$STATE"
        is_transient_scratch "$CHECKOUT" && bad="${bad:+$bad; }CHECKOUT=$CHECKOUT"
    fi
    if [ -n "$bad" ]; then
        err "REFUSING an install rendered from transient scratch space: $bad"
        err "The unit would point at a directory deleted before the first tick, so every pass exits 127"
        err "while 'list-timers' shows the job as scheduled — the inert-enforcer shape (#2032)."
        return 1
    fi
    case "$INTERVAL_MIN" in
        ''|*[!0-9]*) err "REFUSING: CONFLICT_REBASE_INTERVAL_MIN='$INTERVAL_MIN' is not a whole number of minutes — it is rendered into the unit and baked into a persistent unit"; return 1 ;;
    esac
    [ "$INTERVAL_MIN" -ge 1 ] && [ "$INTERVAL_MIN" -le 1440 ] || { err "REFUSING: CONFLICT_REBASE_INTERVAL_MIN=$INTERVAL_MIN is out of range (1..1440 minutes)"; return 1; }
    case "$MAX_PRS" in
        ''|*[!0-9]*) err "REFUSING: CONFLICT_REBASE_MAX='$MAX_PRS' is not a whole number — it is rendered into the unit"; return 1 ;;
    esac
    for v in "HOME=$HOME" "PATH=$PATH" "STATE=$STATE" "TIMER=$TIMER" "CHECKOUT=$CHECKOUT" "REPO=$REPO" "MAX_PRS=$MAX_PRS" "INCLUDE_BEHIND=$INCLUDE_BEHIND"; do
        case "${v#*=}" in
            *\\*) err "REFUSING: ${v%%=*} contains a backslash — the artifact is rendered with sed, where a backslash is an escape, so the rendered path would silently differ from the real one"; return 1 ;;
        esac
    done
    # ⛔ KEY THE SYSTEMD EXEMPTION ON THE PLATFORM, NOT ON `TARGET` (review P2-5). `TARGET` is assigned
    # by `choose_target` ALONE, and `do_install_launchd` calls THIS function before ever calling it — so
    # in the one path this exemption exists for, `TARGET` was empty, `${TARGET:-}` was not `launchd`, the
    # guard was ALWAYS true, and a Darwin install was refused over systemd's whitespace rules while the
    # message named systemd. Measured before the fix: `HOME="/tmp/sp ace" ELDATO_PLATFORM=Darwin …
    # --dry-run` -> `REFUSING: HOME contains whitespace — systemd splits the rendered unit on it`, rc 1.
    # A plist `<string>` may legitimately carry a space, so that threw away a configuration that works,
    # on the exact platform the exemption was written for. `PLATFORM` is resolved from `uname -s` (with
    # ELDATO_PLATFORM as the test seam) before any verb runs, so it is the fact this guard wants.
    if [ "${PLATFORM:-}" != "Darwin" ]; then
        for v in "HOME=$HOME" "PATH=$PATH" "STATE=$STATE" "TIMER=$TIMER" "CHECKOUT=$CHECKOUT" "REPO=$REPO"; do
            case "${v#*=}" in
                *[[:space:]]*) err "REFUSING: ${v%%=*} contains whitespace — systemd splits the rendered unit on it, so it would never run"; return 1 ;;
            esac
        done
    fi
    if [ "${DRY_RUN:-0}" = "1" ]; then
        if [ -e "$STATE" ] && [ ! -w "$STATE" ]; then
            err "REFUSING: state dir '$STATE' exists and is not writable by $(id -un) — every pass would fail to record"; return 1
        fi
        [ -e "$STATE" ] || log_line "dry-run: would create the state dir $STATE"
    elif ! mkdir -p "$STATE" 2>/dev/null || [ ! -w "$STATE" ]; then
        err "REFUSING: state dir '$STATE' is not writable by $(id -un) — every pass would fail to record"; return 1
    fi
    return 0
}

TARGET=""; UNIT_DIR=""; SC=""
choose_target() {
    if [ "$PLATFORM" = "Darwin" ]; then
        TARGET="launchd"; UNIT_DIR="${LAUNCHD_AGENTS_DIR:-${HOME:?HOME is required}/Library/LaunchAgents}"; SC="${LAUNCHCTL:-launchctl}"; return 0
    fi
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ]; then
        TARGET="override"; UNIT_DIR="$SYSTEMD_UNIT_DIR"; SC="${SYSTEMCTL:-systemctl}"; return 0
    fi
    # `${SUDO+x}` distinguishes UNSET from SET-TO-EMPTY, so `SUDO=` really skips the probe.
    if [ -z "${SUDO+x}" ] && sudo -n true >/dev/null 2>&1; then
        TARGET="system"; UNIT_DIR="/etc/systemd/system"; SC="${SYSTEMCTL:-sudo -n systemctl}"; return 0
    fi
    if [ -n "${SUDO+x}" ] && { [ -z "$SUDO" ] || $SUDO true >/dev/null 2>&1; }; then
        TARGET="system"; UNIT_DIR="/etc/systemd/system"; SC="${SYSTEMCTL:-${SUDO:+$SUDO }systemctl}"; return 0
    fi
    if systemctl --user show-environment >/dev/null 2>&1; then
        TARGET="user"; UNIT_DIR="$HOME/.config/systemd/user"; SC="${SYSTEMCTL:-systemctl} --user"; return 0
    fi
    return 1
}

# ── install ──────────────────────────────────────────────────────────────────────────────────
do_install_systemd() {
    local src_svc="$TEMPLATES_DIR/$UNIT_NAME.service" src_tim="$TEMPLATES_DIR/$UNIT_NAME.timer"
    local tmpd changed=0
    [ -f "$src_svc" ] && [ -f "$src_tim" ] || { err "templates missing under $TEMPLATES_DIR ($UNIT_NAME.service / $UNIT_NAME.timer)"; return 1; }
    refuse_bad_target || return 1
    choose_target || { err "no scheduler available: no passwordless sudo for a system unit, and no systemd user manager. Install by hand, or give the box sudo. NOT silently skipping — an unscheduled conflict-rebase bot is the gap this installer exists to close."; return 1; }
    # `--report-only`: the SAME artifact with the observation flag rendered in.

    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/conflict-rebase-unit.XXXXXX")" || { err "cannot create a temp dir"; return 1; }
    render "$src_svc" "$tmpd/$UNIT_NAME.service" || { rm -rf "$tmpd"; return 1; }
    render "$src_tim" "$tmpd/$UNIT_NAME.timer" || { rm -rf "$tmpd"; return 1; }
    if [ -n "$MODE_FLAG" ]; then
        # The mode is an ENVIRONMENT value on both platforms (the .py honours CONFLICT_REBASE_DRY_RUN),
        # so disarming never hand-edits an installed file: it re-renders.
        printf 'Environment=CONFLICT_REBASE_DRY_RUN=1\n' >>"$tmpd/$UNIT_NAME.service"
    fi
    if [ "$TARGET" = "user" ]; then
        sed -i.bak '/^User=/d' "$tmpd/$UNIT_NAME.service" && rm -f "$tmpd/$UNIT_NAME.service.bak"
    fi
    # ⛔ A RENDERED SERVICE WITH NO `ExecStart=` IS A UNIT THAT CANNOT RUN, and systemd accepts the
    # FILE and then refuses the TIMER that triggers it ("unit … to trigger not loaded") — MEASURED
    # 2026-11-07: the first render of this very template shipped without one, `enable --now` printed
    # `Job failed`, and the timer read `inactive` while the files looked perfect. Reading the artifact
    # before installing it is what turns that into an install-time refusal instead of a mystery.
    grep -q '^ExecStart=' "$tmpd/$UNIT_NAME.service" || {
        err "REFUSING: the rendered $UNIT_NAME.service has no ExecStart= — systemd accepts the file and then refuses the timer that triggers it. Fix the template, not the box."
        rm -rf "$tmpd"; return 1; }

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_line "dry-run: would install to $UNIT_DIR (target=$TARGET), enable $UNIT_NAME.timer, cadence ${INTERVAL_MIN}min${MODE_FLAG:+, report-only}"
        log_line "--- $UNIT_NAME.service ---"; sed 's/^/  /' "$tmpd/$UNIT_NAME.service"
        log_line "--- $UNIT_NAME.timer ---"; sed 's/^/  /' "$tmpd/$UNIT_NAME.timer"
        rm -rf "$tmpd"; return 0
    fi

    cmp -s "$tmpd/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.service" || changed=1
    cmp -s "$tmpd/$UNIT_NAME.timer" "$UNIT_DIR/$UNIT_NAME.timer" || changed=1
    mkdir -p "$UNIT_DIR" 2>/dev/null || true
    # The file op follows the TARGET, never $SUDO: TARGET=user is reachable only when the sudo probe
    # FAILED, so routing a user install through sudo asks it to do what it just refused.
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

    $SC daemon-reload >/dev/null 2>&1 || { err "daemon-reload failed"; return 1; }
    # IDEMPOTENCE: the two scheduler calls below run on EVERY install on purpose — they are idempotent
    # and they are what RE-ARMS a timer somebody disabled by hand. What the byte compare avoids is
    # rewriting the unit, not the re-arm (the same split install-harness-apply-timer.sh records).
    $SC enable --now "$UNIT_NAME.timer" || { err "could not enable/start $UNIT_NAME.timer"; return 1; }

    # ⛔ VERIFY AFTER ARMING. A timer that is enabled but whose service cannot start reads healthy in
    # `list-timers` until the first tick fails — the false PASS this family of installers exists for.
    local en act
    en="$($SC is-enabled "$UNIT_NAME.timer" 2>/dev/null || true)"
    act="$($SC is-active "$UNIT_NAME.timer" 2>/dev/null || true)"
    [ "$en" = "enabled" ] || [ "$en" = "enabled-runtime" ] || { err "$UNIT_NAME.timer is not enabled after install (is-enabled=$en)"; return 1; }
    [ "$act" = "active" ] || { err "$UNIT_NAME.timer is not active after install (is-active=$act)"; return 1; }
    log_line "installed: $UNIT_DIR/$UNIT_NAME.{service,timer} (target=$TARGET, scope=${TARGET}, changed=$changed)"
    log_line "armed: $UNIT_NAME.timer enabled+active, cadence ${INTERVAL_MIN}min${MODE_FLAG:+, REPORT-ONLY (dry-run rendered)}"
    log_line "brake: $STATE/PAUSED (create it with 'conflict-rebase-timer.sh pause'; 'resume' removes it)"
    log_line "beacon: $STATE/timer.beat  (epoch of the last completed pass; .log and last-failure sit beside it)"
    return 0
}

do_install_launchd() {
    local src="$LAUNCHD_TEMPLATES_DIR/$LABEL.plist" tmpd changed=0
    [ -f "$src" ] || { err "plist template missing: $src"; return 1; }
    refuse_bad_target || return 1
    # ⛔ THE LAUNCHD TARGET DIRECTORY IS NOT RESOLVED FOR US — AND IT WAS EMPTY. `choose_target` is what
    # assigns TARGET/UNIT_DIR/SC, and this path calls `refuse_bad_target` BEFORE it on purpose (a refusal
    # must precede any scheduler probe). So at this point UNIT_DIR and SC were both empty: `mkdir -p ""`
    # failed with `cannot create ''`, and the macOS install could NEVER complete. `--dry-run` returns above
    # the mkdir, which is exactly why a review that exercised only the dry-run render did not see it —
    # MEASURED on this suite's own fixture: the first real `--install` printed `mkdir: cannot create
    # directory ''` and exited 1. do_status and do_uninstall already set these three explicitly for
    # Darwin; the install path is the one that did not, and nothing ever ran it (review P1-2).
    TARGET="launchd"
    UNIT_DIR="${LAUNCHD_AGENTS_DIR:-${HOME:?HOME is required}/Library/LaunchAgents}"
    SC="${LAUNCHCTL:-launchctl}"
    resolve_launcher || return 1
    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/conflict-rebase-plist.XXXXXX")" || { err "cannot create a temp dir"; return 1; }
    render "$src" "$tmpd/$LABEL.plist" || { rm -rf "$tmpd"; return 1; }
    if [ -n "$MODE_FLAG" ]; then
        # ⛔ THE KEY MUST LAND INSIDE `EnvironmentVariables`, AND THE OLD CODE PUT IT AT THE TOP LEVEL.
        # It inserted before the LAST `</dict>` in the file — which is the TOP-LEVEL dict, not the env
        # one — so launchd ignored an unknown top-level key, while this script printed
        # "REPORT-ONLY (dry-run rendered)" and `plist_is_valid` passed. An operator disarming a bot that
        # REBASES AND PUSHES branches got a valid-looking artifact, a success message, and a bot that
        # kept acting (review F3). Parse, insert into the dict, then READ THE VALUE BACK — a flag that
        # cannot be read back is not a flag.
        python3 - "$tmpd/$LABEL.plist" <<'PY' || { rm -rf "$tmpd"; err "could not render the report-only mode into the plist's EnvironmentVariables"; return 1; }
import sys, plistlib
p = sys.argv[1]
d = plistlib.load(open(p, "rb"))
env = d.get("EnvironmentVariables")
if not isinstance(env, dict):
    sys.exit(1)                      # no env dict to put it in -> refuse, never silently no-op
env["CONFLICT_REBASE_DRY_RUN"] = "1"
plistlib.dump(d, open(p, "wb"))
chk = plistlib.load(open(p, "rb")).get("EnvironmentVariables", {}).get("CONFLICT_REBASE_DRY_RUN")
if chk != "1":
    sys.exit(1)                      # the read-back is the point: no proof, no artifact
PY
    fi
    plist_is_valid "$tmpd/$LABEL.plist" || { err "the rendered plist does not parse — refusing to install it (launchd would refuse it AFTER the artifact is in place, and the failure would read like a scheduler problem)"; rm -rf "$tmpd"; return 1; }
    # …and after it validates, the MODE must still be readable in the artifact we are about to install.
    if [ -n "$MODE_FLAG" ] && ! python3 -c 'import sys, plistlib
d = plistlib.load(open(sys.argv[1], "rb"))
sys.exit(0 if (d.get("EnvironmentVariables") or {}).get("CONFLICT_REBASE_DRY_RUN") == "1" else 1)' "$tmpd/$LABEL.plist" 2>/dev/null; then
        err "the rendered plist does not carry CONFLICT_REBASE_DRY_RUN in EnvironmentVariables — refusing to install a 'report-only' job that would still act"
        rm -rf "$tmpd"; return 1
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_line "dry-run: would install $UNIT_DIR/$LABEL.plist and bootstrap gui/$(id -u)/$LABEL, cadence ${INTERVAL_MIN}min${MODE_FLAG:+, report-only}"
        sed 's/^/  /' "$tmpd/$LABEL.plist"
        rm -rf "$tmpd"; return 0
    fi

    mkdir -p "$UNIT_DIR" || { err "cannot create $UNIT_DIR"; rm -rf "$tmpd"; return 1; }
    cmp -s "$tmpd/$LABEL.plist" "$UNIT_DIR/$LABEL.plist" || changed=1
    install -m 0644 "$tmpd/$LABEL.plist" "$UNIT_DIR/$LABEL.plist" || { err "install failed writing $UNIT_DIR/$LABEL.plist"; rm -rf "$tmpd"; return 1; }
    rm -rf "$tmpd"

    # bootout is best-effort: it fails when the job was never loaded, which is the fresh-box case.
    $SC bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    $SC bootstrap "gui/$(id -u)" "$UNIT_DIR/$LABEL.plist" || { err "launchctl bootstrap failed for $LABEL"; return 1; }
    $SC kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true

    # ⛔ VERIFY AFTER ARMING, by RE-READING the label — not by trusting bootstrap's exit code.
    $SC print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || { err "$LABEL is not loaded after bootstrap — the agent would silently never run"; return 1; }
    log_line "installed: $UNIT_DIR/$LABEL.plist (changed=$changed)"
    log_line "armed: $LABEL loaded in gui/$(id -u), cadence ${INTERVAL_MIN}min${MODE_FLAG:+, REPORT-ONLY (dry-run rendered)}"
    log_line "brake: $STATE/PAUSED (create it with 'conflict-rebase-timer.sh pause'; 'resume' removes it)"
    log_line "beacon: $STATE/timer.beat  (epoch of the last completed pass; .log and last-failure sit beside it)"
    return 0
}

do_install() {
    if [ "$PLATFORM" = "Darwin" ]; then do_install_launchd; else do_install_systemd; fi
}

# ── status ──────────────────────────────────────────────────────────────────────────────────
do_status() {
    local now beat age rc=0 en act last_fire result
    now="$(date +%s)"
    if [ "$PLATFORM" = "Darwin" ]; then
        TARGET="launchd"; UNIT_DIR="${LAUNCHD_AGENTS_DIR:-$HOME/Library/LaunchAgents}"; SC="${LAUNCHCTL:-launchctl}"
        if [ -f "$UNIT_DIR/$LABEL.plist" ]; then log_line "plist: present ($UNIT_DIR/$LABEL.plist)"; else log_line "plist: ABSENT"; rc=1; fi
        if $SC print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then log_line "loaded: yes (gui/$(id -u)/$LABEL)"; else log_line "loaded: NO"; rc=1; fi
        log_line "armed: $([ -f "$UNIT_DIR/$LABEL.plist" ] && echo yes || echo no)"
    else
        if choose_target >/dev/null 2>&1; then :; else SC="${SYSTEMCTL:-systemctl}"; fi
        en="$($SC is-enabled "$UNIT_NAME.timer" 2>/dev/null || true)"
        act="$($SC is-active "$UNIT_NAME.timer" 2>/dev/null || true)"
        last_fire="$($SC show -p LastTriggerUSec --value "$UNIT_NAME.timer" 2>/dev/null || true)"
        # ⛔ SOME SYSTEMD VERSIONS PRINT `n/a` (not an empty string) FOR A TIMER THAT HAS NEVER FIRED.
        # Without this arm `--status` printed `last_fire: n/a` and then passed the `-n` test below, so a
        # never-fired timer read as armed (review F18). Same vocabulary as activate-harness.sh's age_of.
        case "$last_fire" in n/a|never|-) last_fire="" ;; esac
        result="$($SC show -p Result --value "$UNIT_NAME.service" 2>/dev/null || true)"
        log_line "enabled: ${en:-unknown}"
        log_line "active:  ${act:-unknown}"
        log_line "last_fire: ${last_fire:-never}"
        log_line "last_result: ${result:-unknown}"
        log_line "armed: $([ "$en" = enabled ] && echo yes || echo no)"
        [ "$en" = "enabled" ] || rc=1
        [ "$act" = "active" ] || rc=1
        [ -n "$last_fire" ] || { log_line "NEVER FIRED — the unit is installed but has never triggered (on a monotonic timer this means no OnBootSec/OnCalendar armed the cycle)"; rc=1; }
    fi
    if [ -f "$STATE/timer.beat" ]; then
        beat="$(cat "$STATE/timer.beat" 2>/dev/null || echo 0)"
        case "$beat" in ''|*[!0-9]*) beat=0 ;; esac
        age=$(( now - beat ))
        log_line "beacon: $STATE/timer.beat = ${beat} (${age}s ago)"
    else
        log_line "beacon: NEVER — no pass has completed"
        rc=1
    fi
    [ -f "$STATE/PAUSED" ] && log_line "brake: PAUSED (the pass refuses to act)" || log_line "brake: not paused ($STATE/PAUSED absent)"
    [ -f "$STATE/last-failure" ] && { log_line "LAST PASS FAILED: $(cat "$STATE/last-failure")"; rc=1; } || log_line "last pass: ok (or none yet)"
    return "$rc"
}

do_uninstall() {
    local rc=0
    if [ "$PLATFORM" = "Darwin" ]; then
        TARGET="launchd"; UNIT_DIR="${LAUNCHD_AGENTS_DIR:-$HOME/Library/LaunchAgents}"; SC="${LAUNCHCTL:-launchctl}"
        $SC bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
        rm -f "$UNIT_DIR/$LABEL.plist" || rc=1
        # ⛔ RE-READ the label: a file removed while the LOADED job keeps firing is not an uninstall.
        $SC print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && { err "$LABEL is STILL LOADED after bootout"; rc=1; }
        log_line "uninstalled: $UNIT_DIR/$LABEL.plist"
    else
        if choose_target >/dev/null 2>&1; then :; else SC="${SYSTEMCTL:-systemctl}"; fi
        $SC disable --now "$UNIT_NAME.timer" >/dev/null 2>&1 || true
        # ⛔ THE REMOVAL FOLLOWS THE TARGET THE INSTALL WROTE TO. `SYSTEMD_UNIT_DIR` is a documented
        # override seam, and without this arm an override install was "uninstalled" by deleting
        # /etc/systemd/system — files it had never written — while the override copies stayed in place,
        # armed and firing: the installer printed `uninstalled`, and the unit was still there (a false
        # PASS, measured by this suite's T9 before the arm existed).
        case "$TARGET" in
            override) rm -f "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer" || rc=1 ;;
            user) rm -f "$HOME/.config/systemd/user/$UNIT_NAME.service" "$HOME/.config/systemd/user/$UNIT_NAME.timer" || rc=1 ;;
            *)    ${SUDO-sudo -n} rm -f "/etc/systemd/system/$UNIT_NAME.service" "/etc/systemd/system/$UNIT_NAME.timer" || rc=1 ;;
        esac
        $SC daemon-reload >/dev/null 2>&1 || true
        log_line "uninstalled: $UNIT_NAME.{service,timer} (state and beacon left in place: $STATE)"
    fi
    return "$rc"
}

case "$VERB" in
    install)   do_install ;;
    status)    do_status ;;
    uninstall) do_uninstall ;;
esac
