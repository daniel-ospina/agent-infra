#!/usr/bin/env bash
# install-disk-reaper-timer.sh — put the disk reaper on the CELL's clock (agent-infra#2032).
#
# WHY THIS IS AN INSTALLER AND NOT A LINE IN THE BRING-UP. The template has to be rendered from
# machine state (HOME, PATH, the repos this box actually has, the state dir the supervisor reads) and
# installed idempotently; the bring-up is the TRIGGER, this is the policy of WHERE and HOW. Same
# split as install-launchd.sh on macOS — one place renders and converges, everything else calls it.
#
# WHAT IT INSTALLS
#   eldato-disk-reaper.service  — `disk-reaper.sh --apply`, one bounded pass (Type=oneshot)
#   eldato-disk-reaper.timer    — hourly (OnCalendar=hourly, Persistent=true)
#
# ⛔ ARMING IS THE OWNER'S DECISION, AND IT WAS MADE. The general rule (#1678, owner ruling
# 2026-10-11) is that deletion tools ship DRY-RUN and arming is a separate, dated, reversible owner
# step. This feature was explicitly instructed to run unattended on the cell, so the unit ExecStart
# carries `--apply` and the arming is visible in the unit file itself. Pass `--dry-run` to install a
# unit that only reports; re-running with `--install` flips it back. Nothing about the arming is
# hidden in an environment default.
#
# THREE INSTALL TARGETS, tried in this order, and the reason is named in the output:
#   1. a SYSTEM unit via passwordless sudo (/etc/systemd/system) — the cell's normal shape; the
#      service runs as the invoking user, so the uv cache and state dir are the lane's, not root's.
#   2. a USER unit (~/.config/systemd/user) when systemd's user manager actually answers — a cell
#      without sudo still gets a clock.
#   3. nothing — a loud FAILURE with the remedy, never a silent no-op. A reaper that was "installed"
#      but never fires is the false PASS this repo keeps removing.
#
# Usage:
#   install-disk-reaper-timer.sh [--install] [--dry-run] [--status] [--uninstall] [--help]
#
# Env seams (tests + unusual cells):
#   DISK_REAPER            the entry point to install (default: the farmed copy, else beside this)
#   DISK_REAPER_STATE_DIR  status/log dir the service exports (default $HOME/.pi/agent/state)
#   DISK_REAPER_REPOS      colon-separated repos the venv/worktree classes scan
#   DISK_REAPER_WT_AGED_DAYS  worktree age floor for the scheduled pass (default 7)
#   TEMPLATES_DIR          template dir (default: this repo's templates/systemd)
#   SYSTEMD_UNIT_DIR       install dir OVERRIDE (tests: a temp dir, with SYSTEMCTL a fake)
#   SYSTEMCTL              `systemctl` to call (tests: a shim; default `sudo -n systemctl`)
#   SUDO                   `sudo` probe (default `sudo -n`)
#
# Exit codes: 0 ok · 1 failure (named) · 2 usage.
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Templates are NOT farmed (only scripts are), so a farmed copy of this installer must be able to
# find them in the checkout that installed the layer. First existing wins; the failure names all.
if [ -z "${TEMPLATES_DIR:-}" ]; then
    for _cand in "${AGENT_INFRA_PATH:-}/templates/systemd" "$INFRA_ROOT/templates/systemd" \
                 "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/templates/systemd"; do
        [ -n "$_cand" ] && [ -d "$_cand" ] && { TEMPLATES_DIR="$_cand"; break; }
    done
fi
TEMPLATES_DIR="${TEMPLATES_DIR:-$INFRA_ROOT/templates/systemd}"
STATE_DIR="${DISK_REAPER_STATE_DIR:-${HOME:?HOME is required}/.pi/agent/state}"
AGED_DAYS="${DISK_REAPER_WT_AGED_DAYS:-7}"
UNIT_NAME="eldato-disk-reaper"
MODE=--install

say() { printf '%s\n' "$*"; }
err() { printf '%s: %s\n' "${0##*/}" "$*" >&2; }

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

# ── resolve the reaper ──────────────────────────────────────────────────────────────────────────
# The FARMED copy first: it is what a cell has after `pi-bootstrap/setup.sh`, and a unit pointing at
# a worktree checkout would break the day that worktree is reaped (by this very tool).
REAPER=""
if [ -n "${DISK_REAPER:-}" ] && [ ! -f "$DISK_REAPER" ]; then
    err "\$DISK_REAPER is set to '$DISK_REAPER' but that is not a regular file — refusing to install a unit that points at a DIFFERENT copy of the reaper"
    exit 2
