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
# ⛔ AND THE UNIT NAMES A PATH THAT OUTLIVES THE SHELL THAT RENDERED IT (agent-infra#2697). `Existing at
# render time` is not a property systemd can rely on at boot, so the resolved supervisor is refused when it
# cannot survive a cleaning (see `scratch_supervisor_reason`), and the revision it names is RECORDED in the
# unit's environment (`ORCH_SUPERVISOR_PIN`) so `merged ≠ running` is a readable fact rather than a guess.
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
#                          ⛔ REFUSED when it resolves into a lane worktree — a LINKED git worktree checked
#                          out on a BRANCH, a DETACHED one that is not this box's recorded harness pin, or the
#                          fleet's scratch shapes (`*/.worktrees/*`, `/tmp/wt-*`, …) — or under a temporary root
#                          that no deployment root declares (agent-infra#2697): a unit whose
#                          ExecStart a cleaning removes burns its start limit (3 attempts inside 300 s) and
#                          converges to `failed` in well under a minute — SILENTLY, because nothing pages on
#                          it, so the fleet still believes the box has a dispatcher. The refusal names the
#                          durable alternatives (the farm,
#                          $AGENT_INFRA_PATH/scripts, the harness pin)
#   ORCH_SUPERVISOR_PREFER a CALLER's preference (cloud-cell-bringup.sh names the layer checkout it just
#                          installed). A non-durable one is SKIPPED with a loud note and the next candidate is
#                          used — a preference never silently becomes the boot entry point, and it never
#                          withholds the unit a durable candidate can supply
#   AGENT_INFRA_PATH       the checkout this box declares as its deployment surface — one of the roots the
#                          ExecStart refusal accepts under a temporary root (the cells keep their home under
#                          /tmp, so "under /tmp" alone cannot be the rule). ⛔ IT DOES NOT LAUNDER A WORKTREE:
#                          a linked worktree is refused before any declaration is consulted, and it finds
#                          templates too (see TEMPLATES_DIR below)
#   HARNESS_PIN_FILE       the record naming THIS box's harness pin (default $CELL_HOME/.harness-path). Used
#                          only to ADMIT a DETACHED linked worktree — the bring-up creates the pin with
#                          `git worktree add --detach`, so the refusal cannot reject `linked worktree` as a
#                          class. A detached worktree the record does not name is refused: the fleet's
#                          drainer gives a LANE's scratch checkout that same shape under $HOME
#   HARNESS_PIN_DIR        the pin ROOT accepted while no record exists yet (default $CELL_HOME/harness)
#   ORCH_RESTART_SEC       the rendered RestartSec (default 15; a whole number of seconds, >= 1)
#   ORCH_START_TIMEOUT_SEC the ORPHAN-handover ceiling (default 60; a whole number, and one that fits
#                          StartLimitBurst attempts inside StartLimitIntervalSec — see do_install).
#                          Rendered as CONTROLLER_ORPHAN_TIMEOUT, and as TimeoutStartSec — its systemd-side
#                          counterpart (this unit is Type=simple, where that directive does not bound start)
#   ORCH_HANDOVER_TIMEOUT_SEC the handover ceiling for a controller this state dir still OWNS (default 3600;
#                          a whole number >= 1). Long on purpose: that controller is landing work
#   CELL_HOME              the cell's home whose keys.env/state the controller reads (default: DERIVED —
#                          scripts/lib/cell-home.sh). ⛔ It is rendered as BOTH `Environment=HOME=` and
#                          `Environment=CELL_HOME=` in the unit: the home the unit runs as and the home it
#                          pins are the same question, and the pass refuses (exit 27) while they disagree.
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
# ── THE ONE HOME (agent-infra#3453) — DERIVED, never defaulted to the legacy /tmp/cell-home ────────
# ⛔ THIS INSTALLER RENDERS THE UNIT THE PASS'S SPLIT GUARD MEASURES (review F1). The pass compares this
# unit's `Environment=CELL_HOME=` against the home it derives, and it REFUSES every tick (exit 27) while
# they disagree — so a renderer that answers "what is this box's home?" from `$HOME` does not merely
# produce a wrong unit, it makes the pass refuse over a disagreement this file authored. That is not
# hypothetical on the channel the fleet reaches a cell through: `cmux vm exec` runs as `cmux` with
# `HOME=/home/ubuntu`, a directory the image does not create, so `$HOME` there is a home no account
# lives in. The rule lives in `scripts/lib/cell-home.sh`; this is the same consumer block
# `install-repair-service.sh` carries.
CELL_HOME_LIB=""
# ⛔ THE SELF PATH COUNTS ONLY WHEN IT NAMES THIS FILE — see `lib/cell-home.sh` §CONSUMERS.
_SELF="${BASH_SOURCE[0]:-}"; [ -f "$_SELF" ] || _SELF=""     # under `bash -s` $0 is literally `bash` -> `.`
if [ -n "$_SELF" ]; then
  _SELF_DIR="$(cd "$(dirname "$_SELF")" 2>/dev/null && pwd -P)"
  for _cand in "$_SELF_DIR/lib/cell-home.sh" "$_SELF_DIR/../lib/cell-home.sh"; do
    [ -r "$_cand" ] && { CELL_HOME_LIB="$_cand"; break; }
  done
fi
if [ -n "$CELL_HOME_LIB" ]; then . "$CELL_HOME_LIB"; CELL_HOME="$(cell_home_resolve)"; else CELL_HOME="${CELL_HOME:-${HOME:?HOME is required}}"; fi
# ⛔ AN EMPTY CELL_HOME IS NOT A HOME — it is the FILESYSTEM ROOT, and this file renders it into TWO
# `Environment=` lines. A missing resolver is the incomplete-install case, so it is a REFUSAL.
[ -n "$CELL_HOME" ] || { printf '%s: FATAL: %s is not readable and neither CELL_HOME nor HOME is set — refusing to default the cell home (agent-infra#3453)\n' "${0##*/}" "${CELL_HOME_LIB:-lib/cell-home.sh}" >&2; exit 78; }
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
#
# ⛔ AND IT MUST STILL RESOLVE AFTER THE BOX STOPS TOUCHING IT (agent-infra#2697). Existing-at-render-time
# was the ONLY guard on the rendered value, so the installer happily pinned the fleet's dispatcher to
# whatever checkout the operator happened to run `--install` from. MEASURED on cell-1:
# `ExecStart=/bin/bash /tmp/wt-2433-fu/scripts/cloud-cell-supervisor.sh start`, i.e. a LANE WORKTREE at a
# branch nobody merged (`fix/2402-fence-and-scope`). Two silent consequences: `/tmp` entries are dropped by
# `systemd-tmpfiles --clean` once they age out of the window the box's own tmpfiles.d sets — `D /tmp … 30d`
# on this fleet's Ubuntu/systemd-255 image (`/usr/lib/tmpfiles.d/tmp.conf`), 10d on some others; `/tmp` is
# not its own mount on these cells, so the CLEANER, not a reboot, is the mechanism. After that the unit's
# ExecStart cannot resolve; `Restart=always` burns the unit's start limit (3 attempts inside 300 s), systemd
# converges it to `failed` in well under a minute, and NOTHING PAGES — the box is not "supervised and
# retrying", it is DEAD, while the fleet still believes it has a dispatcher. And the code
# the dispatcher runs is a branch nobody merged. Same seam, three cells, three different ExecStart shapes,
# all of them "whatever was beside the installer". Measured again on cell-4 in the shape a TEST render
# leaves behind: `ExecStart="/usr/local/bin/python3.12" "/tmp/rp3055.SzqD2K/converger.py" --repo "o/r"
# --dry-run`, timer enabled and failing every ten minutes since 2026-10-30.
#
# ⛔ WHAT IS DURABLE IS DECIDED BY THE ROOT THE PATH RESOLVES INTO, NOT BY ITS SPELLING, AND NOT BY "is it
# under /tmp". The cells keep their home under `/tmp` (`/tmp/cell-home`) and their harness pin at
# `/tmp/cell-home/harness/<sha>/…` — the CORRECT ExecStart shape, measured on cell-3 — so a rule that
# refused `/tmp` outright would refuse every healthy cell install. That is the same false block
# `runner_autoscale.py` records against a blanket refusal ("refusing would make --install-unit unusable ON
# THE BOXES IT EXISTS FOR"), and this guard must not reintroduce it. So: a path under a temporary root is
# accepted only while it is inside a root THIS BOX DECLARES as its deployment surface (its cell home, its
# home, the checkout `$AGENT_INFRA_PATH` names), and a lane worktree is refused wherever it lives, because
# that is the directory a lane removes when it ends.
# ⛔ THE TEMPORARY-ROOT LIST IS THE ONE `scripts/orchestrator-harness/runner_autoscale.py` ALREADY USES for
# the same judgement (`TRANSIENT_UNIT_PREFIXES`), COPIED here because a farmed installer cannot import the
# python — and the copy is DRIFT-GATED rather than trusted: `install-controller-service.test.sh` §P8 compares
# the two lists as sets, so a root added on either side reddens until both agree. Without that gate the copy
# would be the one that stays un-updated and silently ADMITS the next measured shape. `$TMPDIR` is graded at
# USE time in `transient_root_of`, separately and quoted (never concatenated into the literal: it is a
# property of the calling shell, a relocated temp is under whatever it says, and a value containing a space
# must not split into two bogus roots).
TRANSIENT_ROOTS="/tmp /var/tmp /run /dev/shm /var/folders /private/tmp /private/var/tmp /private/var/folders"

