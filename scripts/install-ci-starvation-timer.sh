#!/usr/bin/env bash
# install-ci-starvation-timer.sh — put the CI runner starvation detector+healer on the CELL's clock.
#
# WHY THIS FILE EXISTS. The detector (`ci_runner_starvation.sh`) is the instrument for agent-infra#2875:
# a starved runner pool (queued>0 AND busy==0) must be sampled every ~2 min and healed after 3
# consecutive starved samples. A detector that is never scheduled is the failure it exists to catch —
# the starved pool read "healthy" in every dashboard because NOBODY MADE THE CALL. This is the CELL
# half: the runners live on the Linux cells (`pi-cell-1`, `pi-cell-4`), and the healer must not run
# from the Mac and must not depend on the runner pool it repairs.
#
# ⛔ THE MECHANISM: SYSTEMD TIMERS — the box's OWN scheduler, and the one this fleet ALREADY uses on a
# cell (`install-cell-timers.sh`, `install-disk-reaper-timer.sh`, `install-controller-service.sh`).
# No new scheduler vocabulary: two unit files are rendered from these templates and enabled with
# `systemctl`, exactly as the other cell timers are.
#
# ⛔ SCOPES, in the same order and for the same reasons as install-disk-reaper-timer.sh:
#   1. a SYSTEM unit via passwordless sudo (/etc/systemd/system) — a cell's normal shape;
#   2. a USER unit (~/.config/systemd/user) when systemd's user manager answers — a cell with no sudo;
#   3. nothing — a LOUD failure naming both attempts. An "installed" timer that never fires is the
#      false PASS this fleet keeps removing.
#
# ⛔ WHAT IT REFUSES (each would install a unit that cannot run, i.e. the inert enforcer this family
# exists to remove):
#   * a healer path that is not a regular readable file (a unit pointing at nothing exits 127 each tick);
#   * a rendered value containing whitespace (systemd SPLITS unquoted Environment=/ExecStart= values);
#   * a leftover `{{PLACEHOLDER}}` after rendering (the unit would exec a literal `{{HEALER}}`);
#   * a state dir that is not writable by the invoking user (the streak/filed markers live there).
#   * a Darwin platform — the Mac's runner pool is a different surface and has no systemd; installing
#     here would be the wrong repair on the wrong box.
#
# Usage:
#   install-ci-starvation-timer.sh [--install]   render + install + enable (idempotent)
#   install-ci-starvation-timer.sh --dry-run     render and PRINT the units; write nothing
#   install-ci-starvation-timer.sh --status      is the timer enabled/active, and what did it last say?
#   install-ci-starvation-timer.sh --uninstall   disable + remove the units
#   install-ci-starvation-timer.sh --help
#
# Env seams (tests + unusual cells):
#   TEMPLATES_DIR       systemd templates (default: this repo's templates/systemd)
#   SYSTEMD_UNIT_DIR    install dir override (tests: a temp dir with a fake `systemctl`)
#   SYSTEMCTL           the systemctl to call (default `systemctl`, or `sudo -n systemctl`)
#   SUDO                the passwordless sudo probe (default `sudo -n`)
#   ELDATO_PLATFORM     override `uname -s` (tests)
#   CI_STARVATION_HEALER  the pass script (default: farmed copy, else this checkout)
#   CI_STARVATION_STATE_DIR  the state dir the unit exports (default $HOME/.pi/agent/state)
#   CI_STARVATION_REPO    owner/repo the detector samples (default daniel-ospina/tortoise)
#
# Exit codes: 0 ok · 1 failure (named) · 2 usage.
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ⛔ Templates are NOT farmed (only scripts are), so a FARMED copy of this installer has no
# ../templates. Resolve the way install-disk-reaper-timer.sh does: the checkout that installed the
# layer (AGENT_INFRA_PATH) first, then this checkout.
if [ -z "${TEMPLATES_DIR:-}" ]; then
    for _cand in "${AGENT_INFRA_PATH:-}/templates/systemd" "$INFRA_ROOT/templates/systemd"; do
        [ -n "$_cand" ] && [ -d "$_cand" ] && { TEMPLATES_DIR="$_cand"; break; }
    done
fi
TEMPLATES_DIR="${TEMPLATES_DIR:-$INFRA_ROOT/templates/systemd}"
PLATFORM="${ELDATO_PLATFORM:-$(uname -s 2>/dev/null || printf unknown)}"
STATE_DIR="${CI_STARVATION_STATE_DIR:-${HOME:?HOME is required}/.pi/agent/state}"
STARVE_REPO="${CI_STARVATION_REPO:-daniel-ospina/tortoise}"
UNIT_NAME="eldato-ci-starvation"
SUDO="${SUDO:-sudo -n}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"

say() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }

sed_esc() { printf '%s' "$1" | sed -e 's/[&\\|]/\\&/g'; }
has_space() { case "$1" in *[[:space:]]*) return 0 ;; esac; return 1; }

