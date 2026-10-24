#!/usr/bin/env bash
# install-repair-service.sh — put the harness's REPAIR service under the platform's service manager
# (agent-infra#2700, child C5).
#
# WHY THIS EXISTS. The repair actuator was TIMER-driven: `pr-doctor` ran on a schedule, so a PR that
# turned red one second after a pass waited out the whole interval with no worker on it. On the Mac
# that interval was `StartInterval 1800` (measured), i.e. a mean 900 s and a worst case 1800 s of
# dead time for a repair that costs one pass. The front end is now `scripts/pr-doctor-trigger.py`,
# which watches the PR surface and starts the SAME doctor when it changes; the 1800 s cadence
# survives only as `--backstop`.
#
# ⛔ THE SERVICE RUNS THE TRIGGER, NOT THE DOCTOR AND NOT A SHELL LOOP. A unit that ran the doctor on
# a timer is the defect this replaces; a unit that ran BOTH the trigger and a doctor loop would be
# two actuators on one queue — the #1761 shape. The trigger decides nothing: it starts the doctor,
# and the doctor owns every repair, every refusal and every budget.
#
# ⛔ `Restart=always`, NOT `on-failure` (#2402). The measured case is an ORDERLY exit: the process
# exits 0 and nothing came back. `on-failure` reproduces that defect byte for byte.
#
# macOS IS REFUSED, and the refusal names the box's own path: a Mac's jobs are launchd agents
# (`templates/launchd/`, rendered by `scripts/install-launchd.sh`), and a systemd unit there would be
# an artifact nothing reads. A refusal that names the right installer is a platform branch; a silent
# "installed" that never fires is the false PASS this repo keeps removing.
#
# INSTALL TARGETS, tried in this order, and the reason is named in the output:
#   1. a SYSTEM unit via passwordless sudo (/etc/systemd/system) — the cell's normal shape; the
#      service runs as the INVOKING user, so `~/.pi/agent/state`, the gh auth and the doctor's
#      dispatch register are the operator's, not root's.
#   2. a USER unit (~/.config/systemd/user) when systemd's user manager answers — a box without
#      sudo still gets a trigger, and the installer says so, because a user manager that dies at
#      logout is a trigger that dies with it.
#   3. nothing — a loud FAILURE with the remedy, never a silent no-op.
#
# Usage:
#   install-repair-service.sh [--install] [--dry-run] [--status] [--uninstall]
#   install-repair-service.sh --dry-run          # render and print; touch NOTHING
#
# Env seams (tests + unusual cells):
#   PR_DOCTOR_TRIGGER     the trigger to install (default: beside this script's repo, else
#                         $HOME/.pi/agent/scripts/pr-doctor-trigger.py)
#   REPAIR_REPO           the repo whose PR surface is watched (default daniel-ospina/tortoise)
#   PR_DOCTOR_REPO_DIR    the checkout the doctor materialises worktrees from
#                         (default $HOME/Documents/GitHub/tortoise)
#   REPAIR_POLL_SEC       the lead, in seconds (default 60)
#   REPAIR_DEBOUNCE_SEC   the coalescing window (default 90)
#   REPAIR_MAX            the doctor's --max (default 8)
#   REPAIR_STATE_DIR      where the trigger's lock + remembered fingerprint live
#                         (default $HOME/.pi/agent/state)
#   REPAIR_RESTART_SEC    the rendered RestartSec (default 15)
#   REPAIR_UNIT_NAME      the unit FILE name (default eldato-pr-doctor-trigger.service)
#   PYTHON_BIN            the interpreter the unit runs (default $(command -v python3))
#   TEMPLATES_DIR         template dir (default: this repo's templates/systemd)
#   SYSTEMD_UNIT_DIR      install dir OVERRIDE (tests: a temp dir, with SYSTEMCTL a fake)
#   SYSTEMCTL             `systemctl` to call (tests: a shim; default `sudo -n systemctl` for a
#                         system unit, `systemctl --user` otherwise)
#   SUDO                  `sudo` probe (default `sudo -n`)
#   ELDATO_PLATFORM       override `uname -s` (tests render the Darwin refusal on any host)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TEMPLATE="${TEMPLATES_DIR:-$ROOT/templates/systemd}/pr-doctor-trigger.service"
UNIT_NAME="${REPAIR_UNIT_NAME:-eldato-pr-doctor-trigger.service}"
REPAIR_REPO="${REPAIR_REPO:-daniel-ospina/tortoise}"
REPO_DIR="${PR_DOCTOR_REPO_DIR:-$HOME/Documents/GitHub/tortoise}"
POLL="${REPAIR_POLL_SEC:-60}"
DEBOUNCE="${REPAIR_DEBOUNCE_SEC:-90}"
MAX="${REPAIR_MAX:-8}"
STATE_DIR="${REPAIR_STATE_DIR:-$HOME/.pi/agent/state}"
RESTART_SEC="${REPAIR_RESTART_SEC:-15}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
SUDO="${SUDO:-sudo -n}"
PLATFORM="${ELDATO_PLATFORM:-$(uname -s)}"

