#!/usr/bin/env bash
# install-drainer-timer.sh — put the ai-drainer on a CELL's clock (systemd).
#
# ── THE LINUX CHOICE, STATED ONCE ─────────────────────────────────────────────────────────────────
# A cell has no launchd. It has exactly two scheduling mechanisms today, and this installer uses one
# of them rather than inventing a third:
#   1. `cloud-cell-doctor.sh loop` — the supervisor's ROLE loop (doctor/reap/merge/hygiene), started
#      by `cloud-cell-supervisor.sh start`;
#   2. systemd timers — `install-disk-reaper-timer.sh` renders templates/systemd/* and
#      `systemctl enable --now`s them (with a passwordless-sudo system unit, else a user unit).
#
# The drainer is scheduled by (2), NOT added as a fifth role. IN ONE SENTENCE WHY: a role is ONE cell's
# controller and the backlog the drainer exists for may belong to a repo that controller is not bound
# to at all — and the fleet already schedules periodic one-shots this way.
# ⛔ This paragraph used to say the drainer's lock "must OUTLIVE its own pass (it waits up to
# LANE_TIMEOUT — the lane's backstop — for the lane it dispatched), so a role would block the loop's merge
# and doctor passes and trip the loop's stall bound". That described #2639's lock scope, which is
# WITHDRAWN: the lock now covers ONE TICK'S CRITICAL SECTION (settle → census → target → dispatch) and the
# tick never waits for a lane — a lane that outlives its tick is simply counted by the next one. See
# templates/systemd/eldato-ai-drainer.service for the full reasoning (and
# for why the bring-up does not install it: a lane dispatcher is per-repo and costs model spend, so
# it is an explicit, per-cell operator step, exactly like the disk reaper's arming).
#
# ⛔ IT IS AN INSTALLER AND NOT A LINE IN THE BRING-UP, for the same reason
# install-disk-reaper-timer.sh is: the artifact must be rendered from machine state (HOME, PATH, the
# state dir, the checkout the script runs from) and installed idempotently. One place renders and
# converges; everything else calls it.
#
# Usage:
#   install-drainer-timer.sh [--install] [--dry-run] [--status] [--uninstall] [--help]
#
# Env seams (tests + unusual cells):
#   DRAINER            the entry point the unit runs   default: this checkout's
#                      scripts/orchestrator-harness/ai-drainer.sh, else the farmed copy in
#                      $HOME/.pi/agent/scripts/ (a cell has no ~/Documents checkout, TCC aside)
#   DRAINER_O          controller runtime dir the pass reads ($O)      default: $HOME/orchestrator
#   DRAINER_STATE      the drainer's state dir ($AI)                   default: $HOME/orchestrator-ai
#   DRAINER_REPO_SLUG  owner/name the brief names                      default: daniel-ospina/agent-infra
#   DRAINER_SEED_REPO  checkout the lane's worktree is branched from    default: $HOME/agent-infra-main
#   MAX_LANES          CPU-side ceiling of the lane target. RENDERED BLANK by default, so the unit
#                      carries no pin and the drainer DERIVES it from this box's cores on every tick
#                      (floor(ncpu x 5/2), the fleet's 2026-10-17 ruling) — a value rendered here is a
#                      PIN that the script will never recompute, which is exactly wrong for a box
#                      whose size can change. Pass it only to override that ceiling deliberately.
#   TEMPLATES_DIR      template dir (default: this repo's templates/systemd)
#   SYSTEMD_UNIT_DIR   install dir OVERRIDE (tests: a temp dir with SYSTEMCTL a fake)
#   SYSTEMCTL          `systemctl` to call  default: user manager if it answers, else `sudo -n systemctl`
#   SUDO               sudo probe           default: `sudo -n`
#
# Exit codes: 0 ok · 1 failure (named) · 2 usage.
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATES_DIR="${TEMPLATES_DIR:-$INFRA_ROOT/templates/systemd}"
UNIT_SRC_SERVICE="eldato-ai-drainer.service"
UNIT_SRC_TIMER="eldato-ai-drainer.timer"

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
err() { printf 'install-drainer-timer: ERROR — %s\n' "$*" >&2; return 1; }

