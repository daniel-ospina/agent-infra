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
        -e "s|{{START_TIMEOUT_SEC}}|$START_TIMEOUT_SEC|g" \
        -e "s|{{HANDOVER_TIMEOUT_SEC}}|$HANDOVER_TIMEOUT_SEC|g" \
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
             "StartLimitIntervalSec=300" "StartLimitBurst=3" "KillMode=process" \
             "TimeoutStartSec=$START_TIMEOUT_SEC" \
             "Environment=CONTROLLER_ORPHAN_TIMEOUT=$START_TIMEOUT_SEC" \
             "Environment=CONTROLLER_HANDOVER_TIMEOUT=$HANDOVER_TIMEOUT_SEC" \
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
controller_proof() { # [<not_before_epoch>] — a heartbeat older than this start proves nothing
    local pid hb now since="${1:-0}"
    local lt rc
    pid=""
    [ ! -f "$O/.orch.lock" ] || pid="$(tr -dc '0-9' <"$O/.orch.lock" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && argv_is_orch_loop "$pid"; then
        # ⛔ SHAPE IS NOT OWNERSHIP (review P1, #2402). Every controller on this box is a shell followed by
        # a shared-harness orch-loop.sh, so a recycled pid — a PEER repo's controller — passes the shape
        # test. A controller always writes $LOCK AFTER it starts, so a process that BEGAN after the lock
        # was written cannot be its owner. Unprovable age (ps/date that cannot answer) is NOT a proof
        # either: fall through to the heartbeat leg rather than certify.
        lt="$(date -r "$O/.orch.lock" +%s 2>/dev/null || true)"
        _proc_began_after "$pid" "${lt:-}"; rc=$?
        [ "$rc" -eq 1 ] && return 0
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
    local tpl tmpd changed=0 linger=0 pid rc pre_active=0 started_at="" proof_since=0 sl_iv sl_burst
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
    case "${START_TIMEOUT_SEC:-}" in
        ''|*[!0-9]*) err "REFUSING: ORCH_START_TIMEOUT_SEC must be a whole number of seconds (got '$START_TIMEOUT_SEC')"; return 1 ;;
    esac
    [ "$START_TIMEOUT_SEC" -ge 1 ] 2>/dev/null \
        || { err "REFUSING: ORCH_START_TIMEOUT_SEC must be >= 1 (got '$START_TIMEOUT_SEC')"; return 1; }
    [ "$(( sl_burst * (START_TIMEOUT_SEC + RESTART_SEC) ))" -lt "$sl_iv" ] \
        || { err "REFUSING: ORCH_START_TIMEOUT_SEC=$START_TIMEOUT_SEC does not fit StartLimitBurst=$sl_burst attempts inside StartLimitIntervalSec=${sl_iv}s — each attempt costs the orphan ceiling plus RestartSec (${RESTART_SEC}s), so $sl_burst failures span $(( sl_burst * (START_TIMEOUT_SEC + RESTART_SEC) ))s, the oldest start ages out of the window before the burst is exceeded, and the unit restarts forever over a start that can never succeed while --status reads supervised. Use ORCH_START_TIMEOUT_SEC <= $(( sl_iv / sl_burst - RESTART_SEC ))s."; return 1; }
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
    say "unit=$UNIT_NAME target=$TARGET"
    # ⛔ NAME A COPY THAT IS NOT THIS STATE DIR'S, INSTEAD OF ANSWERING FOR IT (review P1, #2402). Silence
    # here is what made this verb's rc 0 readable as "my cell is supervised" on a box whose only unit belongs
    # to another state dir. It is reported on its own line and never addressed: the manager answers about the
    # unit NAME, which is machine-scoped.
    while IFS= read -r _f; do
        [ -n "$_f" ] || continue
        say "other_unit=$_f (supervises $(unit_owner_dir "$_f") — NOT this state dir's; NOT read, NOT addressed)"
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
    # ⛔ MainPID IS THE UNIT'S MAIN PROCESS, NOT NECESSARILY THE CONTROLLER (review P2, #2402). Under
    # Type=simple the main process is the launcher (`… start`), which spends harness_apply/cmd_check — and
    # up to CONTROLLER_HANDOVER_TIMEOUT — before it `exec`s the loop, so a live MainPID alone can be a
    # launcher. The CONTROLLER-level witness is the one --install already applies (the lock's owner, age
    # bound; or a plausible heartbeat). Reported here, never used to decide rc: a start that is still
    # inside its first CYC legitimately has neither witness, and turning that into a refusal would be a
    # false red on every healthy start. The stale-heartbeat refusal above is what bounds the ambiguity.
    if controller_proof; then
        say "controller=proved (an owned lock holder, or a heartbeat newer than 2*CYC)"
    else
        say "controller=none-proved yet (no owned lock holder and no plausible heartbeat — expected during the first CYC after a start; the heartbeat bound above is what refuses a dead one)"
    fi
    # NRestarts is the direct evidence for the issue's bullet 3/5 ("it comes back on its own"): a unit
    # that has restarted had a controller that died and was brought back without a human.
    local nr; nr="$(sc_run show -p NRestarts "$UNIT_NAME" 2>/dev/null)"; case "$nr" in NRestarts=*) say "restarts=${nr#NRestarts=}" ;; *) say "restarts=unreadable" ;; esac
    if age="$(heartbeat_age)"; then
        say "heartbeat_age_s=$age"
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
# ⛔ A UNIT FILE'S PRESENCE IS NOT AN OWNERSHIP CLAIM (review P1, #2402). The unit NAME is machine-scoped
# (eldato-orchestrator.service), so "the first copy on the box" can be ANOTHER state dir's — measured on a
# two-state-dir box: B's `--uninstall` disabled and deleted A's unit and reported "the controller is no
# longer supervised" (rc 0), and B's `--status` answered enabled+active+MainPID with rc 0 over a unit B does
# not own, i.e. the #2402 "reads as a healthy box" false green on the one verb the docs tell an operator to
# trust. The rendered unit CARRIES its owner, so ownership is a READ, not a guess.
#
# ⛔ AND THE READ IS THE RESOLUTION, NOT THE RENDERED `Environment=O=` (review P1, #2402). This copy is a
# PINNED MIRROR of `cloud-cell-supervisor.sh::unit_owner_dir`, and it exists because the two answers
# DIVERGED: the unit also renders `Environment=ENV_FILE=`, the controller re-sources that file and
# `keys.env` may repoint `O` — this installer "never sources `$ENV_FILE`", so its `$O` and the
# controller's "can legitimately differ". A bare comparison therefore called this cell's OWN unit another
# state dir's as soon as `keys.env` carried an `O=` line: `--uninstall` reported "not installed for $O" and
# left an ENABLED unit running (`Restart=always`, still supervising), while `--install` could not see the
# existing copy and armed a SECOND one in the other scope — two dispatchers on one queue (#1761). A
# trailing slash is a spelling, not a different state dir. Keep this body identical to the supervisor's:
# §L-iii pins the divergence case here, and cloud-cell-supervisor.test.sh pins the same arm there.
unit_owner_dir() { # <unit file> -> the state dir it supervises; nothing when it carries no O= line
    local f="$1" rendered_o envf unit_home eff
    [ -f "$f" ] || return 1
    rendered_o="$(sed -n 's/^Environment=O=//p' "$f" 2>/dev/null | head -1)"
    envf="$(sed -n 's/^Environment=ENV_FILE=//p' "$f" 2>/dev/null | head -1)"
    unit_home="$(sed -n 's/^Environment=CELL_HOME=//p' "$f" 2>/dev/null | head -1)"
    eff=""
    if [ -n "${envf:-}" ] && [ -r "$envf" ]; then
        # The unit's own declared file, evaluated the way the controller evaluates it, in a throwaway
        # subshell; `env -u` keeps an inherited O/CELL_HOME from shadowing the unit's own. A file with a
        # top-level `exit` ends the subshell silently, and the empty answer falls back to the rendered
        # value — never to "no owner".
        eff="$(env -u O -u CELL_HOME -u ENV_FILE bash -c '
            CELL_HOME="$2"; O="$3"; ENV_FILE="$1"
            set -a; . "$1" >/dev/null 2>&1
            printf "%s" "${O:-}"
        ' _ "$envf" "${unit_home:-}" "${rendered_o:-}" 2>/dev/null || true)"
    fi
    [ -n "${eff:-}" ] || eff="${rendered_o:-}"
    [ -n "${eff:-}" ] || return 1
    printf '%s\n' "${eff%/}"
}
# May this verb address <unit file>? YES for our own copy, and YES for an UNPROVABLE one (no O= line — a
# hand-written or pre-#2402 unit), which is the fail-safe side of #1761: assume it may be ours and never
# launch a tmux controller beside a unit that could be enabled. NO only when it provably supervises a
# DIFFERENT state dir — and then nothing here may disable, delete, or report on it.
unit_is_ours() { # <unit file>
    local own
    own="$(unit_owner_dir "$1")" || return 0
    [ "$own" = "${O%/}" ]
}
# Every installed copy that PROVABLY belongs to another state dir — reported, never addressed.
foreign_units() {
    local d seen=" "
    for d in "${SYSTEMD_UNIT_DIR:-}" "${CONTROLLER_SYSTEM_UNIT_DIR:-/etc/systemd/system}" "$HOME/.config/systemd/user"; do
        [ -n "$d" ] || continue
        case "$seen" in *" $d "*) continue ;; esac
        seen="$seen$d "
        [ -f "$d/$UNIT_NAME" ] || continue
        unit_is_ours "$d/$UNIT_NAME" || printf '%s\n' "$d/$UNIT_NAME"
    done
    return 0
}
# ⛔ FIND THE INSTALLED COPY, DO NOT RE-DERIVE THE SCOPE (review P2, #2402). `choose_target` answers "where
# WOULD this go on THIS box now", which is not "where IS it": a box that installed a USER unit and later
# gained passwordless sudo would resolve to the SYSTEM scope, print `not installed: /etc/systemd/system/…`
# and exit 0 while the user unit stayed installed, enabled and running. The installed file is the evidence.
find_installed_unit() {
    local d seen=" "
    # ⛔ `CONTROLLER_SYSTEM_UNIT_DIR` is the READ side of the system scope (the supervisor's own seam name);
    # `SYSTEMD_UNIT_DIR` stays the WRITE override. Conflating them is how a write-path override decided
    # which installed copy a read-back reported on.
    # ⛔ AND A DIRECTORY IS COUNTED ONCE (review P2, #2402). The two seams are independent, so a caller
    # may point both at one directory — the hermetic suite does exactly that to keep its read-backs off
    # the host. Without this dedupe that configuration reported the SAME file twice, and `installed_units`'
    # "two copies installed" arm then fired on a single unit: install re-runs exited 1 with `changed=1`
    # (`install: re-run rc differs (0 then 1)`, reproduced).
    for d in "${SYSTEMD_UNIT_DIR:-}" "${CONTROLLER_SYSTEM_UNIT_DIR:-/etc/systemd/system}" "$HOME/.config/systemd/user"; do
        [ -n "$d" ] || continue
        case "$seen" in *" $d "*) continue ;; esac
        seen="$seen$d "
        [ -f "$d/$UNIT_NAME" ] || continue
        unit_is_ours "$d/$UNIT_NAME" || continue
        printf '%s\n' "$d/$UNIT_NAME"; return 0
    done
    return 1
}
# every installed copy, in the order the scopes are tried. ONE is the normal case; two is an operator who
# installed both, and the second is why `--uninstall` must not report "no longer supervised" over a copy
# it did not remove.
installed_units() {
    local d seen=" "
    for d in "${SYSTEMD_UNIT_DIR:-}" "${CONTROLLER_SYSTEM_UNIT_DIR:-/etc/systemd/system}" "$HOME/.config/systemd/user"; do
        [ -n "$d" ] || continue
        case "$seen" in *" $d "*) continue ;; esac
        seen="$seen$d "
        [ -f "$d/$UNIT_NAME" ] || continue
        unit_is_ours "$d/$UNIT_NAME" || continue
        printf '%s\n' "$d/$UNIT_NAME"
    done
    return 0
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
    if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
        err "REFUSING to uninstall as root (SUDO_USER=$SUDO_USER): HOME=/root hides the operator's user unit,"
        err "  so this verb would report 'not installed' over a supervisor that is still enabled. Re-run as"
        err "  the operator: sudo -u $SUDO_USER -H bash $0 --uninstall"
        return 1
    fi
    if [ -z "$SC" ]; then choose_target >/dev/null 2>&1 || true; fi
    # the installed copy decides the scope; the resolved one is only the fallback when none is found
    p="$(find_installed_unit)" || p="${UNIT_DIR:+$UNIT_DIR/$UNIT_NAME}"
    while IFS= read -r _f; do
        [ -n "$_f" ] || continue
        say "other_unit=$_f (supervises $(unit_owner_dir "$_f") — NOT this state dir's; left untouched)"
    done < <(foreign_units)
    # ⛔ THE FALLBACK PATH IS NOT A LICENCE TO ADDRESS SOMEONE ELSE'S UNIT (review P1, #2402). When no copy
    # of OURS is installed, `p` falls back to the path THIS box would choose — which on a two-state-dir box
    # is the very directory the foreign copy lives in. Without this check the verb below would `disable
    # --now` and `rm -f` that copy: it stops another cell's controller and strips its Restart=always. There
    # is nothing of ours to uninstall here, so report that and change nothing.
    if [ -n "$p" ] && [ -f "$p" ] && ! unit_is_ours "$p"; then
        say "not installed for $O: the unit at $p supervises $(unit_owner_dir "$p") — nothing to do"
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