# ⛔ THE AMBIENT-GIT SCRUB HAS ONE OWNER (re-review P1, measured END-TO-END). Every git read here that
# answers a question about a DIRECTORY must ignore an exported `GIT_DIR`/`GIT_WORK_TREE` pair: with both set,
# `git -C <lane worktree> rev-parse --show-toplevel` answers the path THEY name and `symbolic-ref -q HEAD`
# reads THAT repository's HEAD. Four call sites scrubbed individually and two, in `linked_worktree_root`,
# did not — so `GIT_DIR=<pin>/.git GIT_WORK_TREE=<pin>` made a BRANCH lane worktree grade "detached at this
# box's recorded pin" and the installer ARMED `ExecStart=<lane worktree>/scripts/cloud-cell-supervisor.sh`
# with rc=0: the exact #2697 shape, admitted by two exported variables. Reproduced before the fix (primary
# clone + detached pin + branch worktree, `ORCH_SUPERVISOR` on the branch worktree): without the pair rc=1
# "LINKED GIT WORKTREE … checked out on a BRANCH", with it rc=0 and the unit rendered. The list therefore
# exists ONCE, and `linked_worktree_root` reads its branch/detached answer through the same scrub as
# `git_dirs` — the two halves of one rule cannot disagree any more.
GIT_SCRUB=(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE GIT_OPTIONAL_LOCKS=0)

