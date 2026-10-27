#!/usr/bin/env bash
# install-worker-supply.sh — render, install and CONVERGE the worker-supply supervisor on a LINUX box
# (agent-infra#2700's supply half). One verb renders from machine state and installs idempotently.
#
# ⛔ WHY AN INSTALLER AND NOT A `systemctl` LINE IN A RUNBOOK. The unit's load-bearing values are
# machine state: the HOME the supervisor runs under, the PATH a re-offered worker needs (the same PATH
# a repair worker gets, because it is the same dispatcher), and the path of the script itself. Written
# by hand, each one is a per-cell discovery — the shape #2716 found on `pi-cell-4`, where the unit
# existed, `is-active` read `active`, and the pass had been failing for want of one directive. A
# runbook cannot be re-run to converge; this can, and it FAILS CLOSED when the artifact it would
# install is not what it claims.
#
# ⛔ macos IS NOT THIS INSTALLER'S JOB. On Darwin the same capability is a launchd job whose template
# lives in `templates/launchd/com.eldato.worker-supply.plist`, and the repo has ONE launchd installer
# (#304). Refusing here — with the command to run instead — is the alternative to a second launchd
# path that would drift from it and double-install one job. The REFUSAL is the teaching, not a gap.
#
# ⛔ IT INSTALLS ONE UNIT AND TOUCHES NOTHING ELSE. `eldato-pr-repair` (the doctor's loop) and
# `eldato-orchestrator` (the lane dispatcher) are different capabilities with their own installers;
# merging them would let one failure take all three down and would re-create #1761's double-dispatcher
# the moment either is re-installed.
#
# Usage:
#   install-worker-supply.sh [--install]   render + install + enable (idempotent)
#   install-worker-supply.sh --dry-run     render and PRINT the unit; write nothing
#   install-worker-supply.sh --status      installed? enabled? active? + the supervisor's own status
#   install-worker-supply.sh --uninstall    disable + remove the unit we installed
#   install-worker-supply.sh --help
#
# Environment (all optional; tests override these):
#   CELL_HOME              default $HOME (a cell's HOME is its own fact: CELL_HOME= also works)
#   O                      the orchestrator state dir, default $CELL_HOME/orchestrator
#   WORKER_SUPPLY_SCRIPT   the script the unit execs (see the candidate list in `resolve_script`)
#   WORKER_SUPPLY_INTERVAL_S / _PREFIX / _MAX_REFILLS   the three bounds the unit renders
#   TEMPLATES_DIR          default <repo>/templates/systemd
#   UNIT_DIR, SYSTEMCTL    scope overrides (tests: a temp dir with a fake `systemctl`)
#   SUDO                   the passwordless sudo probe (default `sudo -n`)
#   ELDATO_PLATFORM        override `uname -s` (tests)
#
# Exit codes: 0 installed/healthy · 1 REFUSED (a named reason) · 2 usage.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
INFRA_ROOT="$(cd "$HERE/.." 2>/dev/null && pwd)"
PLATFORM="${ELDATO_PLATFORM:-$(uname -s 2>/dev/null || printf unknown)}"
CELL_HOME="${CELL_HOME:-$HOME}"
O="${O:-$CELL_HOME/orchestrator}"
SUDO="${SUDO:-sudo -n}"
INTERVAL_S="${WORKER_SUPPLY_INTERVAL_S:-60}"
PREFIX="${WORKER_SUPPLY_PREFIX:-prd-}"
MAX_REFILLS="${WORKER_SUPPLY_MAX_REFILLS:-2}"
UNIT_NAME="eldato-worker-supply.service"
SCRIPT=""

