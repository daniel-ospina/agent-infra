#!/usr/bin/env bash
# install-harness-apply-timer.sh — put HARNESS ACTIVATION on the box's clock, on BOTH platforms
# (agent-infra#2416).
#
# WHY THIS IS AN INSTALLER AND NOT A LINE IN THE BRING-UP. Same split as install-disk-reaper-timer.sh
# (#2032/#2048/#2058) and install-launchd.sh: the artifact has to be RENDERED from machine state
# (HOME, PATH, the checkout, the state dir the pass writes) and installed IDEMPOTENTLY; the bring-up
# is the TRIGGER, this is the policy of WHERE and HOW. One place renders and converges.
#
# ⛔ THE DEFECT THIS EXISTS FOR. `scripts/cloud-cell-supervisor.sh apply` fetches agent-infra main and
# pins the cell's harness to it (#1745), and `start` runs it before every launch. NOTHING SCHEDULED IT,
# so a cell ran whatever code it had when it was last started and `main` moved away underneath it: a
# harness fix that merged but is not live on a cell has fixed nothing. MEASURED 2026-10-23: the Mac
# 91 commits behind with every signal reading "auto", c1's pin naming 54bbb0c6 while its checkout was
# ce987bb2, c3/c4 stale. This installer puts `scripts/harness-apply-pass.sh` (which CALLS those verbs,
# unmodified) on the platform's own scheduler, every ten minutes.
#
# ⛔ IT SCHEDULES, IT DOES NOT RE-IMPLEMENT. `apply`'s semantics are untouched (and if `apply` has a
# defect, that is a separate issue — not a silent fix here). The pass owns the safety predicates; the
# verb owns activation.
#
# ⛔ ARMING IS NOT A SEPARATE OWNER STEP, AND IT IS STILL REVERSIBLE. The general rule (#1678, owner
# ruling 2026-10-11) makes arming a deletion tool a separate dated step. This is a SCHEDULER over a
# verb the box already runs on every `start`, and the brief instructs it to run unattended, so
# `--install` arms it. Reversal is one documented verb (no hand-edit of an installed file):
#     install-harness-apply-timer.sh --uninstall
# and, if the installer is unavailable, the platform's own:
#     systemctl disable --now eldato-harness-apply.timer
#     launchctl bootout gui/$(id -u)/com.eldato.harness-apply
# `--dry-run` is a PREVIEW (renders and prints, writes nothing, enables nothing); it is NOT a disarm.
# ⛔ `--uninstall` VERIFIES the job is gone. A file that was removed while the LOADED job keeps
# firing is not an uninstall — and on the launchd side the job survives until logout unless bootout
# really took, so the label is re-read, not assumed.
#
# INSTALL TARGETS. systemd, tried in this order, and the reason is named in the output:
#   1. a SYSTEM unit via passwordless sudo (/etc/systemd/system) — the cell's normal shape; the
#      service runs as the invoking user, so the pass writes the LANE user's state, not root's.
#   2. a USER unit (~/.config/systemd/user) when systemd's user manager actually answers — a cell
#      without sudo still gets a clock. Needs lingering, which is CHECKED (a user timer without it
#      fires while you are logged in and never again — the inert enforcer that prints green).
#   3. nothing — a loud FAILURE naming the remedy, never a silent no-op. A timer that was "installed"
#      but never fires is the false PASS this repo keeps deleting.
# macOS has exactly one: ~/Library/LaunchAgents (a LaunchAgent, in the user's GUI domain), started
# through the checkout's own interpreter because TCC is per-binary (a launchd-spawned bash/git cannot
# read a repo under ~/Documents) — the same launcher install-disk-reaper-timer.sh uses.
#
# CADENCE. Every 10 minutes (`OnCalendar=*:0/10`, `StartInterval=600`). The pass is a NO-OP when the
# pin already equals the ref tip (exit 0, `action=none`), so the cadence costs one `git fetch` per
# tick and nothing else. `HARNESS_APPLY_INTERVAL_MIN` exists for tests and unusual boxes; the unit
# renders the value that was validated, never an unvalidated one (a bad one is BAKED INTO A PERSISTENT
# UNIT — the disk-reaper installer records the measured consequence of exactly that).
#
# Usage:
#   install-harness-apply-timer.sh [--install] [--dry-run] [--status] [--uninstall] [--help]
#
# Env seams (tests + unusual boxes):
#   HARNESS_APPLY_PASS       the pass entry point to install (default: the farmed copy, else beside this)
#   HARNESS_APPLY_REPO       the agent-infra checkout the pass converges (default: this repo)
#   HARNESS_APPLY_REF        the ref to converge on (default origin/main)
#   HARNESS_APPLY_MODE       pin|sync (default: decided by the pass — see its header)
#   HARNESS_APPLY_STATE_DIR  the pass record/log dir the unit exports (default $HOME/.pi/agent/state)
#   HARNESS_APPLY_INTERVAL_MIN  minutes between passes (default 10; 1..1440)
#   TEMPLATES_DIR            systemd template dir (default: this repo's templates/systemd)
#   LAUNCHD_TEMPLATES_DIR    plist template dir (default: this repo's templates/launchd/harness-apply)
#   SYSTEMD_UNIT_DIR         install dir OVERRIDE (tests: a temp dir, with SYSTEMCTL a fake)
#   LAUNCHD_AGENTS_DIR       LaunchAgents dir OVERRIDE (tests: a temp dir, with LAUNCHCTL a fake)
#   ELDATO_PLATFORM          override `uname -s` (tests render the Darwin artifact on any host)
#   ELDATO_LAUNCHER_PY       the interpreter a launchd job is started with (TCC; see below)
#   ELDATO_LAUNCHER          the TCC launcher script (default: pi-reap-worktrees-launchd.py)
#   SYSTEMCTL / LAUNCHCTL / SUDO  the tools to call / probe (tests: shims)
#   HARNESS_APPLY_EXTRA_SCOPES  colon-separated EXTRA dirs scanned by `--uninstall`'s "another scope"
#                               note (TEST SEAM: read-only scan paths only; production sets nothing)
#
# Exit codes: 0 ok · 1 failure (named) · 2 usage.
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${TEMPLATES_DIR:-}" ]; then
    # ⛔ THE CHECKOUT THAT SHIPS THIS INSTALLER WINS OVER AN AMBIENT $AGENT_INFRA_PATH, and that
    # ordering is deliberate. install-disk-reaper-timer.sh consults $AGENT_INFRA_PATH FIRST because a
    # FARMED copy has no ../templates beside it — still true here, and still handled: a farmed copy at
    # $HOME/.pi/agent/scripts has no $INFRA_ROOT/templates, so it falls through to the next candidate.
    # But when this file IS running from a checkout, that checkout is the authority for its own
    # templates; taking an older checkout's artifact instead would install a unit that runs a pass it
    # was not written against, and the ambient variable is exactly what makes that possible.
    for _cand in "$INFRA_ROOT/templates/systemd" "${AGENT_INFRA_PATH:-}/templates/systemd" \
                 "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/templates/systemd"; do
        [ -n "$_cand" ] && [ -d "$_cand" ] && { TEMPLATES_DIR="$_cand"; break; }
    done