# lane_scratch_shape <resolved path> — the lane-scratch SHAPE this path matches, or nothing.
# ⛔ ONE LIST, MIRRORED FROM `scripts/install-repair-service.sh` (its `case "$SCRIPTS_DIR"` in `render()`,
# which refuses these same shapes for the repair unit) — and the SUITE asserts the two lists are equal (§P6),
# because a second hand-kept copy is exactly what drifts.
lane_scratch_shape() {
    case "${1:-}" in
        */.worktrees/*)  printf '%s' '*/.worktrees/*' ;;
        /tmp/wt-*)       printf '%s' '/tmp/wt-*' ;;
        /tmp/cell-wt-*)  printf '%s' '/tmp/cell-wt-*' ;;
        /tmp/base-*)     printf '%s' '/tmp/base-*' ;;
    esac
}

# pin_root_of_this_box — the harness-pin root this box records, or `$CELL_HOME/harness` (the bring-up's
# default) when no record exists yet.
# ⛔ A DETACHED LINKED WORKTREE IS NOT AUTOMATICALLY A PIN (review-4 P1, measured). Detached is ALSO the shape
# the fleet's drainer gives a lane's scratch checkout — `ai-drainer.sh` runs
# `git worktree add -f "$AI/wt-drainer-<name>" "$SEED_REF"` (`SEED_REF` = `origin/main`, i.e. a detached HEAD)
# under `$HOME`, a DECLARED root — and removes it with `worktree remove --force` when the lane ends. Treating
# "detached ⇒ pin" therefore re-opened the exact class this guard exists for, one layer below the branch rule
# that closed it: measured, that path was ADMITTED. What separates a pin from a lane's scratch is not the HEAD
# state but WHERE the box says its pin lives: `$CELL_HOME/.harness-path` (written by the bring-up) or the
# bring-up's own default `$CELL_HOME/harness` (`HARNESS_PIN_DIR`). A detached worktree outside that root is
# refused.
pin_root_of_this_box() {
    local f p root="" cr
    f="${HARNESS_PIN_FILE:-$CELL_HOME/.harness-path}"
    if [ -f "$f" ]; then
        p="$(head -1 "$f" 2>/dev/null)"
        # ⛔ NORMALISE THE SPELLING BEFORE COMPARING (review-5 P3, measured). Other readers of this record do
        # (`check-farm-drift.sh`, `pi-reap-worktrees.sh`). A record with a trailing slash — `…/scripts/
        # orchestrator-harness/` — did not match the `*/scripts/orchestrator-harness` case, so it was taken as
        # the pin ROOT, compared against the pin TREE, and the box's own pin was refused as foreign.
        while [ "${p%/}" != "$p" ]; do p="${p%/}"; done
        while [ "${p#//}" != "$p" ]; do p="${p#//}"; done
        case "$p" in
            */scripts/orchestrator-harness) root="$(dirname "$(dirname "$p")")" ;;
            '') ;;
            *) root="$p" ;;
        esac
    fi
    [ -n "$root" ] || root="${HARNESS_PIN_DIR:-$CELL_HOME/harness}"
    # ⛔ RESOLVED BEFORE IT IS COMPARED (cycle-2 P1, MEASURED — a FALSE BLOCK on the box's own pin). The caller
    # compares this root against the git toplevel that `linked_worktree_root` read, and git answers a PHYSICAL
    # path; `path_under`'s own contract says both arguments are already resolved by `canon_dir` (see the three
    # declared roots, resolved a few lines below in `scratch_supervisor_reason`). This function normalised
    # SLASHES only, so a record — or a `CELL_HOME`/`HARNESS_PIN_DIR` — whose spelling passes through a benign
    # symlink (`/home/op -> /mnt/data/op`, the layout #2666 measures in this same file) compared a resolved
    # toplevel against an unresolved root, and the box's own harness pin was refused as "NOT the harness pin
    # this box records" while the refusal named that very path as the remedy. Reproduced end to end: a
    # symlinked `CELL_HOME` with the bring-up's own `git worktree add --detach` pin and its recorded
    # `.harness-path` => rc=1; the same tree spelled physically => admitted. `canon_dir` uses `realpath -m`, so
    # it resolves the existing prefix of a path that does not exist yet; an unresolvable root keeps its raw
    # spelling (fail-closed: an ungradable root still cannot match, but the message stays readable).
    cr="$(canon_dir "$root")"
    case "$cr" in
        ''|"$CANON_UNRESOLVED"*) printf '%s\n' "$root" ;;
        *) printf '%s\n' "$cr" ;;
    esac
}

# pin_supervisor_of_this_box — the supervisor inside the harness pin this box records, or nothing.
# ⛔ THE REFUSAL'S OWN SECOND REMEDY WAS NEVER A CANDIDATE (review-8 P1, MEASURED). The refusal text tells an
# operator to use `$CELL_HOME/harness/<pin-sha>/scripts/cloud-cell-supervisor.sh`, and on a cell that file is
# the ONE DURABLE supervisor — yet `resolve_supervisor`'s candidate list never proposed it. WHY that mattered
# is narrower than the version first written here, and the correction is the point: `cloud-cell-supervisor.sh`
# USED to be in NO pi-bootstrap array, so on a fresh cell BOTH other candidates were absent and the install
# refused outright. With the `fleet_srcs` entry this landing adds (#1938), `setup.sh` farms the supervisor FLAT to
# `$HOME/.pi/agent/scripts/cloud-cell-supervisor.sh`, so a correctly-installed box DOES have it. ⛔ THE FARMED
# CANDIDATE AND `beside` ARE NOT SYNONYMS: `beside` is derived from the RUNNING script, so they collapse into
# one candidate ONLY when this installer is invoked from its FARMED path; an invocation from a CHECKOUT —
# including the layer checkout the cell bring-up deliberately prefers — makes `beside` that checkout's sibling,
# a genuinely distinct third candidate. The pin is tried first either way. What is left is the real reason the pin candidates stay: a box whose farm
# predates that entry, or one whose farmed copy was removed, still has the pin and nothing else — and a cell
# that HAS a durable supervisor must not be refused. This is the false block the soft preference exists to
# prevent. ⛔ The old sentence here claimed the loss was "only the unmerged-code ExecStart because it falls
# through to the farm" — the farm SHIPS that file now, so the loss is not limited to ExecStart and the
# fall-through is no longer hypothetical. The pin is resolved FIRST from the RECORD (exact: the tree the
# bring-up materialised this run is the one the record names), so "newest pin" is not guessed by glob order;
# the `<root>/<sha>` scan is the fallback for a box whose record is absent or names only the root.
pin_supervisor_of_this_box() {
    local f p tree root t
    f="${HARNESS_PIN_FILE:-$CELL_HOME/.harness-path}"
    if [ -f "$f" ]; then
        p="$(head -1 "$f" 2>/dev/null)"
        while [ "${p%/}" != "$p" ]; do p="${p%/}"; done
        case "$p" in
            */scripts/orchestrator-harness)
                tree="$(dirname "$(dirname "$p")")"
                if [ -f "$tree/scripts/cloud-cell-supervisor.sh" ]; then
                    printf '%s\n' "$tree/scripts/cloud-cell-supervisor.sh"
                    return 0
                fi ;;
        esac
    fi
    root="$(pin_root_of_this_box)"
    [ -n "$root" ] || return 0
    # the flat-pin layout the guard also admits: the pin ROOT is itself the worktree
    if [ -f "$root/scripts/cloud-cell-supervisor.sh" ]; then
        printf '%s\n' "$root/scripts/cloud-cell-supervisor.sh"
        return 0
    fi
    for t in "$root"/*/; do
        [ -f "${t%/}/scripts/cloud-cell-supervisor.sh" ] \
            && printf '%s\n' "${t%/}/scripts/cloud-cell-supervisor.sh"
    done
    return 0
}

# linked_worktree_root <resolved supervisor> — the LINKED git worktree this path lives in, or nothing.
# ⛔ A NAME LIST CANNOT BE THIS GUARD (re-review P1 of #2697). The measured shape was `/tmp/wt-2433-fu`, and
# a copy nested one fixture deeper (`/tmp/r2697d/wt-2433-fu/…`) matches neither of those patterns nor the
# `/tmp/wt-*` shape — and the next lane picks the next name. What MAKES a lane checkout a lane checkout is
# not its spelling: git records it. In the MAIN clone `--absolute-git-dir` and `--git-common-dir` are the
# same directory; in a LINKED worktree the git dir is `<main>/.git/worktrees/<name>` while the common dir is
# still `<main>/.git`. So the test is git's own arithmetic, and it holds for `/tmp/wt-x`, `$HOME/wt-x`,
# `<repo>/.worktrees/x` and every name after them — while a PRIMARY clone under /tmp (`/tmp/cell-ai`, the
# cells' own checkout) is untouched, which is the shape three cells must keep.
# ⛔ IT IS UNCONDITIONAL: no declared root excuses it. `cloud-cell-bringup.sh` passes the LAYER checkout as
# `AGENT_INFRA_PATH`, and that layer MAY BE the lane's own worktree — so "the caller declared it" is the
# escape this closes, not a reason to admit it.
git_dirs() { # <dir> — prints "<absolute-git-dir> <git-common-dir>", both resolved, or nothing
    command -v git >/dev/null 2>&1 || return 0
    local d="${1:-}" gitdir common
    # ⛔ THE AMBIENT GIT_* SELECTION IS SCRUBBED (re-review P2, measured). `GIT_DIR=<hub>/.git git -C <a
    # linked worktree> rev-parse …` answers the HUB for both questions, so the two agreed and this function
    # printed "main" for a linked worktree — the whole refusal bypassed by one exported variable (a layout
    # this fleet invites: `/tmp/cell-ai` is a bare-configured clone). The question here is "what does GIT
    # say about THIS DIRECTORY", so every variable that redirects git's selection is removed for the call.
    gitdir="$("${GIT_SCRUB[@]}" git -C "$d" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
    common="$("${GIT_SCRUB[@]}" git -C "$d" rev-parse --git-common-dir 2>/dev/null)" || return 0
    [ -n "$gitdir" ] && [ -n "$common" ] || return 0
    # ⛔ `--git-common-dir` ANSWERS A RELATIVE PATH IN A MAIN CLONE (`.git`) AND AN ABSOLUTE ONE IN A LINKED
    # WORKTREE. Compared raw, a primary clone's two answers differ by SPELLING and every primary clone would
    # read as linked — a false block on `/tmp/cell-ai`, the cell's own checkout. Both are resolved here, once.
    case "$common" in /*) ;; *) common="$d/$common" ;; esac
    common="$(canon_dir "$common")"
    case "$common" in "$CANON_UNRESOLVED"*) return 0 ;; esac
    gitdir="$(canon_dir "$gitdir")"
    case "$gitdir" in "$CANON_UNRESOLVED"*) return 0 ;; esac
    [ "${gitdir%/}" = "${common%/}" ] && { printf '%s %s main\n' "$gitdir" "$common"; return 0; }
    printf '%s %s linked\n' "$gitdir" "$common"
}

# git_checkout_unproven <dir> — true when <dir> sits inside a git checkout (a `.git` entry at itself or an
# ancestor — a DIRECTORY in a main clone, a FILE in a linked worktree) and git could not answer about it.
# ⛔ "GIT COULD NOT ANSWER" IS NOT "NOT A WORKTREE" (re-review P2). `git_dirs` prints nothing both when the
# path is not a repository AND when git refused or failed — and the caller read that emptiness as "durable".
# Reproduced before this fix: a linked worktree under a declared root, with a `git` that exits 1 (git's own
# `detected dubious ownership` refusal, which THIS repo's `CONTROLLER_ALLOW_ROOT=1` shape can produce; a
# wrapper exporting GIT_DIR; or git absent), rendered `ExecStart=…/lane-checkout/scripts/…` and armed it.
# Every other unresolvable branch in this file fails CLOSED (`canon_file`, the #2666 unit-dir guard), and so
# does this one now: a checkout we cannot interrogate is an UNPROVEN worktree, never a deployment.
# A farmed copy (no `.git` anywhere above it) is unaffected, which is the shape this must not block.
git_checkout_unproven() {
    local d="${1:-}"
    while [ -n "$d" ] && [ "$d" != "/" ]; do
        [ -e "$d/.git" ] && return 0
        d="$(dirname "$d")"
    done
    return 1
}

# linked_worktree_root <resolved supervisor> — "<root>|branch", "<root>|detached", a REASON sentence, or nothing.
# ⛔ A LINKED WORKTREE IS NOT AUTOMATICALLY A LANE'S — THE HARNESS PIN *IS* ONE (review-3 P1, the finding that
# makes this a rule about the BRANCH). `cloud-cell-bringup.sh` creates every cell's pin with
# `git worktree add --detach <pin-dir>/<sha> <sha>`, so a rule that refuses every linked worktree refuses the
# very shape this installer calls CORRECT and the alternative its own refusal message recommends — an operator
# with no farm is in a loop. What makes the #2697 shape wrong is not "worktree": it is a worktree checked out
# ON A BRANCH, i.e. unmerged code a lane removes when it lands. A DETACHED worktree is a pin at a commit. Git
# answers this directly (`symbolic-ref -q HEAD` errors on a detached HEAD), so the rule stays name-free, and the
# durability question is still decided afterwards by the temporary-root/declared-root test.
linked_worktree_root() {
    local d dirs top
    d="$(dirname "${1:-}")"
    dirs="$(git_dirs "$d")"
    if [ -z "$dirs" ]; then
        if git_checkout_unproven "$d"; then
            if command -v git >/dev/null 2>&1; then
                printf 'it is inside a git checkout (%s) that git itself could not identify — commonly a repository owned by another user (git refuses with "dubious ownership"), a wrapper or environment exporting GIT_DIR, or an unreadable .git — so whether it is a LINKED worktree (a lane checkout removed when the lane ends) cannot be shown' "$d"
            else
                printf 'it is inside a git checkout (%s) but git is not on PATH, so whether it is a LINKED worktree (a lane checkout removed when the lane ends) cannot be shown — install git, or point ORCH_SUPERVISOR at a farmed copy outside any checkout' "$d"
            fi
            return 0
        fi
        return 0
    fi
    case "$dirs" in *' linked') ;; *) return 0 ;; esac
    # ⛔ "LINKED" WITH NO NAME IS STILL LINKED. The two rev-parse calls already disagreed with the plain-clone
    # arithmetic, so an unnamed top level is a worktree we cannot spell — not a reason to admit it.
    # ⛔ THE SAME SCRUB AS `git_dirs` (re-review P1). `git_dirs` already decided this is a LINKED worktree with
    # the ambient selection removed, so the branch/detached question — the one that IS the rule — must be asked
    # the same way. Unscrubbed, an exported pair redirected both reads to the pin and the guard armed the lane.
    top="$("${GIT_SCRUB[@]}" git -C "$d" rev-parse --show-toplevel 2>/dev/null)"
    if [ -z "$top" ]; then
        printf 'it is inside a LINKED GIT WORKTREE that git reported but could not name (its git-dir and common-dir already disagreed, and `rev-parse --show-toplevel` then failed) — a lane checkout removed when the lane ends'
        return 0
    fi
    # ⛔ THE BRANCH, NOT THE WORKTREE (review-3 P1). A detached HEAD is the shape the cells' pin has; a symbolic
    # HEAD is a branch — unmerged work a lane removes when it lands.
    if "${GIT_SCRUB[@]}" git -C "$d" symbolic-ref -q HEAD >/dev/null 2>&1; then
        printf '%s|branch\n' "$top"
    else
        printf '%s|detached\n' "$top"
    fi
    return 0
}

# path_under <path> <root> — true when <path> IS <root> or inside it. Both already resolved by canon_dir.
path_under() {
    local p="${1%/}" r="${2%/}"
    [ -n "$r" ] && [ "$r" != "/" ] || return 1
    case "$p" in "$r"|"$r"/*) return 0 ;; esac
    return 1
}

# canon_file <path> — the physical path of a FILE. `canon_dir` resolves a DIRECTORY (and follows a symlinked
# leaf through realpath/readlink -f), but its last resort is `cd && pwd -P`, which a file cannot do — so on a
# box where neither `realpath` nor `readlink -f` answers, canon_dir reports EVERY file as unresolved and this
# guard would refuse a perfectly durable supervisor. That is a false block, so the fallback resolves the
# CONTAINING DIRECTORY and re-appends the name.
# ⛔ AND THE FALLBACK DOES NOT GET TO FAIL OPEN ON A SYMLINKED LEAF. Resolution is what sees through an alias
# (the measured #2666 escape: `ln -s /etc/systemd/system.control $T/alias` was ADMITTED by a literal match), so
# when the leaf IS a symlink and nothing here can follow it, the answer is "cannot prove" → the caller refuses.
canon_file() {
    local f="${1:-}" out d
    out="$(canon_dir "$f")"
    case "$out" in "$CANON_UNRESOLVED"*) ;; *) printf '%s\n' "$out"; return 0 ;; esac
    [ -L "$f" ] && { printf '%s\n' "$out"; return 0; }
    d="$(canon_dir "$(dirname "$f")")"
    case "$d" in "$CANON_UNRESOLVED"*) printf '%s\n' "$out"; return 0 ;; esac
    printf '%s/%s\n' "${d%/}" "$(basename "$f")"
}

# transient_root_of <resolved path> — the temporary root this path is under, or nothing.
# ⛔ `$TMPDIR` IS GRADED ON ITS OWN AND QUOTED, NEVER CONCATENATED INTO THE LOOP (re-review P3). Appended to
# `$TRANSIENT_ROOTS` it was WORD-SPLIT, so a temp root containing a space (a user-chosen TMPDIR is the common
# case on macOS) became two bogus roots that resolve nowhere and are `continue`d — leaving the box's real temp
# root ungraded by the one rule that exists to grade it. A fail-open on the list itself.
transient_root_of() {
    local p="${1:-}" d root=""
    for d in $TRANSIENT_ROOTS; do
        [ -n "$d" ] || continue
        d="$(canon_dir "$d")"
        case "$d" in "$CANON_UNRESOLVED"*) continue ;; esac
        path_under "$p" "$d" && { root="$d"; break; }
    done
    if [ -z "$root" ] && [ -n "${TMPDIR:-}" ]; then
        d="$(canon_dir "$TMPDIR")"
        case "$d" in
            "$CANON_UNRESOLVED"*) ;;
            *) path_under "$p" "$d" && root="$d" ;;
        esac
    fi
    [ -n "$root" ] && printf '%s\n' "$root"
    return 0
}

# primary_clone_root <dir> — true when <dir> is the MAIN checkout of a git work tree (not a linked worktree):
# the shape a deployment has, and the shape `/tmp/cell-ai` has on every cell.
primary_clone_root() {
    local dirs
    dirs="$(git_dirs "${1:-}")"
    [ -n "$dirs" ] || return 1
    case "$dirs" in *' main') return 0 ;; esac
    return 1
}

# primary_clone_on_lane_branch <dir> — prints the branch name when <dir> is a primary clone checked out on a
# branch that is NOT the clone's default. Empty output + rc 1 when it is on the default (or detached).
# ⛔ BEING A CLONE IS NOT BEING MERGED (cycle-6 P2, MEASURED). `primary_clone_root` is git's main-vs-linked
# arithmetic only — it never asks the branch question that `linked_worktree_root` applies to linked
# worktrees — so a lane that isolates by CLONING instead of `git worktree add` was admitted under a transient
# root, and `cloud-cell-bringup.sh` injects `AGENT_INFRA_PATH=$LAYER_ROOT` itself, so the declaration could be
# the caller's own clone. Reproduced: `/tmp/<fixture>/lane-clone` on `master`-less `lane/x` with
# `AGENT_INFRA_PATH` naming it rendered an ExecStart into it, rc=0. A clone at the DEFAULT branch is a
# deployment (`/tmp/cell-ai` on `main` must keep working); a clone on any other branch is unmerged work a
# lane removes, which is the rule this guard already states in words for every other shape.
# ⛔ NAMED RESIDUAL — THIS HELPER IS ONLY ASKED ABOUT A CLONE UNDER A TRANSIENT ROOT (review-9 P2, MEASURED).
# Both call sites sit AFTER `scratch_supervisor_reason`'s `[ -n "$root" ] || return 1`, which returns "durable"
# for a path outside every temporary root before any clone rule is consulted. So a PRIMARY clone under a
# durable root (`~/agent-infra`) checked out on a lane branch is ADMITTED. That is the same walk that keeps
# linked worktrees refused *wherever* they live, so the asymmetry is deliberate rather than an oversight: a
# linked worktree is removed with `worktree remove` the moment its lane ends, whereas a durable primary clone
# is a checkout the operator owns and keeps — the thing #2697 is about is a PATH THAT DISAPPEARS, and a
# durable path does not. The pin records which revision such a unit then runs. Stated here, and in
# `docs/ops/controller-service.md`, rather than claimed closed.
primary_clone_on_lane_branch() {
    local b def ref rc
    b="$("${GIT_SCRUB[@]}" git -C "${1:-}" symbolic-ref -q --short HEAD 2>/dev/null)" || b=""
    if [ -z "$b" ]; then
        # ⛔ A DETACHED CLONE IS NOT THE DEPLOYMENT SHAPE EITHER (cycle-8 P2, MEASURED — a pre-existing
        # FAIL-OPEN that admitted the #2697 class). The line here used to be `[ -n "$b" ] || return 1` with the
        # comment "detached: no branch to be unmerged at", so a lane that isolates by CLONING and then detaches
        # at a PR head (`git clone … && git checkout <pr-head>`) was ADMITTED under a transient root — an
        # ExecStart naming a path a cleaning removes. A deployment clone is checked out on its default branch;
        # the fleet's only legitimately detached checkout is the harness PIN, which the bring-up creates with
        # `git worktree add --detach` (`cloud-cell-bringup.sh:1588`) and which `linked_worktree_root` grades
        # before this helper is ever consulted — so a detached PRIMARY clone has no admitted deployment shape.
        # Ancestry is the question that can be asked here because there is no name to grade: contained in the
        # default ref = the deployment's revision (admitted); not contained = a PR head (refused).
        # ⛔ AND THE GRADED REF IS NOT "THE DEFAULT BRANCH" — it is the LOCAL `refs/remotes/origin/HEAD` symref,
        # which `git clone` derives from the remote and the caller can rewrite. This guard is an accident guard
        # (see docs/ops/controller-service.md), not a boundary against a caller who rewrites its own refs.
        def="$("${GIT_SCRUB[@]}" git -C "${1:-}" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" || def=""
        def="${def#origin/}"
        # No default ref to compare against: nothing to prove it against. Named residual, disclosed in the doc.
        [ -n "$def" ] || return 1
        ref="refs/remotes/origin/$def"
        "${GIT_SCRUB[@]}" git -C "${1:-}" rev-parse --verify -q "$ref" >/dev/null 2>&1 || return 1
        rc=0
        "${GIT_SCRUB[@]}" git -C "${1:-}" merge-base --is-ancestor HEAD "$ref" >/dev/null 2>&1 || rc=$?
        [ "$rc" -eq 0 ] && return 1                       # contained: the deployment's own revision
        # ⛔ TRI-STATE, NOT A BOOLEAN. `merge-base --is-ancestor` exits 1 for "no" and 128 for "git could not
        # answer"; folding 128 into "not an ancestor" would print a confident verdict git never gave. A read that
        # cannot be made is CANNOT PROVE, and this file's rule for that is refuse, never admit.
        if [ "$rc" -eq 1 ]; then
            printf 'detached-at-unmerged|%s\n' "$("${GIT_SCRUB[@]}" git -C "${1:-}" rev-parse --short HEAD 2>/dev/null)"
        else
            printf 'detached-unproven|%s\n' "$("${GIT_SCRUB[@]}" git -C "${1:-}" rev-parse --short HEAD 2>/dev/null)"
        fi
        return 0
    fi
    case "$b" in main|master) return 1 ;; esac
    def="$("${GIT_SCRUB[@]}" git -C "${1:-}" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" || def=""
    def="${def#origin/}"
    [ -n "$def" ] && [ "$b" = "$def" ] && return 1
    printf 'branch|%s\n' "$b"
    return 0
}

# scratch_supervisor_reason <resolved supervisor> — prints WHY this path is not boot-durable, or nothing
# when it is. Takes the RESOLVED path: a symlink is a spelling, and `ln -s /tmp/wt-x $HOME/sup` must be
# refused for the same reason the #2666 unit-dir guard resolves before it grades.
scratch_supervisor_reason() {
    local p="${1:-}" d root="" declared="" shape="" pin="" tree="" base="" held="" b="" pin_ok=0 name_ok=0
    shape="$(lane_scratch_shape "$p")"
    if [ -n "$shape" ]; then
        printf 'it matches the lane-scratch shape %s — a checkout a lane removes when it ends, whose branch is merged nowhere' "$shape"
        return 0
    fi
    d="$(linked_worktree_root "$p")"
    case "$d" in
        '') ;;                       # not in any git work tree at all (a farmed copy): nothing to refuse here
        *'|detached')
            # ⛔ DETACHED IS NOT ENOUGH — IT MUST BE THE PIN THIS BOX RECORDS (review-4 P1, measured). The
            # fleet's drainer builds a lane's scratch as a DETACHED worktree under `$HOME` and deletes it when
            # the lane ends, so admitting any detached worktree re-opened the #2697 class.
            # ⛔ AND "UNDER THE PIN ROOT" ALONE IS DEFEATED BY THE VARIABLE THAT NAMES THE ROOT (cycle-3 P1,
            # MEASURED — an ambient-env bypass, not doc drift). `pin_root_of_this_box` falls back to
            # `HARNESS_PIN_DIR`, so `HARNESS_PIN_DIR=$HOME` made ALL of `$HOME` a pin root and re-admitted the
            # ordinary drainer scratch: reproduced on a primary clone with `git worktree add --detach
            # $HOME/wt-drainer-x`, `ORCH_SUPERVISOR` on it — refused when the variable was unset, ARMED with the
            # unit naming `ExecStart=…/wt-drainer-x/scripts/cloud-cell-supervisor.sh` when it was `$HOME`. That
            # contradicts `docs/ops/controller-service.md` ("every other detached worktree is refused"), so the
            # TREE ITSELF is graded now, not just its prefix: it must be a PIN TREE — `<pin>/<commit>` as
            # `cloud-cell-bringup.sh` builds it (`git worktree add --detach "$HARNESS_PIN_DIR/$sha"`) — or be
            # exactly the root this box records (the bring-up also accepts a pin that IS the root, when that
            # path is already a worktree of the repo).
            # ⛔ AND A NAME, OR A DECLARATION, IS NOT A PIN (cycle-4 P1, MEASURED — my own previous claim here
            # was OVERBROAD and is corrected by this). Naming and declaring are both CALLER-CONTROLLED inputs, so
            # grading them alone defended nothing: measured on a primary clone, the unit was ARMED for
            #   HARNESS_PIN_DIR=$HOME        + a scratch at `$HOME/<40-hex>`        (the hex basename alone won),
            #   HARNESS_PIN_DIR=<scratch>    + that scratch                      (the equality arm alone won), and
            #   HARNESS_PIN_FILE=<a file naming <scratch>/scripts/orchestrator-harness>  (any directory a record
            #                                                                   names became "the pin").
            # Every one of those is the drainer scratch #2697 exists to refuse. So the tree must now ALSO
            # CORROBORATE ITSELF the way the bring-up corroborates a pin — `cloud-cell-bringup.sh` refuses to
            # call anything its harness pin unless it carries `scripts/orchestrator-harness/orch-loop.sh`
            # ("this is not a harness tree, and a controller started from it would exit at once"). That is a
            # property of the TREE, so it cannot be produced by naming a scratch cleverly, and it is exactly
            # the condition every real pin already satisfies — so it blocks no deployment.
            # ⛔ CORRECTION TO THE PARAGRAPH ABOVE (cycle-5 P1, MEASURED): carrying `orch-loop.sh` is NECESSARY
            # AND NOT SUFFICIENT, so on its own it corroborated nothing. Every real checkout of this repo carries
            # `scripts/orchestrator-harness/orch-loop.sh` — and a lane/drainer scratch IS such a checkout
            # (`ai-drainer.sh`: `git worktree add -f … "$SEED_REF"`), so the missing-file test admitted exactly the
            # scratch it was written to reject: with it present, `HARNESS_PIN_DIR=<scratch>` armed the unit. The
            # discriminating corroboration is the one applied below — the tree's NAME must be a prefix of the
            # commit the tree actually HOLDS — and the flat-pin arm's residual is stated there.
            pin="$(pin_root_of_this_box)"
            tree="${d%|detached}"
            base="$(basename "$tree")"
            # ⛔ THE NAME MUST AGREE WITH THE TREE IT NAMES (cycle-5 P1, MEASURED — this is the arm that did not
            # exist). Being hex was never corroboration: a drainer scratch can be created with any name, and the
            # hex test therefore admitted `$HOME/<40-hex>` and `<exported pin root>/<40-hex>` for a tree holding
            # a DIFFERENT commit. A pin is created by the bring-up as `git worktree add --detach "$pin_dir/$sha"`,
            # so the only thing a real pin guarantees is that its basename is the commit it actually holds. That
            # is a property of the TREE (it is read from the tree), not of the caller's environment, so no naming
            # can manufacture it: the name must be a prefix of the `rev-parse HEAD` OF THIS TREE.
            held="$("${GIT_SCRUB[@]}" git -C "$tree" rev-parse HEAD 2>/dev/null)" || held=""
            if [ -n "$held" ] && [ "${#base}" -ge 7 ] && [ "${#base}" -le 40 ]; then
                case "$base" in
                    *[!0-9a-f]*) ;;           # not a commit id at all: a lane scratch is named by its lane
                    *) case "$held" in "$base"*) name_ok=1 ;; esac ;;
                esac
            fi
            if [ "$name_ok" -eq 1 ]; then
                pin_ok=1
            elif [ "${tree%/}" = "${pin%/}" ]; then
                # ⛔ THE LEGACY FLAT PIN, AND ITS NAMED RESIDUAL (cycle-5 P1). When the pin ROOT is itself the
                # worktree (`cloud-cell-bringup.sh`'s `_pin_is_worktree_of "$HARNESS_PIN_DIR"`, the pre-sha
                # layout) there is no commit name to corroborate, so equality with the pin root is the only
                # signal. The pin root is located by the box's record and its `HARNESS_PIN_DIR`/`HARNESS_PIN_FILE`
                # overrides, which a caller CAN set — so a caller that declares its own scratch as the pin root
                # still arms it. That is accepted, not claimed closed, for the same reason `CELL_HOME`/`HOME`
                # are trusted below: those overrides are how a real box relocates its pin, and refusing them
                # would false-block every cell whose pin is not at the default path. It is an ACCIDENT guard
                # (the #2697 shape was an operator installing from a lane worktree with nothing exported), not
                # a boundary against an operator who deliberately declares a scratch as its pin — that operator
                # can write the unit anyway. Stated here so the claim and the code agree.
                pin_ok=1
            fi
            [ "$pin_ok" -eq 1 ] && [ ! -f "$tree/scripts/orchestrator-harness/orch-loop.sh" ] && pin_ok=0
            if [ "$pin_ok" -ne 1 ] || ! path_under "$tree" "$pin"; then
                printf 'it lives in a DETACHED GIT WORKTREE %s that is NOT the harness pin this box records (%s) — a pin is a TREE named for the commit it holds (`<pin dir>/<sha>`, what the bring-up creates with `git worktree add --detach`) or the recorded pin root itself, AND it carries `scripts/orchestrator-harness/orch-loop.sh`, which is what the bring-up demands of a pin; this one is named `%s`%s, and the fleet drainer builds a lane scratch checkout exactly like it and removes that with `worktree remove` when the lane ends' "$tree" "$pin" "$base" "$([ -f "$tree/scripts/orchestrator-harness/orch-loop.sh" ] && printf '' || printf ' and carries no harness tree')"
                return 0
            fi ;;
        *'|branch')
            printf 'it lives in the LINKED GIT WORKTREE %s, which is checked out on a BRANCH — a lane checkout that is removed when that lane ends, and whose branch is merged nowhere (a pin is DETACHED at a commit; a branch is unmerged work)' "${d%|branch}"
            return 0 ;;
        *)                           # a REASON sentence from linked_worktree_root (unproven, or linked-but-unnamed)
            printf '%s' "$d"
            return 0 ;;
    esac
    root="$(transient_root_of "$p")"
    [ -n "$root" ] || return 1      # not under any temporary root: durable wherever it is
    # ⛔ A DECLARATION IS NOT A SIGNATURE (re-review P1). A reviewer measured the escape: the bring-up passes
    # `AGENT_INFRA_PATH=$LAYER_ROOT`, and the layer may BE the lane's own checkout, so a caller could declare
    # the scratch path it wanted armed (`/tmp/<fixture>/wt-2433-fu/…` matches no name pattern, and a plain
    # copy is not a git worktree, so neither of the checks above sees it). Only the two roots that ARE the
    # box's persistent surface may declare a temporary path unconditionally: `HOME` and `CELL_HOME` — the
    # cells' `/tmp/cell-home` is exactly that, recreated by bring-up. Any OTHER declared root (today that is
    # `AGENT_INFRA_PATH`, the cell's `/tmp/cell-ai` checkout) must itself be durable, or be a PRIMARY git
    # clone: a clone is a deployment, a loose directory of copied scripts under /tmp is a lane's scratch.
    # ⛔ NAMED RESIDUAL (re-review P3): `HOME` and `CELL_HOME` are TRUSTED BY DESIGN, not graded. A caller
    # that exports `CELL_HOME=/tmp/scratch` can therefore arm a path under it — the same laundering §P7
    # closes for `AGENT_INFRA_PATH`, one env var over. It is accepted rather than fixed because grading them
    # would be a FALSE BLOCK on every cell: a cell's home IS `/tmp/cell-home` (transient, not a git clone, not
    # the passwd home), so any rule that demanded durability of it would refuse every bring-up — the exact
    # class `runner_autoscale.py` records. A box's own home is the one root where "temporary" is the design,
    # so the escape is stated here instead of being claimed closed.
    local ch hm
    ch="$(canon_dir "$CELL_HOME")"; case "$ch" in "$CANON_UNRESOLVED"*) ch="" ;; esac
    hm="$(canon_dir "$HOME")";      case "$hm" in "$CANON_UNRESOLVED"*) hm="" ;; esac
    for d in "$CELL_HOME" "$HOME" "${AGENT_INFRA_PATH:-}"; do
        [ -n "$d" ] || continue
        d="$(canon_dir "$d")"
        case "$d" in "$CANON_UNRESOLVED"*) continue ;; esac
        path_under "$p" "$d" || continue
        if [ "$d" = "$ch" ] || [ "$d" = "$hm" ]; then declared="$d"; break; fi
        if [ -z "$(transient_root_of "$d")" ] || { primary_clone_root "$d" && ! primary_clone_on_lane_branch "$d" >/dev/null; }; then declared="$d"; break; fi
        # ⛔ A CLONE ON AN UNMERGED BRANCH IS A LANE CHECKOUT (cycle-6 P2, MEASURED — see the helper). This is
        # the one shape the branch rule was not applied to, and the caller can make the declaration itself.
        # Cycle-8 P2 added the DETACHED shape (`primary_clone_on_lane_branch` prints one of three kinds), and
        # each kind gets its own sentence: a refusal that names a branch on a DETACHED checkout asserts
        # something git never said, which is the class of defect this file keeps removing.
        if b="$(primary_clone_on_lane_branch "$d")" && [ -n "$b" ]; then
            case "$b" in
                branch\|*)
                    printf 'it is under %s, and the root that declares it is a PRIMARY git clone checked out on the BRANCH %s — a clone at the default branch is a deployment, a clone on any other branch is unmerged work a lane removes (a lane that isolates by cloning instead of `git worktree add` lands here), and being a clone is not being merged' \
                        "$root" "${b#branch|}" ;;
                detached-at-unmerged\|*)
                    printf 'it is under %s, and the root that declares it is a PRIMARY git clone on a DETACHED HEAD (%s) that its default branch does NOT contain — a deployment clone is checked out on its DEFAULT branch, and a detached checkout at a commit the default branch does not carry is a PR head a lane removes (a lane that isolates by cloning and then detaches lands here); check the clone out on its default branch, or name the farm or the harness pin' \
                        "$root" "${b#detached-at-unmerged|}" ;;
                detached-unproven\|*)
                    printf 'it is under %s, and the root that declares it is a PRIMARY git clone on a DETACHED HEAD (%s) whose containment CANNOT BE PROVEN — git could not answer `merge-base --is-ancestor` against this clone'\''s default ref, and cannot-prove is refused rather than admitted; check the clone out on its default branch, or name the farm or the harness pin' \
                        "$root" "${b#detached-unproven|}" ;;
                *)
                    printf 'it is under %s, and the root that declares it is a PRIMARY git clone holding work a lane removes (%s)' \
                        "$root" "$b" ;;
            esac
            return 0
        fi
    done
    [ -z "$declared" ] || return 1
    printf 'it is under %s, which a reclaim or a tmp cleaner removes (systemd-tmpfiles --clean drops /tmp entries once they age out of this box'\''s window — 30 days on the fleet'\''s Ubuntu/systemd-255 image, 10 on others), and none of the deployment roots this box declares ACCEPTS it — a root may declare a temporary path only when it is itself durable or a primary git clone (CELL_HOME=%s, HOME=%s%s)' \
        "$root" "$CELL_HOME" "$HOME" "${AGENT_INFRA_PATH:+, AGENT_INFRA_PATH=$AGENT_INFRA_PATH}"
    return 0
}

SUPERVISOR=""
resolve_supervisor() {
    # ⛔ TWO KINDS OF CANDIDATE, AND THE DIFFERENCE IS WHO DECIDED (agent-infra#2697). `ORCH_SUPERVISOR`
    # is the OPERATOR's requirement for this box — a non-durable one is REFUSED, never silently swapped for
    # something else, because the operator named exactly what the unit should run. `ORCH_SUPERVISOR_PREFER`
    # is a CALLER's preference: `cloud-cell-bringup.sh` names the layer checkout it has just installed, so
    # the unit runs the layer's code rather than a possibly-stale farm (that call site's recorded reason).
    # On a durable checkout the preference is honoured unchanged; on a LANE WORKTREE — the measured #2697
    # shape — it is SKIPPED with a loud note instead of arming a unit at a path a lane reaps. What counts as
    # durable still has exactly ONE owner (this guard), so the two call sites cannot drift apart.
    local c r why hard i beside pin_sup
    local -a cands candk
    beside="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/cloud-cell-supervisor.sh"
    # ⛔ THE HARNESS PIN IS THE THIRD KIND OF CANDIDATE, AND IT IS THE ONE THE REFUSAL ALREADY RECOMMENDS
    # (review-8 P1, MEASURED). Preference strength, like the layer: it is the box's own pinned revision, not an
    # operator's named requirement, so an unusable pin is skipped loudly rather than aborting. It sits BEFORE
    # the two farm candidates because a pin is this cell's revision and the farm is a possibly-stale copy of
    # another box's; it sits AFTER the layer preference because the layer is the code this bring-up just
    # installed. Placed after `beside` only in the `cands` literal sense — the ORDER of the loop is what
    # decides, so index 2 is the pin and the two farm paths follow it.
    pin_sup="$(pin_supervisor_of_this_box 2>/dev/null | head -1)"
    cands=( "${ORCH_SUPERVISOR:-}" "${ORCH_SUPERVISOR_PREFER:-}" "$pin_sup" \
            "$HOME/.pi/agent/scripts/cloud-cell-supervisor.sh" "$beside" )
    candk=( 1 0 0 0 0 )
    for i in 0 1 2 3 4; do
        c="${cands[$i]}"; hard="${candk[$i]}"
        # ⛔ AN OPERATOR'S REQUIREMENT THAT DOES NOT EXIST IS REFUSED, NEVER SILENTLY SWAPPED (re-review P2).
        # The candidate loop used to `continue` on a missing path for BOTH strengths, so
        # `ORCH_SUPERVISOR=<typo or moved checkout>` armed the farmed copy and printed nothing — the
        # "merged ≠ running" class this seam exists to surface, reintroduced by the fallthrough itself.
        # A broken symlink and a directory land here too (`-f` is false for both), which is correct: neither
        # can be the unit's ExecStart.
        if [ "$hard" = 1 ] && [ -n "$c" ] && [ ! -f "$c" ]; then
            err "REFUSING: ORCH_SUPERVISOR=$c is not a readable file, so the supervisor the operator named cannot be the unit's ExecStart."
            err "  It is NOT silently replaced by another copy: a requirement swapped for whatever happened to be farmed is exactly"
            err "  the merged-not-running class this seam surfaces (agent-infra#2697). Fix the path, or unset ORCH_SUPERVISOR to accept"
            err "  the defaults (the farm, then beside this installer)."
            return 1
        fi
        [ -n "$c" ] && [ -f "$c" ] || continue
        # ⛔ THE VALUE THE UNIT NAMES IS THE VALUE THAT WAS GRADED — resolved, not as spelled, for the same
        # reason `systemd_unit_dir_refusal` grades the resolved unit directory: otherwise the guard and the
        # ExecStart line can describe two different files whenever either path has a symlink in it.
        r="$(canon_file "$c")"
        case "$r" in
            "$CANON_UNRESOLVED"*)
                err "REFUSING: cannot resolve '$c' to a physical path, so whether the unit's ExecStart would survive a cleaning cannot be shown — a broken symlink and a directory this user cannot read both look like this. Point ORCH_SUPERVISOR at a readable, resolved path."
                return 1 ;;
        esac
        # ⛔ A PATH THIS TEMPLATE CANNOT CARRY IS REFUSED, NOT RENDERED (re-review P2, measured). The template
        # renders `Environment=ORCH_SUPERVISOR_PIN=…` and `ExecStart=/bin/bash {{SUPERVISOR}} start` UNQUOTED,
        # so systemd splits on whitespace: a checkout at `…/home/sp ace` rendered a unit whose pin assignment
        # systemd DROPPED ("Invalid environment assignment, ignoring: ace@…") and whose ExecStart named a path
        # that is not there — while `verify_unit`'s exact-line `grep -qxF` PASSED on the raw text. That is the
        # false-PASS shape this file keeps ruling out, so the render refuses and the operator moves the
        # checkout instead of silently shipping a unit systemd reads differently than the installer does.
        # ⛔ AND THE UNQUOTED SPLIT IS NOT THE ONLY WAY SYSTEMD REWRITES THIS LINE (cycle-2 P2, MEASURED). `%`
        # is a SPECIFIER prefix and `$` starts a VARIABLE EXPANSION in a command line, and both apply to the
        # rendered text: `systemd-analyze verify` on `Environment=ORCH_SUPERVISOR_PIN=/tmp/a%x/repo@abc`
        # reports "Failed to resolve specifiers in PIN=/tmp/a%x/repo@abc, ignoring: Invalid slot" — the pin
        # assignment is DROPPED exactly as the whitespace case drops it — while `verify_unit`'s `grep -qxF`
        # still passes, and `systemd-analyze` refuses to even grade an ExecStart whose path contains `%`.
        # A checkout under such a path therefore renders an artifact systemd reads differently than this
        # installer does, so it is refused for the same reason rather than silently shipped.
        # ⛔ AND THE QUOTING META‑CHARACTERS ARE A THIRD SPELLING (cycle-3 P2, MEASURED). systemd parses these
        # two unquoted lines with its own word splitter, which STRIPS single quotes and interprets `\`: a
        # supervisor under `…/ag'in'fra/…` installed with rc=0 and an ExecStart naming `…/aginfra/…`, which
        # `systemd-analyze verify` then rejected as "not executable" (an unpaired quote gives "Unbalanced
        # quoting, ignoring"; a backslash gives "Ignoring unknown escape sequences") — the same false PASS the
        # whitespace arm closes, one character class over. `verify_unit`'s `grep -qxF` still matches the raw
        # text either way, so the render refuses them too.
        case "$r" in
            *[[:space:]]*|*'"'*|*"'"*|*\\*|*%*|*'$'*)
                if [ "$hard" = 1 ]; then
                    err "REFUSING: the supervisor path '$r' contains whitespace, a quote, a backslash, '%' (a systemd specifier) or '$' (variable expansion), and this unit renders its environment and ExecStart UNQUOTED."
                    err "  systemd would split, strip, expand or drop that value, silently DROP the pin assignment and fail to exec the supervisor (measured:"
                    err "  'Invalid environment assignment, ignoring: …', 'Failed to resolve specifiers …, ignoring: Invalid slot' and an ExecStart whose quoted path is not executable), while the rendered text still looks right."
                    err "  Move the checkout to a path without spaces, quotes, a backslash, '%' or '$', or pass a supervisor that has none."
                    return 1
                fi
                err "note: NOT rendering ExecStart from $r — the path contains whitespace, a quote, a backslash, '%' or '$', which this unit renders unquoted and systemd would split, strip, expand or drop."
                continue ;;
        esac
        if why="$(scratch_supervisor_reason "$r")"; then
            if [ "$hard" = 1 ]; then
                err "REFUSING to render an ExecStart that will not survive this box: $r"
                err "  $why."
                err "  This is the agent-infra#2697 shape, and it fails SILENTLY: once that path is gone the unit's"
                err "  ExecStart cannot resolve, its start limit (3 attempts inside 300 s) is burned inside a minute,"
                err "  systemd converges it to 'failed' — and nothing pages. Every surface that asks reads a dead"
                err "  unit, while the fleet still believes this box has a supervisor."
                err "  Name a DURABLE supervisor instead, any one of:"
                # ⛔ THE REMEDY MUST NOT NAME A SHAPE THIS SAME GUARD REFUSES (review-7 P2, measured). Since
                # `primary_clone_on_lane_branch` landed, "a PRIMARY clone" is not sufficient — a clone on a LANE
                # branch is refused one branch over. An operator following the old wording landed back in the
                # refusal it was printed by, with no way to tell which of the two rules refused them.
                err "    ${AGENT_INFRA_PATH:-<checkout>}/scripts/cloud-cell-supervisor.sh  (a PRIMARY clone on its DEFAULT branch — not a worktree, and not a clone on a lane branch)"
                err "    $CELL_HOME/harness/<pin-sha>/scripts/cloud-cell-supervisor.sh   (the harness pin)"
                err "    $HOME/.pi/agent/scripts/cloud-cell-supervisor.sh        (the farm's PATH — see the warning below)"
                err "  ⛔ THE FARM *DOES* DELIVER THIS FILE AS OF THIS LANDING (#1938): 'cloud-cell-supervisor.sh' joined"
                err "    setup.sh's fleet_srcs, so 'bash pi-bootstrap/setup.sh' DOES create the .pi/agent/scripts"
                err "    path above. ⚠️ This line used to say the opposite, because the entry did not exist when it"
                err "    was written — so on a box installed by an OLDER setup.sh the farmed path may still be ABSENT:"
                err "    re-run the installer, or use one of the two entries above."
                err "  …or pass one explicitly: ORCH_SUPERVISOR=<that path> bash $0 --install"
                return 1
            fi
            # A PREFERENCE, not a requirement: say so loudly and fall through to the next candidate.
            err "note: NOT rendering ExecStart from $r — $why."
            err "  Falling through to the next durable candidate (the #2697 refusal, applied to a CALLER's"
            err "  preference: ORCH_SUPERVISOR_PREFER — an explicit ORCH_SUPERVISOR would have been refused)."
            continue
        fi
        SUPERVISOR="$r"
        break
    done
    [ -n "$SUPERVISOR" ] || {
        err "no DURABLE cloud-cell-supervisor.sh to render — looked at \$ORCH_SUPERVISOR, \$ORCH_SUPERVISOR_PREFER, the harness pin (\$CELL_HOME/harness), \$HOME/.pi/agent/scripts, and beside this installer."
        err "  A unit whose ExecStart a cleaning removes is not supervised: the start limit burns inside a minute,"
        err "  systemd converges it to 'failed', and nothing pages (agent-infra#2697). Name a durable copy:"
        err "    ORCH_SUPERVISOR=${AGENT_INFRA_PATH:-<checkout>}/scripts/cloud-cell-supervisor.sh bash $0 --install"
        err "  ⛔ 'bash pi-bootstrap/setup.sh' DOES create \$HOME/.pi/agent/scripts/cloud-cell-supervisor.sh —"
        err "    the supervisor IS farmed flat by setup.sh's fleet_srcs (#1938), so RE-RUN THE"
        err "    INSTALLER rather than naming a checkout copy by hand."
        err "  Durable roots this box declares: CELL_HOME=$CELL_HOME, HOME=$HOME${AGENT_INFRA_PATH:+, AGENT_INFRA_PATH=$AGENT_INFRA_PATH}"
        return 1
    }
    supervisor_pin
}

# ⛔ RECORD THE REVISION THE UNIT WILL RUN, NOT JUST THE PATH (agent-infra#2697, third bullet). The other
# half of the measured defect was that NOTHING recorded which code a box executes: cell-4's farmed copy was
# sha 9228492e… of Oct 23 while `main` was 1680457a…, and the only way to learn that was `git -C` guessing
# at a path the unit merely names. Rendered into the unit's ENVIRONMENT it is readable from
# `systemctl show eldato-orchestrator -p Environment` and from `--status`, and the controller process
# inherits it, so "which revision is this box running" stops being an inference.
# ⛔ IT IS AN OBSERVATION, NOT A GATE: a supervisor outside any git work tree (a farmed copy, an unpacked
# tarball) is legitimate and records `unknown@unknown`. Refusing it would be a false block on the shape the
# farm actually produces, and this installer must never withhold a supervisor over a diagnostic.
# ⛔ AND IT IS THE REVISION THE UNIT WILL **BOOT**, NOT A CLAIM ABOUT A LIVE PROCESS (re-review P2). `--install`
# re-renders but deliberately does not restart a healthy unit (see do_install), so after a checkout advances
# this value names the bytes the NEXT start executes; a running controller can still be on the previous ones
# until it restarts. Read it as "what this box will boot", which is what it measures.
SUPERVISOR_PIN=""
supervisor_pin() {
    local dir repo="" sha="" gd named="" dirty="" dirt_rc=0 rel="" want="" got=""
    dir="$(dirname "$SUPERVISOR")"
    # ⛔ THE PIN NAMES A REPO THAT ACTUALLY CARRIES THIS FILE (re-review P2, measured). `git -C <dir> rev-parse`
    # answers the nearest ENCLOSING work tree, whether or not it has anything to do with the supervisor: a farmed
    # copy under a `$HOME` that is itself a repository (the ordinary dotfiles layout) recorded a confident
    # `<home>@<sha>` — a PLAUSIBLE WRONG answer to "which code does this unit run", which is worse than none
    # because it reads as proof. So when git NAMES a top level, that work tree must actually TRACK this file;
    # otherwise the pin is `unknown@unknown`.
    if command -v git >/dev/null 2>&1; then
        # ⛔ THE SAME SCRUB AS `git_dirs` (re-review P2): an exported GIT_DIR would make the pin describe the
        # HUB instead of the code the unit runs — a diagnostic that lies is worse than none.
        named="$("${GIT_SCRUB[@]}" git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || named=""
        if [ -n "$named" ]; then
            "${GIT_SCRUB[@]}" git -C "$dir" ls-files --error-unmatch -- "$SUPERVISOR" >/dev/null 2>&1 \
                && repo="$named"
        else
            # ⛔ AND A BARE-CONFIGURED PRIMARY CLONE HAS NO TOP LEVEL TO NAME (re-review P3, measured: this
            # fleet's `/tmp/cell-ai` is `core.bare=true`, so `--show-toplevel` fails while `HEAD` answers). The
            # documented pin is `<repo>@<sha>` and `unknown@unknown` is reserved for "outside any git work tree",
            # so falling back to the git dir is the difference between a usable pin and a diagnostic that is
            # empty precisely on the cells' own shape. `<...>/.git` is stripped when it is a suffix. This arm is
            # deliberately NOT held to the tracking test above: a `core.bare` clone has no work tree and no
            # index for `ls-files` to answer from, and §P3 pins that shape's `<repo>@<sha>`.
            gd="$("${GIT_SCRUB[@]}" git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" || gd=""
            case "$gd" in
                */.git) repo="${gd%/.git}" ;;
                *) repo="$gd" ;;
            esac
        fi
        if [ -n "$repo" ]; then
            sha="$("${GIT_SCRUB[@]}" git -C "$dir" rev-parse HEAD 2>/dev/null)" || sha=""
            # ⛔ A DIRTY WORK TREE MAKES THE RECORDED SHA A CONFIDENT WRONG ANSWER (review-7 P2, MEASURED).
            # `HEAD` describes the COMMIT; it does not describe the BYTES. With the tracked
            # `scripts/cloud-cell-supervisor.sh` hand-edited in the work tree, the install rendered
            # `…/repo@<sha>` while the file the unit executes was a different blob — the pin asserting "the
            # unit boots <sha>" about bytes that are not `<sha>`. That is the same PLAUSIBLE WRONG answer this
            # function already rejects for the dotfiles case, and the repo holds the opposite rule for exactly
            # this question: `cloud-cell-supervisor.sh::stamp_write` reads the dirty bit LIVE and refuses to
            # record a provenance stamp it cannot trust (`agentInfraDirty` exists because "its commit does not
            # describe its bytes"). So the pin says so.
            # ⛔ SCOPED TO THE SUPERVISOR FILE, not the whole tree. An unrelated dirty file (the ordinary state
            # of a working checkout) does not change what this unit executes, and flagging it would make the
            # pin cry wolf until operators learned to ignore it — the diagnostic would be dead.
            # ⛔ AND THE CORROBORATION IS OBJECT-LEVEL, NOT A WORK-TREE `status` (review-8 P2, MEASURED — my own
            # previous version of this block was a FALSE PASS on the shape the fleet actually runs). The dirty
            # read was guarded by `[ -n "$named" ]`, i.e. it only ran when git NAMED a top level — and this
            # fleet's `/tmp/cell-ai` is `core.bare=true`, so `--show-toplevel` fails there and the read was
            # SKIPPED. A hand-edited supervisor on a cell therefore recorded a confident `<repo>@<sha>`, which
            # is exactly the wrong answer this block exists to stop, on the one checkout operators patch in
            # place. No arm could see it (`core.bare` was only ever exercised CLEAN).
            # So the question is asked the way it can always be answered: hash the FILE BYTES and compare them
            # with the blob `HEAD` holds for that path. That needs no work tree and no index, so it answers
            # identically on a bare-configured clone, a normal checkout, and one where the file is not tracked
            # at all (where the tree read fails and the pin degrades — fail-closed).
            rel="${SUPERVISOR#"$repo"/}"
            want="$("${GIT_SCRUB[@]}" git -C "$dir" rev-parse "HEAD:$rel" 2>/dev/null)" || dirt_rc=1
            got="$("${GIT_SCRUB[@]}" git -C "$dir" hash-object -- "$SUPERVISOR" 2>/dev/null)" || dirt_rc=1
            if [ "$dirt_rc" -ne 0 ] || [ -z "$want" ] || [ -z "$got" ]; then
                dirt_rc=1
            elif [ "$want" != "$got" ]; then
                dirty=1
            fi
        fi
    fi
    case "$sha" in ''|*[!0-9a-f]*) sha="unknown" ;; esac
    # ⛔ THE DERIVED `<repo>` IS CHARACTER-GRADED TOO (cycle-6 P3, MEASURED — a FALSE PASS in the pin this PR
    # adds). The reasoning a few lines above holds for `--show-toplevel`, which is always an ANCESTOR of the
    # already character-checked supervisor path — it does NOT hold for the `--absolute-git-dir` fallback, which
    # can answer a path outside the tree (a `.git` pointer at a bare gitdir). Measured:
    # `SUPERVISOR_PIN=[/tmp/<fixture>/bare dir.git@unknown]` rendered as
    # `Environment=ORCH_SUPERVISOR_PIN=/tmp/<fixture>/bare dir.git@unknown`, which systemd drops as an invalid
    # assignment — while `verify_unit`'s `grep -qxF` matched the RAW TEXT and passed. So the unit ships with no
    # pin and the gate that exists to notice says OK. The pin is an OBSERVATION, never a gate, so degrading it
    # to `unknown@unknown` costs nothing and keeps the diagnostic honest.
    # ⛔ THE DERIVED `<repo>` NEEDS NO CHARACTER GRADE OF ITS OWN — AND THE ONE THAT USED TO SIT HERE WAS DEAD
    # CODE THAT ALSO SHIPPED AN UNDOCUMENTED SPELLING (review-9 P2, MEASURED). The cycle-6 grade existed because
    # `--absolute-git-dir` can answer a path outside the tree; it emptied `repo` and left `sha` holding a valid
    # `HEAD`, so the artifact read `unknown@<sha>` — a THIRD spelling this comment did not predict and
    # `docs/ops/controller-service.md` does not document (it promises `<repo>@<sha>` or `unknown@unknown`).
    # ⛔ AND DELETING IT LOSES NOTHING, because the byte read ABOVE already covers every shape that could reach
    # it. A `repo` containing whitespace, a quote, a backslash, `%` or `$` is exactly the class
    # `resolve_supervisor` refuses on the SUPERVISOR PATH, so there are only two cases and both are safe:
    #   (a) the supervisor lives under that `repo` -> its own path carries the character -> refused before this
    #       function is ever called;
    #   (b) it does not -> `rel` ABOVE stays ABSOLUTE, `rev-parse "HEAD:$rel"` fails, `dirt_rc=1`, and the whole
    #       pin degrades to `unknown@unknown` — the documented spelling.
    # Measured: an end-to-end fixture (a work tree whose `.git` file points at a bare gitdir under a SPACED path,
    # so `--show-toplevel` fails and `--absolute-git-dir` answers the spaced path) yields `unknown@unknown` with
    # the grade, without it, and with only its `repo` half — i.e. the grade never decided anything (an INERT
    # ENFORCER). §P3 pins that fixture end to end, so a regression that renders a spaced `<repo>` goes RED.
    [ -n "$repo" ] || repo="unknown"
    # ⛔ A SHA THAT CANNOT BE CORROBORATED IS NOT A SHA (review-7 P2). If the dirty read failed we cannot say
    # whether `<sha>` describes the bytes the unit boots, and recording it anyway is the confident-wrong-answer
    # shape above — so the whole pin degrades rather than shipping an unqualified revision. `+dirty` marks the
    # case we CAN see: HEAD resolves, but the executed file has local edits, so `<sha>` is the commit it was
    # forked from and not the code that runs. Both spellings stay parseable by the `--status` reader.
    if [ "$dirt_rc" -ne 0 ]; then
        SUPERVISOR_PIN="unknown@unknown"
    elif [ -n "$dirty" ]; then
        SUPERVISOR_PIN="${repo}@${sha}+dirty"
    else
        SUPERVISOR_PIN="${repo}@${sha}"
    fi
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
        -e "s|{{HOME}}|$(sed_esc "$CELL_HOME")|g" \
        -e "s|{{CELL_HOME}}|$(sed_esc "$CELL_HOME")|g" \
        -e "s|{{ENV_FILE}}|$(sed_esc "$ENV_FILE")|g" \
        -e "s|{{PATH}}|$(sed_esc "$PATH")|g" \
        -e "s|{{SUPERVISOR}}|$(sed_esc "$SUPERVISOR")|g" \
        -e "s|{{SUPERVISOR_PIN}}|$(sed_esc "$SUPERVISOR_PIN")|g" \
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
             "Environment=ORCH_SUPERVISOR_PIN=$SUPERVISOR_PIN" \
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
    # with a pid that was gone.
    # ⛔ AND THE RE-READ IS AN ALLOW-LIST, NOT A DENY-LIST (review P1, #2627). The first shape of this gate
    # refused only the words `failed` and `inactive`, which left TWO reachable green states:
    #   (a) an UNREADABLE manager read — `|| true` folded it into an empty word that matches neither, so the
    #       case fell through and the verdict printed `installed: … controller pid: <a pid read BEFORE the
    #       poll>`. That is the cannot-read shape this same file treats as FATAL elsewhere
    #       (`unit_active_state` returns 3 for it, :1220-1231), and it is caused by an expired `sudo -n`
    #       timestamp or a user-scope manager with no DBus (`cloud-cell-supervisor.sh:2303-2306`);
    #   (b) `activating` — with `Restart=always` + `RestartSec=15`, the moment a ticked-once loop exits the
    #       unit is `activating (auto-restart)`, NOT `failed`. `controller_proof` passes there on the DEAD
    #       incarnation's fresh heartbeat (its legs are `hb >= since` and `age <= 2*CYC`, neither of which
    #       asks who wrote it), the lock leg fails on the dead pid, `is-active` answers `activating`, the case
    #       fell through, and `--install` exited 0 — which `cloud-cell-bringup.sh` gates `CELL READY` on.
    # So the verdict accepts ONLY the active tier, and only together with a LIVE MainPID read AFTER the poll
    # (the `$pid` above is the pre-poll value; a restart inside the wait replaces it).
    # The accepted words are systemd's OWN active tier, which is exactly the set `systemctl is-active` exits 0
    # for (`systemctl-is-active.c::verb_is_active`: UNIT_ACTIVE, UNIT_RELOADING, UNIT_REFRESHING; the full
    # ActiveState vocabulary is `unit-def.c::unit_active_state_table`). `activating`/`deactivating`/
    # `maintenance`/`failed`/`inactive`/`unknown`/`not-found` and an empty (unreadable) answer are refusals.
    # ⛔ `unit_active_state` MUST NOT BE REUSED HERE: it maps `activating` to 0 on purpose, because that is
    # the right answer for the READS (`--status` reports a restarting unit as on its way) and the wrong one
    # for this verdict — the very distinction the `pre_active` gate above already draws.
    if controller_proof "$proof_since" "$proof_o"; then
        local _post_state _post_rc
        # keep the rc: `|| true` is what made an unreadable read indistinguishable from a healthy one
        if _post_state="$(sc_run is-active "$UNIT_NAME" 2>/dev/null)"; then _post_rc=0; else _post_rc=$?; fi
        if [ "$_post_rc" -ne 0 ] && [ -z "${_post_state:-}" ]; then
            err "cannot read whether $UNIT_NAME is active at the end of the proof wait — '$SC is-active' exited $_post_rc"
            err "  with no answer, so this install cannot say a controller is running (the cell may have no supervisor):"
            err "  a stale 'sudo -n' timestamp or a user-scope manager with no DBus answers exactly like this."
            err "  journalctl -u $UNIT_NAME -n 40"
            return 1
        fi
        case "$_post_state" in
            active|reloading|refreshing)
                # a word systemd calls active must not come with a failing rc: two contradictory answers are
                # not a proof, and picking the friendlier one is how a gate fails open
                [ "$_post_rc" -eq 0 ] || {
                    err "REFUSING: $UNIT_NAME answered '$_post_state' but '$SC is-active' exited $_post_rc — the read contradicts itself:"
                    err "  a state word is a proof only when the verb that printed it agrees."
                    return 1; } ;;
            activating|deactivating)
                err "REFUSING: $UNIT_NAME is '$_post_state' at the end of the proof wait — with Restart=always that is the"
                err "  RestartSec window after the loop exited, not a running controller: the proof passed on the DEAD"
                err "  incarnation's heartbeat (a heartbeat is not a controller, and this one's author is gone)."
                sc_run status "$UNIT_NAME" --no-pager 2>&1 | sed 's/^/  /' | head -20 >&2 || true
                err "  journalctl -u $UNIT_NAME -n 40"
                return 1 ;;
            *)
                err "REFUSING: $UNIT_NAME answered '${_post_state:-<no answer>}' at the end of the proof wait — that is not"
                err "  a running controller, whatever heartbeat the proof read (a heartbeat is not a controller)."
                sc_run status "$UNIT_NAME" --no-pager 2>&1 | sed 's/^/  /' | head -20 >&2 || true
                err "  journalctl -u $UNIT_NAME -n 40"
                return 1 ;;
        esac
        # ⛔ THE MAINPID IS READ AFTER THE POLL (review P1, #2627). The check this gate CLAIMED in its own
        # comment (:1757: "a MainPID that is not live") did not exist: only the state word was re-read, so an
        # `active` unit whose process had exited certified the install and the report printed the pre-poll pid.
        _post_pid="$(unit_main_pid)" || {
            err "cannot read $UNIT_NAME's MainPID at the end of the proof wait — the unit answers '$_post_state' but"
            err "  nothing here can say a controller is running: read journalctl -u $UNIT_NAME -n 40"
            return 1; }
        [ "${_post_pid:-0}" != "0" ] || {
            err "$UNIT_NAME is '$_post_state' with MainPID 0 at the end of the proof wait — no controller process:"
            err "  read journalctl -u $UNIT_NAME -n 40"
            return 1; }
        kill -0 "$_post_pid" 2>/dev/null || {
            err "$UNIT_NAME is '$_post_state' but its MainPID $_post_pid is NOT live at the end of the proof wait —"
            err "  the process that wrote this heartbeat is gone, so the proof's author is gone with it:"
            err "  read journalctl -u $UNIT_NAME -n 40"
            return 1; }
        # report the pid that is actually running, not the one read before the wait
        pid="$_post_pid"
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
    # ⛔ WHICH REVISION BOOTS THIS BOX, read off the INSTALLED artifact (agent-infra#2697). Informational
    # only: a unit rendered before the pin existed prints `absent`, and that is exactly the fact an operator
    # needs (re-render to record it) — it never moves the verdict, because supervision is not the pin.
    # ⛔ AND IT ONLY SPEAKS ABOUT A UNIT THAT EXISTS HERE (re-review P3). Printed unconditionally after
    # `unit=…`, the `absent` line claimed a unit had been "rendered before the pin was recorded" even when
    # nothing was installed at this path, or when the copy present belongs to ANOTHER state dir (which this
    # verb disowns two lines down) — an assertion about an artifact that was not there. The fact is reported
    # only for our own file; otherwise the line says what is true.
    local _pin=""
    if [ -f "$UNIT_DIR/$UNIT_NAME" ] && unit_is_ours "$UNIT_DIR/$UNIT_NAME"; then
        _pin="$(sed -n 's|^Environment=ORCH_SUPERVISOR_PIN=||p' "$UNIT_DIR/$UNIT_NAME" 2>/dev/null | head -1)"
        log_line "supervisor_pin=${_pin:-absent (rendered before the pin was recorded — re-render with --install)}"
    else
        log_line "supervisor_pin=none (no unit of this state dir is installed here)"
    fi
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
        [ -n "$_sup" ] || _sup="cloud-cell-supervisor.sh (farmed FLAT by setup.sh's fleet_srcs (the #1938 fix) — re-run the installer to get it)"
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
