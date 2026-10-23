#!/usr/bin/env bash
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
CELL_HOME="${CELL_HOME:-${HOME:?HOME is required}}"
ENV_FILE="${ENV_FILE:-$CELL_HOME/keys.env}"
O="${O:-$CELL_HOME/orchestrator}"
ACTION=--install

say() { printf '%s\n' "$*"; }
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
TARGET=""; UNIT_DIR=""; SC=""
choose_target() {
    if [ "$PLATFORM" = "Darwin" ]; then
        err "REFUSING on Darwin: a Mac's controller is already a launchd agent with KeepAlive"
        err "  (orchestrator-harness/launchd.plist.template, installed by orchestrator-harness/install.sh)."
        err "  A second supervisor here would be a SECOND dispatcher on one queue — use:"
        err "    bash $INFRA_ROOT/scripts/orchestrator-harness/install.sh --start"
        return 1
    fi
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ]; then
        TARGET="override"; UNIT_DIR="$SYSTEMD_UNIT_DIR"; SC="${SYSTEMCTL:-systemctl}"
        return 0
    fi
    # ⛔ `${SUDO:-sudo -n}` CANNOT BE EMPTY (`:-` substitutes on empty too), so `SUDO=` would be
    # unreachable as a documented "skip the sudo probe" seam. `${SUDO+x}` distinguishes unset from
    # set-to-empty, and a pinned SYSTEMCTL is honoured on the SYSTEM target too — a pinned shim silently
    # overridden installs the unit as one identity and enables it as another.
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
             "StartLimitIntervalSec=300" "StartLimitBurst=3" \
             "Environment=ORCH_FOREGROUND=1" "ExecStart=/bin/bash $SUPERVISOR start" "User=$(id -un)" \
             "WantedBy=multi-user.target"; do
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
unit_active()  { sc_run is-active --quiet "$UNIT_NAME" >/dev/null 2>&1; }
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
heartbeat_age() {
    local hb="$O/heartbeat" t
    [ -f "$hb" ] || return 1
    t="$(tr -dc '0-9' <"$hb" 2>/dev/null)" || return 1
    case "${t:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ "$t" -gt 0 ] 2>/dev/null || return 1
    printf '%s\n' "$(( $(date +%s) - t ))"
}

# ── actions ───────────────────────────────────────────────────────────────────────────────────
do_install() {
    local tpl tmpd changed=0 linger=0 pid rc
    case "${RESTART_SEC:-}" in
        ''|*[!0-9]*) err "REFUSING: ORCH_RESTART_SEC must be a whole number of seconds (got '$RESTART_SEC')"; return 1 ;;
    esac
    [ "$RESTART_SEC" -ge 1 ] 2>/dev/null \
        || { err "REFUSING: ORCH_RESTART_SEC must be >= 1 (got '$RESTART_SEC') — 0 is not a delay"; return 1; }
    resolve_supervisor || return 1
    tpl="$TEMPLATES_DIR/$UNIT_NAME"
    [ -f "$tpl" ] || { err "template missing: $tpl (set TEMPLATES_DIR)"; return 1; }
    choose_target || return 1

    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/controller-unit.XXXXXX")" || { err "cannot create a temp dir"; return 1; }
    render "$tpl" "$tmpd/$UNIT_NAME" || { rm -rf "$tmpd"; return 1; }

    if [ "${DRY_RUN:-0}" = 1 ]; then
        say "dry-run: would install $UNIT_DIR/$UNIT_NAME (target=$TARGET) and enable it"
        say "--- $UNIT_NAME ---"; sed 's/^/  /' "$tmpd/$UNIT_NAME"
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
    sc_run start "$UNIT_NAME" >/dev/null 2>&1 || true

    # ⛔ THE VERDICT IS THE UNIT *AND* A CONTROLLER. `is-active` alone is the false green: the unit is
    # active for the seconds before `start` dies on a missing key, a wrong repo or a foreign controller,
    # and it is also "active" forever if it fails its start limit at the same moment we ask. So ask for
    # the MainPID and for a FRESH heartbeat, and REFUSE the install when the controller is not actually up.
    if ! unit_active; then
        err "the unit is NOT active after install — the cell still has no supervisor:"
        sc_run status "$UNIT_NAME" --no-pager 2>&1 | sed 's/^/  /' | head -20 >&2 || true
        err "  read the reason: journalctl -u $UNIT_NAME -n 40"
        return 1
    fi
    pid="$(unit_main_pid)" || { err "cannot read $UNIT_NAME's MainPID — the unit answers is-active but nothing here can say a controller is running"; return 1; }
    [ "${pid:-0}" != "0" ] || { err "$UNIT_NAME is active with MainPID 0 — no controller process; read: journalctl -u $UNIT_NAME -n 40"; return 1; }

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

    say "installed: target=$TARGET dir=$UNIT_DIR changed=$changed"
    say "  unit:    $UNIT_NAME (Restart=always, RestartSec=${RESTART_SEC}s, After=network-online.target,"
    say "           StartLimitBurst=3/300s so a configuration fault converges to 'failed' instead of looping)"
    say "  exec:    /bin/bash $SUPERVISOR start   (ORCH_FOREGROUND=1 — the controller is the unit's main process)"
    say "  state:   $O   (env: $ENV_FILE)"
    say "  controller pid: $pid"
    local age
    if age="$(heartbeat_age)"; then say "  heartbeat: ${age}s ago"; else say "  heartbeat: not yet (the loop writes $O/heartbeat after its first cycle)"; fi
    say "  stop it: bash $SUPERVISOR stop   |   supervise state: bash $0 --status"
    return 0
}