MODE=--install
case "${1:-}" in
    -h | --help) usage ;;
    --install | --dry-run | --status | --uninstall) MODE="$1" ;;
    '') ;;
    *) usage ;;
esac

HOME_DIR="${HOME:?HOME is required}"
DRAINER_O="${DRAINER_O:-$HOME_DIR/orchestrator}"
DRAINER_STATE="${DRAINER_STATE:-$HOME_DIR/orchestrator-ai}"
DRAINER_REPO_SLUG="${DRAINER_REPO_SLUG:-daniel-ospina/agent-infra}"
DRAINER_SEED_REPO="${DRAINER_SEED_REPO:-$HOME_DIR/agent-infra-main}"
SYSTEMCTL="${SYSTEMCTL:-}"
SUDO="${SUDO:-sudo -n}"

# The script the unit execs. The repo copy is authoritative when it exists (this installer is run
# from a checkout); a cell usually has only the farmed copy, which is what pi-bootstrap ships.
if [ -z "${DRAINER:-}" ]; then
    for _c in "$INFRA_ROOT/scripts/orchestrator-harness/ai-drainer.sh" \
              "$HOME_DIR/.pi/agent/scripts/ai-drainer.sh"; do
        [ -f "$_c" ] && { DRAINER="$_c"; break; }
    done
fi
# ⛔ EVERY PRE-FLIGHT ABORTS. `err` prints and returns 1, and at top level nothing consumed that
# status (there is no `set -e`): a typo in DRAINER printed the error and then installed a unit whose
# ExecStart does not exist, and a wrong TEMPLATES_DIR overwrote the ALREADY-WORKING units with empty
# files — both reporting "ai-drainer scheduled". A refusal that does not stop the install is a
# warning wearing a refusal's words.
[ -n "${DRAINER:-}" ] || { err "ai-drainer.sh not found (looked in this checkout and $HOME/.pi/agent/scripts) — nothing to schedule"; exit 1; }
[ -f "$DRAINER" ] || { err "DRAINER=$DRAINER does not exist"; exit 1; }
[ -f "$TEMPLATES_DIR/$UNIT_SRC_SERVICE" ] || { err "template not found: $TEMPLATES_DIR/$UNIT_SRC_SERVICE"; exit 1; }
[ -f "$TEMPLATES_DIR/$UNIT_SRC_TIMER" ] || { err "template not found: $TEMPLATES_DIR/$UNIT_SRC_TIMER"; exit 1; }

# ── which systemctl, and therefore which unit dir ─────────────────────────────────────────────
# System unit first (the cell's normal shape), user unit when systemd's user manager answers but
# there is no passwordless sudo. Anything else is a LOUD failure: a timer that was "installed" and
# never fires is the false PASS this fleet keeps removing.
resolve_target() {
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ]; then TARGET=override; UNIT_DIR="$SYSTEMD_UNIT_DIR"; SYSTEMCTL="${SYSTEMCTL:-systemctl}"; return 0; fi
    if command -v systemctl >/dev/null 2>&1; then
        if $SUDO systemctl show-environment >/dev/null 2>&1; then
            TARGET=system; UNIT_DIR=/etc/systemd/system; SYSTEMCTL="${SYSTEMCTL:-$SUDO systemctl}"; return 0
        fi
        if [ -n "$(systemctl --user show-environment 2>/dev/null)" ]; then
            TARGET=user; UNIT_DIR="$HOME_DIR/.config/systemd/user"; SYSTEMCTL="${SYSTEMCTL:-systemctl --user}"; return 0
        fi
    fi
    return 1
}
resolve_target || {
    err "no usable scheduler: neither a passwordless-sudo system systemd nor a working user manager answered. The drainer will NOT run unattended — fix systemd (or grant passwordless sudo for systemctl) and re-run."
    exit 1
}
[ -n "${SYSTEMCTL:-}" ] || SYSTEMCTL="$([ "$TARGET" = system ] && printf 'sudo -n systemctl' || printf 'systemctl --user')"

