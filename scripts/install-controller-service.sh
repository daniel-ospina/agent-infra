#!/usr/bin/env bash
# ⛔ SOURCING THIS FILE IS INERT (re-review, #2666). It is a SCRIPT with a top-level argument loop and an
# action dispatch, so `source scripts/install-controller-service.sh` used to fall through to
# `ACTION=--install` and INSTALL A REAL, ENABLED UNIT on whatever box ran it — measured in this lane's own
# verification round, where a reviewer that wanted the helper functions wrote `/etc/systemd/system/
# eldato-orchestrator.service` plus its `multi-user.target.wants` link and had to revert them by hand.
# An enabled unit is a second supervisor the moment anything starts it, which is the #1761 duplicate this
# whole file exists to prevent; a *reading* action must therefore never reach the dispatch. Nothing in this
# repo sources it (checked), so this guard costs no caller anything.
if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then
    return 0 2>/dev/null || exit 0
fi
# install-controller-service.sh — put the cell's ORCHESTRATOR CONTROLLER under a service manager
# (agent-infra#2402).
#
# WHY THIS IS AN INSTALLER AND NOT A LINE IN THE BRING-UP. The artifact has to be rendered from machine
# state (HOME, PATH, the state dir the supervisor reads, the supervisor's own path) and installed
# idempotently; the bring-up is the TRIGGER, this is the policy of WHERE and HOW. Same split as
# install-disk-reaper-timer.sh — one place renders and converges, everything else calls it.
#
# ⛔ THE DEFECT THIS REMOVES. `cloud-cell-supervisor.sh start` handed the controller to a tmux session,
# and a tmux session has nothing above it: when the box emptied and the last session closed, the server
# exited and no surface restarted the controller. MEASURED 2026-10-23 on cell-1: 02:20Z `tmux ls` →
# "no server running on /tmp/tmux-1000/default", `pgrep -fc "[o]rch-loop.sh"` → 0, with landings having
# completed normally at 01:56/02:10/02:16 — the lanes finished and exited, nothing crashed. The cell then
# sits idle with no dispatcher and reads as a healthy idle box.
#
# The unit renders `Restart=always` (NOT `on-failure`: the measured case is an ORDERLY exit 0) with a
# stated `RestartSec`, ordered `After=network-online.target`, and its ExecStart runs the supervisor with
# ORCH_FOREGROUND=1 so the controller becomes the UNIT's main process rather than a session's child.
# `cloud-cell-supervisor.sh` cooperates in both directions: `stop` stops the unit (a pid kill is undone by
# Restart=always within RestartSec) and `start` starts the unit when one is enabled (a tmux controller
# beside an enabled unit is two dispatchers on one queue, #1761).
#
# INSTALL TARGETS, tried in this order, and the reason is named in the output:
#   1. a SYSTEM unit via passwordless sudo (/etc/systemd/system) — the cell's normal shape; the service
#      runs as the invoking user, so the state dir, keys.env and gh auth are the operator's, not root's.
#   2. a USER unit (~/.config/systemd/user) when systemd's user manager actually answers — a box without
#      sudo still gets a supervisor, plus the linger check below (a user manager that dies with the last
#      login is a supervisor that dies with the last lane — the very defect this fixes).
#   3. nothing — a loud FAILURE with the remedy, never a silent no-op. A controller that was "installed"
#      but never supervised is the false PASS this repo keeps removing.
#
# macOS IS REFUSED, not degraded. A Mac's controller is already a launchd agent with KeepAlive
# (`orchestrator-harness/install.sh`), so a second supervisor there would be a second dispatcher. The
# refusal names that installer.
#
# Usage:
#   install-controller-service.sh [--install] [--dry-run] [--status] [--uninstall] [--help]
#
# Env seams (tests + unusual cells):
#   ORCH_SUPERVISOR        the supervisor entry point the unit runs
#                          (default: $HOME/.pi/agent/scripts/cloud-cell-supervisor.sh, else beside this)
#   ORCH_RESTART_SEC       the rendered RestartSec (default 15; a whole number of seconds, >= 1)
#   ORCH_START_TIMEOUT_SEC the ORPHAN-handover ceiling (default 60; a whole number, and one that fits
#                          StartLimitBurst attempts inside StartLimitIntervalSec — see do_install).
#                          Rendered as CONTROLLER_ORPHAN_TIMEOUT, and as TimeoutStartSec — its systemd-side
#                          counterpart (this unit is Type=simple, where that directive does not bound start)
#   ORCH_HANDOVER_TIMEOUT_SEC the handover ceiling for a controller this state dir still OWNS (default 3600;
#                          a whole number >= 1). Long on purpose: that controller is landing work
#   CELL_HOME              the cell's home whose keys.env/state the controller reads (default $HOME)
#   ENV_FILE               the controller's env file (default $CELL_HOME/keys.env)
#   O                      the controller's state dir, used only to READ BACK the heartbeat
#                          (default $CELL_HOME/orchestrator)
#   TEMPLATES_DIR          template dir (default: this repo's templates/systemd)
#   SYSTEMD_UNIT_DIR       install dir OVERRIDE (tests: a temp dir, with SYSTEMCTL a fake)
#   SYSTEMCTL              `systemctl` to call (tests: a shim; default `sudo -n systemctl` for a system
#                          unit, `systemctl --user` otherwise)
#   SUDO                   `sudo` probe (default `sudo -n`)
#   ELDATO_PLATFORM        override `uname -s` (tests render the Darwin refusal on any host)
#   CONTROLLER_UNIT        unit name override (default eldato-orchestrator.service)
#
# Exit codes: 0 ok · 1 failure (named) · 2 usage.
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_NAME="${CONTROLLER_UNIT:-eldato-orchestrator.service}"
# THE UNIT NAME IS A NAME, NOT A PATH (review residual round 6, #2666). `CONTROLLER_UNIT` is concatenated
# onto the directory this installer GRADES (`$UNIT_DIR/$UNIT_NAME`), so a value carrying `/` or `..` would
# write outside the directory that was checked — the guard would grade one path and `install` the other. The
# template filename is taken from the same value, so a traversal here is also a template traversal.
case "$UNIT_NAME" in
    ''|.|..|*/*) printf '%s: %s\n' "${0##*/}" "REFUSING CONTROLLER_UNIT='$UNIT_NAME': it must be a bare unit file name (no '/', not '.' or '..') — it is appended to the unit directory this installer grades, so a path here would write outside it, and the template filename comes from the same value" >&2; exit 2 ;;
esac
# Templates are NOT farmed (only scripts are), so a farmed copy of this installer must be able to find
# them in the checkout that installed the layer. ⛔ THE CANDIDATE MUST CARRY *THIS* TEMPLATE, not merely
# exist: $AGENT_INFRA_PATH is set on every cell and is often a DIFFERENT (older) checkout, so a
# directory-exists test silently rendered another tree's templates — measured while writing this PR as
# "template missing: <the other checkout>/templates/systemd/eldato-orchestrator.service".
if [ -z "${TEMPLATES_DIR:-}" ]; then
    for _cand in "$INFRA_ROOT/templates/systemd" "${AGENT_INFRA_PATH:-}/templates/systemd"; do
        [ -n "$_cand" ] && [ -f "$_cand/$UNIT_NAME" ] && { TEMPLATES_DIR="$_cand"; break; }
    done
    # No candidate carries it: report against the first dir that EXISTS, so the operator sees a real path.
    if [ -z "${TEMPLATES_DIR:-}" ]; then
        for _cand in "$INFRA_ROOT/templates/systemd" "${AGENT_INFRA_PATH:-}/templates/systemd"; do
            [ -n "$_cand" ] && [ -d "$_cand" ] && { TEMPLATES_DIR="$_cand"; break; }
        done
    fi
fi
TEMPLATES_DIR="${TEMPLATES_DIR:-$INFRA_ROOT/templates/systemd}"
PLATFORM="${ELDATO_PLATFORM:-$(uname -s 2>/dev/null || printf 'unknown')}"
RESTART_SEC="${ORCH_RESTART_SEC:-15}"
# ⛔ TWO BOUNDS, AND ONLY ONE OF THEM CAN DESCRIBE AN IMPOSSIBLE START (review P1, #2402). A `Type=simple`
# start job completes at fork (systemd.service(5)), so `TimeoutStartSec` does NOT bound `ExecStart`; the
# earlier claim that it did was inert, and the wait fell back to the supervisor's 3600 s default. Both
# bounds are now rendered into the unit's ENVIRONMENT, where the supervisor actually reads them:
#   CONTROLLER_ORPHAN_TIMEOUT (START_TIMEOUT_SEC) — a session outlived its loop. An orphan never exits, so
#     that start can never succeed: StartLimitBurst of them must fit INSIDE StartLimitIntervalSec
#     (`burst × (orphan + RestartSec) < interval`, enforced in do_install) so the burst is exceeded and the
#     unit converges to `failed` instead of restarting forever.
#   CONTROLLER_HANDOVER_TIMEOUT (HANDOVER_TIMEOUT_SEC) — an owned controller is still running, which is the
#     migration path and is landing work. A long bound is correct here; a short one would fail the upgrade.
START_TIMEOUT_SEC="${ORCH_START_TIMEOUT_SEC:-60}"
HANDOVER_TIMEOUT_SEC="${ORCH_HANDOVER_TIMEOUT_SEC:-3600}"
CELL_HOME="${CELL_HOME:-${HOME:?HOME is required}}"
ENV_FILE="${ENV_FILE:-$CELL_HOME/keys.env}"
O="${O:-$CELL_HOME/orchestrator}"
ACTION=--install

log_line() { printf '%s\n' "$*"; }
err() { printf '%s: %s\n' "${0##*/}" "$*" >&2; }

# help_text — print the header comments. The range is DERIVED from the `set -uo pipefail` line, never a
# hand-maintained constant: a constant silently truncates the header whenever a line is added above it.
help_text() {
    local n
    n="$(grep -n '^set -uo pipefail' "$0" 2>/dev/null | head -1 | cut -d: -f1)"
    case "${n:-}" in ''|*[!0-9]*) err "cannot locate the header in $0"; return 2 ;; esac
    sed -n "2,$((n - 1))p" "$0"
}

# ── the supervisor the unit runs ────────────────────────────────────────────────────────────────
# ⛔ RESOLVED AND PROVEN TO EXIST BEFORE ANYTHING IS RENDERED. A unit whose ExecStart names a missing file
# is the inert-enforcer shape: `enable --now` succeeds, `is-active` says active, and every restart is a
# 127 with no controller — a supervised-looking box that dispatches nothing.
SUPERVISOR=""
resolve_supervisor() {
    local c
    for c in "${ORCH_SUPERVISOR:-}" \
             "$HOME/.pi/agent/scripts/cloud-cell-supervisor.sh" \
             "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/cloud-cell-supervisor.sh"; do
        [ -n "$c" ] && [ -f "$c" ] && { SUPERVISOR="$c"; break; }
    done
    [ -n "$SUPERVISOR" ] || {
        err "cloud-cell-supervisor.sh not found — looked at \$ORCH_SUPERVISOR, \$HOME/.pi/agent/scripts, and beside this installer. Farm it first: bash pi-bootstrap/setup.sh"
        return 1
    }
    return 0
}

