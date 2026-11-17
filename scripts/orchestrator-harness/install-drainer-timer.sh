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
#   DRAINER_FLEET_REPO checkout whose origin carries refs/boxes/*      default: $DRAINER_SEED_REPO
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
# Exit codes: 0 ok · 1 failure (named) · 2 usage · 3 --status: installed unit carries a STALE
#             `Environment=LANE_TIMEOUT` pin (re-run the installer on this cell to re-render it) ·
#             4 --status: the service and/or the timer is MISSING, so this box dispatches NOTHING
#             (`--status` used to report that as exit 0 — "no drainer at all" reading healthy on a
#             verb whose exit code is the published contract) · 5 --status: installed, but the cap it
#             dispatches at cannot be DETERMINED — no pin and an unreadable `ExecStart` script, a pin
#             whose value is not a number of seconds, or a pin line systemd would REJECT (an
#             unterminated quote makes systemd abandon the line) — named as unknown rather than
#             silently graded clean.
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATES_DIR="${TEMPLATES_DIR:-$INFRA_ROOT/templates/systemd}"
# ⛔ THE `Environment=` GRAMMAR IS A SHARED LIBRARY, NOT A COPY (re-review of #4065, finding 1). This
# installer reads the INSTALLED unit's `Environment=LANE_TIMEOUT` pin, and the disk reaper's installer
# already owned a parser for exactly that grammar — with the measured defeats behind it (a quoted pin,
# several assignments on one line, whitespace around the `=`, a `<unit>.d/*.conf` drop-in). Reading the
# pin here with a single-line `grep` made the two readers disagree about the SAME unit, and this one
# failed OPEN (rc 0 = "provably agrees with the seam") over a box dispatching at the old cap. One
# definition, two callers: `scripts/lib/systemd-unit-parse.sh` documents the grammar and the
# `!unparseable:` contract, and it is farmed (`pi-bootstrap/setup.sh`'s `lib_srcs`) so a cell resolves it.
# ⛔ A MISSING LIBRARY IS FATAL: without `effective_env` the pin would resolve as empty, and empty is the
# "no pin" branch — the false clean this file exists to remove, recreated by a missing file.
SYSTEMD_UNIT_PARSE_LIB="$INFRA_ROOT/scripts/lib/systemd-unit-parse.sh"
if [ ! -f "$SYSTEMD_UNIT_PARSE_LIB" ]; then
    printf 'install-drainer-timer: ERROR — %s is missing; --status parses the installed pin with it and cannot grade this box without it\n' "$SYSTEMD_UNIT_PARSE_LIB" >&2
    exit 1
fi
# shellcheck source=scripts/lib/systemd-unit-parse.sh
. "$SYSTEMD_UNIT_PARSE_LIB"
command -v effective_env >/dev/null 2>&1 \
    || { printf 'install-drainer-timer: ERROR — %s did not define effective_env\n' "$SYSTEMD_UNIT_PARSE_LIB" >&2; exit 1; }
# ⛔ THE `ExecStart=` GRAMMAR IS THE SAME LIBRARY (round-2 re-review, P2). This verb's no-pin arm graded
# the script named by the BASE unit file, so a drop-in that replaces `ExecStart=` was invisible and the
# arm returned 0 over a unit systemd runs differently. A missing definition here would silently grade
# NOTHING (the loop would see no ExecStart at all and report UNKNOWN), so it is fatal for the same reason
# the `Environment=` reader's is: an unreadable grammar must not become a verdict.
command -v effective_execstarts >/dev/null 2>&1 \
    || { printf 'install-drainer-timer: ERROR — %s did not define effective_execstarts\n' "$SYSTEMD_UNIT_PARSE_LIB" >&2; exit 1; }