# ⛔ THE LANE'S BOUND IS RENDERED FROM THE SEAM, NOT FROM A LOCAL LITERAL (agent-infra#2888 review,
# P2 — verified). This used to render `${LANE_TIMEOUT:-3000}` at INSTALL time into an `Environment=` PIN,
# and a pin WINS over the script's own default — so on every box this installer touched,
# `ai-drainer.sh`'s `${LANE_TIMEOUT:-${LANE_BACKSTOP_S:-7200}}` could never take effect and drainer
# lanes stayed killed at 50 min: 300 s above the 2700 s progress allowance, i.e. the censoring survived
# on the box whose job is to drain the backlog, and raising `LANE_BACKSTOP_S` changed nothing there.
# Resolved ONCE here, from the harness copy being installed, so the two cannot drift.
DRAINER_LANE_TIMEOUT="${LANE_BACKSTOP_S:-}"
if [ -z "$DRAINER_LANE_TIMEOUT" ]; then
    DRAINER_LANE_TIMEOUT="$(sed -n 's/^LANE_BACKSTOP_S="${LANE_BACKSTOP_S:-\([0-9][0-9]*\)}".*/\1/p' \
                              "$(dirname "${BASH_SOURCE[0]}")/spawn-gate.sh" 2>/dev/null | head -1)"
fi
case "$DRAINER_LANE_TIMEOUT" in ''|*[!0-9]*|0) DRAINER_LANE_TIMEOUT=7200 ;; esac

render() { # <template> <dest>
    local v tmp
    # ⛔ RENDER TO A TEMP FILE AND CHECK THE RESULT. Writing straight to "$2" let the shell truncate
    # the destination BEFORE `sed` failed, and the only post-check (grep for `{{`) cannot match an
    # EMPTY file — so `DRAINER_REPO_SLUG='a|b'` installed two zero-byte units, enabled the timer and
    # printed "scheduled". The checks below are on the bytes that would actually be installed.
    tmp="$2.tmp.$$"
    sed -e "s|{{USER}}|$(id -un)|g" \
        -e "s|{{HOME}}|$HOME_DIR|g" \
        -e "s|{{PATH}}|${PATH:-/usr/local/bin:/usr/bin:/bin}|g" \
        -e "s|{{O}}|$DRAINER_O|g" \
        -e "s|{{AI}}|$DRAINER_STATE|g" \
        -e "s|{{REPO_SLUG}}|$DRAINER_REPO_SLUG|g" \
        -e "s|{{SEED_REPO}}|$DRAINER_SEED_REPO|g" \
        -e "s|{{MAX_LANES}}|${MAX_LANES:-}|g" \
        -e "s|{{MIN_SWAP_MB}}|${MIN_SWAP_MB:-700}|g" \
        -e "s|{{LANE_TIMEOUT}}|${LANE_TIMEOUT:-$DRAINER_LANE_TIMEOUT}|g" \
        -e "s|{{DRAINER}}|$DRAINER|g" \
        "$1" >"$tmp" || { rm -f "$tmp"; err "sed could not render $1 (a value carries '|' or '&'?) — refusing to install a partial unit"; return 1; }
    # A value carrying `|`/`&` corrupts the substitution; a leftover `{{…}}` means a placeholder
    # nothing substituted. Both are refusals, and so is an empty result: a unit with no ExecStart
    # enables, activates and then does nothing every 20 minutes.
    if grep -q '{{' "$tmp"; then rm -f "$tmp"; err "unsubstituted placeholder remains in the rendered unit"; return 1; fi
    if [ ! -s "$tmp" ]; then rm -f "$tmp"; err "rendered $1 is EMPTY — refusing to install it"; return 1; fi
    case "$1" in
        *.service) grep -q '^ExecStart=' "$tmp" \
            || { rm -f "$tmp"; err "rendered service has no ExecStart — it would enable and do nothing"; return 1; } ;;
        *.timer)   grep -q '^\[Timer\]' "$tmp" \
            || { rm -f "$tmp"; err "rendered timer has no [Timer] section"; return 1; } ;;
    esac
    mv -f "$tmp" "$2"
}