# ── choose a target ─────────────────────────────────────────────────────────────────────────────
TARGET=""; UNIT_DIR=""; SC=""; WANTED_BY="multi-user.target"
# ⛔ THE BOOT TARGET IS A PROPERTY OF THE SCOPE, NOT A CONSTANT (review P2, #2402). `multi-user.target`
# does not exist in a per-user manager, so a user unit enabled against it would never be brought back —
# the defect this installer removes, one layer down. Resolved here beside the scope so the two cannot
# disagree, and the rendered line is asserted below.
# ⛔ A UNIT DIRECTORY SYSTEMD READS AND THIS FLEET'S READERS DO NOT IS A SECOND DISPATCHER (review P1,
# #2402; re-review P1). `SYSTEMD_UNIT_DIR` is the installer's WRITE override, but the supervisor discovers a
# unit only under the system dir (`CONTROLLER_SYSTEM_UNIT_DIR`, default `/etc/systemd/system`) and the user
# dirs it enumerates (`cloud-cell-supervisor.sh::controller_unit_copies`). systemd additionally loads units
# from `/etc/systemd/system.control`, `/etc/systemd/system.attached`, `/run/systemd/system.control`,
# `/run/systemd/system.attached`, `/run/systemd/generator*`, `/usr/lib/systemd/system`,
# `/usr/local/lib/systemd/system`, and the user managers' `/etc/systemd/user`, `/etc/xdg/systemd/user`,
# `~/.local/share/systemd/user`. A unit written into any of those is ENABLED and BOOT-ARMED while
# `start`/`stop`/`status` cannot see it at all: when it dies the doctor finds no unit, launches a tmux
# controller, and `Restart=always` revives the unit — TWO dispatchers on one queue (#1761), the exact
# duplicate this feature exists to prevent.
#
# ⛔ NOT A HAND-MAINTAINED LIST OF DIRECTORIES, AND NOT A LITERAL COMPARISON (re-review P1, #2666). Two
# measured escapes of the first form: an UNLISTED systemd path (`/run/systemd/system.control` — which
# `systemd-analyze unit-paths` prints on this host — was admitted and dry-ran `would install …`), and any
# SYMLINKED spelling of a refused directory (`ln -s /etc/systemd/system.control $T/alias &&
# SYSTEMD_UNIT_DIR=$T/alias` was admitted), because a literal match cannot see through an alias. So the
# decision is taken on the RESOLVED path, and the test is the systemd TREE (every directory under a
# manager's unit root), not one filename per revision of systemd. The only members of those trees that
# stay allowed are the two directories the cooperating verbs read BY DEFAULT — compared after resolution,
# so re-pointing `CONTROLLER_SYSTEM_UNIT_DIR` at a refused directory cannot make the guard agree with
# itself. A directory OUTSIDE every systemd tree (a hermetic test fixture under `$TMPDIR`) is always
# allowed: nothing boots it.
# ⛔ THE PATH IS RESOLVED WITH `mkdir -p` SEMANTICS, OR NOT AT ALL (review P1 rounds 4 and 5, #2666). Four
# successive fixes each graded a slightly different path than the one `mkdir -p` writes to: a literal that
# never collapsed `..`; a `..` collapsed LEXICALLY across a missing component; then a `..` popped across a
# MISSING component that landed on an existing SYMLINK (`<tmp>/tree/new/../lnk/systemd/user` — `new` does not
# exist, so a lexical pop skips it and then reads `lnk` as a plain name, while `mkdir -p` creates `new`,
# steps back, and FOLLOWS `lnk`). `realpath -m` has exactly the semantics needed — it resolves every
# component that exists, follows symlinks wherever the filesystem can answer, and collapses only what does
# not exist.
#
# ⛔ AND WHEN THE BOX CANNOT ANSWER, THE GUARD REFUSES INSTEAD OF GRADING A GUESS. `__unresolved__:<raw>` is
# returned and `choose_target` turns it into a loud refusal naming the missing tool: a directory that cannot
# be shown to be outside systemd's unit trees is not one this installer may arm a unit in. The alternative —
# the best-effort literal every earlier round shipped — is a fail-OPEN, and a fail-open here puts an enabled,
# boot-armed unit somewhere `start`/`stop`/`status` cannot see it (#1761).
CANON_UNRESOLVED='__unresolved__:'
canon_dir() { # <dir> — the physical path `mkdir -p` WOULD land on, or `__unresolved__:<dir>`
    local d="${1:-}" out=""
    [ -n "$d" ] || return 0
    if command -v realpath >/dev/null 2>&1; then
        out="$(realpath -m -- "$d" 2>/dev/null || true)"
        [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    fi
    if command -v readlink >/dev/null 2>&1 && readlink -f -- "$d" >/dev/null 2>&1; then
        out="$(readlink -f -- "$d")"
        [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    fi
    if [ -d "$d" ]; then
        out="$( cd "$d" 2>/dev/null && pwd -P )"
        # A LEADING SLASH RUN IS ONE SLASH (review P1 round 6, #2666): POSIX makes a leading `//`
        # implementation-defined and bash's `pwd -P` PRESERVES it, so on a box where neither `realpath` nor
        # `readlink -f` can answer, `//etc/systemd/user` came back spelled with two slashes and matched no
        # tree pattern — ADMITTED, where the same directory with one slash is refused. Collapsing it here
        # means every branch returns the same spelling for the same directory.
        # ⛔ AND ONLY WHEN `cd` ACTUALLY ANSWERED (VGATE round 6, #2666): collapsing BEFORE the emptiness
        # test turned a failed `cd` — a directory that exists but cannot be entered (mode), or one removed
        # between `-d` and `cd` — into `/`, which the `[ -n "$out" ]` gate then accepted. That is the exact
        # fail-open this branch is not allowed to have: a directory the guard cannot grade must reach the
        # `__unresolved__` sentinel below, never be read as the root.
        if [ -n "$out" ]; then
            while [ "${out#/}" != "$out" ]; do out="${out#/}"; done
            printf '%s\n' "/$out"; return 0
        fi
    fi
    printf '%s%s\n' "$CANON_UNRESOLVED" "$d"
}
unit_dir_under() { # <resolved dir> <root> — true when <dir> IS <root> or inside it (both resolved)
    local d="${1%/}" r
    r="$(canon_dir "${2:-}")"
    [ -n "$r" ] && [ "$r" != "/" ] || return 1
    case "$d" in "$r"|"$r"/*) return 0 ;; esac
    return 1
}
unit_dir_in_systemd_tree() { # <resolved dir> — a tree one of systemd's managers loads units from
    local d="${1%/}" r
    case "$d" in
        /etc/systemd|/etc/systemd/*) return 0 ;;
        /run/systemd|/run/systemd/*) return 0 ;;
        /run/user/*/systemd|/run/user/*/systemd/*) return 0 ;;
        /usr/lib/systemd|/usr/lib/systemd/*) return 0 ;;
        /usr/local/lib/systemd|/usr/local/lib/systemd/*) return 0 ;;
        /lib/systemd|/lib/systemd/*) return 0 ;;
        /etc/xdg/systemd|/etc/xdg/systemd/*) return 0 ;;
    esac
    # ⛔ THE HOME AND XDG ROOTS ARE RESOLVED BEFORE THEY ARE COMPARED (re-review P1, #2666). The candidate is
    # resolved; comparing it against an UNRESOLVED `${HOME}` re-opened the very hole this fix closes — with
    # `$HOME` a symlink (`/home/op -> /mnt/data/op`), `$HOME/.local/share/systemd/user` resolved to
    # `/mnt/data/op/...` and matched no pattern, so a real systemd user unit dir was ADMITTED while the
    # previous revision refused it. `$XDG_CONFIG_HOME`/`$XDG_DATA_HOME`/`$XDG_RUNTIME_DIR` are real user
    # manager unit roots too (systemd.unit(5)) and were missing entirely.
    for r in "${XDG_CONFIG_HOME:-}" "${XDG_DATA_HOME:-}" "${XDG_RUNTIME_DIR:-}"; do
        [ -n "$r" ] && unit_dir_under "$d" "$r/systemd" && return 0
    done
    for r in "${HOME:-}" "$(passwd_home "$(id -u)" 2>/dev/null || true)" "$(passwd_home "${SUDO_USER:-}" 2>/dev/null || true)"; do
        [ -n "$r" ] || continue
        unit_dir_under "$d" "$r/.config/systemd" && return 0
        unit_dir_under "$d" "$r/.local/share/systemd" && return 0
    done
    return 1
}
unit_dir_is_read_by_default() { # <resolved dir> — searched by the supervisor with NO override in play
    local d="${1%/}" h
    [ "$d" = "/etc/systemd/system" ] && return 0
    for h in "${HOME:-}" "$(passwd_home "$(id -u)" 2>/dev/null || true)" "$(passwd_home "${SUDO_USER:-}" 2>/dev/null || true)"; do
        [ -n "$h" ] && [ "$d" = "$(canon_dir "${h%/}/.config/systemd/user")" ] && return 0
    done
    return 1
}
wanted_by() {
    case "$1" in
        user) printf 'default.target\n' ;;
        *)    printf 'multi-user.target\n' ;;
    esac
}
choose_target() {
    if [ "$PLATFORM" = "Darwin" ]; then
        err "REFUSING on Darwin: a Mac's controller is already a launchd agent with KeepAlive"
        err "  (orchestrator-harness/launchd.plist.template, installed by orchestrator-harness/install.sh)."
        err "  A second supervisor here would be a SECOND dispatcher on one queue — use:"
        err "    bash $INFRA_ROOT/scripts/orchestrator-harness/install.sh --start"
        return 1
    fi
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ]; then
        _unit_dir_resolved="$(canon_dir "$SYSTEMD_UNIT_DIR")"
        # ⛔ AN UNRESOLVABLE DIRECTORY IS REFUSED, NOT GUESSED (review P1 round 5, #2666). Grading the raw
        # spelling is how four earlier rounds each failed open; a path that cannot be shown to be outside
        # systemd's unit trees is not one this installer may arm a unit in.
        case "$_unit_dir_resolved" in
            "$CANON_UNRESOLVED"*)
                err "REFUSING SYSTEMD_UNIT_DIR=$SYSTEMD_UNIT_DIR: it cannot be resolved to a physical path on this"
                err "  box (no 'realpath -m' and no usable 'readlink -f'), so it cannot be shown to be OUTSIDE systemd's"
                err "  unit trees. A unit installed where systemd loads it and start/stop/status do not look is an"
                err "  enabled, boot-armed SECOND dispatcher (#1761)."
                err "  Fix: install coreutils ('realpath'), or install into the system or the user unit dir."
                return 1 ;;
        esac
        if [ -n "$_unit_dir_resolved" ] && unit_dir_in_systemd_tree "$_unit_dir_resolved" \
           && ! unit_dir_is_read_by_default "$_unit_dir_resolved"; then
            err "REFUSING SYSTEMD_UNIT_DIR=$SYSTEMD_UNIT_DIR (resolves to $_unit_dir_resolved): systemd loads units"
            err "  from there, but every cooperating verb (start/stop/status) discovers a unit only under"
            err "  /etc/systemd/system or \$HOME/.config/systemd/user — so this would install an ENABLED, BOOT-ARMED"
            err "  unit that nothing here can see. When it dies the doctor launches a tmux controller and"
            err "  Restart=always revives the unit: TWO dispatchers on one queue (#1761), the duplicate this"
            err "  feature exists to prevent."
            err "  Fix: install into the system or the user unit dir — or point SYSTEMD_UNIT_DIR at a directory"
            err "  systemd does NOT load from (a hermetic test dir). The decision is taken on the RESOLVED path,"
            err "  so a symlink to a systemd directory is refused too."
            return 1
        fi
        TARGET="override"; UNIT_DIR="$SYSTEMD_UNIT_DIR"; SC="${SYSTEMCTL:-systemctl}"
        WANTED_BY="$(wanted_by override)"
        return 0
    fi
    # ⛔ `${SUDO:-sudo -n}` CANNOT BE EMPTY (`:-` substitutes on empty too), so `SUDO=` would be
    # unreachable as a documented "skip the sudo probe" seam. `${SUDO+x}` distinguishes unset from
    # set-to-empty, and a pinned SYSTEMCTL is honoured on the SYSTEM target too — a pinned shim silently
    # overridden installs the unit as one identity and enables it as another.
    if [ -z "${SUDO+x}" ] && sudo -n true >/dev/null 2>&1; then
        TARGET="system"; UNIT_DIR="/etc/systemd/system"; SC="${SYSTEMCTL:-sudo -n systemctl}"
        WANTED_BY="$(wanted_by system)"
        return 0
    fi
    if [ -n "${SUDO+x}" ] && { [ -z "$SUDO" ] || $SUDO true >/dev/null 2>&1; }; then
        TARGET="system"; UNIT_DIR="/etc/systemd/system"; SC="${SYSTEMCTL:-${SUDO:+$SUDO }systemctl}"
        WANTED_BY="$(wanted_by system)"
        return 0
    fi
    if systemctl --user show-environment >/dev/null 2>&1; then
        TARGET="user"; UNIT_DIR="$HOME/.config/systemd/user"; SC="${SYSTEMCTL:-systemctl} --user"
        WANTED_BY="$(wanted_by user)"
        return 0
    fi
    # ⛔ LOUD, NEVER SILENT. The header promises "nothing — a loud FAILURE with the remedy, never a silent
    # no-op", and a bare `return 1` here broke that promise: `do_install` exited 1 with NO output, so an
    # operator saw a failed verb and no reason — indistinguishable from a crash, and the one state ("this
    # box has no supervisor at all") most worth naming.
    err "REFUSING: no service manager is available on this box — nothing could supervise the controller"
    err "  tried: a SYSTEM unit via passwordless sudo (/etc/systemd/system), then systemd's USER manager."
    err "  Fix: provision systemd (or passwordless sudo for this operator), then re-run this installer."
    err "  Until then the controller is a tmux session with nothing above it (#2402): it keeps working"
    err "  until the box empties, and then it is gone with no signal."
    return 1
}

# render <template> <dest> — the ONE place placeholders are substituted. Both failure modes are caught:
# an unresolved `{{…}}` token (a template line with no rule — the unit then carries a literal path that
# never resolves) and an empty substitution (an `Environment=` with no value, which for SCOPE/ENV_FILE is
# FATAL operator config inside the loop rather than a default).
render() {
    local tpl="$1" dest="$2"
    sed -e "s|{{USER}}|$(sed_esc "$(id -un)")|g" \
        -e "s|{{HOME}}|$(sed_esc "$HOME")|g" \
        -e "s|{{CELL_HOME}}|$(sed_esc "$CELL_HOME")|g" \
        -e "s|{{ENV_FILE}}|$(sed_esc "$ENV_FILE")|g" \
        -e "s|{{PATH}}|$(sed_esc "$PATH")|g" \
        -e "s|{{SUPERVISOR}}|$(sed_esc "$SUPERVISOR")|g" \
        -e "s|{{RESTART_SEC}}|$RESTART_SEC|g" \
        -e "s|{{START_TIMEOUT_SEC}}|$START_TIMEOUT_SEC|g" \
        -e "s|{{HANDOVER_TIMEOUT_SEC}}|$HANDOVER_TIMEOUT_SEC|g" \
        -e "s|{{O}}|$(sed_esc "$O")|g" \
        -e "s|{{UNIT_NAME}}|$(sed_esc "$UNIT_NAME")|g" \
        -e "s|{{WANTED_BY}}|$WANTED_BY|g" \
        "$tpl" >"$dest" || return 1
    if grep -q '{{' "$dest"; then
        err "unresolved placeholder in the rendered unit:"; grep -n '{{' "$dest" >&2; return 1
    fi
    return 0
}
sed_esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# verify_unit <rendered file> — the properties the ISSUE names, asserted on the ARTIFACT rather than
# trusted to the template. A unit that renders `Restart=on-failure` would be a supervisor for crashes
# only, and the measured case is an orderly exit 0 — the exact defect, re-shipped.
verify_unit() {
    local f="$1" k
    for k in "Restart=always" "RestartSec=$RESTART_SEC" "After=network-online.target" \
             "StartLimitIntervalSec=300" "StartLimitBurst=3" "KillMode=process" \
             "TimeoutStartSec=$START_TIMEOUT_SEC" \
             "Environment=CONTROLLER_ORPHAN_TIMEOUT=$START_TIMEOUT_SEC" \
             "Environment=CONTROLLER_HANDOVER_TIMEOUT=$HANDOVER_TIMEOUT_SEC" \
             "Environment=ORCH_FOREGROUND=1" "Environment=O=$O" \
             "Environment=CONTROLLER_UNIT=$UNIT_NAME" \
             "ExecStart=/bin/bash $SUPERVISOR start" "User=$(id -un)" \
             "WantedBy=${WANTED_BY:-multi-user.target}"; do
        grep -qxF -- "$k" "$f" || { err "REFUSING: the rendered unit does not carry '$k'"; return 1; }
    done
    # The ExecStart target must EXIST — see resolve_supervisor's note. Checked on the rendered text, not
    # on $SUPERVISOR, so a template that names a different path cannot pass this.
    [ -f "$SUPERVISOR" ] || { err "REFUSING: ExecStart names $SUPERVISOR, which does not exist"; return 1; }
    return 0
}

# ── read-backs ────────────────────────────────────────────────────────────────────────────────
# $SC is a COMMAND STRING (it may be "sudo -n systemctl"), so it is expanded unquoted on purpose.
sc_run() { $SC "$@"; }
# ⛔ THREE ANSWERS, NOT TWO (review P2, #2402). `is-active --quiet` answers "no" for BOTH `inactive` and
# "cannot read", and `--status` is the verb an operator reads as a verdict: folding an unreadable read
# into "nothing is supervising the controller" is a definite claim about a state nobody observed.
# 0 = active · 1 = a real inactive/failed WORD · 3 = cannot read. The words are systemd's own.
unit_active_state() {
    local out
    out="$(sc_run is-active "$UNIT_NAME" 2>/dev/null)"
    case "$out" in
        active|reloading|activating) return 0 ;;
        inactive|failed|deactivating|maintenance|unknown|not-found|bad) return 1 ;;
    esac
    return 3
}
unit_active() { unit_active_state >/dev/null 2>&1; }
unit_enabled() { sc_run is-enabled --quiet "$UNIT_NAME" >/dev/null 2>&1; }
# MainPID via `show -p` (the `--value` spelling needs systemd >= 230). An UNREADABLE answer is reported
# as such by the caller, never folded into "no pid".
unit_main_pid() {
    local out
    out="$(sc_run show -p MainPID "$UNIT_NAME" 2>/dev/null)" || return 1
    case "$out" in MainPID=*) ;; *) return 1 ;; esac
    out="${out#MainPID=}"; out="${out%%[!0-9]*}"
    printf '%s\n' "${out:-0}"
}
# Seconds since the controller's last cycle, from the heartbeat the loop itself writes. Empty when it
# cannot be read — and empty is NEVER printed as healthy (see do_status).
# ⛔ A DIGIT RUN IS NOT NECESSARILY AN INSTANT (review P2, #2402; the same four guards `lc_hb_age` in
# orchestrator-harness/launchd-cycle.sh carries, measured there):
#   * `[ "$t" -le M ]` parses a LEADING-ZERO run as DECIMAL while `$(( ))` parses it as OCTAL, so the value
#     compared is not the value subtracted — `0001234567` yielded a FABRICATED ~1.79e9s age, i.e. a healthy
#     controller reported as stale;
#   * a heartbeat in the FUTURE (a clock correction, a state dir copied from another clock) makes
#     `now - t` NEGATIVE, and `[ -N -le bound ]` is true for every negative N — so a DEAD controller would
#     read as FRESH forever, on the one surface documented as stricter than `is-active`;
#   * a very long run overflows `$(( ))`.
# So: force decimal, bound the length, require a plausible epoch instant, tolerate <=60s of skew, and clamp
# the age at 0 (an age is seconds SINCE the write; it can never be negative).
# ⛔ ONE PARSER, AND THE SKEW BAND IS EXPLICIT (review P1/P2, #2402). A heartbeat instant has two
# consumers with different tolerances:
#   * an AGE read (`--status`, `--install`'s report) may accept a value up to 60 s in the FUTURE, because a
#     clock a few seconds fast is not a dead controller — and the age is clamped at 0;
#   * a START-PROOF value (`pre_active`, `_controller_proof_dir`) may NOT: `_proc_began_after` answers
#     "the MainPID began before it" for EVERY process when the instant is in the future, so a heartbeat one
#     second ahead cleared the `since` binding and certified an install over a start that produced no
#     controller — the #2402 false PASS, narrowed to a 60-second band by the earlier fix and still there.
# The repo already settled this asymmetry (`launchd-cycle.sh::lc_hb_value`, "THE 60s SKEW BAND BELONGS TO THE
# AGE READ ONLY"); this is that rule, with the band as a parameter so there is ONE parser and no drift.
#   _heartbeat_epoch <state dir> [<band seconds>]   (band defaults to 0: the strict, start-proof reading)
_heartbeat_epoch() { # <state dir> [<band>] -> the instant it records; nothing when absent or implausible
    local hb="${1%/}/heartbeat" band="${2:-0}" t now
    case "$band" in ''|*[!0-9]*) band=0 ;; esac
    [ -f "$hb" ] || return 1
    t="$(tr -dc '0-9' < "$hb" 2>/dev/null)" || return 1
    case "${t:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#t}" -le 12 ] || return 1
    t=$(( 10#$t ))
    [ "$t" -ge 1000000000 ] 2>/dev/null || return 1
    now="$(date +%s)"
    [ "$t" -le "$(( now + band ))" ] 2>/dev/null || return 1
    printf '%s\n' "$t"
}
heartbeat_age() {    local dir="${1:-$O}" t now age
    t="$(_heartbeat_epoch "$dir" 60)" || return 1
    now="$(date +%s)"
    age=$(( now - t ))
    [ "$age" -ge 0 ] || age=0
    printf '%s\n' "$age"
}
# Is the process at <pid> the harness loop? The argv SHAPE, not a path prefix.
# ⛔ THE `$O/` PREFIX FORM WAS AN INERT WITNESS (review P1, #2402). MEASURED 2026-10-17 on `pi-cell-2`
# (scripts/orchestrator-bringup.sh:225): the controller's argv is
#   bash /tmp/bringup-1761/scripts/orchestrator-harness/orch-loop.sh
# — the HARNESS path, NOT `$O/orch-loop.sh` (`$O` is seeded so the WORKERS can be invoked from it; the
# controller execs the harness it was started from). A `grep -qF "$O/orch-loop.sh"` therefore never
# matched on the only platform this installer supports, so the documented second witness could not fire
# and the install verdict rested on the heartbeat alone — while the supervisor's own `lock_controller_pid`
# called the very same process `controller: RUNNING`. This is the SHAPE half of that one rule — a shell
# followed by an orch-loop.sh, which is what both the loop and its wrapper look like. The AGE half is
# `_proc_began_after` below, the same predicate the supervisor and the doctor apply.
argv_is_orch_loop() { # <pid>
    local c
    c="$(ps -o command= -p "$1" 2>/dev/null)" || return 1
    # shellcheck disable=SC2086
    set -- $c
    [ "$#" -ge 2 ] || return 1
    case "${1##*/}" in bash|sh|dash|zsh) ;; *) return 1 ;; esac
    case "${2##*/}" in orch-loop.sh) return 0 ;; *) return 1 ;; esac
}
# ⛔ THE AGE HALF OF THE SAME RULE, AND IT IS A PINNED MIRROR — NOT A THIRD OPINION (review P1, #2402).
# controller_proof's lock leg checked SHAPE only, while cloud-cell-supervisor.sh::lock_controller_pid and
# cloud-cell-doctor.sh::service_controller_present both require "the process BEGAN BEFORE the record was
# written", because a stale $O/.orch.lock outlives a kill -9/OOM/reboot and the OS recycles pids: on this
# fleet the recycled target is a PEER repo's controller with the same basename from the same shared
# harness path, so shape alone matches perfectly. Without this, --install (and the bring-up's
# check_controller_service, which runs it) certified a unit whose start produced NO controller.
# This script is deployed STANDALONE (a farmed copy has no sibling lib), so it mirrors
# scripts/lib/pid-identity.sh verbatim; install-controller-service.test.sh §N extracts both bodies and
# REDDENS if they drift (the same drift pin cloud-cell-supervisor.test.sh §(p) applies).
# Same value as LOCK_START_SLACK_SECONDS / PID_START_SLACK_SECONDS (the drift arm pins all three).
LOCK_START_SLACK_SECONDS=5
_proc_start_epoch() {
  local p="${1:-}" e d h m s r
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  e="$("${PS_BIN:-/bin/ps}" -o etime= -p "$p" 2>/dev/null | tr -d '[:space:]')" || return 1
  [ -n "$e" ] || return 1
  d=0
  case "$e" in *-*) d="${e%%-*}"; r="${e#*-}" ;; *) r="$e" ;; esac
  case "$d" in ''|*[!0-9]*) return 1 ;; esac
  case "$r" in
    *:*:*) h="${r%%:*}"; r="${r#*:}"; m="${r%%:*}"; s="${r##*:}" ;;
    *:*)   h=0;                 m="${r%%:*}"; s="${r##*:}" ;;
    *) return 1 ;;
  esac
  case "$h$m$s" in ''|*[!0-9]*) return 1 ;; esac
  # 10#, NOT a bare arithmetic expansion: etime ZERO-PADS its fields and bash reads 08 as OCTAL, so an
  # 08/09 in any field made this fail — and a failed age would read as "began before the fence" = owner.
  h=$((10#${h:-0})); m=$((10#${m:-0})); s=$((10#${s:-0})); d=$((10#${d:-0}))
  printf '%s\n' "$(( $(date +%s) - (d * 86400 + h * 3600 + m * 60 + s) ))"
}
# 0 = the process began AFTER <epoch> (so it cannot own a record written before it), 1 = provably before,
# 2 = cannot tell. Three outcomes, because folding "cannot tell" into "began before" makes an unreadable
# age the strongest possible evidence of ownership (the #1856 defect this predicate exists to close).
_proc_began_after() {
  local pe="${2:-}" ps
  case "$pe" in ''|*[!0-9]*) return 2 ;; esac
  ps="$(_proc_start_epoch "${1:-}")" || return 2
  [ "$ps" -gt "$((pe + LOCK_START_SLACK_SECONDS))" ]
}
# Is a CONTROLLER of this state dir running? (review P1, #2402) The harness's single-instance lock names
# the loop's pid; identity is checked as well as liveness, because a recycled pid is not our loop (#1178).
# A plausible heartbeat is the second witness (the loop's own first cycle), so a cell whose lock the loop
# has not taken YET — harness_apply + cmd_check run first — is not refused for the seconds it needs.
controller_proof() { # [<not_before_epoch>] [<resolved state dir>] — a heartbeat older than this start proves nothing
    _controller_proof_dir "$O" "${1:-0}" && return 0
    # ⛔ THE CONTROLLER MAY NOT WRITE TO THE INSTALLER'S `$O` (review P1 round 9, #2402). The installer never
    # sources `$ENV_FILE`, but the SUPERVISOR does (`set -a`), so a `keys.env` carrying an `O=` line moves the
    # controller's state dir — its lock and its heartbeat land in the RESOLVED dir, not in this installer's.
    # Polling only `$O` therefore failed a correctly supervised cell after the full proof timeout, while
    # `--status` called the same cell healthy: two instruments disagreeing, which is the class this PR keeps
    # removing. Both are polled; the union makes "which one is authoritative" unnecessary.
    [ -n "${2:-}" ] && [ "${2%/}" != "${O%/}" ] && _controller_proof_dir "${2%/}" "${1:-0}"
}
_controller_proof_dir() { # <state dir> <not_before_epoch>
    local pid hb now since="${2:-0}" o="$1"
    local lt rc
    pid=""
    [ ! -f "$o/.orch.lock" ] || pid="$(tr -dc '0-9' <"$o/.orch.lock" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && argv_is_orch_loop "$pid"; then
        # ⛔ SHAPE IS NOT OWNERSHIP (review P1, #2402). Every controller on this box is a shell followed by
        # a shared-harness orch-loop.sh, so a recycled pid — a PEER repo's controller — passes the shape
        # test. A controller always writes $LOCK AFTER it starts, so a process that BEGAN after the lock
        # was written cannot be its owner. Unprovable age (ps/date that cannot answer) is NOT a proof
        # either: fall through to the heartbeat leg rather than certify.
        lt="$(date -r "$o/.orch.lock" +%s 2>/dev/null || true)"
        _proc_began_after "$pid" "${lt:-}"; rc=$?
        [ "$rc" -eq 1 ] && return 0
    fi
    # ⛔ THE BAND IS ZERO HERE (review P1, #2402): this is a START-PROOF value, so an instant in the future
    # is not "a clock a few seconds fast" — it makes the value look older than every process on the box,
    # which is what let a fast clock certify a start that produced nothing. One parser, two tolerances.
    hb="$(_heartbeat_epoch "$o")" || return 1
    now="$(date +%s)"
    # ⛔ A HEARTBEAT FROM BEFORE THIS START IS NOT A CONTROLLER THIS START PRODUCED (review P1, #2402).
    # `start` is a NO-OP when the unit is already running, so a DEAD controller's leftover heartbeat —
    # up to 2·CYC old, the bound below — certified a unit whose start produced nothing, and the verdict
    # printed a pid for a controller that did not exist. The binding is skipped ONLY for an idempotent
    # re-install, where the unit was already active and its heartbeat legitimately predates us.
    [ "$hb" -ge "$since" ] || return 1
    # a heartbeat older than two cycles is not proof of a controller NOW (the same bound --status uses)
    [ "$(( now - hb ))" -le "$(( ${CYC:-240} * 2 ))" ]
}

