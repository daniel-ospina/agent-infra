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
TARGET=""; UNIT_DIR=""; SC=""; WANTED_BY="multi-user.target"
# ⛔ THE BOOT TARGET IS A PROPERTY OF THE SCOPE, NOT A CONSTANT (review P2, #2402). `multi-user.target`
# does not exist in a per-user manager, so a user unit enabled against it would never be brought back —
# the defect this installer removes, one layer down. Resolved here beside the scope so the two cannot
# disagree, and the rendered line is asserted below.
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
        -e "s|{{O}}|$(sed_esc "$O")|g" \
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
             "StartLimitIntervalSec=300" "StartLimitBurst=3" \
             "Environment=ORCH_FOREGROUND=1" "Environment=O=$O" \
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
heartbeat_age() {    local hb="$O/heartbeat" t now age
    [ -f "$hb" ] || return 1
    t="$(tr -dc '0-9' <"$hb" 2>/dev/null)" || return 1
    case "${t:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#t}" -le 12 ] || return 1
    t=$(( 10#$t ))
    [ "$t" -ge 1000000000 ] 2>/dev/null || return 1
    now="$(date +%s)"
    [ "$t" -le "$(( now + 60 ))" ] 2>/dev/null || return 1
    age=$(( now - t ))
    [ "$age" -ge 0 ] || age=0
    printf '%s\n' "$age"
}
# Is a CONTROLLER of this state dir running? (review P1, #2402) The harness's single-instance lock names
# the loop's pid; identity is checked as well as liveness, because a recycled pid is not our loop (#1178).
# A plausible heartbeat is the second witness (the loop's own first cycle), so a cell whose lock the loop
# has not taken YET — harness_apply + cmd_check run first — is not refused for the seconds it needs.
controller_proof() { # [<not_before_epoch>] — a heartbeat older than this start proves nothing
    local pid hb now since="${1:-0}"
    pid=""
    [ ! -f "$O/.orch.lock" ] || pid="$(tr -dc '0-9' <"$O/.orch.lock" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
       && ps -o args= -p "$pid" 2>/dev/null | grep -qF "$O/orch-loop.sh"; then
        return 0
    fi
    hb=""
    [ ! -f "$O/heartbeat" ] || hb="$(tr -dc '0-9' <"$O/heartbeat" 2>/dev/null || true)"
    case "${hb:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#hb}" -le 12 ] || return 1
    hb=$(( 10#$hb ))
    [ "$hb" -ge 1000000000 ] 2>/dev/null || return 1
    now="$(date +%s)"
    [ "$hb" -le "$(( now + 60 ))" ] 2>/dev/null || return 1
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
    local tpl tmpd changed=0 linger=0 pid rc pre_active=0 started_at="" proof_since=0
    # ⛔ REFUSE AN ELEVATED INSTALL (review P2, #2402). `sudo bash install-controller-service.sh` renders
    # User=root / HOME=/root / O=/root/orchestrator, and verify_unit *requires* that — so the unit is green,
    # runs as root with root's keys.env and gh auth, and, because it is ENABLED, a later `start` delegates
    # to it and the cell's controller can never come up until someone runs --uninstall. The sibling this
    # installer follows refuses exactly this; so does this one.
    if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
        err "REFUSING to install as root (SUDO_USER=$SUDO_USER): the controller would run as root, with root's"
        err "  keys.env, gh auth and state dir — and an enabled unit that fails stays enabled, so 'start' would"
        err "  keep delegating to a controller that cannot run."
        err "  Re-run as the operator: sudo -u $SUDO_USER -H bash $0 --install"
        return 1
    fi
    case "${RESTART_SEC:-}" in
        ''|*[!0-9]*) err "REFUSING: ORCH_RESTART_SEC must be a whole number of seconds (got '$RESTART_SEC')"; return 1 ;;
    esac
    [ "$RESTART_SEC" -ge 1 ] 2>/dev/null \
        || { err "REFUSING: ORCH_RESTART_SEC must be >= 1 (got '$RESTART_SEC') — 0 is not a delay"; return 1; }
    resolve_supervisor || return 1
    tpl="$TEMPLATES_DIR/$UNIT_NAME"
    [ -f "$tpl" ] || { err "template missing: $tpl (set TEMPLATES_DIR)"; return 1; }
    choose_target || return 1
    # ⛔ NEVER ARM A SECOND SUPERVISOR IN THE OTHER SCOPE (review P2, #2402). `enable` is unconditional, so a
    # box that installed a USER unit and later gained passwordless sudo would get a SYSTEM unit too — both
    # enabled, both started at boot, and the loser parked in the adopt-wait forever. The bring-up re-runs
    # --install on every --check, so this is not exotic: it is the next bring-up.
    local other; other="$(installed_units)"
    if [ -n "$other" ] && [ "$other" != "$UNIT_DIR/$UNIT_NAME" ]; then
        err "REFUSING: a unit is already installed at $other, and this run targets $UNIT_DIR/$UNIT_NAME."
        err "  Two ENABLED units are two supervisors for one queue (#1761). Remove the other one first:"
        err "    bash $0 --uninstall   # resolves the INSTALLED copy, then re-run --install"
        return 1
    fi

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
    # ⛔ A HEARTBEAT MUST BE BOUND TO *THIS* START (review P1, #2402): a dead controller's leftover
    # heartbeat certified a unit whose `start` produced nothing. `pre_active` is read BEFORE `start`
    # because an idempotent re-install of a healthy unit must keep passing on that unit's older
    # heartbeat — `start` is a no-op there, and the lock leg proves the controller anyway.
    unit_active_state >/dev/null 2>&1 && pre_active=1
    started_at="$(date +%s)"
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
    local waited=0
    while [ "$waited" -lt "${CONTROLLER_PROOF_TIMEOUT:-240}" ]; do
        controller_proof "$proof_since" && break
        # a unit that has already converged to `failed` will not produce a controller — stop waiting
        case "$(sc_run is-active "$UNIT_NAME" 2>/dev/null)" in failed) break ;; esac
        sleep 2; waited=$((waited + 2))
    done
    controller_proof "$proof_since" || {
        err "$UNIT_NAME is active with MainPID $pid, but NO CONTROLLER PROVED ITSELF in ${waited}s:"
        err "  expected the harness's lock ($O/.orch.lock) held by a live orch-loop.sh, or a heartbeat at $O/heartbeat."
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

    say "installed: target=$TARGET dir=$UNIT_DIR changed=$changed"
    say "  unit:    $UNIT_NAME (Restart=always, RestartSec=${RESTART_SEC}s, After=network-online.target,"
    say "           WantedBy=$WANTED_BY,"
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
    local active enabled pid age rc=0 _found=""
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
    say "unit=$UNIT_NAME target=$TARGET"
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
    say "enabled=$enabled"
    say "active=$active"
    if pid="$(unit_main_pid 2>/dev/null)"; then
        say "main_pid=$pid"
        # ⛔ MainPID 0 IS NOT A CONTROLLER (review P1, #2402; do_install already refuses it). `is-active`
        # reports `activating` during a RestartSec wait and this installer maps that to "active", so a
        # readable-but-old heartbeat let `--status` return 0 for a unit with no controller process — while
        # the doc promises it requires BOTH an active/enabled unit AND a controller MainPID. A heartbeat is
        # evidence the loop TICKED once; it is not evidence one is running now.
        [ "${pid:-0}" != "0" ] || { err "the unit is active with MainPID 0 — no controller process (the RestartSec/activating state, or a start that died): journalctl -u $UNIT_NAME -n 40"; rc=1; }
    else say "main_pid=UNREADABLE"; rc=1; fi
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
        # ⛔ AN UNREADABLE HEARTBEAT IS NOT A FAILED UNIT (review P2, #2402). The supervisor sources
        # $ENV_FILE with `set -a` and documents that `keys.env` may repoint $O, so this installer's $O and
        # the controller's can legitimately differ — and the first cycle writes the file minutes later
        # (CYC). Failing the verb over that was a false red on a healthy service-managed cell. The unit's
        # own MainPID is the proof that a controller is running; the heartbeat is a fresher fact, not a gate.
        say "heartbeat_age_s=UNREADABLE (no READABLE $O/heartbeat — path read: \$O=$O; the file can be absent, or present with a value that is not a plausible instant (too small to be an epoch second, future-dated beyond 60s of skew, or over-long), and a keys.env 'O=' line moves the controller's state dir; the first cycle writes the file after one CYC)"
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
    case "$1" in
        "$HOME/.config/systemd/user") TARGET="user";   SC="${SYSTEMCTL:-systemctl} --user" ;;
        *)                            TARGET="system"
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
    esac
}
# ⛔ FIND THE INSTALLED COPY, DO NOT RE-DERIVE THE SCOPE (review P2, #2402). `choose_target` answers "where
# WOULD this go on THIS box now", which is not "where IS it": a box that installed a USER unit and later
# gained passwordless sudo would resolve to the SYSTEM scope, print `not installed: /etc/systemd/system/…`
# and exit 0 while the user unit stayed installed, enabled and running. The installed file is the evidence.
find_installed_unit() {
    local d
    # ⛔ `CONTROLLER_SYSTEM_UNIT_DIR` is the READ side of the system scope (the supervisor's own seam name);
    # `SYSTEMD_UNIT_DIR` stays the WRITE override. Conflating them is how a write-path override decided
    # which installed copy a read-back reported on.
    for d in "${SYSTEMD_UNIT_DIR:-}" "${CONTROLLER_SYSTEM_UNIT_DIR:-/etc/systemd/system}" "$HOME/.config/systemd/user"; do
        [ -n "$d" ] && [ -f "$d/$UNIT_NAME" ] && { printf '%s\n' "$d/$UNIT_NAME"; return 0; }
    done
    return 1
}
# every installed copy, in the order the scopes are tried. ONE is the normal case; two is an operator who
# installed both, and the second is why `--uninstall` must not report "no longer supervised" over a copy
# it did not remove.
installed_units() {
    local d
    for d in "${SYSTEMD_UNIT_DIR:-}" "${CONTROLLER_SYSTEM_UNIT_DIR:-/etc/systemd/system}" "$HOME/.config/systemd/user"; do
        [ -n "$d" ] && [ -f "$d/$UNIT_NAME" ] && printf '%s\n' "$d/$UNIT_NAME"
    done
    return 0
}
do_uninstall() {
    local p left
    # ⛔ AN ELEVATED UNINSTALL CANNOT SEE THE OPERATOR'S UNIT (review P2, #2402). Running the installer
    # through `sudo` sets HOME=/root, so every reader here ($HOME/.config/systemd/user, the state dir)
    # describes root's world: find_installed_unit found nothing, the verb printed "not installed" and
    # returned 0 while the operator's user unit stayed installed, enabled and restarting the controller —
    # the exact false pass --uninstall exists to refuse.
    if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
        err "REFUSING to uninstall as root (SUDO_USER=$SUDO_USER): HOME=/root hides the operator's user unit,"
        err "  so this verb would report 'not installed' over a supervisor that is still enabled. Re-run as"
        err "  the operator: sudo -u $SUDO_USER -H bash $0 --uninstall"
        return 1
    fi
    if [ -z "$SC" ]; then choose_target >/dev/null 2>&1 || true; fi
    # the installed copy decides the scope; the resolved one is only the fallback when none is found
    p="$(find_installed_unit)" || p="${UNIT_DIR:+$UNIT_DIR/$UNIT_NAME}"
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
        say "not installed: $p"; return 0
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