say_status() {
    local svc="$1" tmr="$2"
    printf 'installer target: %s (%s)\n' "$TARGET" "$UNIT_DIR"
    for u in "$svc" "$tmr"; do
        if [ -f "$UNIT_DIR/$u" ]; then printf '  %-34s installed\n' "$u"; else printf '  %-34s MISSING\n' "$u"; fi
    done
    if [ -f "$UNIT_DIR/$tmr" ]; then
        printf '  timer state: %s\n' "$($SYSTEMCTL is-active "$tmr" 2>/dev/null || true)"
        printf '  next run:    %s\n' "$($SYSTEMCTL list-timers --all "$tmr" 2>/dev/null | sed -n '2p' | sed 's/  */ /g' || true)"
    fi
}

case "$MODE" in
    --status) say_status "$UNIT_SRC_SERVICE" "$UNIT_SRC_TIMER"; exit 0 ;;
    --uninstall)
        $SYSTEMCTL disable --now "$UNIT_SRC_TIMER" >/dev/null 2>&1 || true
        # ⛔ A REMOVAL THAT DID NOT HAPPEN IS NOT AN UNINSTALL. `rm -f` returning non-zero printed the
        # error and then announced "nothing dispatches from this cell any more", exit 0 — so an
        # operator could believe a still-armed 20-minute dispatcher was gone.
        rm -f "$UNIT_DIR/$UNIT_SRC_TIMER" "$UNIT_DIR/$UNIT_SRC_SERVICE" \
            || { err "cannot remove the units from $UNIT_DIR — the timer is STILL ARMED"; exit 1; }
        [ ! -f "$UNIT_DIR/$UNIT_SRC_TIMER" ] \
            || { err "$UNIT_DIR/$UNIT_SRC_TIMER still exists after removal — it is STILL ARMED"; exit 1; }
        $SYSTEMCTL daemon-reload >/dev/null 2>&1 || true
        printf 'drainer timer removed — nothing dispatches from this cell any more\n'
        exit 0 ;;
esac

# ⛔ --dry-run MUST NOT CREATE ANYTHING — especially not the state dir, which is itself evidence the
# `second-controller` inventory row reads. A preview that creates a directory is a preview that can
# turn a box red. The checks run for a real install; the preview reports what it WOULD create.
[ -z "$DRAINER_O" ] || [ -d "$DRAINER_O" ] || { err "DRAINER_O=$DRAINER_O does not exist — the pass would count zero lanes and dispatch as if the box were idle"; exit 1; }

tmpd="$(mktemp -d)" || { err "mktemp failed"; exit 1; }
render "$TEMPLATES_DIR/$UNIT_SRC_SERVICE" "$tmpd/$UNIT_SRC_SERVICE" || exit 1
render "$TEMPLATES_DIR/$UNIT_SRC_TIMER" "$tmpd/$UNIT_SRC_TIMER" || exit 1

if [ "$TARGET" = "user" ] && ! command -v loginctl >/dev/null 2>&1; then
    rm -rf "$tmpd"
    err "this box needs a USER unit, but there is no loginctl here to prove the manager LINGERS — a user timer that stops with your last session fires once and never again. Grant passwordless sudo for a system target, then re-run."
    exit 1
fi
if [ "$TARGET" = "user" ]; then
    if grep -q '^User=' "$tmpd/$UNIT_SRC_SERVICE"; then
        # grep -v, not `sed -i`: this file's editing rules forbid sed for line surgery, and a
        # rendered temp unit must be rebuilt rather than edited in place.
        grep -v '^User=' "$tmpd/$UNIT_SRC_SERVICE" >"$tmpd/svc.new" \
            && mv -f "$tmpd/svc.new" "$tmpd/$UNIT_SRC_SERVICE"
    fi
    linger="$(loginctl show-user "$(id -un)" -p Linger 2>/dev/null | sed 's/^Linger=//')"
    # ⛔ A PREVIEW MUST NOT ENABLE LINGERING. `loginctl enable-linger` is a PERSISTENT system change
    # (usually needing root), and running it here made `--dry-run` — documented as creating nothing —
    # mutate the box. In preview mode it is READ only, and the plan is printed instead.
    if [ "$linger" != "yes" ]; then
        if [ "$MODE" = "--dry-run" ]; then
            printf 'would enable lingering for %s (loginctl enable-linger) — without it a user timer stops with your last session