# ── actions ───────────────────────────────────────────────────────────────────────────────────
do_install() {
    local tpl tmpd changed=0 linger=0 pid rc pre_active=0 started_at="" proof_since=0 sl_iv sl_burst
    # ⛔ REFUSE ANY ROOT-RUN INSTALL, NOT JUST `sudo bash` (review P2 round 16, #2402). The guard used to test
    # `id -u = 0 AND SUDO_USER set`, so it refused the one spelling that carries a stand-in and ADMITTED every
    # other root run — `su -`, a direct root login, any root-run provision — which renders `User=root`,
    # `HOME=/root`, `O=/root/orchestrator` and passes `verify_unit` (its `User=$(id -un)` IS root). That is the
    # same outcome the paragraph above describes: a root-owned ENABLED unit with root's keys.env and gh auth,
    # which a later `start` delegates to, so the cell's own controller can never come up. `SUDO_USER` only
    # chooses the remedy sentence now; the refusal is on the uid.
    # ⛔ AND AN EXPLICIT OVERRIDE EXISTS, because a root-only container is a real (if unsupported) shape: it
    # must ASK, and the ask is named in the refusal rather than discovered by reading this script. The
    # hermetic suite asks too (its `inst` fixture exports CONTROLLER_ALLOW_ROOT=1), so a suite run on a root
    # runner exercises the SAME path an operator does instead of being exempted by a different rule.
    if [ "$(id -u)" = "0" ] && [ "${CONTROLLER_ALLOW_ROOT:-0}" != "1" ]; then
        err "REFUSING to install as root (uid 0${SUDO_USER:+, SUDO_USER=$SUDO_USER}): the controller would run as"
        err "  root, with root's keys.env, gh auth and state dir — and an enabled unit that fails stays enabled, so"
        err "  'start' would keep delegating to a controller that cannot run."
        if [ -n "${SUDO_USER:-}" ]; then
            err "  Re-run as the operator: sudo -u $SUDO_USER -H bash $0 --install"
        fi
        err "  If a root-owned controller is genuinely what you want, ask for it explicitly:"
        err "    CONTROLLER_ALLOW_ROOT=1 bash $0 --install"
        return 1
    fi
    case "${RESTART_SEC:-}" in
        ''|*[!0-9]*) err "REFUSING: ORCH_RESTART_SEC must be a whole number of seconds (got '$RESTART_SEC')"; return 1 ;;
    esac
    # ⛔ BASE 10, NORMALISED ONCE (review P1 round 15, #2402). The shape test above accepts a LEADING-ZERO
    # value, and `$(( 015 ))` is OCTAL 13 while `[ ]` and systemd read the same `015` as DECIMAL 15 — so the
    # guard modelled a different number from the one it rendered into the unit and the one systemd parsed.
    # Measured: `ORCH_RESTART_SEC=015 ORCH_START_TIMEOUT_SEC=100` was refused quoting a 76 s remedy computed
    # from 13 s, and following that 76 s makes a real per-attempt cost of 101 s → 3 × 101 > 300, the endless
    # restart this arithmetic exists to exclude; `ORCH_START_TIMEOUT_SEC=060 ORCH_RESTART_SEC=200` printed a
    # remedy the very next guard refused (octal quotient, decimal comparison). Normalising here makes the
    # modelled, rendered and parsed numbers the same integer.
    # ⛔ NORMALISE **AFTER** THE RANGE CHECK, AND BOUND THE LENGTH FIRST (review P1 round 16, #2402). `10#`
    # does NOT fail on overflow — bash silently wraps modulo 2^64, so `018446744073709551631` became 15 and,
    # normalised BEFORE the range test, was ACCEPTED and rendered as `RestartSec=15`: a value the operator
    # never asked for, substituted without a word (the base commit refused it). The range test runs on the raw
    # base-10 string (so `015` passes as 15), then the value is normalised so the arithmetic below cannot read
    # it as octal; the length bound is what makes that safe.
    [ "${#RESTART_SEC}" -le 9 ] \
        || { err "REFUSING: ORCH_RESTART_SEC must be a small whole number of seconds (got '$RESTART_SEC') — nothing this large can fit a start-limit window"; return 1; }
    [ "$RESTART_SEC" -ge 1 ] 2>/dev/null \
        || { err "REFUSING: ORCH_RESTART_SEC must be >= 1 (got '$RESTART_SEC') — 0 is not a delay"; return 1; }
    case "$RESTART_SEC" in 0?*) RESTART_SEC=$(( 10#$RESTART_SEC )) ;; esac
    # ⛔ THE ORPHAN CEILING MUST FIT `StartLimitBurst` ATTEMPTS INSIDE `StartLimitIntervalSec` — NOT MERELY
    # SIT BELOW IT (review P2, #2402). systemd refuses the start AFTER the burst is exceeded
    # (`systemd.unit(5)`: units "started more than burst times within an interval time span are not
    # permitted to start any more"), so an impossible start converges to `failed` only when `burst`
    # failures fit inside ONE window. Each attempt costs the orphan ceiling (the wait, then the failure)
    # PLUS `RestartSec`, so the relation is
    #     StartLimitBurst × (CONTROLLER_ORPHAN_TIMEOUT + RestartSec) < StartLimitIntervalSec
    # and the earlier "orphan < interval" test was satisfied by the OLD 120 s default: 120 + 15 = 135 s per
    # attempt, three failures span 405 s > the 300 s window, the oldest start ages out before the fourth is
    # refused — so the unit restarted FOREVER, parking 120 s per cycle and re-running cmd_check's network
    # reads, while the template, this installer, the doc and §J all claimed it converged to `failed` (which
    # is the state `--status` prints and `reset-failed` acts on). 60 s is the supervisor's OWN default
    # (CONTROLLER_ORPHAN_TIMEOUT), so the two instruments now agree as well as the arithmetic working.
    # Both limits are READ FROM THE TEMPLATE: the template owns the numbers (verify_unit asserts them), and a
    # second copy of 300/3 here is how the two would drift apart.
    tpl="$TEMPLATES_DIR/$UNIT_NAME"
    [ -f "$tpl" ] || { err "template missing: $tpl (set TEMPLATES_DIR)"; return 1; }
    sl_iv="$(sed -n 's/^StartLimitIntervalSec=//p' "$tpl" 2>/dev/null | head -1)"
    sl_burst="$(sed -n 's/^StartLimitBurst=//p' "$tpl" 2>/dev/null | head -1)"
    case "${sl_iv:-}" in ''|*[!0-9]*) sl_iv=300 ;; esac
    case "${sl_burst:-}" in ''|*[!0-9]*) sl_burst=3 ;; esac
    # same base-10 normalisation as RESTART_SEC, and the same ordering rule: the length bound and the range
    # check come FIRST, so a padded value cannot wrap into an accepted one (review P1 round 16, #2402).
    [ "${#sl_iv}" -le 9 ] || { err "REFUSING: the template's StartLimitIntervalSec is absurdly large ('$sl_iv')"; return 1; }
    [ "${#sl_burst}" -le 6 ] || { err "REFUSING: the template's StartLimitBurst is absurdly large ('$sl_burst')"; return 1; }
    case "$sl_iv" in 0?*) sl_iv=$(( 10#$sl_iv )) ;; esac
    case "$sl_burst" in 0?*) sl_burst=$(( 10#$sl_burst )) ;; esac
    # ⛔ A BURST OF 0 IS "NO START LIMIT" — refuse it rather than divide by it (see the magnitude guard
    # below), because that is the endless-restart mode this whole arithmetic exists to exclude.
    [ "$sl_burst" -ge 1 ] 2>/dev/null \
        || { err "REFUSING: the template's StartLimitBurst is '${sl_burst}' — a burst of 0 means NO start limit, so a start that can never succeed would restart for ever while --status reads supervised. The bound this installer validates needs a positive burst."; return 1; }
    case "${START_TIMEOUT_SEC:-}" in
        ''|*[!0-9]*) err "REFUSING: ORCH_START_TIMEOUT_SEC must be a whole number of seconds (got '$START_TIMEOUT_SEC')"; return 1 ;;
    esac
    [ "$START_TIMEOUT_SEC" -ge 1 ] 2>/dev/null \
        || { err "REFUSING: ORCH_START_TIMEOUT_SEC must be >= 1 (got '$START_TIMEOUT_SEC')"; return 1; }
    [ "${#START_TIMEOUT_SEC}" -le 9 ] \
        || { err "REFUSING: ORCH_START_TIMEOUT_SEC must be a small whole number of seconds (got '$START_TIMEOUT_SEC')"; return 1; }
    case "$START_TIMEOUT_SEC" in 0?*) START_TIMEOUT_SEC=$(( 10#$START_TIMEOUT_SEC )) ;; esac
    # ⛔ THE RELATION IS DIVIDED, NEVER MULTIPLIED (review P2, #2402). The shape test above accepts a
    # 19-DIGIT value, and `sl_burst * (START_TIMEOUT_SEC + RESTART_SEC)` then WRAPS NEGATIVE — measured:
    # 3 * (3074457345618258602 + 15) = -9223372036854775765 — so `-lt $sl_iv` PASSED and a unit with an
    # orphan ceiling of ~1e11 years installed looking validated: a start that can never fail inside the
    # window, a burst that never fills, a controller that never comes back. That is precisely the failure
    # this guard exists to remove, admitted by the guard itself. Integer division cannot overflow.
    # `- 1` on the interval keeps the relation EXACTLY the one the multiplication tested —
    # burst*(t+RestartSec) < interval  ⇔  t <= (interval-1)/burst - RestartSec — and the bound is computed
    # ONCE so the refusal can only quote the number the test enforced. (It used to print `300/3-15` = 85 s
    # while the test required at most 84: a remedy the guard then refused.)
    # ⛔ THE CEILING IS NOT THE WHOLE COST OF AN ATTEMPT (review P1 round 12, #2402). The supervisor polls in
    # 5 s steps, so a T-second ceiling can cost T+5 s of wall time, and every attempt also pays the
    # supervisor's own startup and `cmd_check` reads. With the shipped 300/3 window and the maximum the
    # earlier bound allowed, `3 × (84 + 15) = 297 < 300` left 3 s of slack for BOTH — attempts landed far
    # enough apart that the oldest aged out before the burst was exceeded, the unit restarted for ever, and
    # `--status` read it supervised: reachable by following this guard's own printed remedy. The supervisor
    # no longer overruns its bound (it tests the NEXT 5 s step), and both allowances are named here once,
    # subtracted from the ceiling, and quoted in the refusal.
    WAIT_QUANTUM_SEC=5
    ATTEMPT_OVERHEAD_SEC=5
    sl_maxtime=$(( (sl_iv - 1) / sl_burst - RESTART_SEC - WAIT_QUANTUM_SEC - ATTEMPT_OVERHEAD_SEC ))
    # ⛔ A NEGATIVE BOUND IS NOT A REMEDY, AND THE CAUSE MUST BE NAMED CORRECTLY (review P2 rounds 9 and 10,
    # #2402). Two defects lived here: the sentence printed the negative bound as advice
    # ("Use ORCH_START_TIMEOUT_SEC <= -401s."), and it blamed the TEMPLATE even when the operator's own
    # `ORCH_RESTART_SEC` was what pushed the window out of reach — an operator who followed it (raising
    # StartLimitIntervalSec above `RestartSec × burst`) was then refused by `verify_unit`, which pins the
    # rendered window. The true minimum is `burst × (RestartSec + 1) + 1` (one whole second of orphan ceiling
    # for the LAST attempt, plus one so the burst can be EXCEEDED inside the window), and it is computed ONCE
    # so the message can only quote what the guard enforces.
    sl_min_iv=$(( sl_burst * (RESTART_SEC + WAIT_QUANTUM_SEC + ATTEMPT_OVERHEAD_SEC + 1) + 1 ))
    sl_max_rs=$(( (sl_iv - 1) / sl_burst - WAIT_QUANTUM_SEC - ATTEMPT_OVERHEAD_SEC - 1 ))
    # ⛔ A REMEDY MUST BE FOLLOWABLE WITHOUT A SECOND, UNDOCUMENTED KNOB (review P2 round 10, #2402). The
    # refusal used to offer `ORCH_RESTART_SEC <= 98` — the bound that fits a 1 s orphan ceiling — while the
    # ceiling still defaulted to 60 s, so an operator who followed it met a SECOND refusal naming a variable
    # the message never mentioned (`ORCH_START_TIMEOUT_SEC <= 1s`). The bound is now derived from the ceiling
    # ACTUALLY IN FORCE, so one edit satisfies both guards; the 1 s-ceiling shape is still named, as an
    # explicit second knob.
    # ⛔ AND IT NO LONGER ADVISES RAISING StartLimitIntervalSec (review P2 round 10, #2402): `verify_unit`
    # PINS the rendered window, so that advice was refused by this same installer's own artifact check. A
    # remedy that cannot be followed is the defect class this PR exists to remove, not a nicety.
    # ...and it subtracts the SAME allowances as the ceiling itself (review P1 round 12, #2402): a bound
    # derived without them is a bound this guard then refuses (measured: 39 s at the 60 s default failed the
    # very next check, because 3 × (60 + 39 + 10) = 327 > 300).
    sl_max_rs_at_ceiling=$(( (sl_iv - 1) / sl_burst - START_TIMEOUT_SEC - WAIT_QUANTUM_SEC - ATTEMPT_OVERHEAD_SEC ))
    # ⛔ THE RULE IN THE SENTENCE MUST BE THE RULE THE GUARD ENFORCES (review P2 round 15, #2402). It said the
    # ceiling and RestartSec "must sum to at most" the raw quotient (99 at the shipped window), while the
    # check below allows at most that minus the poll quantum and the per-attempt overhead (89) — so an
    # operator who split the budget instead of copying the example was refused by the same message that
    # told them they were fine. Computed ONCE here, used in both the sentence and the guard.
    # ⛔ DERIVED FROM THE VALUE THE GUARD TESTS, NOT RE-DERIVED (review P2 round 16, #2402): a second
    # expansion of the same quotient can drift the moment one of them is edited, which is exactly how the
    # round-15 defect appeared. `sl_maxtime` is what `[ "$START_TIMEOUT_SEC" -le "$sl_maxtime" ]` enforces,
    # so the sentence quotes that plus RestartSec and cannot disagree with it.
    sl_sum_max=$(( sl_maxtime + RESTART_SEC ))
    if [ "$sl_maxtime" -lt 1 ]; then
        err "REFUSING: no orphan ceiling fits this start limit — StartLimitBurst=$sl_burst attempts inside StartLimitIntervalSec=${sl_iv}s leave nothing for RestartSec=${RESTART_SEC}s plus a >= 1s ceiling (the minimum window is ${sl_min_iv}s), so NO configuration would converge to failed."
        if [ "$sl_max_rs_at_ceiling" -ge 1 ]; then
            err "  ORCH_RESTART_SEC=${RESTART_SEC} is what made the window too small: use ORCH_RESTART_SEC <= ${sl_max_rs_at_ceiling} with the current ORCH_START_TIMEOUT_SEC=${START_TIMEOUT_SEC} — the two must sum to at most ${sl_sum_max}s inside ${sl_iv}s."
        elif [ "$sl_max_rs" -ge 1 ]; then
            err "  ORCH_RESTART_SEC=${RESTART_SEC} plus ORCH_START_TIMEOUT_SEC=${START_TIMEOUT_SEC} overrun the window together: lower BOTH — e.g. ORCH_RESTART_SEC <= ${sl_max_rs} with ORCH_START_TIMEOUT_SEC=1 — so the ceiling plus RestartSec fits ${sl_burst} attempts inside ${sl_iv}s."
        else
            err "  StartLimitIntervalSec=${sl_iv}s cannot fit ${sl_burst} attempts at any RestartSec >= 1 (it needs >= ${sl_min_iv}s): that is a change to the shipped TEMPLATE and to verify_unit's pin, not an operator knob."
        fi
        return 1
    fi
    [ "$START_TIMEOUT_SEC" -le "$sl_maxtime" ] \
        || { err "REFUSING: ORCH_START_TIMEOUT_SEC=$START_TIMEOUT_SEC does not fit StartLimitBurst=$sl_burst attempts inside StartLimitIntervalSec=${sl_iv}s — each attempt costs the orphan ceiling plus RestartSec (${RESTART_SEC}s), and $sl_burst of them must fit inside the window. Past that bound the oldest start ages out before the burst is exceeded, so the unit restarts for ever over a start that can never succeed while --status reads supervised. Use ORCH_START_TIMEOUT_SEC <= ${sl_maxtime}s."; return 1; }
    case "${HANDOVER_TIMEOUT_SEC:-}" in
        ''|*[!0-9]*) err "REFUSING: ORCH_HANDOVER_TIMEOUT_SEC must be a whole number of seconds (got '$HANDOVER_TIMEOUT_SEC')"; return 1 ;;
    esac
    [ "$HANDOVER_TIMEOUT_SEC" -ge 1 ] 2>/dev/null \
        || { err "REFUSING: ORCH_HANDOVER_TIMEOUT_SEC must be >= 1 (got '$HANDOVER_TIMEOUT_SEC') — a handover that is given no time at all fails every upgrade"; return 1; }
    resolve_supervisor || return 1
    choose_target || return 1
    # ⛔ NEVER ARM A SECOND SUPERVISOR IN THE OTHER SCOPE (review P2, #2402). `enable` is unconditional, so a
    # box that installed a USER unit and later gained passwordless sudo would get a SYSTEM unit too — both
    # enabled, both started at boot, and the loser parked in the adopt-wait forever. The bring-up re-runs
    # --install on every --check, so this is not exotic: it is the next bring-up.
    local other target_resolved; other="$(installed_units)"
    # ⛔ COMPARE RESOLVED PATHS, NOT SPELLINGS (re-review P2, #2666): `installed_unit_copies` prints resolved
    # paths, so the target must be resolved too — otherwise a symlinked or slash-suffixed `UNIT_DIR` reads as
    # a DIFFERENT copy and this guard refuses a healthy idempotent re-install.
    target_resolved="$(canon_dir "$UNIT_DIR")/$UNIT_NAME"
    if [ -n "$other" ] && [ "$other" != "$target_resolved" ]; then
        err "REFUSING: a unit is already installed at $other, and this run targets $UNIT_DIR/$UNIT_NAME."
        err "  Two ENABLED units are two supervisors for one queue (#1761). Remove the other one first:"
        err "    bash $0 --uninstall   # resolves the INSTALLED copy, then re-run --install"
        return 1
    fi
    # ⛔ NEVER OVERWRITE A COPY THAT PROVABLY SUPERVISES ANOTHER STATE DIR (review P1, #2402). The guard
    # above filters to OUR copies (`installed_units` skips foreign ones), so a unit file at the WRITE target
    # that belongs to another state dir was not a competitor — it was something to `install -m 0644` over,
    # and that is the #2402 defect caused by another cell's install: the overwrite strips that cell's
    # `Restart=always`, its enabled unit then `ExecStart`s THIS cell's `O=`, and the damage lands BEFORE the
    # controller proof, so this verb may still exit non-zero (or 0 on the heartbeat leg) with that cell's
    # supervision already gone. `--status` and `--uninstall` refuse this exact case; `--install` is the one
    # verb that writes, so it is the one that must refuse first. `cloud-cell-bringup.sh --check` re-runs
    # `--install` every time, so this is the next bring-up, not an exotic state.
    if [ -f "$UNIT_DIR/$UNIT_NAME" ] && ! unit_is_ours "$UNIT_DIR/$UNIT_NAME"; then
        err "REFUSING: $UNIT_DIR/$UNIT_NAME already exists and supervises state dir '$(unit_owner_dir "$UNIT_DIR/$UNIT_NAME" 2>/dev/null)', NOT this one ($O)."
        err "  Overwriting it would replace that cell's supervisor with this one — its controller would then run on"
        err "  this state dir's queue (two dispatchers on one queue, #1761) or on none, with its Restart=always gone."
        err "  Leave it alone and remove it only from the cell that owns it: bash $0 --uninstall, run by THAT state dir."
        err "  (A second unit under its own name needs a template OF THAT NAME in TEMPLATES_DIR — CONTROLLER_UNIT"
        err "  is the template's file name too, so the override alone would refuse with 'template missing'.)"
        return 1
    fi

    # ⛔ ONE DECISION POINT, NOT TWO (review P1 round 9, #2402). This block used to REPEAT the ownership test
    # as `unit_owner_dir != $O`, i.e. the RESOLUTION alone, while the guard above is the UNION (rendered `O=`
    # OR resolution). On a cell whose `keys.env` carries an `O=` line — the state the union exists for — the
    # union let the cell's OWN copy through and this block then refused it, unforgeably: `--install` never
    # converged, `changed=0` was unreachable, and the remedy it printed told the operator to UNINSTALL the
    # supervisor of a healthy cell. The union above already refuses every provably-foreign copy (and its
    # message names the owner), so a second test could only disagree with it. Deleted deliberately.

    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/controller-unit.XXXXXX")" || { err "cannot create a temp dir"; return 1; }
    render "$tpl" "$tmpd/$UNIT_NAME" || { rm -rf "$tmpd"; return 1; }

    if [ "${DRY_RUN:-0}" = 1 ]; then
        log_line "dry-run: would install $UNIT_DIR/$UNIT_NAME (target=$TARGET) and enable it"
        log_line "--- $UNIT_NAME ---"; sed 's/^/  /' "$tmpd/$UNIT_NAME"
        rm -rf "$tmpd"; return 0
    fi
    verify_unit "$tmpd/$UNIT_NAME" || { rm -rf "$tmpd"; return 1; }

    # ⛔ A UNIT THE OPERATOR DID NOT MEAN TO PUT IN /tmp. systemd will load a unit from any path given to
    # `link`, but a unit file that a reboot removes is a supervisor that silently stops existing — the
    # class this installer exists to remove. The two supported scopes are the only targets.
    case "$UNIT_DIR" in
        /etc/systemd/system|"$HOME/.config/systemd/user") ;;
        *) [ "$TARGET" = "override" ] || { err "REFUSING: $UNIT_DIR is not a persistent unit scope"; rm -rf "$tmpd"; return 1; } ;;
    esac

    mkdir -p "$UNIT_DIR" 2>/dev/null || { err "cannot create $UNIT_DIR"; rm -rf "$tmpd"; return 1; }
    # IDEMPOTENT: report whether the bytes moved, so a second install is visibly a no-op. The write is
    # staged-then-renamed so a live systemd never reads a half-written unit.
    if cmp -s "$tmpd/$UNIT_NAME" "$UNIT_DIR/$UNIT_NAME"; then
        changed=0
    else
        changed=1
        cp -f "$tmpd/$UNIT_NAME" "$tmpd/staged" || { err "cannot stage the unit"; rm -rf "$tmpd"; return 1; }
        if [ "$TARGET" = "system" ]; then
            ${SUDO-sudo -n} install -m 0644 "$tmpd/staged" "$UNIT_DIR/$UNIT_NAME" \
                || { err "install failed writing $UNIT_DIR/$UNIT_NAME (system target)"; rm -rf "$tmpd"; return 1; }
        else
            mv -f "$tmpd/staged" "$UNIT_DIR/$UNIT_NAME" \
                || { err "install failed writing $UNIT_DIR/$UNIT_NAME"; rm -rf "$tmpd"; return 1; }
        fi
    fi
    rm -rf "$tmpd"

    # ALWAYS re-read unit files (cheap, idempotent), then make sure the unit is enabled AND started.
    sc_run daemon-reload >/dev/null 2>&1 || { err "daemon-reload failed"; return 1; }
    sc_run enable "$UNIT_NAME" >/dev/null 2>&1 \
        || { err "could not enable $UNIT_NAME — it would not come back after a reboot"; return 1; }
    # ⛔ `start`, NOT `restart`: on an idempotent re-install of a HEALTHY unit, a restart would kill a
    # working controller (mid-merge, mid-dispatch) for no reason. `start` is a no-op when it is already
    # running, which is what "running the installer twice changes nothing" has to mean.
    # ⛔ A HEARTBEAT MUST BE BOUND TO *THIS* START (review P1, #2402): a dead controller's leftover
    # heartbeat certified a unit whose `start` produced nothing. `pre_active` is read BEFORE `start`
    # because an idempotent re-install of a healthy unit must keep passing on that unit's older
    # heartbeat — `start` is a no-op there, and the lock leg proves the controller anyway.
    # ⛔ `activating`/`reloading` IS NOT "PRE-ACTIVE" (review P2, #2402). `unit_active_state` returns 0 for
    # them, and `activating` is exactly the `Restart=always` window (RestartSec) — the normal state of a unit
    # whose controller just exited, i.e. the measured #2402 shape. Scoring it as pre-active CLEARS the
    # `since` binding below, so a landing inside that window accepted the DEAD incarnation's heartbeat (the
    # ≤2·CYC bound still passes) and exited 0 over a start that produced no controller — the precise false
    # PASS the binding exists to close. Only the literal word `active` skips the binding.
    # ⛔ ...AND `active` ALONE STILL CERTIFIES A DEAD INCARNATION (review P1, #2402). The literal word closes
    # the `activating` window, but an ACTIVE unit also covers a FRESH LAUNCHER after the previous controller
    # died: systemd has restarted the unit and `ExecStart` is still inside harness_apply/cmd_check (budgeted
    # 600 s), so the heartbeat in $O is the DEAD incarnation's and its age still fits the <=2xCYC leg. Asking
    # the process table settles it: a launcher that BEGAN AFTER the heartbeat cannot be its author. Same
    # shape+age rule the lock leg uses, so an unprovable age fails CLOSED (and says so) rather than
    # certifying - a false red here is an install that refuses, a false green is the #2402 defect.
    # ⛔ THE HEARTBEAT THAT COUNTS IS THE ONE THE PROOF WILL READ (review P1, #2402). The proof below trusts
    # the unit's RESOLVED state dir (`proof_o`), because a `keys.env` `O=` line moves where the controller
    # writes; a gate that read only this installer's `$O/heartbeat` found NOTHING there, escaped to
    # `pre_active=1`, and then the dead incarnation's heartbeat in the RESOLVED dir satisfied the <=2xCYC leg
    # — the same false PASS, one state wider, and byte-for-byte what this gate claims to close. Resolve the
    # proof dir BEFORE the gate: if a heartbeat exists in the dir the proof will consult (falling back to
    # `$O`), the MainPID-began-at/before test applies to THAT file; only when neither dir has one is there
    # nothing to bind.
    local proof_o=""
    proof_o="$(unit_owner_dir "$UNIT_DIR/$UNIT_NAME" 2>/dev/null || true)"
    if [ "$(sc_run is-active "$UNIT_NAME" 2>/dev/null)" = active ]; then
        local _pre_pid _pre_hb _pre_rc _pre_d
        _pre_pid="$(unit_main_pid 2>/dev/null || true)"
        _pre_hb=""
        for _pre_d in "${proof_o:-}" "$O"; do
            [ -n "${_pre_d:-}" ] || continue
            _pre_hb="$(_heartbeat_epoch "$_pre_d")" || _pre_hb=""
            [ -n "${_pre_hb:-}" ] && break
        done
        if [ -z "${_pre_hb:-}" ]; then
            # No heartbeat in ANY dir the proof reads: nothing can be certified from one, and the lock leg
            # still decides.
            pre_active=1
        elif [ "${_pre_pid:-0}" = "0" ]; then
            : # an active unit with no MainPID proves nothing about a heartbeat
        else
            _proc_began_after "$_pre_pid" "$_pre_hb"; _pre_rc=$?
            case "$_pre_rc" in
                1) pre_active=1 ;;
                2) log_line "warning: cannot date MainPID $_pre_pid - NOT treating $UNIT_NAME as pre-active; a heartbeat predating this start will not certify it" ;;
                *) : ;;
            esac
        fi
    fi
    started_at="$(date +%s)"
    # ⛔ CLEAR A HIT START LIMIT FIRST (review P1, #2402). Converging to `failed` is this unit's DESIGNED
    # outcome for a configuration fault (3 attempts in 300 s), and systemd then REFUSES to start the unit
    # again until `reset-failed` (`man systemctl`: "if a unit's start limit ... is hit and the unit refuses to
    # be started again, use this command to make it startable again"). Without this, the documented remedy —
    # fix the key/repo/pin and re-run the installer — could never bring the cell back: `start` was discarded
    # (`|| true`), nothing reset the counter, and the verb reported "the unit is NOT active after install"
    # forever, with a journal naming a cause the operator had already fixed. `reset-failed` is a no-op on a
    # healthy unit, and it cannot mask a fault: the following `start` and the controller proof still decide.
    sc_run reset-failed "$UNIT_NAME" >/dev/null 2>&1 || true
    sc_run start "$UNIT_NAME" >/dev/null 2>&1 || true
    proof_since=0
    [ "$pre_active" = 1 ] || proof_since="$started_at"

    # ⛔ THE VERDICT IS THE UNIT *AND* A CONTROLLER. `is-active` alone is the false green: the unit is
    # active for the seconds before `start` dies on a missing key, a wrong repo or a foreign controller,
    # and it is also "active" forever if it fails its start limit at the same moment we ask.
    # ⛔ AND A MAINPID IS STILL NOT A CONTROLLER (review P1, #2402): the process doing `cmd_check` — which
    # `die`s on a missing key, a wrong repo or a foreign controller — IS that MainPID until it refuses, and
    # the unit's StartLimit* then leaves it `failed`. So the verdict waits for the HARNESS's own proof: the
    # single-instance lock `orch-loop.sh` takes ($O/.orch.lock) owned by a live orch-loop.sh invocation, or a
    # plausible heartbeat. `Type=simple` forks, so the proof is POLLED, not read once.
    local ast=3
    unit_active_state; ast=$?
    if [ "$ast" -ne 0 ]; then
        [ "$ast" -eq 3 ] \
          && err "cannot read whether $UNIT_NAME is active after install — the cell may have no supervisor:" \
          || err "the unit is NOT active after install — the cell still has no supervisor:"
        sc_run status "$UNIT_NAME" --no-pager 2>&1 | sed 's/^/  /' | head -20 >&2 || true
        err "  read the reason: journalctl -u $UNIT_NAME -n 40"
        return 1
    fi
    pid="$(unit_main_pid)" || { err "cannot read $UNIT_NAME's MainPID — the unit answers is-active but nothing here can say a controller is running"; return 1; }
    [ "${pid:-0}" != "0" ] || { err "$UNIT_NAME is active with MainPID 0 — no controller process; read: journalctl -u $UNIT_NAME -n 40"; return 1; }
    local waited=0 proof_budget proof_budget_src _hb_bound
    # ⛔ THE PROOF POLLS THE STATE DIR THE UNIT RESOLVES TO, as well as this installer's `$O` (review P1
    # round 9, #2402): the supervisor sources `$ENV_FILE` (`set -a`), so a `keys.env` `O=` line moves the
    # controller's lock and heartbeat there while this installer never sources the file. Resolved from the
    # INSTALLED copy, so the proof asks about the same unit the manager is running.
    # ⛔ AND IT MUST OUTWAIT THE PHASE IT WATCHES (review P1, #2402). `systemctl start` forks
    # (`Type=simple`) and returns BEFORE `ExecStart`'s `start` has run `harness_apply` + `cmd_check` and
    # `exec`ed the loop — the phase the supervisor already budgets 600 s for
    # (`CONTROLLER_SERVICE_START_TIMEOUT`/`CONTROLLER_START_TIMEOUT`), raised from 60 s because 60 s
    # produced a false FATAL on a real cell. This poll defaulted to 240 s AND its own predicate accepts a
    # heartbeat up to `2 × CYC` (480 s), so a controller whose first witness landed between 240 s and
    # 480 s was ACCEPTED by the predicate and never observed by the poll: `--install` printed "NO
    # CONTROLLER PROVED ITSELF in 240s", `cloud-cell-bringup.sh` died on that rc, and `CELL READY` was
    # refused on a cell that was supervised and about to dispatch. The default is the start budget's own
    # 600 s, widened only when the heartbeat bound below is larger than it.
    proof_budget="${CONTROLLER_PROOF_TIMEOUT:-600}"
    proof_budget_src="CONTROLLER_PROOF_TIMEOUT"
    if [ -z "${CONTROLLER_PROOF_TIMEOUT:-}" ]; then
        # ⛔ THE MESSAGE NAMES THE KNOB THAT SET THE BUDGET (review P2, #2402): quoting
        # `CONTROLLER_PROOF_TIMEOUT` over a value the HEARTBEAT BOUND widened would send the operator to an
        # unset variable — the same "the sentence must be the rule the guard enforces" class this PR keeps
        # closing (round 15 did it for the start-limit window).
        proof_budget_src="the start budget"
        _hb_bound=$(( ${CYC:-240} * 2 ))
        if [ "$_hb_bound" -gt "$proof_budget" ]; then
            proof_budget="$_hb_bound"
            proof_budget_src="the heartbeat bound, 2 x CYC"
        fi
    fi
    while [ "$waited" -lt "$proof_budget" ]; do
        controller_proof "$proof_since" "$proof_o" && break
        # a unit that has already converged to `failed` will not produce a controller — stop waiting
        case "$(sc_run is-active "$UNIT_NAME" 2>/dev/null)" in failed) break ;; esac
        sleep 2; waited=$((waited + 2))
    done
    # ⛔ A PROOF IS ONLY GOOD IF ITS AUTHOR IS STILL THERE (review P1, #2402). The heartbeat leg accepts a
    # plausible heartbeat without asking whether the process that wrote it is alive, and a loop that ticked
    # once and exited leaves a FRESH heartbeat behind — so the poll could pass on a dead incarnation's last
    # tick while the unit had already converged to `failed`, and the verdict then printed a green "installed"
    # with a pid that was gone. Re-read the facts the manager holds AFTER the poll, in the same pass as the
    # proof: a `failed`/`inactive` unit, or a MainPID that is not live, is a start that produced no
    # controller, whatever the heartbeat says.
    if controller_proof "$proof_since" "$proof_o"; then
        local _post_state
        _post_state="$(sc_run is-active "$UNIT_NAME" 2>/dev/null || true)"
        case "$_post_state" in
            failed|inactive)
                err "$UNIT_NAME reported '$_post_state' at the end of the proof wait — the unit has already given up:"
                err "  a heartbeat is not a controller, and this one's author is gone (no live loop holds the lock)."
                sc_run status "$UNIT_NAME" --no-pager 2>&1 | sed 's/^/  /' | head -20 >&2 || true
                err "  journalctl -u $UNIT_NAME -n 40"
                return 1 ;;
        esac
    fi
    controller_proof "$proof_since" "$proof_o" || {
        err "$UNIT_NAME is active with MainPID $pid, but NO CONTROLLER PROVED ITSELF in ${waited}s of ${proof_budget}s (${proof_budget_src}):"
        err "  expected the harness's lock ($O/.orch.lock$([ -n "$proof_o" ] && [ "${proof_o%/}" != "${O%/}" ] && printf ' or %s/.orch.lock' "${proof_o%/}")) held by a live orch-loop.sh, or a heartbeat in the same state dir."
        err "  An active unit whose start is about to die (no key, a foreign controller, a bad pin) converges to"
        err "  'failed' at StartLimitBurst — the #2402 defect, with a green install on top of it. Read:"
        sc_run status "$UNIT_NAME" --no-pager 2>&1 | sed 's/^/  /' | head -20 >&2 || true
        err "  journalctl -u $UNIT_NAME -n 40"
        return 1
    }

    # linger, for the USER target only: a user manager stops at the last logout, which would make the
    # supervisor die with the operator's ssh session — the tmux defect one layer down.
    if [ "$TARGET" = "user" ]; then
        if command -v loginctl >/dev/null 2>&1; then
            if loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null | grep -qx yes; then
                linger=1
            else
                loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
                loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null | grep -qx yes && linger=1
            fi
        fi
        if [ "$linger" != 1 ]; then
            err "REFUSING to report success: the USER unit is enabled but linger is NOT on, so the manager"
            err "  (and the controller with it) dies at the last logout — the same defect, one layer down."
            err "  Fix: sudo loginctl enable-linger $(id -un)  then re-run this installer."
            return 1
        fi
    fi

    log_line "installed: target=$TARGET dir=$UNIT_DIR changed=$changed"
    log_line "  unit:    $UNIT_NAME (Restart=always, RestartSec=${RESTART_SEC}s, After=network-online.target,"
    log_line "           WantedBy=$WANTED_BY,"
    log_line "           StartLimitBurst=3/300s so a configuration fault converges to 'failed' instead of looping)"
    # ⛔ THE ORDERING DOES NOT BIND IN THE USER SCOPE, AND SAYING SO IS PART OF THE INSTALL (review P1,
    # #2402). `network-online.target` exists only in the SYSTEM manager (`/usr/lib/systemd/system`); a
    # per-user manager ships default/basic/graphical-session/timers and no network target, so systemd DROPS
    # this unit's `After=`/`Wants=` dependency instead of honouring it. That is not cosmetic: `start` runs
    # `cmd_check`'s GitHub read and exits non-zero when the box is offline, so a boot whose network is not up
    # yet can spend all three attempts inside the 300 s window, converge to `failed`, and — by design — nothing
    # re-arms a `failed` unit automatically. The bound is DISCLOSED here rather than hidden behind a dependency
    # that silently vanished, and the recovery is named. The SYSTEM scope has the ordering.
    if [ "$TARGET" = "user" ]; then
        log_line "  ordering: ⚠️  After=/Wants=network-online.target does NOT bind in this (USER) scope — a per-user"
        log_line "            manager ships no network-online.target, so systemd drops the dependency. A boot whose"
        log_line "            network is not up yet can fill StartLimitBurst and converge to 'failed' with no unattended"
        log_line "            recovery: re-arm with 'bash $0 --install' or 'ORCH_FOREGROUND=0 bash $SUPERVISOR start'."
        log_line "            The SYSTEM scope has the ordering. (The pin matters: a lane shell inside a service-managed"
        log_line "            controller's tree inherits ORCH_FOREGROUND=1, and an unpinned start would re-parent the"
        log_line "            controller into that shell while the unit stays enabled.)"
    fi
    log_line "  exec:    /bin/bash $SUPERVISOR start   (ORCH_FOREGROUND=1 — the controller is the unit's main process)"
    log_line "  state:   $O   (env: $ENV_FILE)"
    log_line "  controller pid: $pid"
    local age
    # ⛔ NAME THE DIR THAT WAS READ (review P2, #2402): with a `keys.env` `O=` line the controller writes to
    # the RESOLVED dir, and a report that points at $O sends the operator to a file nothing writes.
    if age="$(heartbeat_age "${proof_o:-$O}")"; then log_line "  heartbeat: ${age}s ago"; else log_line "  heartbeat: not yet (the loop writes ${proof_o:-$O}/heartbeat after its first cycle)"; fi
    log_line "  stop it: bash $SUPERVISOR stop   |   supervise state: bash $0 --status"
    return 0
}