fi
for cand in "${DISK_REAPER:-}" "${HOME:-}/.pi/agent/scripts/disk-reaper.sh" "$INFRA_ROOT/scripts/disk-reaper.sh"; do
    [ -n "$cand" ] || continue
    if [ -f "$cand" ]; then REAPER="$cand"; break; fi
done

# ── repos: what this box actually has ───────────────────────────────────────────────────────────
# Rendered into the unit so the scheduled pass never depends on a shell's environment. A candidate
# is kept only when git answers for it — a unit scanning a path that is not a repo fails closed every
# hour, which is how an alarm becomes wallpaper.
resolve_repos() {
    local r seen=" " out=""
    local list="${DISK_REAPER_REPOS:-}"
    if [ -z "$list" ]; then
        list="$(printf '%s\n' "${REPO:-}" "${TORTOISE_REPO:-}" "${WORKDIR:-}" "${AGENT_INFRA_PATH:-}")"
    fi
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        case "$seen" in *" $r "*) continue ;; esac
        seen="$seen$r "
        git -C "$r" rev-parse --git-dir >/dev/null 2>&1 || continue
        out="${out}${out:+:}$r"
    done <<<"$(printf '%s\n' "$list" | tr ':' '\n')"
    printf '%s' "$out"
}

render() { # render <template> <dest>
    local tpl="$1" dest="$2"
    sed -e "s|{{USER}}|$(id -un)|g" \
        -e "s|{{HOME}}|$HOME|g" \
        -e "s|{{PATH}}|$PATH|g" \
        -e "s|{{STATE_DIR}}|$STATE_DIR|g" \
        -e "s|{{REPOS}}|$REPOS|g" \
        -e "s|{{AGED_DAYS}}|$AGED_DAYS|g" \
        -e "s|{{REAPER}}|$REAPER|g" \
        "$tpl" >"$dest" || return 1
    grep -q '{{' "$dest" && { err "unresolved placeholder in $tpl"; grep -n '{{' "$dest" >&2; return 1; }
    return 0
}

# ── choose a target ─────────────────────────────────────────────────────────────────────────────
TARGET=""; UNIT_DIR=""; SC=""
choose_target() {
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ]; then
        TARGET="override"; UNIT_DIR="$SYSTEMD_UNIT_DIR"; SC="${SYSTEMCTL:-systemctl}"
        return 0
    fi
    if [ "${SUDO:-sudo -n}" = "" ] || ${SUDO:-sudo -n} true >/dev/null 2>&1; then
        TARGET="system"; UNIT_DIR="/etc/systemd/system"; SC="${SYSTEMCTL:-sudo -n systemctl}"
        return 0
    fi
    if systemctl --user show-environment >/dev/null 2>&1; then
        TARGET="user"; UNIT_DIR="$HOME/.config/systemd/user"; SC="systemctl --user"
        return 0
    fi
    return 1
}