' "$(id -un)"
        else
            loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
            linger="$(loginctl show-user "$(id -un)" -p Linger 2>/dev/null | sed 's/^Linger=//')"
        fi
    fi
    if [ "$linger" != "yes" ]; then
        rm -rf "$tmpd"
        err "this box needs a USER unit, but lingering is '${linger:-unknown}' — the user manager stops when your last session ends, so the timer would fire now and never again. Enable it (loginctl enable-linger $(id -un), often needing root) or grant passwordless sudo for systemctl, then re-run."
        exit 1
    fi
fi
if [ "$MODE" = "--dry-run" ]; then
    if [ -d "$DRAINER_STATE" ]; then
        # The install REFUSES an unwritable state dir; a preview that only warned would green-light an
        # install that cannot work — so the preview reaches the same verdict and exits non-zero.
        [ -w "$DRAINER_STATE" ] || { rm -rf "$tmpd"; err "state dir $DRAINER_STATE exists and is NOT writable by $(id -un) — every pass would fail closed (this preview refuses it, as the install would)"; exit 1; }
    else
        printf 'would create %s/logs\n' "$DRAINER_STATE"
    fi
    printf 'would install to %s (target %s):\n\n' "$UNIT_DIR" "$TARGET"
    sed 's/^/  /' "$tmpd/$UNIT_SRC_SERVICE" "$tmpd/$UNIT_SRC_TIMER"
    rm -rf "$tmpd"
    exit 0
fi

# The state dir must exist and be writable by THIS user: the unit runs as this user and every pass
# would fail closed on an unwritable log dir.
mkdir -p "$DRAINER_STATE/logs" 2>/dev/null || { rm -rf "$tmpd"; err "cannot create $DRAINER_STATE/logs"; exit 1; }
[ -w "$DRAINER_STATE" ] || { rm -rf "$tmpd"; err "state dir $DRAINER_STATE is not writable by $(id -un)"; exit 1; }
# ⛔ A USER UNIT WITH A `User=` LINE IS REJECTED BY systemd, and a user unit whose manager STOPS when
# the last session ends fires only while an ssh session is open — an installed timer that schedules
# nothing, the false PASS this installer refuses for the system target. The sibling installer carries
# the same guard for the same reason; both must refuse rather than report green.
mkdir -p "$UNIT_DIR" 2>/dev/null || { rm -rf "$tmpd"; err "cannot create $UNIT_DIR (a system target needs sudo; a user target needs a home dir)"; exit 1; }
for u in "$UNIT_SRC_SERVICE" "$UNIT_SRC_TIMER"; do
    if [ -f "$UNIT_DIR/$u" ] && cmp -s "$UNIT_DIR/$u" "$tmpd/$u"; then
        printf '  %s: unchanged\n' "$u"
    else
        cp "$tmpd/$u" "$UNIT_DIR/$u" || { rm -rf "$tmpd"; err "cannot write $UNIT_DIR/$u"; exit 1; }
        printf '  %s: written\n' "$u"
    fi
done
rm -rf "$tmpd"
$SYSTEMCTL daemon-reload >/dev/null 2>&1 || { err "systemctl daemon-reload failed — the units on disk are not the units systemd knows"; exit 1; }
$SYSTEMCTL enable --now "$UNIT_SRC_TIMER" >/dev/null 2>&1 || { err "systemctl enable --now $UNIT_SRC_TIMER failed — an installed timer that is not enabled never fires"; exit 1; }

# ⛔ READ IT BACK. A unit on disk and an enabled timer is not the same statement as "the timer is
# active"; the answer is the read after, never the command's status.
state="$($SYSTEMCTL is-active "$UNIT_SRC_TIMER" 2>/dev/null || true)"
[ "$state" = "active" ] || { err "the timer is installed but NOT active (state: ${state:-unknown})"; exit 1; }
printf 'ai-drainer scheduled: %s active in %s (state dir %s, log %s/logs/ai-drainer.log)\n' \
    "$UNIT_SRC_TIMER" "$UNIT_DIR" "$DRAINER_STATE" "$DRAINER_STATE"