do_status() {
    local active enabled pid age rc=0 _found="" _f
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ]; then
        TARGET="override"; UNIT_DIR="$SYSTEMD_UNIT_DIR"; SC="${SYSTEMCTL:-systemctl}"
    else
        # ⛔ THE INSTALLED COPY DECIDES, NOT WHAT THIS INVOCATION WOULD CHOOSE (review P2, #2402). As root
        # (`sudo bash … --status`) the probe prefers the SYSTEM manager, so a healthy USER-scope install
        # answered `is-enabled` with `not-found`, `show` failed, and the verb reported "the unit is NOT
        # enabled — it will not come back after a reboot" with rc 1: a false negative on the exact property
        # this verb exists to check, from the command the docs tell operators to run.
        if _found="$(find_installed_unit)"; then
            UNIT_DIR="$(dirname "$_found")"; scope_for_dir "$UNIT_DIR"
        else
            choose_target || { err "no service manager available — nothing is supervising the controller"; return 1; }
        fi
    fi
    log_line "unit=$UNIT_NAME target=$TARGET"
    # ⛔ NAME A COPY THAT IS NOT THIS STATE DIR'S, INSTEAD OF ANSWERING FOR IT (review P1, #2402). Silence
    # here is what made this verb's rc 0 readable as "my cell is supervised" on a box whose only unit belongs
    # to another state dir. It is reported on its own line and never addressed: the manager answers about the
    # unit NAME, which is machine-scoped.
    while IFS= read -r _f; do
        [ -n "$_f" ] || continue
        log_line "other_unit=$_f (supervises $(unit_owner_dir "$_f") — NOT this state dir's; NOT read, NOT addressed)"
    done < <(foreign_units)
    # ⛔ AND DO NOT ASK THE MANAGER ABOUT A NAME THAT IS PROVABLY SOMEONE ELSE'S (review P1, #2402). The
    # `is-enabled`/`is-active`/`show -p MainPID` reads below are answered by the unit NAME, so on the
    # measured two-state-dir box they described A's unit while B held nothing: rc 0, "active", a live
    # MainPID — B's operator reads that as their own cell being supervised. When the copy resolved for THIS
    # scope provably supervises another state dir, there is nothing of ours here to verify.
    if [ -f "$UNIT_DIR/$UNIT_NAME" ] && ! unit_is_ours "$UNIT_DIR/$UNIT_NAME"; then
        err "nothing installed for $O here: the unit at $UNIT_DIR supervises $(unit_owner_dir "$UNIT_DIR/$UNIT_NAME") — UNKNOWN whether this state dir is supervised by anything (it is not by that unit)"
        return 1
    fi
    # ⛔ AN UNREADABLE IS NOT A "NO" (review P2, #2402): both reads below report UNKNOWN rather than a
    # definite verdict, because `--status` is the documented verification verb. `is-enabled` prints a state
    # WORD on success; an EMPTY answer is not a state (a shim, a truncated read).
    case "$(sc_run is-enabled "$UNIT_NAME" 2>/dev/null)" in
        enabled|enabled-runtime|alias) enabled="enabled" ;;
        disabled|masked|masked-runtime|static|indirect|generated|transient|linked|linked-runtime|not-found|bad) enabled="not-enabled" ;;
        *) enabled="unreadable" ;;
    esac
    local _ast=3
    unit_active_state; _ast=$?
    case "$_ast" in
        0) active="active" ;;
        1) active="not-active" ;;
        *) active="UNREADABLE" ;;
    esac
    log_line "enabled=$enabled"
    log_line "active=$active"
    if pid="$(unit_main_pid 2>/dev/null)"; then
        log_line "main_pid=$pid"
        # ⛔ MainPID 0 IS NOT A CONTROLLER (review P1, #2402; do_install already refuses it). `is-active`
        # reports `activating` during a RestartSec wait and this installer maps that to "active", so a
        # readable-but-old heartbeat let `--status` return 0 for a unit with no controller process — while
        # the doc promises it requires BOTH an active/enabled unit AND a controller MainPID. A heartbeat is
        # evidence the loop TICKED once; it is not evidence one is running now.
        [ "${pid:-0}" != "0" ] || { err "the unit is active with MainPID 0 — no controller process (the RestartSec/activating state, or a start that died): journalctl -u $UNIT_NAME -n 40"; rc=1; }
    else log_line "main_pid=UNREADABLE"; rc=1; fi
    # ⛔ MainPID IS THE UNIT'S MAIN PROCESS, NOT NECESSARILY THE CONTROLLER (review P2, #2402). Under
    # Type=simple the main process is the launcher (`… start`), which spends harness_apply/cmd_check — and
    # up to CONTROLLER_HANDOVER_TIMEOUT — before it `exec`s the loop, so a live MainPID alone can be a
    # launcher. The CONTROLLER-level witness is the one --install already applies (the lock's owner, age
    # bound; or a plausible heartbeat). Reported here, never used to decide rc: a start that is still
    # inside its first CYC legitimately has neither witness, and turning that into a refusal would be a
    # false red on every healthy start. The stale-heartbeat refusal above is what bounds the ambiguity.
    # ⛔ AND IT READS THE UNIT'S RESOLVED DIR TOO (review P2, #2402). `--status` is what the bring-up gates
    # `CELL READY` on, and on a `keys.env`-repointed cell it read only this installer's `$O`: the heartbeat
    # witness was UNREADABLE and `controller=` reported none-proved while it returned 0 — a dispatcher that
    # is gone, certified. Same resolved dir the proof in `--install` uses.
    local _st_o=""
    _st_o="$(unit_owner_dir "$UNIT_DIR/$UNIT_NAME" 2>/dev/null || true)"
    if controller_proof 0 "$_st_o"; then
        log_line "controller=proved (an owned lock holder, or a heartbeat newer than 2*CYC)"
    else
        log_line "controller=none-proved yet (no owned lock holder and no plausible heartbeat — expected during the first CYC after a start; the heartbeat bound above is what refuses a dead one)"
    fi
    # NRestarts is the direct evidence for the issue's bullet 3/5 ("it comes back on its own"): a unit
    # that has restarted had a controller that died and was brought back without a human.
    local nr; nr="$(sc_run show -p NRestarts "$UNIT_NAME" 2>/dev/null)"; case "$nr" in NRestarts=*) log_line "restarts=${nr#NRestarts=}" ;; *) log_line "restarts=unreadable" ;; esac
    if age="$(heartbeat_age "${_st_o:-$O}")"; then
        log_line "heartbeat_age_s=$age"
        # Two cycles + 300s is the same staleness bound install.sh uses for launchd: a quiet cell is not a
        # wedged one, and a wedged one must not read as fresh.
        # ⛔ AND NEVER TIGHTER THAN THE DOCTOR'S DEFAULT (review P2, #2402): `cloud-cell-doctor.sh` bounds
        # staleness at `CONTROLLER_STALE_S` (default 900), and this installer never sources `$ENV_FILE`, so
        # `CYC` is only whatever the caller's shell carries. At the DEFAULTS the two instruments disagreed
        # (780 s vs 900 s) and a healthy 800 s-old heartbeat made `--status` exit 1 while the doctor called
        # the same controller RUNNING. Two instruments must not disagree about whether a cell is alive, so
        # the floor is the doctor's, and the doctor's OWN value — when the operator sets it — is the authority
        # in BOTH directions: a raised bound is honoured (no second, tighter opinion here) and a lowered one
        # too (an operator who tightened the doctor meant it for every instrument). Only the unset case needs
        # a floor, and that floor is the doctor's default 900.
        local bound
        case "${CONTROLLER_STALE_S:-}" in
            ''|*[!0-9]*) bound=$(( ${CYC:-240} * 2 + 300 )); [ "$bound" -ge 900 ] || bound=900 ;;
            *) bound="$CONTROLLER_STALE_S" ;;
        esac
        [ "$age" -le "$bound" ] || { err "the controller has not ticked for ${age}s (> ${bound}s) — the unit is up but the loop is not cycling"; rc=1; }
    else
        # ⛔ AN UNREADABLE HEARTBEAT IS NOT A FAILED UNIT (review P2, #2402). The supervisor sources
        # $ENV_FILE with `set -a` and documents that `keys.env` may repoint $O, so this installer's $O and
        # the controller's can legitimately differ — and the first cycle writes the file minutes later
        # (CYC). Failing the verb over that was a false red on a healthy service-managed cell. The unit's
        # own MainPID is the proof that a controller is running; the heartbeat is a fresher fact, not a gate.
        log_line "heartbeat_age_s=UNREADABLE (no READABLE $O/heartbeat — path read: \$O=$O, unit dir=${_st_o:-<same>}; the file can be absent, or present with a value that is not a plausible instant (too small to be an epoch second, future-dated beyond 60s of skew, or over-long), and a keys.env 'O=' line moves the controller's state dir; the first cycle writes the file after one CYC)"
        if [ "${pid:-0}" = "0" ]; then
            err "no heartbeat AND no MainPID — nothing is running under the unit: journalctl -u $UNIT_NAME -n 40"
            rc=1
        fi
    fi
    [ "$active" = "active" ] || {
        [ "$active" = "UNREADABLE" ] \
          && err "cannot read whether the unit is active — whether anything is supervising the controller is UNKNOWN, not 'no'" \
          || err "the unit is NOT active — nothing is supervising the controller"
        rc=1
    }
    [ "$enabled" = "enabled" ] || {
        [ "$enabled" = "unreadable" ] \
          && err "cannot read whether the unit is enabled — whether it comes back after a reboot is UNKNOWN, not 'no'" \
          || err "the unit is NOT enabled — it will not come back after a reboot"
        rc=1
    }
    return "$rc"
}