log_line()  { printf '%s\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
warn() { printf '  ⚠️  %s\n' "$*" >&2; }
err()  { printf '  ❌ %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ── the template, from THIS tree first (a checkout renders its own template; a farmed copy of this
# installer has no `../templates`, so it falls through to the environment's checkout) ────────────
for _cand in "${TEMPLATES_DIR:-}" "$INFRA_ROOT/templates/systemd" "${AGENT_INFRA_PATH:-}/templates/systemd"; do
    [ -n "$_cand" ] || continue
    if [ -f "$_cand/$UNIT_NAME" ]; then TEMPLATES_DIR="$_cand"; break; fi
done
TEMPLATES_DIR="${TEMPLATES_DIR:-$INFRA_ROOT/templates/systemd}"

# ── the script the unit execs ─────────────────────────────────────────────────────────────────
# ⛔ IT MUST RESOLVE. A unit pointed at nothing exits 127 every tick and `is-active` still reads
# `activating`, which is the false PASS this installer exists to remove. Ordered: an explicit override,
# then the FARMED layer (`$CELL_HOME/.pi/agent/scripts`, the flat farm the other cell units exec), then
# this checkout (a Mac-shaped install, and the shape the launchd template uses too).
resolve_script() {
    local c
    for c in "${WORKER_SUPPLY_SCRIPT:-}" \
             "$CELL_HOME/.pi/agent/scripts/worker-supply.sh" \
             "$CELL_HOME/.pi/agent/scripts/orchestrator-harness/worker-supply.sh" \
             "$INFRA_ROOT/scripts/orchestrator-harness/worker-supply.sh"; do
        [ -n "$c" ] || continue
        if [ -f "$c" ]; then SCRIPT="$c"; return 0; fi
    done
    return 1
}

# ── scope: a system unit where passwordless sudo answers, else the user manager ────────────────
resolve_scope() {
    if [ -n "${UNIT_DIR:-}" ] && [ -n "${SYSTEMCTL:-}" ]; then SCOPE="explicit"; return 0; fi
    if $SUDO true 2>/dev/null; then
        SCOPE="system"; UNIT_DIR="/etc/systemd/system"; SYSTEMCTL="$SUDO systemctl"
    elif systemctl --user show-environment >/dev/null 2>&1; then
        SCOPE="user"; UNIT_DIR="$HOME/.config/systemd/user"; SYSTEMCTL="systemctl --user"
    else
        err "REFUSING: no service manager is reachable — no passwordless sudo for a system unit, and the"
        err "  user manager does not answer. A supervisor that is 'installed' but not supervised is the"
        err "  false PASS this installer exists to remove."
        return 1
    fi
    return 0
}

# ── PATH, rendered from the directories the binaries ACTUALLY resolve to ───────────────────────
# The supervisor itself needs almost nothing, but it re-offers orders through the dispatcher, so its
# PATH is the one a repair worker gets. `*/shims` is excluded for the reason install-repair-service.sh
# gives: the shipped launchers refuse it, and a supervisor that inherited it would be the one unit
# whose workers diverge from the fleet's PATH model.
render_path() {
    local dirs="" b d
    for b in gh git python3 node nproc pi uv perl ps awk; do
        d="$(command -v "$b" 2>/dev/null)" || continue
        d="$(dirname "$d")"
        case "$d" in */shims|*/.pi/*) continue ;; esac
        case ":$dirs:" in *":$d:"*) continue ;; esac
        dirs="${dirs:+$dirs:}$d"
    done
    for d in /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
        case ":$dirs:" in *":$d:"*) continue ;; esac
        dirs="${dirs:+$dirs:}$d"
    done
    printf '%s\n' "$dirs"
}

# ── render: ONE place placeholders are substituted, and it REFUSES to emit a unit carrying one ──
# A leftover `{{PATH}}` renders as a LITERAL in `Environment=`, the unit starts, and every probe the
# supervisor makes fails for a reason nobody can see from `systemctl status`.
render() { # <dest>
    local dest="$1" tpl="$TEMPLATES_DIR/$UNIT_NAME" path user
    [ -f "$tpl" ] || die "REFUSING: template missing: $tpl (set TEMPLATES_DIR)"
    [ -n "$SCRIPT" ] || die "REFUSING: resolve_script found no worker-supply.sh — farm the harness first (cell-install.sh) or set WORKER_SUPPLY_SCRIPT"
    path="$(render_path)"
    user="${USER:-$(id -un 2>/dev/null || printf root)}"
    # ⛔ systemd SPLITS an unquoted Environment=/ExecStart= value on whitespace, so a rendered value
    # containing a space would silently start the wrong program. Refuse rather than install that.
    # The three knobs are IN this set (#2896 round 2): they are rendered into `Environment=` too, and
    # `WORKER_SUPPLY_PREFIX='prd -'` widens the order glob into a two-word pattern that matches nothing.
    case "$path$SCRIPT$user$CELL_HOME$O$INTERVAL_S$PREFIX$MAX_REFILLS" in
      *[[:space:]]*) die "REFUSING: a rendered value contains whitespace (PATH='$path' SCRIPT='$SCRIPT' PREFIX='$PREFIX') — systemd would split it" ;;
    esac
    # ⛔ THE TWO NUMBERS ARE RENDERED AND THEN COMPARED BY A `[ ]` TEST, so a typo here is not a cosmetic
    # unit: `WORKER_SUPPLY_MAX_REFILLS=two` makes the crash-loop bound INERT (`[ <n> -ge two ]` never
    # parses, the pass reads "not deferred") and `WORKER_SUPPLY_INTERVAL_S=abc` makes `sleep` fail at
    # once, so `--loop` re-passes with no interval. REFUSE at render time; the supervisor itself falls
    # back to its shipped default instead (worker-supply.sh), because a running supply path must not
    # refuse to supply.
    case "$MAX_REFILLS" in
      ''|*[!0-9]*) die "REFUSING: WORKER_SUPPLY_MAX_REFILLS='$MAX_REFILLS' is not a non-negative integer — the per-order crash-loop bound would be INERT" ;;
      0?*) die "REFUSING: WORKER_SUPPLY_MAX_REFILLS='$MAX_REFILLS' has a leading zero — the supervisor's own rule (`valid_num`) rejects it, so the rendered bound would be silently replaced by the default" ;;
    esac
    case "$INTERVAL_S" in
      ''|*[!0-9]*) die "REFUSING: WORKER_SUPPLY_INTERVAL_S='$INTERVAL_S' is not a positive integer — \`sleep\` would fail and --loop would spin" ;;
      0?*) die "REFUSING: WORKER_SUPPLY_INTERVAL_S='$INTERVAL_S' has a leading zero — the supervisor's own rule (`valid_num`) rejects it, so the rendered cadence would be silently replaced by the default" ;;
    esac
    [ "$INTERVAL_S" -gt 0 ] || die "REFUSING: WORKER_SUPPLY_INTERVAL_S=0 makes --loop re-pass with no interval"
    sed -e "s|{{SCRIPT}}|$SCRIPT|g" \
        -e "s|{{USER}}|$user|g" \
        -e "s|{{HOME}}|$CELL_HOME|g" \
        -e "s|{{PATH}}|$path|g" \
        -e "s|{{INTERVAL_S}}|$INTERVAL_S|g" \
        -e "s|{{PREFIX}}|$PREFIX|g" \
        -e "s|{{MAX_REFILLS}}|$MAX_REFILLS|g" \
        "$tpl" > "$dest" || die "REFUSING: could not render $tpl"
    if grep -q '{{[A-Z_]*}}' "$dest" 2>/dev/null; then
        die "REFUSING: rendered unit still contains a placeholder: $(grep -o '{{[A-Z_]*}}' "$dest" | head -1)"
    fi
    return 0
}

# ── verbs ─────────────────────────────────────────────────────────────────────────────────────
do_dry_run() {
    local tmp
    resolve_script || die "REFUSING: resolve_script found no worker-supply.sh"
    resolve_scope || exit 1
    tmp="$(mktemp "${TMPDIR:-/tmp}/worker-supply-unit.XXXXXX")" || die "REFUSING: no temp file"
    render "$tmp" || { rm -f "$tmp"; exit 1; }
    log_line "scope=$SCOPE unit_dir=$UNIT_DIR script=$SCRIPT"
    awk '{ printf "  %s\n", $0 }' "$tmp"
    rm -f "$tmp"
    return 0
}

do_install() {
    local dest tmp
    resolve_script || die "REFUSING: resolve_script found no worker-supply.sh — farm the harness first (cell-install.sh) or set WORKER_SUPPLY_SCRIPT"
    resolve_scope || exit 1
    dest="$UNIT_DIR/$UNIT_NAME"
    tmp="$(mktemp "${TMPDIR:-/tmp}/worker-supply-unit.XXXXXX")" || die "REFUSING: no temp file"
    render "$tmp" || { rm -f "$tmp"; exit 1; }
    # ⛔ BYTE-IDENTICAL => NO RELOAD. This installer is the propagation trigger (a merged template bump
    # re-renders on the next run), so a no-op must stay a no-op: restarting a healthy supervisor costs
    # an interval of supply for nothing. So the unchanged path RETURNS here — `daemon-reload`/`enable`/
    # `restart` below would each pay that interval on a box where nothing changed (the read-back still
    # runs, because "unchanged file + not running" is a real state that must not read as healthy).
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        ok "unit unchanged: $dest"
        rm -f "$tmp"
        $SYSTEMCTL is-active --quiet "$UNIT_NAME" && { ok "active: $UNIT_NAME"; return 0; }
        ok "not active — starting the unchanged unit (no reload needed)"
        $SYSTEMCTL enable "$UNIT_NAME" >/dev/null 2>&1 || die "REFUSING: enable failed (is-enabled would read disabled)"
        $SYSTEMCTL start "$UNIT_NAME" || die "REFUSING: start failed"
        if $SYSTEMCTL is-active --quiet "$UNIT_NAME"; then
            ok "active: $UNIT_NAME"
        else
            err "REFUSING: $UNIT_NAME is enabled but NOT active — journalctl -u $UNIT_NAME"
            return 1
        fi
        "$SCRIPT" status 2>/dev/null | sed 's/^/    /' || warn "could not read the supervisor's status yet (its first pass may still be running)"
        return 0
    fi
    mkdir -p "$UNIT_DIR" 2>/dev/null || { rm -f "$tmp"; die "REFUSING: cannot create $UNIT_DIR"; }
    install -m 0644 "$tmp" "$dest" 2>/dev/null || die "REFUSING: cannot write $dest"
    ok "unit written: $dest"
    rm -f "$tmp"
    $SYSTEMCTL daemon-reload || die "REFUSING: daemon-reload failed — the unit on disk is not the unit the manager holds"
    $SYSTEMCTL enable "$UNIT_NAME" >/dev/null 2>&1 || die "REFUSING: enable failed (is-enabled would read disabled)"
    $SYSTEMCTL restart "$UNIT_NAME" || die "REFUSING: restart failed"
    # ⛔ A READ-BACK, NOT A HOPE: `is-active` for the unit we just started, plus the supervisor's own
    # first record. An "installed" supervisor that is not running is the defect, not the fix.
    if $SYSTEMCTL is-active --quiet "$UNIT_NAME"; then
        ok "active: $UNIT_NAME"
    else
        err "REFUSING: $UNIT_NAME is enabled but NOT active — journalctl -u $UNIT_NAME"
        return 1
    fi
    "$SCRIPT" status 2>/dev/null | sed 's/^/    /' || warn "could not read the supervisor's status yet (its first pass may still be running)"
    return 0
}

do_status() {
    resolve_script || warn "no worker-supply.sh resolved — the unit cannot be exec'ing one"
    resolve_scope || exit 1
    local dest="$UNIT_DIR/$UNIT_NAME" rc=0
    if [ -f "$dest" ]; then ok "installed: $dest"; else err "not installed: $dest"; rc=1; fi
    if $SYSTEMCTL is-enabled --quiet "$UNIT_NAME" >/dev/null 2>&1; then ok "enabled: yes"; else err "enabled: no"; rc=1; fi
    if $SYSTEMCTL is-active --quiet "$UNIT_NAME" >/dev/null 2>&1; then ok "active: yes"; else err "active: no"; rc=1; fi
    [ -n "$SCRIPT" ] && { log_line "supervisor status:"; "$SCRIPT" status 2>&1 | sed 's/^/    /'; }
    # ⛔ THE EXIT CODE MUST CARRY THE VERDICT, NOT JUST THE LAST TEST (review #2896 round 3). `--status`
    # printed `❌ not installed` / `❌ enabled: no` / `❌ active: no` and still exited 0 whenever the unit
    # FILE existed — so a caller that reads the code (a lane, a supervisor, `set -e`) was told "healthy"
    # about a unit that is not running, which is the false PASS this installer exists to remove; the
    # contract three lines into this file says `0 installed/healthy`. `install-controller-service.sh`
    # fixed the same defect on its own `--status` (#2402).
    return "$rc"
}

do_uninstall() {
    resolve_scope || exit 1
    $SYSTEMCTL disable --now "$UNIT_NAME" >/dev/null 2>&1 || warn "disable --now did not answer (already stopped?)"
    rm -f "$UNIT_DIR/$UNIT_NAME" 2>/dev/null || warn "could not remove $UNIT_DIR/$UNIT_NAME"
    $SYSTEMCTL daemon-reload >/dev/null 2>&1 || true
    ok "removed $UNIT_NAME ($SCOPE scope)"
    return 0
}

MODE=install
while [ $# -gt 0 ]; do
    case "$1" in
        --install|install) MODE=install ;;
        --dry-run) MODE=dry ;;
        --status|status) MODE=status ;;
        --uninstall|uninstall) MODE=uninstall ;;
        -h|--help) awk 'NR>1 && /^set -uo pipefail/ { exit } NR>1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        *) log_line "usage: install-worker-supply.sh [--install|--dry-run|--status|--uninstall|--help]"; exit 2 ;;
    esac
    shift
done

if [ "$PLATFORM" = "Darwin" ]; then
    die "REFUSING: this installer is the LINUX half. On macOS the same supervisor is a launchd job — install it with:  bash $(cd "$INFRA_ROOT/.." 2>/dev/null && pwd)/scripts/install-launchd.sh  (template: templates/launchd/com.eldato.worker-supply.plist)"
fi

case "$MODE" in
    dry) do_dry_run ;;
    install) do_install ;;
    status) do_status ;;
    uninstall) do_uninstall ;;
esac
