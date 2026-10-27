#!/usr/bin/env bash
# install-cell-timers.sh — put the OBJECTIVE REMINDER and the CONTROLLER WATCHDOG on a cell's clock.
#
# ⛔ WHY THIS FILE EXISTS. Both passes were built and armed by hand on the operator's Mac, where they
# live as ~/.pi/agent/scripts/* and a LaunchAgent each — invisible to a fresh machine and to every cell.
# That is the live-only class this repo keeps filing (#2248: a redeploy silently reverts it; #1552: the
# unversioned orchestration layer). The macOS half is now templates/launchd/ + install-launchd.sh (the
# repo's one installer for launchd). This is the CELL half, because a cell has no launchd.
#
# ⛔ THE MECHANISM: SYSTEMD TIMERS — the box's OWN scheduler, and the one this fleet ALREADY uses on a
# cell. Precedent, both shipped: `install-disk-reaper-timer.sh` (eldato-disk-reaper.timer, hourly) and
# `install-controller-service.sh` (eldato-orchestrator.service). Two alternatives were considered and
# rejected, on evidence rather than taste:
#   * CRON — `crontab` writes fail with EINTR on the operator's Mac (recorded), and a cell has no
#     crontab surface the fleet manages; it would be a fourth timer vocabulary with no reader.
#   * The CELL DOCTOR LOOP (`cloud-cell-supervisor.sh doctor`, tmux session `cell-doctor`, roles
#     doctor/reap/merge/hygiene) — this is the cell's REPAIR cadence, not a generic clock: its `doctor`
#     role already owns "keep ONE dispatcher running", and the watchdog's restart verb is
#     `cloud-cell-supervisor.sh start` — the same verb the doctor role uses. Folding the watchdog into
#     that loop would put two restart paths on one 30 s loop with no shared budget, which is exactly the
#     double-restart the watchdog's own doc refuses. The doctor loop is therefore LEFT ALONE, and the
#     watchdog gets its own unit and its own budget. (The reminder has no place there at all: the doctor
#     loop runs in a tmux session with no agent attached.)
#   Neither component invents a scheduler; both are rendered here and enabled with `systemctl`, exactly
#   as the disk reaper's timer is.
#
# ⛔ SCOPES, in the same order and for the same reasons as install-disk-reaper-timer.sh:
#   1. a SYSTEM unit via passwordless sudo (/etc/systemd/system) — a cell's normal shape;
#   2. a USER unit (~/.config/systemd/user) when systemd's user manager answers — a cell with no sudo;
#   3. nothing — a LOUD failure naming both attempts. An "installed" timer that never fires is the
#      false PASS this fleet keeps removing, and the inventory row would read MISSING only if someone
#      looked.
#   `User={{USER}}` is rendered on both scopes (the same choice install-controller-service.sh makes);
#   systemd's user manager logs it as unsupported and runs as the invoking user, which is the intent.
#
# ⛔ WHAT IT REFUSES (each one would otherwise install a unit that cannot run):
#   * a script path that is not a regular readable file (a unit pointing at nothing exits 127 every tick);
#   * a rendered value containing whitespace (systemd SPLITS unquoted Environment=/ExecStart= values, so
#     the unit would start the wrong program);
#   * a leftover `{{PLACEHOLDER}}` after rendering (the unit would exec a literal `{{SCRIPT}}`);
#   * a state dir that is not writable by the invoking user (the watchdog's restart budget lives there,
#     and an unwritable budget makes it stop restarting by design — visible, but from a unit that looks
#     installed: refuse instead).
#
# Usage:
#   install-cell-timers.sh [--install]   render + install + enable both timers (idempotent)
#   install-cell-timers.sh --dry-run     render and PRINT both units; write nothing
#   install-cell-timers.sh --status      is each timer enabled/active, and what did its pass last say?
#   install-cell-timers.sh --uninstall   disable + remove the units we installed
#   install-cell-timers.sh --help
#
# Env seams (tests + unusual cells):
#   TEMPLATES_DIR   systemd templates (default: this repo's templates/systemd)
#   SYSTEMD_UNIT_DIR  install dir override (tests: a temp dir with a fake `systemctl`)
#   SYSTEMCTL       the systemctl to call (default `systemctl`, or `sudo -n systemctl` for system scope)
#   SUDO            the passwordless sudo probe (default `sudo -n`)
#   ELDATO_PLATFORM override `uname -s` (tests)
#   REMINDER_SCRIPT WATCHDOG_SCRIPT      the two pass scripts (defaults: this checkout)
#   CELL_HOME       a cell's home (default $HOME)
#   O               the controller state dir (default $CELL_HOME/orchestrator)
#   OBJECTIVE_MAX_BYTES  the reminder's byte budget (default 420)
#
# Exit codes: 0 ok · 1 failure (named) · 2 usage.
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES_DIR="${TEMPLATES_DIR:-$INFRA_ROOT/templates/systemd}"
PLATFORM="${ELDATO_PLATFORM:-$(uname -s 2>/dev/null || printf unknown)}"
CELL_HOME="${CELL_HOME:-$HOME}"
O="${O:-$CELL_HOME/orchestrator}"
STATE_DIR="${STATE_DIR:-$CELL_HOME/.pi/agent/state}"
REMINDER_SCRIPT="${REMINDER_SCRIPT:-}"
WATCHDOG_SCRIPT="${WATCHDOG_SCRIPT:-$INFRA_ROOT/scripts/orchestrator-harness/watchdog-loop.sh}"
SUPERVISOR="${SUPERVISOR:-$INFRA_ROOT/scripts/cloud-cell-supervisor.sh}"
OBJECTIVE_MAX_BYTES="${OBJECTIVE_MAX_BYTES:-420}"
SUDO="${SUDO:-sudo -n}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"