# ⛔ AND SO IS THE HAZARD LIST (round-2 re-review, F1/F3). `env_compile_hazards` names the directives and
# the raw-text constructs that move the environment BEHIND `Environment=` (`EnvironmentFile=`,
# `UnsetEnvironment=`, `PassEnvironment=`, a C-style escape, a `%`-specifier) — each MEASURED as an rc 0
# false clean in this verb. A cell farmed from an older lib would not define it, and treating that as
# "no hazards" would recreate the false PASS silently, which is exactly the failure mode this file's
# other two guards exist to prevent.
command -v env_compile_hazards >/dev/null 2>&1 \
    || { printf 'install-drainer-timer: ERROR — %s did not define env_compile_hazards\n' "$SYSTEMD_UNIT_PARSE_LIB" >&2; exit 1; }
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
# The queue repo whose origin carries `refs/boxes/*`. Rendered into the unit so the fleet line can say
# WHICH channel it read (`chan=`). The seed checkout is the default because it carries the same origin
# on this fleet — and ⛔ AN INSTALLED UNIT DOES NOT RE-CHECK THAT (fresh review round 12, P2; the
# comment that stood here claimed the opposite). The drainer's seed-origin guard runs ONLY while
# `FLEET_REPO` is EMPTY (`ai-drainer.sh`: `[ -z "$FLEET_REPO" ] && [ -n "${SEED_REPO:-}" ] …`), and this
# installer always renders `Environment=FLEET_REPO={{FLEET_REPO}}`, so on every unit it writes that
# guard is DEAD CODE. What the installed path does get is ATTRIBUTION: `chan=` stamps the channel it
# actually read, so a wrong-but-readable seed reports `published=0 INELIGIBLE=N … chan=<that repo>` —
# named, not silent. Override `DRAINER_FLEET_REPO` when the seed checkout is not the fleet's channel.
DRAINER_FLEET_REPO="${DRAINER_FLEET_REPO:-$DRAINER_SEED_REPO}"
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
# `ai-drainer.sh`'s `${LANE_TIMEOUT:-${LANE_BACKSTOP_S:-36000}}` could never take effect and drainer
# lanes stayed killed at 50 min: 300 s above the 2700 s progress allowance, i.e. the censoring survived
# on the box whose job is to drain the backlog, and raising `LANE_BACKSTOP_S` changed nothing there.
# Resolved ONCE here, from the harness copy being installed, so the two cannot drift.
DRAINER_LANE_TIMEOUT="${LANE_BACKSTOP_S:-}"
if [ -z "$DRAINER_LANE_TIMEOUT" ]; then
    DRAINER_LANE_TIMEOUT="$(sed -n 's/^LANE_BACKSTOP_S="${LANE_BACKSTOP_S:-\([0-9][0-9]*\)}".*/\1/p' \
                              "$(dirname "${BASH_SOURCE[0]}")/spawn-gate.sh" 2>/dev/null | head -1)"
fi
case "$DRAINER_LANE_TIMEOUT" in ''|*[!0-9]*|0) DRAINER_LANE_TIMEOUT=36000 ;; esac

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
        -e "s|{{FLEET_REPO}}|$DRAINER_FLEET_REPO|g" \
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