# ⛔ THE DIRECTORY A UNIT WAS FOUND IN DECIDES ITS MANAGER (review P2, #2402). Deriving the scope from
# what this box would choose NOW is a different question: a box whose /etc copy is installed but whose
# probe currently prefers the user manager would send `disable --now` to the wrong systemd, get a failure
# (or a silent no-op on a unit that is not there) and then report on the wrong unit. Three callers share
# this: --status, --uninstall, and the supervisor's own scope helper.
scope_for_dir() { # <unit dir> -> sets TARGET and SC
    # ⛔ THE SCOPE IS "IS THIS THE SYSTEM DIRECTORY", NOT "IS IT THE CALLER'S HOME" (review P1 round 19, #2402 / B+D).
    # This compared the directory to `$HOME/.config/systemd/user` — the CALLER's home — while the find beside it
    # was widened to the passwd home of the invoking uid and `SUDO_USER`'s passwd home. Every copy found
    # through those candidates is by construction NOT `$HOME/.config/systemd/user`, so it was classified
    # SYSTEM and handed to the system manager: a healthy enabled user unit answered `enabled=not-enabled
    # active=not-active` and `--status` exited 1 over it (the false red the widening was meant to fix), a
    # foreign same-named system unit was read and reported as OURS (false green), and `--uninstall` could
    # `disable --now` another cell's supervisor after printing that it had left that unit untouched. This is
    # the supervisor's own rule (`sup_systemctl`: anything that is not the system dir is user scope), and the
    # two must agree — one definition of "which manager owns this file".
    case "$1" in
        "${CONTROLLER_SYSTEM_UNIT_DIR:-/etc/systemd/system}"|"${SYSTEMD_UNIT_DIR:-}")
                                      TARGET="system"
                                      # ⛔ THE SYSTEM SCOPE NEEDS THE PRIVILEGE THE INSTALL USED (review P2,
                                      # #2402). `choose_target` resolves it as `sudo -n systemctl`; deriving
                                      # a bare `systemctl` here meant `--uninstall` issued an UNPRIVILEGED
                                      # `disable --now`, got "Interactive authentication required", reported
                                      # "still ENABLED" and removed nothing — the documented uninstall path
                                      # unusable on the cell's normal shape. `${SUDO+…}` is kept for the
                                      # explicit-SUDO seam (it expands to nothing when SUDO is unset OR empty).
                                      if [ -n "${SYSTEMCTL:-}" ]; then SC="$SYSTEMCTL"
                                      elif [ -n "${SUDO+x}" ]; then SC="${SUDO:+$SUDO }systemctl"
                                      else SC="sudo -n systemctl"; fi ;;
        *)                            TARGET="user";   SC="${SYSTEMCTL:-systemctl} --user" ;;
    esac
}
# ⛔ A UNIT FILE'S PRESENCE IS NOT AN OWNERSHIP CLAIM (review P1, #2402). The unit NAME is machine-scoped
# (eldato-orchestrator.service), so "the first copy on the box" can be ANOTHER state dir's — measured on a
# two-state-dir box: B's `--uninstall` disabled and deleted A's unit and reported "the controller is no
# longer supervised" (rc 0), and B's `--status` answered enabled+active+MainPID with rc 0 over a unit B does
# not own, i.e. the #2402 "reads as a healthy box" false green on the one verb the docs tell an operator to
# trust. The rendered unit CARRIES its owner, so ownership is a READ, not a guess.
#
# ⛔ OWNERSHIP IS TWO READS, AND A UNIT IS OURS IF EITHER SAYS SO (review P1 round 9, #2402). The unit
# carries its owner TWICE — the `Environment=O=` it RENDERS (what `verify_unit` pins to the installing
# state dir) and what it RESOLVES to (`ENV_FILE` re-sourced, and `keys.env` may repoint `O`) — and the two
# legitimately differ in BOTH directions. Reading renders only called the SUPERVISOR's own unit foreign
# whenever `keys.env` repointed `O` (its `$O` is the resolution); reading resolutions only called THIS
# INSTALLER's own unit foreign whenever `keys.env` repointed `O` (its `$O` is the rendered/environment
# value, and `verify_unit` guarantees its own copies render it). Either answer is the unit's own claim
# about itself, so ownership is the UNION — and a unit that provably matches neither is still foreign, so
# #1761's "never arm a second supervisor" and §L's negative control both hold. `unit_owner_dir` keeps
# answering the RESOLUTION (that is what the controller actually supervises, so it is what the reports
# print); `unit_rendered_owner` answers the render. Keep these bodies identical to the supervisor's:
# §L-iii/§L-iv pin both directions here, and cloud-cell-supervisor.test.sh pins them there.
#
# ⛔ AND ROOT MUST NEVER EXECUTE AN OPERATOR-WRITABLE FILE (review P2 round 9, #2402). The resolution above
# is obtained by evaluating the unit's `Environment=ENV_FILE=` the way the controller does (`set -a; . file`)
# — the only read that answers "which state dir does the controller actually use". But `keys.env` is the
# operator's file and `--status` is documented as `sudo bash … --status`, so evaluating it AS ROOT lets any
# account that can write that file execute with root's authority, from a verb that only READS. As root the
# file is therefore evaluated as the account that OWNS it (the account that could have written it, and the
# account the controller runs as), via `runuser`; when that cannot be arranged — no `runuser`, or an owner
# that cannot be read — it is NOT evaluated at all and the caller falls back to the RENDERED owner, which
# the unit carries in cleartext. The fallback is lossless for ownership because it is the union above.
unit_rendered_owner() { # <unit file> -> the owner the unit RENDERS; nothing when it carries no O= line
    local v
    [ -f "$1" ] || return 1
    v="$(sed -n 's/^Environment=O=//p' "$1" 2>/dev/null | head -1)"
    [ -n "${v:-}" ] || return 1
    # A trailing slash is a spelling difference, not a different state dir.
    printf '%s\n' "${v%/}"
}
env_file_owner_o() { # <envf> <unit_cell_home> <rendered_o> [<unit_home>] -> resolved O; nothing when not evaluated
    local f="$1" home="$2" rendered="$3" unit_homeenv="${4:-}" owner="" runner=() out=""
    [ -n "${f:-}" ] && [ -r "$f" ] || return 1
    if [ "$(id -u)" = "0" ]; then
        # ⛔ THE TEST IS "WHO CAN WRITE IT", NOT "WHO OWNS IT" (review P2 round 9, #2402). Ownership alone
        # missed the shape `sudo tee`/`sudo cp` leaves behind: a `keys.env` OWNED by root and group- or
        # other-WRITABLE (`-rw-rw-r-- root:staff`, umask 002 in a shared group) was used as its own "owner",
        # ran as root, and executed with root's authority — the escalation this guard exists to close, one
        # permission bit away. Two changes, both fail-closed: do not evaluate the file AT ALL when any account
        # but its owner can write it, so the caller falls back to the RENDERED `O=` — cleartext in the unit,
        # and lossless for ownership because ownership is the UNION; and derive the RUNNER FROM THE FILE (see
        # below).
        local fmode fowner
        fmode="$(stat -c %A -- "$f" 2>/dev/null)" || return 1
        [ -n "${fmode:-}" ] || return 1
        # Group/other WRITE on the file itself. (The directory is deliberately not tested: if another
        # account can REPLACE the file, the replacement's owner is that account — which the runner rule
        # below covers — so a directory test would only cause false refusals on shared-group cells without
        # closing anything additional.)
        case "${fmode:5:1}${fmode:8:1}" in *w*) return 1 ;; esac
        # ⛔ THE RUNNER IS DERIVED FROM THE FILE, NEVER FROM THE CALLER (review P1 round 11, #2402). Preferring
        # `SUDO_USER` ran the file as the INVOKING operator rather than as the account that can write it: a
        # `keys.env` owned by account A, read through a documented `sudo bash … --status`, executed A's code
        # with the SUDOER's authority — the same escalation this guard closes for the group-writable shape,
        # one ownership bit away (the mode test only rejects group/other WRITE, so a `0644` file owned by
        # another account passes it). The file's OWNER is the account that can write it, so that is who it
        # runs as; `SUDO_USER` is only the non-root stand-in for the one case ownership cannot answer — the
        # owner IS root, and root can write anything, so "owned by root" says nothing about who could have
        # written it. No stand-in ⇒ do not evaluate at all (fall back to the rendered `O=`).
        fowner="$(stat -c %U -- "$f" 2>/dev/null)" || return 1
        [ -n "${fowner:-}" ] || return 1
        if [ "$fowner" = "root" ]; then
            owner="${SUDO_USER:-}"
            [ -n "${owner:-}" ] || return 1
            [ "$owner" != "root" ] || return 1
        else
            owner="$fowner"
        fi
        if [ "$owner" != "root" ]; then
            command -v runuser >/dev/null 2>&1 || return 1
            runner=(runuser -u "$owner" --)
        fi
    fi
    # ⛔ THE UNIT'S OWN `HOME` IS PART OF THE EVALUATION (review P2, #2402). A `keys.env` may spell the state
    # dir in terms of `$HOME` (`O=$HOME/orchestrator`), and the unit carries `Environment=HOME=` precisely
    # because the controller resolves it that way. With HOME inherited from the CALLER, one unit file resolved
    # to two different state dirs depending on who ran the verb — so account B read account A's unit as its
    # OWN and `--status`/`--uninstall` acted on a foreign dispatcher. Keep this body identical to the
    # supervisor's copy; an empty value keeps the caller's HOME.
    # ⛔ `-u HOME` MUST NOT BE ADDED (review P2 round 17, #2402): unsetting it made the documented fallback
    # impossible — with no `Environment=HOME=` in the unit, `O=$HOME/o` resolved to `/o`, a path no cell has.
    # The inherited value IS the caller's HOME, which is the documented fallback. Keep this body identical to
    # the supervisor's copy.
    out="$(${runner[@]:+"${runner[@]}"} env -u O -u CELL_HOME -u ENV_FILE bash -c '
        [ -z "$4" ] || HOME="$4"
        CELL_HOME="$2"; O="$3"; ENV_FILE="$1"
        set -a; . "$1" >/dev/null 2>&1
        printf "%s" "${O:-}"
    ' _ "$f" "${home:-}" "${rendered:-}" "${unit_homeenv:-}" 2>/dev/null || true)"
    [ -n "${out:-}" ] || return 1
    printf '%s\n' "$out"
}
unit_owner_dir() { # <unit file> -> the state dir it RESOLVES to; nothing when nothing is readable
    local f="$1" rendered_o envf unit_home unit_homeenv eff
    [ -f "$f" ] || return 1
    rendered_o="$(unit_rendered_owner "$f")" || rendered_o=""
    envf="$(sed -n 's/^Environment=ENV_FILE=//p' "$f" 2>/dev/null | head -1)"
    unit_home="$(sed -n 's/^Environment=CELL_HOME=//p' "$f" 2>/dev/null | head -1)"
    # the HOME the unit itself runs with — see env_file_owner_o's note (`O=$HOME/...`).
    unit_homeenv="$(sed -n 's/^Environment=HOME=//p' "$f" 2>/dev/null | head -1)"
    eff=""
    if [ -n "${envf:-}" ]; then
        # A file with a top-level `exit` ends the subshell silently, and an empty answer falls back to the
        # rendered value — never to "no owner".
        eff="$(env_file_owner_o "$envf" "${unit_home:-}" "${rendered_o:-}" "${unit_homeenv:-}")" || eff=""
    fi
    [ -n "${eff:-}" ] || eff="${rendered_o:-}"
    [ -n "${eff:-}" ] || return 1
    printf '%s\n' "${eff%/}"
}
# May this verb address <unit file>? YES for our own copy, and YES for an UNPROVABLE one (no O= line and no
# readable env file — a hand-written or pre-#2402 unit), which is the fail-safe side of #1761: assume it may
# be ours and never launch a tmux controller beside a unit that could be enabled. NO only when it provably
# supervises a DIFFERENT state dir by BOTH reads — and then nothing here may disable, delete, or report on it.
unit_is_ours() { # <unit file>
    local own rendered
    own="$(unit_owner_dir "$1")" || own=""
    rendered="$(unit_rendered_owner "$1")" || rendered=""
    [ -n "$own" ] || [ -n "$rendered" ] || return 0
    [ "$own" = "${O%/}" ] && return 0
    [ "$rendered" = "${O%/}" ]
}
# Every installed copy that PROVABLY belongs to another state dir — reported, never addressed.
foreign_units() { # the copies that provably supervise ANOTHER state dir — reported, never acted on
    local d seen=" "
    # ⛔ ENUMERATED THE SAME WAY THE OWNED COPIES ARE (review P2 round 5, #2666): this reader kept the raw
    # spellings, so one foreign copy reached as two spellings was printed twice — a report-only defect (this
    # function decides nothing) but a confusing one, and the fix is the shared enumeration it should have used.
    for d in "${SYSTEMD_UNIT_DIR:-}" "${CONTROLLER_SYSTEM_UNIT_DIR:-/etc/systemd/system}"; do
        [ -n "$d" ] || continue
        d="$(canon_dir "$d")"
        [ -n "$d" ] || continue
        case "$d" in "$CANON_UNRESOLVED"*) continue ;; esac
        case "$seen" in *" $d "*) continue ;; esac
        seen="$seen$d "
        [ -f "$d/$UNIT_NAME" ] || continue
        unit_is_ours "$d/$UNIT_NAME" || printf '%s\n' "$d/$UNIT_NAME"
    done
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        d="$(canon_dir "$d")"
        [ -n "$d" ] || continue
        case "$d" in "$CANON_UNRESOLVED"*) continue ;; esac
        case "$seen" in *" $d "*) continue ;; esac
        seen="$seen$d "
        [ -f "$d/$UNIT_NAME" ] || continue
        unit_is_ours "$d/$UNIT_NAME" || printf '%s\n' "$d/$UNIT_NAME"
    done < <(installed_user_unit_dirs)
    return 0
}
# ⛔ FIND THE INSTALLED COPY, DO NOT RE-DERIVE THE SCOPE (review P2, #2402). `choose_target` answers "where
# WOULD this go on THIS box now", which is not "where IS it": a box that installed a USER unit and later
# gained passwordless sudo would resolve to the SYSTEM scope, print `not installed: /etc/systemd/system/…`
# and exit 0 while the user unit stayed installed, enabled and running. The installed file is the evidence.
# The home the passwd database names for a user — NEVER `$HOME`, which the caller re-points (or which
# `sudo` rewrites to /root). This is the directory `systemctl --user` itself resolves.
passwd_home() {
    [ -n "${1:-}" ] || return 0
    getent passwd "$1" 2>/dev/null | cut -d: -f6
}
# ⛔ A USER-SCOPE UNIT HAS NO RECORDED OWNER, SO EVERY HONEST CANDIDATE IS READ (review P2 round 18, #2402).
# The search below used `$HOME/.config/systemd/user` — the CALLER's home. `sudo bash $0 --status` rewrites
# HOME to /root, so a healthy enabled unit became "not-enabled / not-active" and `--status` exited 1 over it,
# while the doc promises the verb resolves the INSTALLED copy first. The operator's own home is what the
# user manager actually reads, so it is tried before the caller's.
installed_user_unit_dirs() {
    local h
    [ -n "${CONTROLLER_USER_UNIT_DIR:-}" ] && printf '%s\n' "$CONTROLLER_USER_UNIT_DIR"
    h="${HOME:-}"; [ -n "$h" ] && printf '%s\n' "$h/.config/systemd/user"
    h="$(passwd_home "$(id -u)")"; [ -n "$h" ] && printf '%s\n' "$h/.config/systemd/user"
    h="$(passwd_home "${SUDO_USER:-}")"; [ -n "$h" ] && printf '%s\n' "$h/.config/systemd/user"
    return 0
}
installed_unit_copies() { # every copy of OUR unit this box can find: system scope, then every honest user dir
    local d seen=" "
    # ⛔ `CONTROLLER_SYSTEM_UNIT_DIR` is the READ side of the system scope (the supervisor's own seam name);
    # `SYSTEMD_UNIT_DIR` stays the WRITE override. Conflating them is how a write-path override decided
    # which installed copy a read-back reported on.
    # ⛔ AND A DIRECTORY IS COUNTED ONCE (review P2, #2402). The two seams are independent, so a caller
    # may point both at one directory — the hermetic suite does exactly that to keep its read-backs off
    # the host. Without this dedupe that configuration reported the SAME file twice, and the
    # "two copies installed" arm then fired on a single unit: install re-runs exited 1 with `changed=1`
    # (`install: re-run rc differs (0 then 1)`, reproduced).
    # ⛔ ONE ENUMERATION, NOT TWO (review P2, #2402). `installed_units` used to hard-code
    # `$HOME/.config/systemd/user` alone while this reader also tried `CONTROLLER_USER_UNIT_DIR` and the
    # PASSWD homes, so the "never arm a second supervisor in the other scope" guard could not see an
    # operator-installed user unit whenever $HOME was not the operator's — and `cloud-cell-bringup.sh`
    # forces HOME=$CELL_HOME before running the installer. Reproduced at the previous head: with our own
    # user unit in the passwd home and HOME=$CELL_HOME, `--install` printed `installed: … changed=1` and
    # left TWO copies for one state dir, no refusal. Two ENABLED units are two supervisors for one queue:
    # `stop` addresses one while the other revives the controller (#1761). The guard now shares the
    # read-back verbs' enumeration, so the two can never disagree about what is installed.
    # ⛔ AND A DIRECTORY IS COUNTED ONCE — BY ITS RESOLVED SPELLING (review P2, #2402; re-review P2, #2666).
    # The seams it unions (`SYSTEMD_UNIT_DIR`, `CONTROLLER_SYSTEM_UNIT_DIR`, `CONTROLLER_USER_UNIT_DIR`, the
    # caller's `$HOME`, the passwd homes) are spelled independently, so the SAME directory arrives twice with
    # a trailing slash or through a symlinked home and a literal `$seen` let both through: the "already
    # installed" guard then printed ONE file twice as two copies and refused a healthy idempotent re-install
    # with `--uninstall` (destructive) as its remedy. `cloud-cell-bringup.sh --check` re-runs `--install`
    # every time and the shape this PR targets is exactly HOME != passwd home, so that refusal was permanent
    # rather than an edge. Resolved once, used for the dedupe, the printed path, and the guard's comparison.
    for d in "${SYSTEMD_UNIT_DIR:-}" "${CONTROLLER_SYSTEM_UNIT_DIR:-/etc/systemd/system}"; do
        [ -n "$d" ] || continue
        d="$(canon_dir "$d")"
        [ -n "$d" ] || continue
        case "$d" in "$CANON_UNRESOLVED"*) continue ;; esac   # unresolvable: never a copy we can reason about
        case "$seen" in *" $d "*) continue ;; esac
        seen="$seen$d "
        [ -f "$d/$UNIT_NAME" ] || continue
        unit_is_ours "$d/$UNIT_NAME" || continue
        printf '%s\n' "$d/$UNIT_NAME"
    done
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        d="$(canon_dir "$d")"
        [ -n "$d" ] || continue
        case "$d" in "$CANON_UNRESOLVED"*) continue ;; esac   # unresolvable: never a copy we can reason about
        case "$seen" in *" $d "*) continue ;; esac
        seen="$seen$d "
        [ -f "$d/$UNIT_NAME" ] || continue
        unit_is_ours "$d/$UNIT_NAME" || continue
        printf '%s\n' "$d/$UNIT_NAME"
    done < <(installed_user_unit_dirs)
    return 0
}
find_installed_unit() { # the first copy, in scope order (the installed file is the evidence)
    local p
    # NOT `| head -1`: under `set -euo pipefail` a writer SIGPIPE'd by `head` fails the whole pipeline
    # (#836 class — a present value reported as missing).
    p="$(installed_unit_copies)"
    [ -n "$p" ] || return 1
    printf '%s\n' "${p%%$'\n'*}"
    return 0
}
# every installed copy, in the order the scopes are tried. ONE is the normal case; two is an operator who
# installed both, and the second is why `--uninstall` must not report "no longer supervised" over a copy
# it did not remove.
installed_units() {
    installed_unit_copies
}
do_uninstall() {
    local p left _f
    # ⛔ ANOTHER STATE DIR'S UNIT IS NOT OURS TO REMOVE, AND NOT SILENT EITHER (review P1, #2402): the
    # `--uninstall` for state dir B used to `disable --now` and `rm -f` A's unit and report success, which
    # stops A's controller and strips its Restart=always — the #2402 defect, caused by another cell's verb.
    # Named once, up front, so an operator on a two-state-dir box is never blind to what was left alone.
    # ⛔ AN ELEVATED UNINSTALL CANNOT SEE THE OPERATOR'S UNIT (review P2, #2402). Running the installer
    # through `sudo` sets HOME=/root, so every reader here ($HOME/.config/systemd/user, the state dir)
    # describes root's world: find_installed_unit found nothing, the verb printed "not installed" and
    # returned 0 while the operator's user unit stayed installed, enabled and restarting the controller —
    # the exact false pass --uninstall exists to refuse.
    # ⛔ AND IT IS THE UID, NOT `SUDO_USER` (review P1, #2402). The guard below used to test
    # `id -u = 0 AND SUDO_USER set`, which refused the ONE spelling that carries a stand-in and ADMITTED
    # every other root run — `su -`, a direct root login, any root-run provision. Those have HOME=/root and
    # no SUDO_USER, so the same blind read reported "not installed" (rc 0) over an operator-home unit that
    # was still enabled and restarting the controller. This is the same weak test the INSTALL guard was
    # rewritten to remove, and its own comment (:427 above) names the defect; the two halves had drifted.
    # `CONTROLLER_ALLOW_ROOT=1` is the one opt-in, shared with `--install`, so a root-only container is a
    # decision the operator states rather than a state the verb guesses.
    if [ "$(id -u)" = "0" ] && [ "${CONTROLLER_ALLOW_ROOT:-0}" != "1" ]; then
        err "REFUSING to uninstall as root (uid 0${SUDO_USER:+, SUDO_USER=$SUDO_USER}): HOME=/root hides the operator's user unit,"
        err "  so this verb would report 'not installed' over a supervisor that is still enabled. Re-run as"
        err "  the operator: ${SUDO_USER:+sudo -u $SUDO_USER -H }bash $0 --uninstall"
        err "  (on a root-only box, the documented escape is the same one --install uses:"
        err "    CONTROLLER_ALLOW_ROOT=1 bash $0 --uninstall)"
        return 1
    fi
    if [ -z "$SC" ]; then choose_target >/dev/null 2>&1 || true; fi
    # the installed copy decides the scope; the resolved one is only the fallback when none is found
    p="$(find_installed_unit)" || p="${UNIT_DIR:+$UNIT_DIR/$UNIT_NAME}"
    while IFS= read -r _f; do
        [ -n "$_f" ] || continue
        log_line "other_unit=$_f (supervises $(unit_owner_dir "$_f") — NOT this state dir's; left untouched)"
    done < <(foreign_units)
    # ⛔ THE FALLBACK PATH IS NOT A LICENCE TO ADDRESS SOMEONE ELSE'S UNIT (review P1, #2402). When no copy
    # of OURS is installed, `p` falls back to the path THIS box would choose — which on a two-state-dir box
    # is the very directory the foreign copy lives in. Without this check the verb below would `disable
    # --now` and `rm -f` that copy: it stops another cell's controller and strips its Restart=always. There
    # is nothing of ours to uninstall here, so report that and change nothing.
    if [ -n "$p" ] && [ -f "$p" ] && ! unit_is_ours "$p"; then
        log_line "not installed for $O: the unit at $p supervises $(unit_owner_dir "$p") — nothing to do"
        return 0
    fi
    if [ -z "$p" ]; then err "no unit scope resolved — nothing to uninstall"; return 1; fi
    UNIT_DIR="$(dirname "$p")"
    scope_for_dir "$UNIT_DIR"
    # ⛔ "NOT INSTALLED" IS ONLY A SUCCESS WHEN NOTHING IS INSTALLED (review P2, #2402). The early return
    # used to fire whenever the RESOLVED path was absent, before `installed_units` was ever consulted — so
    # a differently-resolved scope could hide a live, enabled copy behind rc 0.
    if [ ! -f "$p" ]; then
        left="$(installed_units)"
        if [ -n "$left" ]; then
            err "not installed at $p, but a copy EXISTS elsewhere: $(printf '%s' "$left" | tr '\n' ' ')"
            err "  re-run --uninstall so the installed copy decides the scope"
            return 1
        fi
        log_line "not installed: $p"; return 0
    fi
    # ⛔ NOT SWALLOWED (review P2). A failed disable leaves the `…target.wants` symlink in place, so the
    # unit is still enabled after its file is gone — and removing the file does not stop a running
    # controller either. Reporting success there is "uninstalled" over a supervisor that is still armed.
    sc_run disable --now "$UNIT_NAME" >/dev/null 2>&1 \
        || { err "could not disable $UNIT_NAME — it is still ENABLED (it would return on the next boot) and may still be running: systemctl disable --now $UNIT_NAME"; return 1; }
    if [ "$TARGET" = "system" ]; then
        ${SUDO-sudo -n} rm -f "$p" || { err "cannot remove $p"; return 1; }
    else
        rm -f "$p" || { err "cannot remove $p"; return 1; }
    fi
    sc_run daemon-reload >/dev/null 2>&1 || true
    # ⛔ A SECOND INSTALLED COPY IS STILL A SUPERVISOR (review P2, #2402). Reporting "no longer supervised"
    # over a copy this verb did not remove is the false pass; name it and fail, so the operator finishes
    # the job instead of walking away from a unit that is still enabled and will start at boot.
    local left; left="$(installed_units)"
    if [ -n "$left" ]; then
        err "uninstalled $p, but ANOTHER copy remains: $(printf '%s' "$left" | tr '\n' ' ')"
        err "  that unit is still installed (and may still be enabled) — remove it too: re-run --uninstall"
        return 1
    fi
    # ⛔ THE REMEDY MUST BE RUNNABLE (review P2 round 19, #2402 / C). `$SUPERVISOR` is resolved only on the
    # INSTALL path (`resolve_supervisor` was called by `do_install` alone), so this printed
    # `start it by hand with 'bash  start'` — the one instruction an operator is left with after removing the
    # supervisor, and it cannot be followed. Resolve it here too, and fall back to the shipped script's own
    # path so the sentence is never empty.
    local _sup="${SUPERVISOR:-}"
    if [ -z "$_sup" ]; then
        # `resolve_supervisor` ERRS when it finds nothing, which would abort the message; the uninstall has
        # already succeeded at this point, so take its candidates without the hard failure.
        for _sup in "${ORCH_SUPERVISOR:-}" \
                    "$HOME/.pi/agent/scripts/cloud-cell-supervisor.sh" \
                    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/cloud-cell-supervisor.sh"; do
            [ -n "$_sup" ] && [ -f "$_sup" ] && break || _sup=""
        done
        [ -n "$_sup" ] || _sup="cloud-cell-supervisor.sh (farm it: bash pi-bootstrap/setup.sh)"
    fi
    log_line "uninstalled $p — the controller is no longer supervised: start it by hand with 'bash $_sup start', and note that a tmux controller is NOT restarted by anything (#2402)"
    return 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --install)   ACTION=--install ;;
        --dry-run)   ACTION=--install; DRY_RUN=1 ;;
        --status)    ACTION=--status ;;
        --uninstall) ACTION=--uninstall ;;
        --help|-h)   ACTION=--help ;;
        *)           err "unknown argument: $1 (try --help)"; exit 2 ;;
    esac
    shift
done

case "$ACTION" in
    --help)      help_text; exit $? ;;
    --install)   do_install; exit $? ;;
    --status)    do_status; exit $? ;;
    --uninstall) do_uninstall; exit $? ;;
esac