fi
TEMPLATES_DIR="${TEMPLATES_DIR:-$INFRA_ROOT/templates/systemd}"
# The plist lives OUTSIDE templates/launchd/ on purpose: install-launchd.sh installs EVERY
# `templates/launchd/*.plist` with no arguments and a different placeholder set, so a copy there
# would render with `{{…}}` unresolved, be SKIPPED with a warning, and the box would silently have no
# scheduled pass — the inert-enforcer shape. Same reason templates/launchd/reaper/ exists.
if [ -z "${LAUNCHD_TEMPLATES_DIR:-}" ]; then
    for _cand in "$INFRA_ROOT/templates/launchd/harness-apply" \
                 "${AGENT_INFRA_PATH:-}/templates/launchd/harness-apply" \
                 "${TEMPLATES_DIR%/systemd}/launchd/harness-apply"; do
        [ -n "$_cand" ] && [ -d "$_cand" ] && { LAUNCHD_TEMPLATES_DIR="$_cand"; break; }
    done
fi
LAUNCHD_TEMPLATES_DIR="${LAUNCHD_TEMPLATES_DIR:-$INFRA_ROOT/templates/launchd/harness-apply}"
PLATFORM="${ELDATO_PLATFORM:-$(uname -s 2>/dev/null || printf 'unknown')}"
STATE_DIR="${HARNESS_APPLY_STATE_DIR:-${HOME:?HOME is required}/.pi/agent/state}"
INTERVAL_MIN="${HARNESS_APPLY_INTERVAL_MIN:-10}"
UNIT_NAME="eldato-harness-apply"
LABEL="com.eldato.${UNIT_NAME#eldato-}"
PASS_REF="${HARNESS_APPLY_REF:-origin/main}"
PASS_MODE="${HARNESS_APPLY_MODE:-}"

# ── the checkout the pass converges ──────────────────────────────────────────────────────────
# ⛔ A FARMED INSTALLER HAS NO CHECKOUT BESIDE IT. On a cell this file lives at
# $HOME/.pi/agent/scripts/, so `$INFRA_ROOT` is $HOME/.pi/agent — defaulted from it, the unit would
# point the pass at a directory that is not a git checkout, EVERY tick would fail, and
# `list-timers` would keep showing the job as scheduled: the inert-enforcer shape this installer
# exists to remove, produced by its own default. So the checkout is RESOLVED, and a box with none is
# a REFUSAL (the disk-reaper installer's "zero repos is a refusal, not a warning", same reason).
resolve_pass_repo() {
    local cand main
    for cand in "${HARNESS_APPLY_REPO:-}" "${AGENT_INFRA_PATH:-}" "$INFRA_ROOT" \
                "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"; do
        [ -n "$cand" ] && [ -d "$cand" ] || continue
        # ⛔ `rev-parse --git-dir` IS THE TEST, AND `worktree list` IS ONLY A PREFERENCE. The point of
        # the second call is to land on the MAIN worktree rather than a pin (a farmed installer may sit
        # inside a linked one); but a listing that cannot be read must not turn a checkout that git has
        # just confirmed into "no checkout on this box" — that is a false refusal, and it is what made
        # this refuse under a test harness whose `git` is a functional stub (measured).
        git -C "$cand" rev-parse --git-dir >/dev/null 2>&1 || continue
        main="$(git -C "$cand" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')"
        PASS_REPO="${main:-$cand}"
        return 0
    done
    return 1
}
PASS_REPO=""

say() { printf '%s\n' "$*"; }
err() { printf '%s: %s\n' "${0##*/}" "$*" >&2; }

help_text() {
    local n
    n="$(grep -n '^set -uo pipefail' "$0" 2>/dev/null | head -1 | cut -d: -f1)"
    # NO CONSTANT FALLBACK: a hand-maintained range silently truncated the disk-reaper installer's
    # help every time its header grew (measured there), and a piped start cannot derive it at all.
    if [ -z "$n" ]; then
        err "cannot derive the help range (invoke this FILE, not a pipe: 'bash $(basename "${BASH_SOURCE[0]:-$0}") --help')"
        return 2
    fi
    # ⛔ ONE PROCESS, NO PIPELINE. The obvious `sed -n "2,Np" "$0" | sed …` reads the FILE through
    # `$0`, and a static discard guard cannot resolve that producer — it fails closed on the payload
    # and refuses the whole invocation, which would make this script unrunnable by the very lanes it
    # must never disturb (measured). `awk` answers the same question in one process: print the header
    # lines up to the `set -uo pipefail` sentinel, dropping the leading `# `.
    awk 'NR == 1 { next } /^set -uo pipefail/ { exit } { sub(/^# ?/, ""); print }' "$0"
}
usage() { help_text; exit 2; }