ACTION=--install
for arg in "$@"; do
  case "$arg" in
    --install|--uninstall|--status|--dry-run) ACTION="$arg" ;;
    --help|-h) sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

die()  { printf '❌ %s\n' "$*" >&2; exit 1; }
ok()   { printf '✅ %s\n' "$*"; }
say()  { printf '   %s\n' "$*"; }

# ── the trigger to install ─────────────────────────────────────────────────────────────────────
find_trigger() {
  local c
  for c in "${PR_DOCTOR_TRIGGER:-}" "$HERE/pr-doctor-trigger.py" "$ROOT/scripts/pr-doctor-trigger.py" \
           "$HOME/.pi/agent/scripts/pr-doctor-trigger.py"; do
    [ -n "$c" ] && [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# ── the scope, decided once ────────────────────────────────────────────────────────────────────
# A system unit is the cell's shape (passwordless sudo, no queryable user manager); a user unit is
# the fallback that still gives the box a trigger. Both are reported, never implied.
resolve_scope() {
  if [ -n "${SYSTEMD_UNIT_DIR:-}" ]; then
    SCOPE=system; UNIT_DIR="$SYSTEMD_UNIT_DIR"
    SYSTEMCTL="${SYSTEMCTL:-$SUDO systemctl}"
    WANTED_BY=multi-user.target
    return 0
  fi
  if $SUDO true >/dev/null 2>&1; then
    SCOPE=system; UNIT_DIR=/etc/systemd/system
    SYSTEMCTL="${SYSTEMCTL:-$SUDO systemctl}"
    WANTED_BY=multi-user.target
    return 0
  fi
  if systemctl --user show-environment >/dev/null 2>&1; then
    SCOPE=user; UNIT_DIR="${HOME}/.config/systemd/user"
    SYSTEMCTL="${SYSTEMCTL:-systemctl --user}"
    # ⛔ `multi-user.target` DOES NOT EXIST in a per-user manager, so enabling against it writes a
    # wants-link for a target that is never loaded: the trigger would run once and never come back
    # at next boot — the #2402 defect one layer down, on the very scope whose whole point is to
    # survive a logout.
    WANTED_BY=default.target
    return 0
  fi
  return 1
}

render() { # → stdout
  sed -e "s|{{USER}}|$(id -un)|g" \
      -e "s|{{HOME}}|${HOME}|g" \
      -e "s|{{PATH}}|${PATH}|g" \
      -e "s|{{PYTHON}}|${PYTHON_BIN}|g" \
      -e "s|{{TRIGGER}}|${TRIGGER}|g" \
      -e "s|{{GH_REPO}}|${REPAIR_REPO}|g" \
      -e "s|{{REPO_DIR}}|${REPO_DIR}|g" \
      -e "s|{{POLL}}|${POLL}|g" \
      -e "s|{{DEBOUNCE}}|${DEBOUNCE}|g" \
      -e "s|{{MAX}}|${MAX}|g" \
      -e "s|{{STATE_DIR}}|${STATE_DIR}|g" \
      -e "s|{{RESTART_SEC}}|${RESTART_SEC}|g" \
      -e "s|{{WANTED_BY}}|${WANTED_BY}|g" \
      "$TEMPLATE"
}

# ── preflight: nothing renders over a missing exec, and the platform is named ────────────────
if [ "$PLATFORM" != "Linux" ]; then
  die "this installer renders a SYSTEMD unit, which $(printf '%s' "$PLATFORM") does not run. The Mac's jobs are
   launchd agents: install the trigger's job with scripts/install-launchd.sh (templates/launchd/),
   which is the installer that owns that platform. (ELDATO_PLATFORM exists so tests can exercise
   this refusal anywhere.)"
fi
[ -f "$TEMPLATE" ] || die "missing unit template: $TEMPLATE"
[ -n "$PYTHON_BIN" ] || die "no python3 on PATH — the unit's ExecStart would name an empty interpreter"
TRIGGER="$(find_trigger)" || die "pr-doctor-trigger.py not found (looked beside this script, in this
   repo's scripts/, and in \$HOME/.pi/agent/scripts). Install the farm first: pi-bootstrap/setup.sh"
[ -f "$TRIGGER" ] || die "the trigger resolves to a non-file: $TRIGGER"

if ! resolve_scope; then
  die "no service manager answered: no passwordless sudo for a system unit and no systemd user
   manager. Nothing was installed — a trigger that is 'installed' but never fires is a false PASS."
fi
UNIT_PATH="$UNIT_DIR/$UNIT_NAME"

case "$ACTION" in
  --status)
    if [ ! -f "$UNIT_PATH" ]; then
      say "$UNIT_NAME: NOT INSTALLED ($UNIT_PATH)"; exit 3
    fi
    say "unit:     $UNIT_PATH ($SCOPE scope)"
    say "enabled:  $($SYSTEMCTL is-enabled "$UNIT_NAME" 2>&1)"
    say "active:   $($SYSTEMCTL is-active "$UNIT_NAME" 2>&1)"
    # Read the ARTIFACT, not the send: the installed ExecStart must be the TRIGGER.
    if grep -qF "$TRIGGER" "$UNIT_PATH" && grep -qF -- "--backstop 1800" "$UNIT_PATH"; then
      ok "the installed ExecStart runs the trigger with the 1800 s backstop"
    else
      say "⛔ the installed unit does not carry the trigger + backstop — re-run --install"; exit 4
    fi
    exit 0
    ;;
  --uninstall)
    [ -f "$UNIT_PATH" ] || { say "$UNIT_NAME: not installed"; exit 0; }
    $SYSTEMCTL disable --now "$UNIT_NAME" >/dev/null 2>&1
    rm -f "$UNIT_PATH"
    $SYSTEMCTL daemon-reload >/dev/null 2>&1
    # Read back: "uninstalled" is a claim about the filesystem, so verify it.
    [ -f "$UNIT_PATH" ] && die "the unit file SURVIVED removal: $UNIT_PATH"
    ok "$UNIT_NAME removed"
    exit 0
    ;;
  --dry-run)
    render
    exit 0
    ;;