# execstart_script <one effective ExecStart command line> — the SCRIPT an interpreter invocation runs
# (`/bin/bash <script> [args…]`), or empty when the line is not that shape.
#
# ⛔ EMPTY IS NOT "NO SCRIPT" — it is "this verb cannot read the script from the artifact", and every
# caller here turns it into UNKNOWN (5), never into a clean. Deliberately narrow: the first word must be
# a shell (`bash`, `/bin/bash`, `/usr/bin/bash`, `sh`, …), the second must be a literal path. A `bash -c
# '…'` form puts the script INSIDE a string and a quoted path is not resolvable here, so both read as
# unreadable rather than being guessed at — the fail-closed direction, and named as such in the output.
execstart_script() {
    printf '%s\n' "$1" | awk '
        { line = $0
          sub(/^[ \t]+/, "", line)
          n = split(line, w, /[ \t]+/)
          if (n < 2) exit
          if (w[1] !~ /(^|\/)(ba)?sh$/) exit      # not a shell in program position
          if (w[2] ~ /^-/) exit                   # `bash -c …`: the script is inside the string
          if (w[2] ~ /^["\047]/) exit            # quoted path: not readable as a literal here
          print w[2] }'
}

say_status() {
    local svc="$1" tmr="$2" installed want missing=0
    printf 'installer target: %s (%s)\n' "$TARGET" "$UNIT_DIR"
    for u in "$svc" "$tmr"; do
        if [ -f "$UNIT_DIR/$u" ]; then printf '  %-34s installed\n' "$u"; else printf '  %-34s MISSING\n' "$u"; missing=1; fi
    done
    if [ -f "$UNIT_DIR/$tmr" ]; then
        printf '  timer state: %s\n' "$($SYSTEMCTL is-active "$tmr" 2>/dev/null || true)"
        printf '  next run:    %s\n' "$($SYSTEMCTL list-timers --all "$tmr" 2>/dev/null | sed -n '2p' | sed 's/  */ /g' || true)"
    fi
    # ⛔ "NO DRAINER AT ALL" IS NOT A CLEAN STATUS (agent-infra#4034 review, P3 — verified). The grading
    # block below lives inside `if [ -f "$UNIT_DIR/$svc" ]` and the function ended `return 0`, so a box
    # with NO unit printed `… MISSING` and exited 0. Once the exit code is the contract an automated
    # check reads, that is the same false PASS the exit-3 change exists to remove, one row up its own
    # output: "the drainer is armed at the right cap" and "this box dispatches nothing" were
    # indistinguishable. MISSING gets its own code (4) and a named line, so the two are separable
    # without parsing prose.
    if [ "$missing" -eq 1 ]; then
        printf '  ⛔ NOT ARMED: this box dispatches NOTHING at any cap — the missing unit(s) above are not\n'
        printf '      installed. Run this installer (no arguments) on this cell to arm them.\n'
        return 4
    fi
    # ⛔ A STALE `Environment=LANE_TIMEOUT` PIN IS THE #4034 DEFECT ONE LAYER OUT, AND --status COULD NOT SEE
    # IT. The unit is rendered ONCE, at install time (see the seam block above), and an installed pin WINS
    # over `ai-drainer.sh`'s compiled default (`LANE_TIMEOUT="${LANE_TIMEOUT:-...}"`, passed straight to the
    # dispatcher). So a cell whose unit predates a seam change keeps dispatching at the OLD cap forever
    # while the checkout, the docs and the tests all say the new one — and this verb reported only
    # installed/MISSING + timer state, so such a box read healthy. Print the pin beside the value this
    # checkout would render now, and WARN on a mismatch; exit 3 so an automated check can act on it.
    if [ -f "$UNIT_DIR/$svc" ]; then
        # ⛔ ONE LINE SHAPE IS NOT "THE PIN" (re-review of #4065, finding 1 — verified). This reader was
        # `grep '^Environment=LANE_TIMEOUT='`, a SPELLING match, and it was the FAIL-OPEN arm of this
        # verb: every spelling below is LEGAL systemd and every one of them read as "the unit carries no
        # pin", which falls through to the `ExecStart=` grading below and exits 0 — published as
        # "provably agrees with the seam" (docs/ops/ai-drainer.md) — over a box dispatching at the old
        # cap. The `ExecStart=` reader below fails SAFE (rc 5); this one failed OPEN, in the one verb
        # whose whole purpose is making a stale pin visible.
        #
        #     Environment="LANE_TIMEOUT=7200"          (quoted — systemd.exec(5) `Environment=`)
        #     Environment=HOME=/x LANE_TIMEOUT=7200    (several assignments on one line)
        #     Environment = LANE_TIMEOUT=7200          (whitespace around the key and the `=`)
        #     <unit>.service.d/*.conf                  (parsed AFTER the unit, so it WINS)
        #
        # ⛔ SO THE PIN IS READ WITH THE SAME PARSER THE DISK REAPER'S READ-BACK USES, not with a second
        # one that can disagree with it about the same unit (`scripts/lib/systemd-unit-parse.sh`; a
        # reader anchored on one line shape is exactly the "#1872 shape" of two readers of one fact). It
        # normalises indentation, whitespace and both quote styles, takes several assignments per line,
        # applies last-assignment-wins (`Environment=` repeats MERGE, the last wins), honours a bare
        # `Environment=` RESET, and reports a line systemd would REJECT as `!unparseable:` instead of
        # guessing at its value. The unit is fed in first and its drop-ins after it, in systemd's own
        # order, so a drop-in's override is what this verb grades.
        local unit_text envmap unparsed installed want pin_unreadable=0 hazards
        unit_text="$( { cat "$UNIT_DIR/$svc"
                        for _d in "$UNIT_DIR/$svc.d"/*.conf; do [ -f "$_d" ] && cat "$_d"; done
                      } 2>/dev/null )"
        # ⛔ A DIRECTIVE THAT MOVES THE ENVIRONMENT BEHIND `Environment=` MAKES THE CAP UNCERTIFIABLE, AND
        # THIS VERB USED TO GRADE IT ANYWAY (round-2 re-review, F1/F3 — both MEASURED at rc 0). The pin
        # map below is a reading of `Environment=` and of nothing else, while systemd compiles the
        # environment from SEVERAL sources (`systemd.exec(5)`: `Environment=`, then `EnvironmentFile=`, then
        # `PassEnvironment=`, and `UnsetEnvironment=` "as the final step", so "the later source … wins"):
        #
        #     EnvironmentFile=/…/lane.env   (that file: LANE_TIMEOUT=7200)
        #     Environment=\x4CA\x4EE_TIMEOUT=7200     (systemd expands \x4C→L, \x4E→N: a 7200 pin)
        #
        # both read here as "36000 s installed … agrees" and exited **0** over a box at 7200. The family
        # is the one `scripts/cell-self-pin.sh` refuses BY NAME (`ENV_MUTATING_DIRECTIVES`) and closes at
        # the raw-text boundary, and the check now lives in the shared lib so both callers inherit it.
        #
        # ⛔ UNKNOWN (5) OUTRANKS THE GRADING BELOW, IN BOTH DIRECTIONS: a hazard means the `Environment=`
        # map is NOT the environment systemd compiles, so no value taken from it — a matching pin, a stale
        # pin, or the absence of one — can be certified. This is not the harmless direction: reporting a
        # STALE pin whose override we cannot read would send an operator to re-render a unit that is
        # already right, and reporting CLEAN is the false PASS this whole verb exists to remove.
        #
        # ⛔ AND A MISSING ARM IS NOT A SILENT PASS: a hazard the lib cannot report is worth nothing, so
        # the lib guard at the top of this file refuses to run without it (fail-closed, like its siblings).
        hazards="$(env_compile_hazards "$unit_text")"
        if [ -n "$hazards" ]; then
            printf '  ⚠️  UNREADABLE CAP: this unit (or one of its drop-ins) carries a directive that changes the\n'
            printf '      environment BEHIND `Environment=`, so the value this box actually dispatches at cannot be\n'
            printf '      certified from this file — systemd compiles the environment from several sources and the\n'
            printf '      later one wins (`EnvironmentFile=`), `UnsetEnvironment=` clears a variable as the final\n'
            printf '      step, and a `%%`-specifier or a C-style escape (`\\x4C` is `L`) can spell a variable name\n'
            printf '      this reader cannot reconstruct:\n'
            printf '%s\n' "$hazards" | sed -n 's/^/        /p'
            printf '      A cap that cannot be certified is UNKNOWN, not healthy: re-render the pin in the unit with\n'
            printf '      this installer (no arguments), or move the variable it sets out of the environment.\n'
            return 5
        fi
        envmap="$(effective_env "$unit_text")"
        unparsed="$(printf '%s\n' "$envmap" | sed -n 's/^!unparseable://p')"
        case "$unparsed" in *LANE_TIMEOUT*) pin_unreadable=1 ;; esac
        installed="$(printf '%s\n' "$envmap" | sed -n 's/^LANE_TIMEOUT=//p' | tail -1 | tr -d '\r')"
        want="${LANE_TIMEOUT:-$DRAINER_LANE_TIMEOUT}"
        case "${installed:-}" in
        '')
            # ⛔ A PIN NOTHING COULD RESOLVE IS ITS OWN STATE — UNKNOWN (5), NEVER "NO PIN" (re-review of
            # #4065, finding 1). `LANE_TIMEOUT` is mentioned on an `Environment=` line that systemd would
            # REJECT (an unterminated quote: systemd returns EINVAL, logs, and ABANDONS the whole line,
            # so the process starts WITHOUT it) — this box's cap is therefore UNKNOWABLE from the unit,
            # and reporting it as absent would be the false clean this exit code exists to remove, one
            # spelling over. ⛔ NOT a text grep for the name: a bare `Environment=` RESET legitimately
            # CLEARS an earlier pin, and the shipped template carries the name in a COMMENT — both must
            # still read as "no pin", so only the parser's own failure signal counts.
            if [ "$pin_unreadable" -eq 1 ]; then
                printf '  ⚠️  UNREADABLE PIN: an `Environment=` line in this unit names LANE_TIMEOUT but is not a line systemd\n'
                printf '      would accept (unbalanced quotes), and systemd ABANDONS such a line — so the cap this box\n'
                printf '      dispatches at is UNKNOWN, not healthy:\n'
                printf '%s\n' "$unparsed" | sed -n 's/.*LANE_TIMEOUT.*/        Environment=\0/p'
                printf '      Re-run this installer (no arguments) on this cell to re-render the pin.\n'
                return 5
            fi
            # ⛔ "NO PIN" IS NOT "CLEAN" (agent-infra#4034 review, P3). With no pin the unit dispatches at
            # the default COMPILED INTO THE SCRIPT ITS OWN `ExecStart=` NAMES — so a box whose `$O` tree
            # predates the seam keeps the OLD cap while the checkout, the docs and the suite all say the
            # new one. That is the same state this exit code exists to make automatable, arriving through
            # the other door, so grade it the same way: read the script the unit would ACTUALLY run (never
            # the copy this checkout happens to hold), and decide on ITS literal. An ExecStart that is not
            # an ai-drainer.sh at all is named as UNKNOWN rather than being called clean — it is not
            # evidence of a stale cap, and it is not evidence of a fresh one either.
            #
            # ⛔ "THE UNIT" MEANS UNIT **+ DROP-INS**, IN SYSTEMD'S ORDER (round-2 re-review, P2 — verified).
            # This read was `sed -n 's|^ExecStart=/bin/bash ||p' "$UNIT_DIR/$svc"` — THE BASE FILE ALONE, on
            # one spelling — while the `Environment=` reader three arms above already used the drop-in-aware
            # `$unit_text`. So a `<unit>.service.d/*.conf` carrying `ExecStart=` + `ExecStart=/bin/bash
            # <other script>` was INVISIBLE here: the arm graded the base file's script, printed "agrees with
            # the … s this checkout would render" at :310 and returned 0 — a false clean in the verb whose
            # exit code is the published contract, over a unit systemd runs differently. MEASURED on this
            # fixture: base `ExecStart=/bin/bash <fresh>`, drop-in `ExecStart=` + `ExecStart=/bin/bash
            # <stale 7200>` read **rc 0** before this change and **rc 3** after it. It is the same shape
            # `install-disk-reaper-timer.sh` closed with `effective_execstarts` (a drop-in made the install
            # print "verify: ExecStart + HOME read back", exit 0, over a unit that ran `/bin/true`). ⛔ AND
            # THE CLAIM IT WAS PROPPING UP IS WITHDRAWN (round-2 re-review, F4): "closed in every spelling"
            # was false at that head — four measured spellings outside this arm still exited 0 — so what
            # this file asserts is the narrower thing it tests: the command is read from the text systemd
            # parses, and a cap that CANNOT be certified is 5, never 0.
            #
            # Systemd's own semantics, not a last-line guess: `ExecStart=` is read from `$unit_text` by
            # `effective_execstarts` from the SHARED parser (`scripts/lib/systemd-unit-parse.sh` — one
            # definition, both callers), so a bare `ExecStart=` RESET (which is how a drop-in MASKS a unit)
            # drops every earlier assignment, `ExecStart = /bin/bash …` normalises, and `Type=oneshot`'s
            # several commands are ALL graded: a oneshot runs every one of them, so a stale cap in any of
            # them is this box's stale cap. UNKNOWN (5) outranks clean but not stale: a script we cannot
            # resolve is not evidence of a fresh cap, and a stale one among them is a definite finding.
            local execs line exe have stale="" unknown="" fresh=""
            execs="$(effective_execstarts "$unit_text")"
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                exe="$(execstart_script "$line")"
                if [ -z "$exe" ] || [ ! -f "$exe" ]; then
                    unknown="${exe:-$line}"; continue
                fi
                have="$(sed -n 's/^LANE_TIMEOUT="${LANE_TIMEOUT:-${LANE_BACKSTOP_S:-\([0-9][0-9]*\)}}".*/\1/p' \
                          "$exe" 2>/dev/null | head -1)"
                case "${have:-}" in ''|*[!0-9]*) unknown="$exe"; continue ;; esac
                if [ "$have" != "$want" ]; then stale="$have $exe"; else fresh="$have"; fi
            done <<<"$execs"
            if [ -n "$stale" ]; then
                printf '  LANE_TIMEOUT pin: (none — the unit carries no pin, so it dispatches at %s s compiled into\n' "${stale%% *}"
                printf '      %s)\n' "${stale#* }"
                printf '  ⚠️  STALE CAP: this no-pin unit runs a script whose own default is %s s, but the seam now says %s s —\n' "${stale%% *}" "$want"
                printf '      the box keeps the old cap until this unit is re-rendered: re-run this installer\n'
                printf '      (no arguments) on this cell.\n'
                return 3
            elif [ -z "$execs" ]; then
                printf '  LANE_TIMEOUT pin: (none — the unit carries no pin, and its ExecStart names no readable script, so the cap\n'
                printf '      this box actually dispatches at is UNKNOWN; re-run this installer to pin it)\n'
                return 5
            elif [ -n "$unknown" ]; then
                printf '  LANE_TIMEOUT pin: (none — the unit carries no pin, and %s names no script this verb can read (an\n' "$unknown"
                printf '      ExecStart that is not `bash <script>`, or one whose script is missing), so the cap this box\n'
                printf '      dispatches at is UNKNOWN; re-run this installer to pin it)\n'
                return 5
            else
                printf '  LANE_TIMEOUT pin: (none — the unit carries no pin, and the %s s compiled into %s\n' "$fresh" "${exe}"
                printf '      agrees with the %s s this checkout would render)\n' "$want"
            fi ;;
        *[!0-9]*)
            # ⛔ THE SAME RULE FOR A VALUE THAT IS NOT A NUMBER OF SECONDS (re-review of #4065, finding 1).
            # `LANE_TIMEOUT=abc` is a box whose cap is UNKNOWN: it is not evidence of a stale cap (so not
            # 3) and it is certainly not evidence of a fresh one (so never 0). Naming it is the whole job.
            printf '  ⚠️  UNREADABLE PIN: this unit sets LANE_TIMEOUT to `%s`, which is not a number of seconds. The seam\n' "$installed"
            printf '      cannot compare against it, so the cap this box dispatches at is UNKNOWN, not healthy: re-run this\n'
            printf '      installer (no arguments) on this cell to re-render the pin.\n'
            return 5 ;;
        *)
            printf '  LANE_TIMEOUT pin: %s s installed · %s s would be rendered now\n' "$installed" "$want"
            if [ "$installed" != "$want" ]; then
                printf '  ⚠️  STALE PIN: this unit dispatches lanes at %s s, but the seam now says %s s — a rendered pin beats the\n' "$installed" "$want"
                printf '      default, so this box keeps the old cap until the unit is re-rendered: re-run this installer\n'
                printf '      (no arguments) on this cell.\n'
                return 3
            fi ;;
        esac
    fi
    return 0
}

case "$MODE" in
    # exit 3 on a stale pin: distinct from 1 (failure) and 2 (usage), so `--status` is scriptable — a
    # warning that can only be read by eye is the invisibility this verb was changed to remove.
    --status) say_status "$UNIT_SRC_SERVICE" "$UNIT_SRC_TIMER"; exit $? ;;
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