UNITS=(eldato-objective-reminder.service eldato-objective-reminder.timer \
       eldato-controller-watchdog.service eldato-controller-watchdog.timer)

log_line() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
usage() { sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

sed_esc() { printf '%s' "$1" | sed -e 's/[&\\|]/\\&/g'; }

# has_space <value> — systemd splits unquoted values on whitespace.
has_space() { case "$1" in *[[:space:]]*) return 0 ;; esac; return 1; }

resolve_target() {
  local sc=""
  if [ -n "${SYSTEMD_UNIT_DIR:-}" ]; then
    UNIT_DIR="$SYSTEMD_UNIT_DIR"; TARGET="override"; SC="$SYSTEMCTL"; return 0
  fi
  if $SUDO true >/dev/null 2>&1; then
    UNIT_DIR="/etc/systemd/system"; TARGET="system"; SC="$SUDO $SYSTEMCTL"; return 0
  fi
  if systemctl --user show-environment >/dev/null 2>&1; then
    UNIT_DIR="$HOME/.config/systemd/user"; TARGET="user"; SC="systemctl --user"; return 0
  fi
  UNIT_DIR=""; TARGET=""
  return 1
}

# ── resolution + validation ─────────────────────────────────────────────────────────────────────
# The farmed copy FIRST: it is what a cell has after pi-bootstrap/setup.sh, and a unit that execs a
# different copy than the one the layer installed runs a different policy than the one on disk.
pick_reminder() {
  local c
  for c in "${REMINDER_SCRIPT:-}" "$CELL_HOME/.pi/agent/scripts/objective-reminder.sh" \
           "$INFRA_ROOT/scripts/objective-reminder.sh"; do
    [ -n "$c" ] && [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

preflight() { # $1 = reminder path
  local r="$1" f bad=0
  for f in "$r" "$WATCHDOG_SCRIPT" "$SUPERVISOR"; do
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then err "not a readable file: $f"; bad=1; fi
  done
  for f in "$TEMPLATES_DIR/eldato-objective-reminder.service" "$TEMPLATES_DIR/eldato-objective-reminder.timer" \
           "$TEMPLATES_DIR/eldato-controller-watchdog.service" "$TEMPLATES_DIR/eldato-controller-watchdog.timer"; do
    [ -f "$f" ] || { err "template missing: $f"; bad=1; }
  done
  for f in "$r" "$WATCHDOG_SCRIPT" "$CELL_HOME" "$O" "$STATE_DIR"; do
    has_space "$f" && { err "path contains whitespace, which systemd splits: $f"; bad=1; }
  done
  case "$OBJECTIVE_MAX_BYTES" in ''|*[!0-9]*) err "OBJECTIVE_MAX_BYTES='$OBJECTIVE_MAX_BYTES' is not a whole number"; bad=1 ;; esac
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  [ -w "$STATE_DIR" ] || { err "state dir is not writable by $(id -un): $STATE_DIR (the watchdog's restart budget lives there; refuse rather than install a pass that cannot keep its bound)"; bad=1; }
  [ "$bad" -eq 0 ]
}

render() { # <template> <dest>
  local t="$1" d="$2"
  sed -e "s|{{USER}}|$(sed_esc "$(id -un)")|g" \
      -e "s|{{HOME}}|$(sed_esc "$CELL_HOME")|g" \
      -e "s|{{PATH}}|$(sed_esc "${PATH:-/usr/local/bin:/usr/bin:/bin}")|g" \
      -e "s|{{SCRIPT}}|$(sed_esc "${3:-}")|g" \
      -e "s|{{STATE_DIR}}|$(sed_esc "$STATE_DIR")|g" \
      -e "s|{{O}}|$(sed_esc "$O")|g" \
      -e "s|{{SUPERVISOR}}|$(sed_esc "$SUPERVISOR")|g" \
      -e "s|{{MAX_BYTES}}|$(sed_esc "$OBJECTIVE_MAX_BYTES")|g" \
      "$t" > "$d" || return 1
  # ⛔ A leftover placeholder is an installed unit that execs a literal `{{SCRIPT}}` — refuse, never skip.
  if grep -q '{{' "$d"; then err "unrendered placeholder in $d"; grep -o '{{[A-Z_]*}}' "$d" | sort -u | tr '\n' ' ' >&2; printf '\n' >&2; return 1; fi
  return 0
}

do_render_all() { # <outdir>
  local r="$1" out="$2" rc=0
  render "$TEMPLATES_DIR/eldato-objective-reminder.service" "$out/eldato-objective-reminder.service" "$r" || rc=1
  render "$TEMPLATES_DIR/eldato-objective-reminder.timer"   "$out/eldato-objective-reminder.timer" || rc=1
  render "$TEMPLATES_DIR/eldato-controller-watchdog.service" "$out/eldato-controller-watchdog.service" "$WATCHDOG_SCRIPT" || rc=1
  render "$TEMPLATES_DIR/eldato-controller-watchdog.timer"   "$out/eldato-controller-watchdog.timer" || rc=1
  return "$rc"
}

# ── verbs ──────────────────────────────────────────────────────────────────────────────────────
cmd_dry_run() {
  local r out
  r="$(pick_reminder)" || { err "objective-reminder.sh not found (looked at \$REMINDER_SCRIPT, $CELL_HOME/.pi/agent/scripts, $INFRA_ROOT/scripts)"; return 1; }
  preflight "$r" || return 1
  out="$(mktemp -d "${TMPDIR:-/tmp}/cell-timers.XXXXXX")" || return 1
  do_render_all "$r" "$out" || { rm -rf "$out"; return 1; }
  for f in "${UNITS[@]}"; do printf '=== %s ===\n' "$f"; cat "$out/$f"; done
  rm -rf "$out"
  log_line ""
  log_line "dry run: rendered 4 units for platform=$PLATFORM; nothing was written or enabled."
  return 0
}

cmd_install() {
  local r out rc=0 u
  if [ "$PLATFORM" = "Darwin" ]; then
    # ⛔ NOT A SILENT SKIP: on a Mac these two jobs are LaunchAgents, and install-launchd.sh owns them.
    # Naming the owner is the difference between "not applicable" and "nobody installed it".
    log_line "platform=Darwin: a Mac has no systemd. These two jobs are installed from templates/launchd/ by:"
    log_line "    bash $INFRA_ROOT/scripts/install-launchd.sh"
    log_line "  (com.eldato.objective-reminder and com.eldato.controller-watchdog — nothing was written here.)"
    return 0
  fi
  r="$(pick_reminder)" || { err "objective-reminder.sh not found (looked at \$REMINDER_SCRIPT, $CELL_HOME/.pi/agent/scripts, $INFRA_ROOT/scripts)"; return 1; }
  preflight "$r" || return 1
  resolve_target || { err "no systemd target on this box: tried a SYSTEM unit via passwordless sudo and a USER unit via 'systemctl --user'. Nothing was installed — a scheduled pass with no scheduler is the false PASS this installer refuses."; return 1; }
  log_line "installing into the $TARGET scope: $UNIT_DIR (systemctl: $SC)"

  out="$(mktemp -d "${TMPDIR:-/tmp}/cell-timers.XXXXXX")" || return 1
  if ! do_render_all "$r" "$out"; then rm -rf "$out"; return 1; fi

  mkdir -p "$UNIT_DIR" 2>/dev/null || { err "cannot create $UNIT_DIR"; rm -rf "$out"; return 1; }
  for u in "${UNITS[@]}"; do
    if [ -f "$UNIT_DIR/$u" ] && cmp -s "$out/$u" "$UNIT_DIR/$u"; then
      log_line "  $u: unchanged"
      continue
    fi
    if [ "$TARGET" = system ] || [ "$(id -u)" = 0 ]; then
      cp "$out/$u" "$UNIT_DIR/$u" || rc=1
    else
      cp "$out/$u" "$UNIT_DIR/$u" 2>/dev/null || { err "cannot write $UNIT_DIR/$u"; rc=1; }
    fi
    [ "$rc" -eq 0 ] && log_line "  $u: installed"
  done
  rm -rf "$out"
  [ "$rc" -eq 0 ] || return 1

  $SC daemon-reload >/dev/null 2>&1 || { err "$SC daemon-reload failed — the units are on disk but not seen by the manager"; return 1; }
  for u in eldato-objective-reminder.timer eldato-controller-watchdog.timer; do
    if ! $SC enable --now "$u" >/dev/null 2>&1; then
      err "$SC enable --now $u failed — an installed timer that is not enabled never fires"
      rc=1
    fi
  done
  [ "$rc" -eq 0 ] || return 1
  if [ "$TARGET" = user ]; then
    # ⛔ WITHOUT LINGER a user manager stops at the last logout: the timers silently stop on the box
    # nobody is logged into, which is every cell. Name it (the disk reaper's installer does the same).
    if command -v loginctl >/dev/null 2>&1 && ! loginctl show-user "$(id -un)" 2>/dev/null | grep -q 'Linger=yes'; then
      log_line "  ⚠️  Linger is NOT enabled for $(id -un): these timers stop at logout. Enable with: sudo loginctl enable-linger $(id -un)"
    fi
  fi
  log_line "installed: objective reminder every 10 min, controller watchdog every 5 min ($TARGET scope)."
  log_line "  read back with: bash $0 --status"
  return 0
}

cmd_status() {
  local u st rc=0 out line
  if [ "$PLATFORM" = "Darwin" ]; then
    log_line "platform=Darwin — these jobs are launchd, not systemd: NOT APPLICABLE here."
    log_line "  check them with: bash $INFRA_ROOT/scripts/install-launchd.sh --status"
    return 0
  fi
  resolve_target || { log_line "UNKNOWN: no systemd manager answers, so neither timer's state can be read (that is not 'healthy')"; return 2; }
  for u in eldato-objective-reminder.timer eldato-controller-watchdog.timer; do
    st="$($SC is-active "$u" 2>/dev/null || true)"
    en="$($SC is-enabled "$u" 2>/dev/null || true)"
    printf '%s\tenabled=%s\tactive=%s\n' "$u" "${en:-unknown}" "${st:-unknown}"
    case "$en$st" in *enabled*active) ;; *) rc=1 ;; esac
  done
  # The last verdict each pass wrote — an exit code is not one (both passes exit 0 by design).
  for f in "$STATE_DIR/objective-reminder.log" "$STATE_DIR/controller-watchdog.log"; do
    if [ -f "$f" ]; then
      line="$(tail -1 "$f" 2>/dev/null)"
      printf 'last[%s]\t%s\n' "$(basename "$f")" "${line:-<empty>}"
    else
      printf 'last[%s]\t<absent — the pass has not run since it was installed>\n' "$(basename "$f")"
    fi
  done
  return "$rc"
}

cmd_uninstall() {
  local u
  if [ "$PLATFORM" = "Darwin" ]; then
    log_line "platform=Darwin — nothing to remove here; the launchd jobs belong to install-launchd.sh."
    return 0
  fi
  resolve_target || { err "no systemd manager answers, so nothing can be disabled"; return 1; }
  for u in eldato-objective-reminder.timer eldato-controller-watchdog.timer; do
    $SC disable --now "$u" >/dev/null 2>&1 || true
  done
  for u in "${UNITS[@]}"; do rm -f "$UNIT_DIR/$u" 2>/dev/null || true; done
  $SC daemon-reload >/dev/null 2>&1 || true
  log_line "removed both timers and their units from $UNIT_DIR (the passes' own logs are left in $STATE_DIR)."
  return 0
}

case "${1:---install}" in
  --install)   cmd_install ;;
  --dry-run)   cmd_dry_run ;;
  --status)    cmd_status ;;
  --uninstall) cmd_uninstall ;;
  --help|-h)   usage ;;
  *) printf 'usage: %s [--install|--dry-run|--status|--uninstall|--help]\n' "$(basename "$0")" >&2; exit 2 ;;
esac