esac

# ── install (idempotent) ─────────────────────────────────────────────────────────────────────
mkdir -p "$UNIT_DIR" || die "cannot create $UNIT_DIR"
NEW="$(mktemp)"; trap 'rm -f "$NEW"' EXIT
render >"$NEW" || die "render failed"
grep -qF -- "{{" "$NEW" && die "the render left an unsubstituted placeholder — refusing to install a
   unit with a literal {{TOKEN}} in its ExecStart"
if [ -f "$UNIT_PATH" ] && cmp -s "$NEW" "$UNIT_PATH"; then
  ok "already installed and unchanged: $UNIT_PATH"
  $SYSTEMCTL daemon-reload >/dev/null 2>&1
else
  install -m 0644 "$NEW" "$UNIT_PATH" || die "cannot write $UNIT_PATH"
  ok "installed $UNIT_PATH ($SCOPE scope)"
  $SYSTEMCTL daemon-reload >/dev/null 2>&1
fi
$SYSTEMCTL enable "$UNIT_NAME" >/dev/null 2>&1 \
  || die "could not ENABLE $UNIT_NAME — a unit that is installed but not enabled never comes back"
$SYSTEMCTL restart "$UNIT_NAME" >/dev/null 2>&1 \
  || say "⚠️  restart failed; the unit is enabled and will come up at next boot (check --status)"
# ⛔ READ BACK THE ARTIFACT, not the exit status of the verbs above: "installed" is a claim about
# what the manager will RUN, and the only evidence is the manager's own answer plus the file.
[ -f "$UNIT_PATH" ] || die "the unit file is gone after install: $UNIT_PATH"
en="$($SYSTEMCTL is-enabled "$UNIT_NAME" 2>&1)"
[ "$en" = "enabled" ] || die "$UNIT_NAME is NOT enabled (systemctl says: $en) — nothing would restart
   a dead trigger. This is a FAILED install, not a warning."
grep -qF "$TRIGGER" "$UNIT_PATH" || die "the installed unit does not name the trigger ($TRIGGER)"
ok "$UNIT_NAME enabled ($en)"
say "status: $($SYSTEMCTL is-active "$UNIT_NAME" 2>&1)  ·  journal: journalctl -u $UNIT_NAME -n 50"
exit 0