# ── resolve the pass ───────────────────────────────────────────────────────────────────────────
# The FARMED copy first (that is what a cell has after `pi-bootstrap/setup.sh`, and a unit pointing
# at a worktree checkout would break the day that worktree is reaped).
PASS=""
if [ -n "${HARNESS_APPLY_PASS:-}" ] && [ ! -f "$HARNESS_APPLY_PASS" ]; then
    err "\$HARNESS_APPLY_PASS is set to '$HARNESS_APPLY_PASS' but that is not a regular file — refusing to install a unit that points at a DIFFERENT copy of the pass"
    exit 2
fi
for cand in "${HARNESS_APPLY_PASS:-}" "${HOME:-}/.pi/agent/scripts/harness-apply-pass.sh" "$INFRA_ROOT/scripts/harness-apply-pass.sh"; do
    [ -n "$cand" ] || continue
    [ -f "$cand" ] && { PASS="$cand"; break; }
done

# A path systemd can actually execute. systemd resolves a relative ExecStart argument against the
# UNIT's working directory (not this installer's cwd), so a relative value is a permanent 127 that
# `[ -f ]` cannot tell from a working install.
is_absolute_path() { case "$1" in /*) return 0 ;; *) return 1 ;; esac; }

# ── refuse to install a unit that points into transient scratch space ───────────────────────────
# MEASURED (2026-10-18, pi-cell-2/-3) on the disk-reaper installer: a harness ran it with
# HOME=/tmp/tmp.XXXX/bg/home and no SYSTEMD_UNIT_DIR, so the unit's ExecStart named a directory that
# was deleted before the first tick. Every pass then exited 127 (command not found) while
# `systemctl list-timers` showed the job scheduled and healthy — an inert enforcer produced by the
# INSTALLER. The same guard is required here: this pass is the only thing that keeps a box's code
# current, so a dead unit is the drift the feature exists to stop.
#
# ⛔ NORMALISE FIRST. macOS sets TMPDIR with a TRAILING SLASH, so a naive prefix test misses the
# very path it exists to refuse (measured in the disk-reaper installer).
is_transient_scratch() {
    local p="$1" t t2
    [ -n "$p" ] || return 1
    p="$(printf '%s' "$p" | tr -s '/')"
    case "$p" in
        /tmp/tmp.?*|/var/tmp/tmp.?*|/private/tmp/tmp.?*|/private/var/tmp/tmp.?*) return 0 ;;
        /var/folders/*/*/T/tmp.?*|/private/var/folders/*/*/T/tmp.?*) return 0 ;;
    esac
    for t in "${TMPDIR:-}"; do
        [ -n "$t" ] || continue
        t="$(printf '%s' "$t" | tr -s '/')"
        t="${t%/}"
        [ -n "$t" ] || continue
        case "$t" in /var/*) t2="/private$t" ;; *) t2="$t" ;; esac
        case "$p" in "$t"/tmp.?*|"$t2"/tmp.?*|"/private$t"/tmp.?*) return 0 ;; esac
    done
    return 1
}

is_real_systemd_dir() {
    case "$(printf '%s' "${1:-}" | tr -s '/')" in
        /etc/systemd*|/usr/lib/systemd*|/lib/systemd*|/run/systemd*) return 0 ;;
    esac
    return 1
}

refuse_transient_target() {
    local t="${TARGET:-scheduled}" bad="" v p skip=0
    # ⛔ THE CHECKOUT IS RESOLVED (AND REFUSED WHEN ABSENT) BEFORE ANYTHING IS RENDERED, because every
    # other guard downstream is about a unit that CAN run — and a unit whose pass converges a
    # non-checkout can never do its work.
    resolve_pass_repo || {
        err "REFUSING: no agent-infra checkout resolved on this box (looked at \$HARNESS_APPLY_REPO, \$AGENT_INFRA_PATH, $INFRA_ROOT) — the pass would converge nothing and every tick would fail. Set HARNESS_APPLY_REPO=<checkout>."
        return 1
    }
    # The pass is the artifact; without it nothing runs at all, so this REFUSES (and names the
    # remedy) BEFORE the value checks below — a missing pass used to be reported as
    # "PASS '' is not an absolute path", which sends an operator looking for a path bug.
    if [ -z "$PASS" ] || [ ! -f "$PASS" ] || [ ! -r "$PASS" ]; then
        err "REFUSING: no harness-apply-pass.sh resolved (looked at \$HARNESS_APPLY_PASS, \$HOME/.pi/agent/scripts, $INFRA_ROOT/scripts) — a unit that cannot run is worse than none. Farm it first: bash pi-bootstrap/setup.sh"
        return 1
    fi
    for v in "PASS=$PASS" "HOME=$HOME" "STATE_DIR=$STATE_DIR"; do
        p="${v#*=}"
        is_absolute_path "$p" || {
            err "REFUSING: ${v%%=*} '$p' is not an absolute path — systemd resolves ExecStart against the unit's working directory, so the pass would exit 127 every tick"
            return 1
        }
    done
    # ⛔ THE BYPASS IS SCOPED TO THE HEURISTIC. A scratch SYSTEMD_UNIT_DIR (the documented test seam)
    # skips the scratch CHECK and nothing else — it must never short-circuit the existence checks.
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ] && ! is_real_systemd_dir "$SYSTEMD_UNIT_DIR"; then skip=1; fi
    if [ "$skip" != 1 ]; then
        is_transient_scratch "$PASS"    && bad="PASS=$PASS"
        is_transient_scratch "$HOME"    && bad="${bad:+$bad; }HOME=$HOME"
        is_transient_scratch "$STATE_DIR" && bad="${bad:+$bad; }STATE_DIR=$STATE_DIR"
    fi
    if [ -n "$bad" ]; then
        err "REFUSING a $t install rendered from transient scratch space: $bad"
        err "The unit would point at a directory deleted before the first tick, so every pass exits 127"
        err "while 'list-timers' shows the job as scheduled — the exact inert-enforcer shape this"
        err "installer must never create (agent-infra#2032, measured on pi-cell-2/-3)."
        err "Re-run from the box's real HOME (a login shell or cloud-cell-bringup.sh), or set"
        err "SYSTEMD_UNIT_DIR to a scratch dir when this is a test."
        return 1
    fi
    case "$INTERVAL_MIN" in
        ''|*[!0-9]*) err "REFUSING: HARNESS_APPLY_INTERVAL_MIN='$INTERVAL_MIN' is not a whole number of minutes — it is rendered into the unit and baked into a persistent unit"; return 1 ;;
    esac
    [ "$INTERVAL_MIN" -ge 1 ] && [ "$INTERVAL_MIN" -le 1440 ] || {
        err "REFUSING: HARNESS_APPLY_INTERVAL_MIN=$INTERVAL_MIN is out of range (1..1440 minutes)"; return 1; }
    # ⛔ EVERY SUBSTITUTED VALUE GOES THROUGH `sed` — where a BACKSLASH IS AN ESCAPE. Measured on the
    # disk-reaper installer: `s|{{HOME}}|/tmp/a\b|` rendered `/tmp/ab`, exit 0, no `{{` left for the
    # post-render guard, and the unit pointed at a path that does not exist.
    for v in "HOME=$HOME" "PATH=$PATH" "STATE_DIR=$STATE_DIR" "PASS=$PASS" "PASS_REPO=$PASS_REPO" "PASS_REF=$PASS_REF"; do
        case "${v#*=}" in
            *\\*) err "REFUSING: ${v%%=*} contains a backslash — the artifact is rendered with sed, where a backslash is an escape, so the rendered path would silently differ from the real one"; return 1 ;;
        esac
    done
    # The state dir must be writable BY THE SERVICE USER, or every pass fails closed on its record.
    # `--dry-run` MUST NOT CREATE IT: the preview would then write to the filesystem it is only
    # supposed to describe (the disk-reaper installer records that defect).
    if [ "${DRY_RUN:-0}" = "1" ]; then
        if [ -e "$STATE_DIR" ] && [ ! -w "$STATE_DIR" ]; then
            err "REFUSING: state dir '$STATE_DIR' exists and is not writable by $(id -un) — every pass would fail to record"; return 1
        fi
        [ -e "$STATE_DIR" ] || say "dry-run: would create the state dir $STATE_DIR"
    elif ! mkdir -p "$STATE_DIR" 2>/dev/null || [ ! -w "$STATE_DIR" ]; then
        err "REFUSING: state dir '$STATE_DIR' is not writable by $(id -un) — every pass would fail to record"; return 1
    fi
    return 0
}

# The whitespace rule is a SYSTEMD rule (unquoted Environment=/ExecStart= values are split), not a
# launchd one (a plist value is a <string> of its own) — the same split the disk-reaper installer
# records. It needs $TARGET, so it runs AFTER choose_target.
refuse_systemd_unsafe_values() {
    local v
    [ "${TARGET:-}" = "launchd" ] && return 0
    for v in "HOME=$HOME" "PATH=$PATH" "STATE_DIR=$STATE_DIR" "PASS=$PASS" "PASS_REPO=$PASS_REPO"; do
        case "${v#*=}" in
            *[[:space:]]*) err "REFUSING: ${v%%=*} contains whitespace — systemd splits the rendered unit on it, so it would never run"; return 1 ;;
        esac
    done
    return 0
}

# XML-escape a value for the plist AND for `sed`'s replacement half. `&` expands to the whole match
# in a sed replacement and is the XML entity introducer; a backslash starts an escape. Both escapes
# are needed, and an unescaped `&` makes the plist MALFORMED (launchd then refuses it).
xml_sed_repl() {
    printf '%s' "$1" \
        | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        | sed -e 's/[&\\|]/\\&/g'
}

render() { # render <template> <dest>
    local tpl="$1" dest="$2"
    sed -e "s|{{USER}}|$(xml_sed_repl "$(id -un)")|g" \
        -e "s|{{HOME}}|$(xml_sed_repl "$HOME")|g" \
        -e "s|{{PATH}}|$(xml_sed_repl "$PATH")|g" \
        -e "s|{{STATE_DIR}}|$(xml_sed_repl "$STATE_DIR")|g" \
        -e "s|{{PASS}}|$(xml_sed_repl "$PASS")|g" \
        -e "s|{{PASS_DIR}}|$(xml_sed_repl "${PASS%/*}")|g" \
        -e "s|{{PASS_REPO}}|$(xml_sed_repl "$PASS_REPO")|g" \
        -e "s|{{PASS_REF}}|$(xml_sed_repl "$PASS_REF")|g" \
        -e "s|{{PASS_MODE}}|$(xml_sed_repl "$PASS_MODE")|g" \
        -e "s|{{INTERVAL_MIN}}|$INTERVAL_MIN|g" \
        -e "s|{{INTERVAL_SEC}}|$(( INTERVAL_MIN * 60 ))|g" \
        -e "s|{{LABEL}}|$LABEL|g" \
        -e "s|{{PY_BIN}}|$(xml_sed_repl "${PY_BIN:-}")|g" \
        -e "s|{{LAUNCHER}}|$(xml_sed_repl "${LAUNCHER:-}")|g" \
        "$tpl" >"$dest" || return 1
    grep -q '{{' "$dest" && { err "unresolved placeholder in $tpl"; grep -n '{{' "$dest" >&2; return 1; }
    return 0
}

# A rendered plist launchd cannot parse must not be installed: `bootstrap` would refuse it AFTER the
# artifact is installed, and the failure then reads like a scheduler problem.
plist_is_valid() {
    local f="$1"
    if command -v plutil >/dev/null 2>&1; then
        plutil -lint "$f" >/dev/null 2>&1 && return 0
        return 1
    fi
    command -v python3 >/dev/null 2>&1 || return 0   # no parser available: do not invent a refusal
    python3 -c 'import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$f" >/dev/null 2>&1
}

# The binary that holds TCC access is the checkout's own interpreter; no interpreter or no launcher
# is a REFUSAL, never a degraded `bash` job that would fail closed every ten minutes.
resolve_launcher() {
    local cand
    PY_BIN="${ELDATO_LAUNCHER_PY:-}"
    if [ -z "$PY_BIN" ]; then
        for cand in "${HARNESS_APPLY_REPO:-}/.venv/bin/python" "${AGENT_INFRA_PATH:-}/.venv/bin/python" \
                    "${HOME:-}/.pi/agent/.venv/bin/python"; do
            [ -n "$cand" ] && [ -x "$cand" ] && { PY_BIN="$cand"; break; }
        done
    fi
    if [ -z "$PY_BIN" ]; then
        PY_BIN="$(command -v python3 2>/dev/null || true)"
        [ -n "$PY_BIN" ] && err "WARNING: no checkout .venv/bin/python resolved — the job will run with $PY_BIN. If this box's repos are under ~/Documents, pin the checkout's interpreter with ELDATO_LAUNCHER_PY=<repo>/.venv/bin/python (TCC is per-binary)."
    fi
    [ -n "$PY_BIN" ] || { err "REFUSING: no interpreter resolved for the launchd job — set ELDATO_LAUNCHER_PY to the checkout's .venv/bin/python, the binary that holds the TCC access this pass needs"; return 1; }
    [ -x "$PY_BIN" ] || { err "REFUSING: the launchd interpreter '$PY_BIN' is not executable"; return 1; }
    LAUNCHER="${ELDATO_LAUNCHER:-}"
    if [ -z "$LAUNCHER" ]; then
        for cand in "${HOME:-}/.pi/agent/scripts/pi-reap-worktrees-launchd.py" \
                    "${PASS%/*}/pi-reap-worktrees-launchd.py" "$INFRA_ROOT/scripts/pi-reap-worktrees-launchd.py"; do
            [ -n "$cand" ] && [ -f "$cand" ] && { LAUNCHER="$cand"; break; }
        done
    fi
    [ -n "$LAUNCHER" ] && [ -f "$LAUNCHER" ] || { err "REFUSING: the launchd TCC launcher (pi-reap-worktrees-launchd.py) was not found beside the pass, in \$HOME/.pi/agent/scripts, or in $INFRA_ROOT/scripts — without it the pass cannot read a repo under ~/Documents"; return 1; }
    return 0
}

# ── choose a target ───────────────────────────────────────────────────────────────────────────
TARGET=""; UNIT_DIR=""; SC=""
choose_target() {
    if [ "$PLATFORM" = "Darwin" ]; then
        TARGET="launchd"
        UNIT_DIR="${LAUNCHD_AGENTS_DIR:-${HOME:?HOME is required}/Library/LaunchAgents}"
        SC="${LAUNCHCTL:-launchctl}"
        return 0
    fi
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ]; then
        TARGET="override"; UNIT_DIR="$SYSTEMD_UNIT_DIR"; SC="${SYSTEMCTL:-systemctl}"
        return 0
    fi
    # ⛔ `${SUDO+x}` DISTINGUISHES UNSET FROM SET-TO-EMPTY, so the documented "SUDO= skips the probe"
    # seam means what it says (the disk-reaper installer records both halves of this defect). And the
    # SCOPE FLAG SURVIVES A PIN: a pinned shim used alone would enable against the SYSTEM manager while
    # the unit was written to ~/.config/systemd/user.
    if [ -z "${SUDO+x}" ] && sudo -n true >/dev/null 2>&1; then
        TARGET="system"; UNIT_DIR="/etc/systemd/system"; SC="${SYSTEMCTL:-sudo -n systemctl}"
        return 0
    fi
    if [ -n "${SUDO+x}" ] && { [ -z "$SUDO" ] || $SUDO true >/dev/null 2>&1; }; then
        TARGET="system"; UNIT_DIR="/etc/systemd/system"; SC="${SYSTEMCTL:-${SUDO:+$SUDO }systemctl}"
        return 0
    fi
    if systemctl --user show-environment >/dev/null 2>&1; then
        TARGET="user"; UNIT_DIR="$HOME/.config/systemd/user"; SC="${SYSTEMCTL:-systemctl} --user"
        return 0
    fi
    return 1
}

# ── actions ──────────────────────────────────────────────────────────────────────────────────
do_install() {
    [ -n "$PASS" ] || { err "harness-apply-pass.sh not found — looked at \$HARNESS_APPLY_PASS, \$HOME/.pi/agent/scripts, and $INFRA_ROOT/scripts. Farm it first: bash pi-bootstrap/setup.sh"; return 1; }
    if [ "$PLATFORM" = "Darwin" ]; then do_install_launchd; else do_install_systemd; fi
}

do_install_systemd() {
    local src_svc="$TEMPLATES_DIR/$UNIT_NAME.service" src_tim="$TEMPLATES_DIR/$UNIT_NAME.timer"
    local tmpd changed=0
    [ -f "$src_svc" ] && [ -f "$src_tim" ] || { err "templates missing under $TEMPLATES_DIR"; return 1; }
    # ⛔ A ROOT INSTALL LOOKS AFTER ROOT'S STATE, NOT THE LANES'. `{{USER}}` is `id -un` and {{HOME}} is
    # $HOME, so `sudo bash install-harness-apply-timer.sh --install` renders `User=root` with
    # `Environment=HOME=/root` and the pass then records into /root — while the lane user's checkout is
    # never advanced. WHAT THIS REFUSES: an invocation that ARRIVED THROUGH SUDO (SUDO_USER set). A
    # genuine root shell has no SUDO_USER and is not refused.
    if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
        err "REFUSING to install as root (SUDO_USER=$SUDO_USER): the unit would run as root and advance"
        err "root's state, not $SUDO_USER's."
        err "Run it as the user that owns the lanes:  sudo -u $SUDO_USER -H bash $0 --install"
        return 1
    fi
    # ⛔ THE SCRATCH/PASS/STATE GUARDS RUN BEFORE TARGET SELECTION: a box whose HOME is transient
    # scratch must be told THAT, not "no scheduler available".
    refuse_transient_target || return 1
    choose_target || { err "no scheduler available: no passwordless sudo for a system unit, and no systemd user manager. Install by hand, or give the cell sudo. NOT silently skipping — a harness that is never applied is the drift this exists to stop."; return 1; }
    refuse_systemd_unsafe_values || return 1

    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/harness-apply-unit.XXXXXX")" || { err "cannot create a temp dir"; return 1; }
    render "$src_svc" "$tmpd/$UNIT_NAME.service" || { rm -rf "$tmpd"; return 1; }
    render "$src_tim" "$tmpd/$UNIT_NAME.timer" || { rm -rf "$tmpd"; return 1; }
    # A USER unit may not carry User= (systemd rejects it).
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

    # Install only when the rendered BYTES differ. `changed=0` is the idempotence the suite asserts.
    # The reload + `enable --now` below still run on EVERY install, deliberately: they are idempotent,
    # they cost nothing on an unchanged unit, and they are what re-arms a timer somebody disabled by
    # hand. What the byte compare avoids is REWRITING the unit (and re-issuing the file op), not the
    # two idempotent scheduler calls.
    cmp -s "$tmpd/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.service" || changed=1
    cmp -s "$tmpd/$UNIT_NAME.timer" "$UNIT_DIR/$UNIT_NAME.timer" || changed=1
    mkdir -p "$UNIT_DIR" 2>/dev/null || true
    # ⛔ THE FILE OP FOLLOWS THE TARGET, NOT $SUDO: `TARGET=user` is reachable only when the sudo probe
    # FAILED, so routing a user install through sudo asks it to do what it just refused.
    case "$TARGET" in
        override) cp -f "$tmpd/$UNIT_NAME.service" "$tmpd/$UNIT_NAME.timer" "$UNIT_DIR/" || { err "copy failed"; rm -rf "$tmpd"; return 1; } ;;
        user)     install -m 0644 "$tmpd/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.service" \
                       && install -m 0644 "$tmpd/$UNIT_NAME.timer" "$UNIT_DIR/$UNIT_NAME.timer" \
                       || { err "install failed writing $UNIT_DIR (target=user, no sudo needed)"; rm -rf "$tmpd"; return 1; } ;;
        *)        ${SUDO-sudo -n} install -m 0644 "$tmpd/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.service" \
                       && ${SUDO-sudo -n} install -m 0644 "$tmpd/$UNIT_NAME.timer" "$UNIT_DIR/$UNIT_NAME.timer" \
                       || { err "install failed (target=$TARGET, dir=$UNIT_DIR)"; rm -rf "$tmpd"; return 1; } ;;
    esac
    rm -rf "$tmpd"

    $SC daemon-reload >/dev/null 2>&1 || { err "daemon-reload failed"; return 1; }
    $SC enable --now "$UNIT_NAME.timer" || { err "could not enable/start $UNIT_NAME.timer"; return 1; }

    # ⛔ A USER UNIT WITHOUT LINGERING IS AN INERT ENFORCER THAT PRINTS GREEN: `user@.service` stops
    # when the user's last session ends, so `enable --now` succeeds, `--status` says `active`, the
    # bring-up reports "scheduled", and the timer never fires again. Checked, not assumed.
    if [ "$TARGET" = "user" ]; then
        linger="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)"
        if [ "$linger" != "yes" ]; then
            loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
            linger="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)"
        fi
        if [ "$linger" != "yes" ]; then
            err "REFUSING to report this as installed: a USER timer cannot fire after your session ends"
            err "without lingering (loginctl show-user $(id -un) -p Linger -> '${linger:-unknown}')."
            err "Enable it, then re-run:  sudo loginctl enable-linger $(id -un)"
            return 1
        fi
        say "  linger: enabled (the user timer survives logout)"
    fi

    say "installed: target=$TARGET dir=$UNIT_DIR changed=$changed"
    say "  pass:   $PASS"
    say "  repo:   $PASS_REPO  (ref $PASS_REF${PASS_MODE:+, mode $PASS_MODE})"
    say "  every:  ${INTERVAL_MIN}m"
    say "  record: $STATE_DIR/harness-apply.status"
    if $SC is-enabled "$UNIT_NAME.timer" >/dev/null 2>&1; then
        say "  timer:  enabled"
    else
        err "timer is NOT enabled after install — the harness will not be applied unattended"; return 1
    fi
    return 0
}

do_install_launchd() {
    local src_plist="$LAUNCHD_TEMPLATES_DIR/$LABEL.plist"
    local tmpd changed=0 loaded=0
    [ -f "$src_plist" ] || { err "plist template missing: $src_plist (set LAUNCHD_TEMPLATES_DIR)"; return 1; }
    choose_target || { err "no scheduler available"; return 1; }
    resolve_launcher || return 1
    refuse_transient_target || return 1

    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/harness-apply-plist.XXXXXX")" || { err "cannot create a temp dir"; return 1; }
    render "$src_plist" "$tmpd/$LABEL.plist" || { rm -rf "$tmpd"; return 1; }
    # ⛔ A PLIST THAT DOES NOT PARSE IS NOT INSTALLED. A placeholder inside an XML COMMENT renders a
    # doubled dash into it, which is forbidden there — the disk-reaper installer measured exactly this
    # and the box silently had no job while the installer said OK.
    plist_is_valid "$tmpd/$LABEL.plist" || {
        err "REFUSING: the rendered plist is not well-formed XML — launchd would refuse it and this box would have no scheduled pass"
        err "  rendered: $tmpd/$LABEL.plist"
        if command -v python3 >/dev/null 2>&1; then
            python3 -c 'import sys,xml.etree.ElementTree as ET
try:
    ET.parse(sys.argv[1])
except ET.ParseError as e:
    print("  parser: %s" % e, file=sys.stderr)' "$tmpd/$LABEL.plist" || true
        fi
        rm -rf "$tmpd"; return 1
    }

    if [ "${DRY_RUN:-0}" = "1" ]; then
        say "dry-run: would install to $UNIT_DIR (target=$TARGET) and bootstrap $LABEL"
        say "--- $LABEL.plist ---"; sed 's/^/  /' "$tmpd/$LABEL.plist"
        rm -rf "$tmpd"
        return 0
    fi

    cmp -s "$tmpd/$LABEL.plist" "$UNIT_DIR/$LABEL.plist" || changed=1
    mkdir -p "$UNIT_DIR" 2>/dev/null || { err "cannot create $UNIT_DIR"; rm -rf "$tmpd"; return 1; }
    cp -f "$tmpd/$LABEL.plist" "$UNIT_DIR/$LABEL.plist" || { err "copy failed"; rm -rf "$tmpd"; return 1; }
    rm -rf "$tmpd"

    # Only re-bootstrap when the bytes moved or the job is not loaded. The loaded test matches the
    # WHOLE label (last field), never a substring: `…-old` must not satisfy it.
    $SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {found=1} END{exit !found}' && loaded=1
    if [ "$changed" = 1 ] || [ "$loaded" = 0 ]; then
        $SC bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
        $SC bootstrap "gui/$(id -u)" "$UNIT_DIR/$LABEL.plist" >/dev/null 2>&1 \
            || $SC load -w "$UNIT_DIR/$LABEL.plist" >/dev/null 2>&1 \
            || { err "could not bootstrap $LABEL from $UNIT_DIR/$LABEL.plist — the harness will NOT be applied unattended"; return 1; }
    fi

    say "installed: target=$TARGET dir=$UNIT_DIR changed=$changed"
    say "  launch: $PY_BIN $LAUNCHER --script $PASS"
    say "  repo:   $PASS_REPO  (ref $PASS_REF${PASS_MODE:+, mode $PASS_MODE})"
    say "  every:  ${INTERVAL_MIN}m"
    say "  record: $STATE_DIR/harness-apply.status"
    if $SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {found=1} END{exit !found}'; then
        say "  agent:  loaded"
    else
        err "agent $LABEL is NOT loaded after install — the harness will not be applied unattended"; return 1
    fi
    return 0
}

do_status() {
    local ACTIVE REC="" REC_RC=0 LAST_RUN=""
    choose_target || { err "no scheduler available"; return 1; }
    say "target=$TARGET dir=$UNIT_DIR"
    if [ "$TARGET" = "launchd" ]; then
        if ! $SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {found=1} END{exit !found}'; then
            say "installed=no"
            [ -f "$UNIT_DIR/$LABEL.plist" ] && say "note=plist present at $UNIT_DIR/$LABEL.plist but the agent is NOT loaded"
            return 1
        fi
        say "installed=yes"
        say "loaded=yes"
        LAST_RUN="$($SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {print $2; exit}')"
        say "last_exit=${LAST_RUN:-unknown}"
        # ALLOW-LIST, not a blacklist: a loaded agent exiting 1/2/127 is a box whose harness is not
        # being advanced, and 127 is the inert-enforcer shape this installer exists to prevent.
        # ⛔ THE PASS'S OWN SUCCESS CODES, NOT THE DISK REAPER'S. 0 is `current`, 10 is `advanced` and
        # 11 is `mended` — the same set the systemd unit's SuccessExitStatus renders. Copied from the
        # reaper's `0|5|6` instead, this treated **10 as a failure**: on a Mac that had just been
        # advanced (every tick after a merge) `--status` exited 1, so `cloud-cell-bringup.sh` refused
        # `CELL READY` for the healthiest possible state.
        case "${LAST_RUN:-}" in
            ''|-|0|10|11) ;;
            *) err "the last pass exited ${LAST_RUN} — the harness is not being applied; see $STATE_DIR/harness-apply.log"; return 1 ;;
        esac
        say "cadence=StartInterval=${INTERVAL_MIN}m"
    else
        if ! $SC cat "$UNIT_NAME.service" >/dev/null 2>&1; then
            say "installed=no"
            return 1
        fi
        say "installed=yes"
        say "enabled=$($SC is-enabled "$UNIT_NAME.timer" 2>/dev/null || echo no)"
        ACTIVE="$($SC is-active "$UNIT_NAME.timer" 2>/dev/null || echo no)"
        say "timer_active=$ACTIVE"
        say "next_run=$($SC list-timers --all --no-pager 2>/dev/null | awk -v u="$UNIT_NAME.timer" '$0 ~ u {print $1" "$2" "$3; exit}')"
        # ⛔ AN ENABLED-BUT-INACTIVE TIMER IS NOT A SCHEDULE. Returning 0 there would certify a box
        # whose harness is never applied — the inert-enforcer shape, in the verb meant to detect it.
        case "${ACTIVE:-}" in
            active|activating) ;;
            *) err "the timer is '${ACTIVE:-unknown}', not active — the harness will NOT be applied unattended"; return 1 ;;
        esac
    fi
    # The PASS RECORD is the third leg: the scheduler can be armed while every pass fails. Its own
    # `--print-status` applies the staleness bound, so "the timer stopped firing" is an alarm and not
    # a quiet absence.
    say "--- pass record ---"
    # ⛔ NOT `REC="$(cond && bash … || printf …)"`. The `||` arm fires on a NON-ZERO rc — which is
    # exactly the answer this leg exists to read — so it replaced a `status=failed rc=21` line with
    # "no pass script" and reset REC_RC to the printf's 0: the gate then certified an armed scheduler
    # whose every pass was refusing (measured while writing this file).
    if [ -f "$PASS" ]; then
        REC="$(bash "$PASS" --print-status 2>&1)"; REC_RC=$?
    else
        REC="status=unknown — no pass script at $PASS"; REC_RC=3
    fi
    printf '%s\n' "$REC" | sed 's/^/  /'
    # ⛔ `status=never` IS A NOTE, NOT A FAILURE — but only when the SCHEDULER says it fired. A fresh
    # install has no record for a few minutes (the first tick), and failing readiness there would red
    # every bring-up that installs this. It is a FAILURE when the job claims it ran and left no usable
    # record: that is a pass refusing before it can write anything. Same split the disk-reaper status
    # verb records, and for the same reason.
    case "$REC" in
        status=never*)
            case "${LAST_RUN:-}" in
                ''|-|0) say "  note=no pass has completed yet (the job runs one at its first tick)" ;;
                unknown) say "  note=no pass record yet, and the scheduler's last run is unreadable" ;;
                *) [ "$TARGET" = launchd ] && { err "the job last exited $LAST_RUN and no pass record exists — the pass is refusing before it can record anything"; return 1; } ;;
            esac ;;
        *) [ "$REC_RC" -eq 0 ] || { err "the pass record is not healthy (see above)"; return 1; } ;;
    esac
    return 0
}

do_uninstall() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        say "dry-run: would disable and remove the installed schedule (nothing was changed)"
        return 0
    fi
    choose_target || { err "no scheduler available"; return 1; }
    if [ "$TARGET" = "launchd" ]; then
        # ⛔ A DISARM IS NOT DONE BECAUSE `bootout` RETURNED: the plist can be gone while the LOADED
        # job keeps firing until logout. Prove the label is gone.
        $SC bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || $SC unload "$UNIT_DIR/$LABEL.plist" >/dev/null 2>&1 || true
        rm -f "$UNIT_DIR/$LABEL.plist"
        if $SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {found=1} END{exit !found}'; then
            err "$LABEL is STILL LOADED after bootout — it will keep firing; log out or reboot, or bootout gui/$(id -u)/$LABEL by hand"
            return 1
        fi
        say "uninstalled $LABEL from $UNIT_DIR (not loaded)"
        return 0
    fi
    $SC disable --now "$UNIT_NAME.timer" >/dev/null 2>&1 || true
    case "$TARGET" in
        user)     rm -f "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer" || { err "cannot remove the unit files from $UNIT_DIR (target=user)"; return 1; } ;;
        override) rm -f "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer" || { err "cannot remove the unit files from $UNIT_DIR (target=override)"; return 1; } ;;
        *)        ${SUDO-sudo -n} rm -f "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer" || { err "cannot remove the unit files from $UNIT_DIR (target=system)"; return 1; } ;;
    esac
    $SC daemon-reload >/dev/null 2>&1 || true
    if [ -e "$UNIT_DIR/$UNIT_NAME.service" ] || [ -e "$UNIT_DIR/$UNIT_NAME.timer" ]; then
        err "NOT reporting this as uninstalled — the unit files are STILL PRESENT in $UNIT_DIR (target=$TARGET)"
        err "(an enabled timer here still fires the pass; remove them as the right user, then re-run)"
        return 1
    fi
    # The user scope is re-derived from the CURRENT $HOME, so an install made from another context
    # leaves a unit this run cannot even see. Reported, not failed: a cell can legitimately carry a
    # system-scope install while an operator uninstalls a user-scope one.
    for d in "$HOME/.config/systemd/user" /root/.config/systemd/user /home/*/.config/systemd/user /etc/systemd/system \
             $(printf '%s' "${HARNESS_APPLY_EXTRA_SCOPES:-}" | tr ':' ' '); do
        [ -n "$d" ] || continue
        [ "$d" = "$UNIT_DIR" ] && continue
        if [ -e "$d/$UNIT_NAME.service" ] || [ -e "$d/$UNIT_NAME.timer" ]; then
            err "note: $UNIT_NAME is ALSO installed in $d (another scope) — this removed $UNIT_DIR only"
            err "      an enabled timer THERE still fires the pass; uninstall it from that scope"
        fi
    done
    say "uninstalled $UNIT_NAME from $UNIT_DIR (target=$TARGET)"
    return 0
}

MODE=--install
while [ $# -gt 0 ]; do
    case "$1" in
        --install)   MODE=--install ;;
        --dry-run)   DRY_RUN=1 ;;
        --status)    MODE=--status ;;
        --uninstall) MODE=--uninstall ;;
        --help|-h)   help_text; exit $? ;;
        *)           usage ;;
    esac
    shift
done

case "$MODE" in
    --install)   do_install ;;
    --status)    do_status ;;
    --uninstall) do_uninstall ;;
esac