do_status() {
    local active enabled pid age rc=0
    [ -n "${SYSTEMD_UNIT_DIR:-}" ] && { TARGET="override"; UNIT_DIR="$SYSTEMD_UNIT_DIR"; SC="${SYSTEMCTL:-systemctl}"; }
    if [ -z "$SC" ]; then choose_target || { err "no service manager available — nothing is supervising the controller"; return 1; }; fi
    say "unit=$UNIT_NAME target=$TARGET"
    if ! enabled="$(sc_run is-enabled "$UNIT_NAME" 2>/dev/null)"; then enabled="unreadable"; fi
    if unit_active; then active="active"; else active="not-active"; fi
    say "enabled=$enabled"
    say "active=$active"
    if pid="$(unit_main_pid 2>/dev/null)"; then say "main_pid=$pid"; else say "main_pid=UNREADABLE"; rc=1; fi
    # NRestarts is the direct evidence for the issue's bullet 3/5 ("it comes back on its own"): a unit
    # that has restarted had a controller that died and was brought back without a human.
    local nr; nr="$(sc_run show -p NRestarts "$UNIT_NAME" 2>/dev/null)"; case "$nr" in NRestarts=*) say "restarts=${nr#NRestarts=}" ;; *) say "restarts=unreadable" ;; esac
    if age="$(heartbeat_age)"; then
        say "heartbeat_age_s=$age"
        # Two cycles + 300s is the same staleness bound install.sh uses for launchd: a quiet cell is not a
        # wedged one, and a wedged one must not read as fresh.
        local bound=$(( ${CYC:-240} * 2 + 300 ))
        [ "$age" -le "$bound" ] || { err "the controller has not ticked for ${age}s (> ${bound}s) — the unit is up but the loop is not cycling"; rc=1; }
    else
        say "heartbeat_age_s=UNREADABLE (no $O/heartbeat)"
        [ "$active" = "active" ] && rc=1
    fi
    [ "$active" = "active" ] || { err "the unit is NOT active — nothing is supervising the controller"; rc=1; }
    [ "$enabled" = "enabled" ] || { err "the unit is NOT enabled — it will not come back after a reboot"; rc=1; }
    return "$rc"
}

do_uninstall() {
    local p
    if [ -z "$SC" ]; then choose_target >/dev/null 2>&1 || true; fi
    if [ -z "$UNIT_DIR" ]; then err "no unit scope resolved — nothing to uninstall"; return 1; fi
    p="$UNIT_DIR/$UNIT_NAME"
    # disable BEFORE removing the file: a removed-but-enabled unit comes back on the next daemon-reload.
    [ -f "$p" ] || { say "not installed: $p"; return 0; }
    sc_run disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
    if [ "$TARGET" = "system" ]; then
        ${SUDO-sudo -n} rm -f "$p" || { err "cannot remove $p"; return 1; }
    else
        rm -f "$p" || { err "cannot remove $p"; return 1; }
    fi
    sc_run daemon-reload >/dev/null 2>&1 || true
    say "uninstalled $p — the controller is no longer supervised: start it by hand with 'bash $SUPERVISOR start', and note that a tmux controller is NOT restarted by anything (#2402)"
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