# ── actions ────────────────────────────────────────────────────────────────────────────────────
do_install() {
    local src_svc="$TEMPLATES_DIR/$UNIT_NAME.service" src_tim="$TEMPLATES_DIR/$UNIT_NAME.timer"
    local tmpd changed=0
    [ -n "$REAPER" ] || { err "disk-reaper.sh not found — looked at \$DISK_REAPER, \$HOME/.pi/agent/scripts, and $INFRA_ROOT/scripts. Farm it first: bash pi-bootstrap/setup.sh"; return 1; }
    [ -f "$src_svc" ] && [ -f "$src_tim" ] || { err "templates missing under $TEMPLATES_DIR"; return 1; }
    REPOS="$(resolve_repos)"
    [ -n "$REPOS" ] || err "WARNING: no repo resolved on this box — the venv and worktree classes will fail closed every pass. Set DISK_REAPER_REPOS or REPO."
    choose_target || { err "no scheduler available: no passwordless sudo for a system unit, and no systemd user manager. Install by hand, or give the cell sudo. NOT silently skipping — a reaper that never runs is the failure this exists to remove."; return 1; }

    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/disk-reaper-unit.XXXXXX")" || { err "cannot create a temp dir"; return 1; }
    render "$src_svc" "$tmpd/$UNIT_NAME.service" || { rm -rf "$tmpd"; return 1; }
    render "$src_tim" "$tmpd/$UNIT_NAME.timer" || { rm -rf "$tmpd"; return 1; }
    # A USER unit may not carry User= (systemd rejects it), so drop that line in that mode.
    if [ "$TARGET" = "user" ]; then
        sed -i.bak '/^User=/d' "$tmpd/$UNIT_NAME.service" && rm -f "$tmpd/$UNIT_NAME.service.bak"
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
        say "dry-run: would install to $UNIT_DIR (target=$TARGET) and enable $UNIT_NAME.timer"
        say "--- $UNIT_NAME.service ---"; sed 's/^/  /' "$tmpd/$UNIT_NAME.service"
        say "--- $UNIT_NAME.timer ---"; sed 's/^/  /' "$tmpd/$UNIT_NAME.timer"
        rm -rf "$tmpd"
        return 0
    fi

    # Install only when the rendered bytes differ: a `daemon-reload` + restart on every bring-up
    # would reset Persistent= bookkeeping and re-run the pass at every check.
    cmp -s "$tmpd/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.service" || changed=1
    cmp -s "$tmpd/$UNIT_NAME.timer" "$UNIT_DIR/$UNIT_NAME.timer" || changed=1
    mkdir -p "$UNIT_DIR" 2>/dev/null || true
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ]; then
        cp -f "$tmpd/$UNIT_NAME.service" "$tmpd/$UNIT_NAME.timer" "$UNIT_DIR/" || { err "copy failed"; rm -rf "$tmpd"; return 1; }
    else
        ${SUDO:-sudo -n} install -m 0644 "$tmpd/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.service" \
            && ${SUDO:-sudo -n} install -m 0644 "$tmpd/$UNIT_NAME.timer" "$UNIT_DIR/$UNIT_NAME.timer" \
            || { err "install failed (sudo/systemd)"; rm -rf "$tmpd"; return 1; }
    fi
    rm -rf "$tmpd"

    # ALWAYS re-read unit files (cheap, idempotent), then make sure the timer is enabled+started.
    $SC daemon-reload >/dev/null 2>&1 || { err "daemon-reload failed"; return 1; }
    $SC enable --now "$UNIT_NAME.timer" || { err "could not enable/start $UNIT_NAME.timer"; return 1; }

    say "installed: target=$TARGET dir=$UNIT_DIR changed=$changed"
    say "  reaper: $REAPER"
    say "  repos:  ${REPOS:-<none>}  (worktree floor ${AGED_DAYS}d)"
    say "  state:  $STATE_DIR/disk-reaper.status"
    if $SC is-enabled "$UNIT_NAME.timer" >/dev/null 2>&1; then
        say "  timer:  enabled"
    else
        err "timer is NOT enabled after install — the reaper will not run unattended"; return 1
    fi
    return 0
}

do_status() {
    local next
    choose_target || { err "no scheduler available"; return 1; }
    say "target=$TARGET dir=$UNIT_DIR"
    if ! $SC cat "$UNIT_NAME.service" >/dev/null 2>&1; then
        say "installed=no"
        return 1
    fi
    say "installed=yes"
    say "enabled=$($SC is-enabled "$UNIT_NAME.timer" 2>/dev/null || echo no)"
    say "timer_active=$($SC is-active "$UNIT_NAME.timer" 2>/dev/null || echo no)"
    next="$($SC list-timers --all --no-pager 2>/dev/null | awk -v u="$UNIT_NAME.timer" '$0 ~ u {print $1" "$2" "$3; exit}')"
    say "next_run=${next:-unknown}"
    say "last_run=$($SC show -p ExecMainStatus --value "$UNIT_NAME.service" 2>/dev/null || echo unknown)"
    if [ -n "$REAPER" ] && [ -f "$REAPER" ]; then
        say "--- pass record ---"
        bash "$REAPER" --print-status 2>&1 | sed 's/^/  /' || true
    fi
    return 0
}

do_uninstall() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        say "dry-run: would disable and remove $UNIT_NAME.service/.timer (nothing was changed)"
        return 0
    fi
    choose_target || { err "no scheduler available"; return 1; }
    $SC disable --now "$UNIT_NAME.timer" >/dev/null 2>&1 || true
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ]; then
        rm -f "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer"
    else
        ${SUDO:-sudo -n} rm -f "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer"
    fi
    $SC daemon-reload >/dev/null 2>&1 || true
    say "uninstalled $UNIT_NAME from $UNIT_DIR"
    return 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --install)   MODE=--install ;;
        --dry-run)   DRY_RUN=1 ;;
        --status)    MODE=--status ;;
        --uninstall) MODE=--uninstall ;;
        --help|-h)   sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) usage ;;
    esac
    shift
done

case "$MODE" in
    --install)   do_install ;;
    --status)    do_status ;;
    --uninstall) do_uninstall ;;
esac