# resolve_healer — the farmed copy first: it is what a cell has after pi-bootstrap/setup.sh, and a
# unit pointing at a worktree checkout breaks the day that worktree is reaped.
resolve_healer() {
  local c
  for c in "${CI_STARVATION_HEALER:-}" "$HOME/.pi/agent/scripts/ci_runner_starvation.sh" \
           "$INFRA_ROOT/scripts/ci_runner_starvation.sh"; do
    [ -n "$c" ] && [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

resolve_target() {
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

preflight() { # $1 = healer path
  local h="$1" f bad=0
  for f in "$h" "$TEMPLATES_DIR/$UNIT_NAME.service" "$TEMPLATES_DIR/$UNIT_NAME.timer"; do
    [ -f "$f" ] && [ -r "$f" ] || { err "not a readable file: $f"; bad=1; }
  done
  for f in "$h" "$HOME" "$STATE_DIR"; do
    has_space "$f" && { err "path contains whitespace, which systemd splits: $f"; bad=1; }
  done
  has_space "$STARVE_REPO" && { err "STARVE_REPO contains whitespace: '$STARVE_REPO'"; bad=1; }
  case "$STARVE_REPO" in */*) ;; *) err "STARVE_REPO must be owner/repo (got '$STARVE_REPO')"; bad=1 ;; esac
  if [ "${DRY_RUN:-0}" = 1 ]; then
    [ -e "$STATE_DIR" ] && [ ! -w "$STATE_DIR" ] && { err "state dir '$STATE_DIR' exists and is not writable by $(id -un)"; bad=1; }
  else
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    [ -w "$STATE_DIR" ] || { err "state dir is not writable by $(id -un): $STATE_DIR (the streak/filed markers live there; refuse rather than install a pass that cannot keep its bound)"; bad=1; }
  fi
  [ "$bad" -eq 0 ]
}

render() { # <template> <dest> <healer>
  local t="$1" d="$2"
  sed -e "s|{{USER}}|$(sed_esc "$(id -un)")|g" \
      -e "s|{{HOME}}|$(sed_esc "$HOME")|g" \
      -e "s|{{PATH}}|$(sed_esc "${PATH:-/usr/local/bin:/usr/bin:/bin}")|g" \
      -e "s|{{STATE_DIR}}|$(sed_esc "$STATE_DIR")|g" \
      -e "s|{{STARVE_REPO}}|$(sed_esc "$STARVE_REPO")|g" \
      -e "s|{{HEALER}}|$(sed_esc "${3:-}")|g" \
      "$t" >"$d" || return 1
  # ⛔ A leftover placeholder is an installed unit that execs a literal `{{HEALER}}` — refuse, never skip.
  if grep -q '{{' "$d"; then err "unrendered placeholder in $d"; grep -o '{{[A-Z_]*}}' "$d" | sort -u | tr '\n' ' ' >&2; printf '\n' >&2; return 1; fi
  return 0
}

cmd_dry_run() {
  local h out rc=0
  h="$(resolve_healer)" || { err "ci_runner_starvation.sh not found (looked at \$CI_STARVATION_HEALER, \$HOME/.pi/agent/scripts, $INFRA_ROOT/scripts)"; return 1; }
  preflight "$h" || return 1
  out="$(mktemp -d "${TMPDIR:-/tmp}/ci-starvation-unit.XXXXXX")" || return 1
  render "$TEMPLATES_DIR/$UNIT_NAME.service" "$out/$UNIT_NAME.service" "$h" || rc=1
  render "$TEMPLATES_DIR/$UNIT_NAME.timer"   "$out/$UNIT_NAME.timer"   "$h" || rc=1
  for f in "$UNIT_NAME.service" "$UNIT_NAME.timer"; do printf '=== %s ===\n' "$f"; cat "$out/$f"; done
  rm -rf "$out"
  say ""
  say "dry run: rendered 2 units for platform=$PLATFORM; nothing was written or enabled."
  return "$rc"
}

cmd_install() {
  if [ "$PLATFORM" = "Darwin" ]; then
    # ⛔ NOT A SILENT SKIP: this healer runs on the Linux cells only. The Mac's runner pool is a
    # different surface (and its scheduler is launchd, not systemd) — installing here would be the
    # wrong repair on the wrong box.
    say "platform=Darwin — this timer is for the LINUX CELLS only (the runners live there; the Mac's"
    say "  pool is a different surface and has no systemd). Nothing was written here."
    return 0
  fi
  local h out rc=0 u
  h="$(resolve_healer)" || { err "ci_runner_starvation.sh not found (looked at \$CI_STARVATION_HEALER, \$HOME/.pi/agent/scripts, $INFRA_ROOT/scripts). Farm it first: bash pi-bootstrap/setup.sh"; return 1; }
  preflight "$h" || return 1
  resolve_target || { err "no systemd target on this box: tried a SYSTEM unit via passwordless sudo and a USER unit via 'systemctl --user'. Nothing was installed — a scheduled pass with no scheduler is the false PASS this installer refuses."; return 1; }
  say "installing into the $TARGET scope: $UNIT_DIR (systemctl: $SC)"

  out="$(mktemp -d "${TMPDIR:-/tmp}/ci-starvation-unit.XXXXXX")" || return 1
  if ! render "$TEMPLATES_DIR/$UNIT_NAME.service" "$out/$UNIT_NAME.service" "$h"; then rm -rf "$out"; return 1; fi
  if ! render "$TEMPLATES_DIR/$UNIT_NAME.timer"   "$out/$UNIT_NAME.timer"   "$h"; then rm -rf "$out"; return 1; fi
  # A USER unit may not carry User= (systemd rejects it), so drop that line in that mode.
  if [ "$TARGET" = "user" ]; then
    sed -i.bak '/^User=/d' "$out/$UNIT_NAME.service" && rm -f "$out/$UNIT_NAME.service.bak"
  fi

  mkdir -p "$UNIT_DIR" 2>/dev/null || { err "cannot create $UNIT_DIR"; rm -rf "$out"; return 1; }
  for u in "$UNIT_NAME.service" "$UNIT_NAME.timer"; do
    if [ -f "$UNIT_DIR/$u" ] && cmp -s "$out/$u" "$UNIT_DIR/$u"; then
      say "  $u: unchanged"
      continue
    fi
    if [ "$TARGET" = system ] || [ "$(id -u)" = 0 ]; then
      cp "$out/$u" "$UNIT_DIR/$u" || rc=1
    else
      cp "$out/$u" "$UNIT_DIR/$u" 2>/dev/null || { err "cannot write $UNIT_DIR/$u"; rc=1; }
    fi
    [ "$rc" -eq 0 ] && say "  $u: installed"
  done
  rm -rf "$out"
  [ "$rc" -eq 0 ] || return 1

  $SC daemon-reload >/dev/null 2>&1 || { err "$SC daemon-reload failed — the units are on disk but not seen by the manager"; return 1; }
  if ! $SC enable --now "$UNIT_NAME.timer" >/dev/null 2>&1; then
    err "$SC enable --now $UNIT_NAME.timer failed — an installed timer that is not enabled never fires"
    return 1
  fi
  if [ "$TARGET" = user ]; then
    if command -v loginctl >/dev/null 2>&1 && ! loginctl show-user "$(id -un)" 2>/dev/null | grep -q 'Linger=yes'; then
      say "  ⚠️  Linger is NOT enabled for $(id -un): a USER timer stops at logout. Enable with: sudo loginctl enable-linger $(id -un)"
    fi
  fi
  say "installed: ci runner starvation check every 2 min (heals after 3 starved samples) — $TARGET scope."
  say "  read back with: bash $0 --status"
  return 0
}

cmd_status() {
  local st en rc=0 line
  if [ "$PLATFORM" = "Darwin" ]; then
    say "platform=Darwin — this timer is for the Linux cells only; NOT APPLICABLE here."
    return 0
  fi
  resolve_target || { say "UNKNOWN: no systemd manager answers, so the timer's state cannot be read (that is not 'healthy')"; return 2; }
  st="$($SC is-active "$UNIT_NAME.timer" 2>/dev/null || true)"
  en="$($SC is-enabled "$UNIT_NAME.timer" 2>/dev/null || true)"
  printf '%s\tenabled=%s\tactive=%s\n' "$UNIT_NAME.timer" "${en:-unknown}" "${st:-unknown}"
  case "$en$st" in *enabled*active) ;; *) rc=1 ;; esac
  if [ -f "$STATE_DIR/ci-runner-starvation.log" ]; then
    line="$(tail -1 "$STATE_DIR/ci-runner-starvation.log" 2>/dev/null)"
    printf 'last[ci-runner-starvation.log]\t%s\n' "${line:-<empty>}"
  else
    printf 'last[ci-runner-starvation.log]\t<absent — the pass has not run since it was installed>\n'
  fi
  return "$rc"
}

cmd_uninstall() {
  local u
  if [ "$PLATFORM" = "Darwin" ]; then
    say "platform=Darwin — nothing to remove here."
    return 0
  fi
  resolve_target || { err "no systemd manager answers, so nothing can be disabled"; return 1; }
  $SC disable --now "$UNIT_NAME.timer" >/dev/null 2>&1 || true
  for u in "$UNIT_NAME.service" "$UNIT_NAME.timer"; do rm -f "$UNIT_DIR/$u" 2>/dev/null || true; done
  $SC daemon-reload >/dev/null 2>&1 || true
  say "removed the timer and its unit from $UNIT_DIR (the pass's own state is left in $STATE_DIR)."
  return 0
}

case "${1:---install}" in
  --install)   cmd_install ;;
  --dry-run)   DRY_RUN=1 cmd_dry_run ;;
  --status)    cmd_status ;;
  --uninstall) cmd_uninstall ;;
  --help|-h)   usage 0 ;;
  *) printf 'usage: %s [--install|--dry-run|--status|--uninstall|--help]\n' "$(basename "$0")" >&2; exit 2 ;;
esac
