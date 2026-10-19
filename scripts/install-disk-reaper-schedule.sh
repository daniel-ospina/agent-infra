#!/usr/bin/env bash
# install-disk-reaper-schedule.sh — ONE verb that puts the consolidated disk reaper on the clock on
# BOTH platforms this fleet runs on (agent-infra#2032 on the cells, #2048 on the Macs).
#
# WHY THIS IS AN INSTALLER AND NOT A LINE IN A BRING-UP. The artifact has to be rendered from machine
# state (HOME, PATH, the repos this box actually has, the state dir, the pass's own path) and installed
# idempotently; the bring-up is the TRIGGER, this is the policy of WHERE and HOW. Same split as
# install-launchd.sh on macOS — one place renders and converges, everything else calls it.
#
# ONE PASS, TWO SCHEDULERS. The pass (`disk-reaper.sh`) and its flags are IDENTICAL on both platforms;
# only the scheduler differs:
#   Linux  → systemd timer  eldato-disk-reaper.timer  (+ .service, Type=oneshot, hourly)
#   Darwin → launchd job    com.eldato.disk-reaper    (StartInterval 3600, RunAtLoad)
# This file also carries the one other thing that legitimately differs — the BINARY-RESOLUTION SEAM.
# On macOS a launchd-spawned `bash` cannot read a script, or a repo, under ~/Documents: TCC is
# per-binary and denies it (#427; the falsified control experiment is in #1095). So the Darwin job
# starts the checkout's own interpreter on the farmed launcher `pi-reap-worktrees-launchd.py`, which
# reads the SAME `disk-reaper.sh` and hands it to bash on stdin, with the SAME mode flag. The entry
# point and the flags are unchanged; only the process that opens the file is. That is the seam.
#
# ⛔ ARMING IS A SEPARATE, VISIBLE STEP (#1678, owner ruling 2026-10-11). This installer ships
# REPORT-ONLY: with no mode flag it installs a job whose argument list carries the pass's dry-run flag.
# `--apply` installs the armed job, and the flag lands INSIDE the installed unit/plist, so the arming
# is readable from the scheduled artifact itself and is never hidden in an environment default.
# Re-running with `--dry-run` installs the report-only job again: reversible, one copy, no drift.
#
# ⛔ A CHANGED PASS RELOADS ITS JOB (#1738). An edit to a script a scheduled job runs is silent until
# the job is reloaded — the loaded job keeps the program and environment it was bootstrapped with. So
# the installer records the pass's SHA-256 in $STATE_DIR/disk-reaper.schedule and FORCES a reload when
# the pass's bytes change, even when the unit text is byte-identical, and names why
# (`reload_reason=unit-changed|pass-changed|not-loaded|none`). On systemd the script is re-read at
# every ExecStart; the reload happens there too, so the rule is ONE rule on both platforms instead of a
# Mac-only carve-out that quietly stops applying when the pass moves.
#
# `--status` answers the same questions on both platforms in ONE vocabulary: `platform=`,
# `scheduler=`, `job=`, `installed=`, `enabled=`, `active=`, `armed=`, `next_run=`, `interval_seconds=`,
# `last_exit=`, `pass_drift=`, and then the pass record itself — the SAME file, written by the SAME
# pass, so "what did it free and did it succeed" cannot drift between a cell and a laptop. `armed=` is
# read from the INSTALLED artifact, never from the flags this invocation was given.
#
# Install targets:
#   Linux   1. a SYSTEM unit via passwordless sudo (/etc/systemd/system) — the cell's normal shape;
#           2. a USER unit (~/.config/systemd/user) when systemd's user manager answers;
#           3. nothing — a loud FAILURE with the remedy, never a silent no-op.
#   Darwin  ~/Library/LaunchAgents/com.eldato.disk-reaper.plist, bootstrapped into gui/$(id -u).
#   A box with neither scheduler is a loud FAILURE: a reaper that was "installed" but never fires is
#   the false PASS this repo keeps removing.
#
# Usage:
#   install-disk-reaper-schedule.sh [--install] [--apply|--dry-run] [--preview]
#                                   [--status] [--uninstall] [--help]
#
#   (no mode flag)  install a REPORT-ONLY job (the shipped stance, #1678)
#   --apply         install the ARMED job (owner decision; visible in the installed unit)
#   --dry-run       install the report-only job (the default, said explicitly)
#   --preview       render and print what WOULD be installed; write nothing, install nothing
#   --status        is this box reaped, by what, when did the last pass run, what did it free, did it
#                   succeed — exit 0 when scheduled+loaded, 1 when not scheduled
#   --uninstall     bootout/disable and remove the job (and the schedule stamp)
#
# Env seams (tests + unusual boxes):
#   DISK_REAPER              the pass to schedule (default: the farmed copy, else beside this script)
#   DISK_REAPER_STATE_DIR    status/log/stamp dir (default $HOME/.pi/agent/state)
#   DISK_REAPER_REPOS        colon-separated repos the venv/worktree classes scan
#   DISK_REAPER_WT_AGED_DAYS worktree age floor for the scheduled pass (default 7)
#   DISK_REAPER_PLATFORM     override detection: linux | darwin (tests)
#   TEMPLATES_DIR            systemd template dir (default: this repo's templates/systemd)
#   LAUNCHD_TEMPLATE         launchd template (default: templates/launchd/com.eldato.disk-reaper.plist.tmpl)
#   SYSTEMD_UNIT_DIR         unit dir OVERRIDE (tests: a temp dir)
#   SYSTEMCTL                `systemctl` to call (default `sudo -n systemctl`)
#   SUDO                     `sudo` probe (default `sudo -n`)
#   DISK_REAPER_AGENTS_DIR   launchd install dir (default $HOME/Library/LaunchAgents)
#   LAUNCHCTL                `launchctl` to call (tests: a shim)
#   LAUNCHD_DOMAIN           launchd domain (default gui/$(id -u))
#   DISK_REAPER_LABEL        launchd label override (tests: a throwaway label)
#   DISK_REAPER_PYTHON       interpreter for the Darwin launcher (default: a tortoise checkout's
#                            .venv python — the binary that HOLDS the TCC access — else python3)
#   ELDATO_ALLOW_TEST_HOME   permit launchd management when $HOME is not the real home (tests ONLY;
#                            requires a launchctl shim — same contract as install-launchd.sh, #446)
#
# Exit codes: 0 ok · 1 failure (named) · 2 usage.
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Templates are NOT farmed (only scripts are), so a farmed copy of this installer must be able to find
# them in the checkout that installed the layer. First existing wins.
if [ -z "${TEMPLATES_DIR:-}" ]; then
    for _cand in "${AGENT_INFRA_PATH:-}/templates/systemd" "$INFRA_ROOT/templates/systemd"; do
        [ -n "$_cand" ] && [ -d "$_cand" ] && { TEMPLATES_DIR="$_cand"; break; }
    done
fi
if [ -z "${LAUNCHD_TEMPLATE:-}" ]; then
    for _cand in "${AGENT_INFRA_PATH:-}/templates/launchd/com.eldato.disk-reaper.plist.tmpl" \
                 "$INFRA_ROOT/templates/launchd/com.eldato.disk-reaper.plist.tmpl"; do
        [ -n "$_cand" ] && [ -f "$_cand" ] && { LAUNCHD_TEMPLATE="$_cand"; break; }
    done
fi
TEMPLATES_DIR="${TEMPLATES_DIR:-$INFRA_ROOT/templates/systemd}"
LAUNCHD_TEMPLATE="${LAUNCHD_TEMPLATE:-$INFRA_ROOT/templates/launchd/com.eldato.disk-reaper.plist.tmpl}"
STATE_DIR="${DISK_REAPER_STATE_DIR:-${HOME:?HOME is required}/.pi/agent/state}"
AGED_DAYS="${DISK_REAPER_WT_AGED_DAYS:-7}"
UNIT_NAME="eldato-disk-reaper"                           # systemd
LABEL="${DISK_REAPER_LABEL:-com.eldato.disk-reaper}"     # launchd
STAMP="$STATE_DIR/disk-reaper.schedule"
MODE_FLAG="--dry-run"                                    # the shipped stance (#1678)
MODE=--install
INTERVAL_SECONDS=3600

say() { printf '%s\n' "$*"; }
err() { printf '%s: %s\n' "${0##*/}" "$*" >&2; }
warn() { printf '%s: WARNING: %s\n' "${0##*/}" "$*" >&2; }

usage() { sed -n '2,81p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

# ── resolve the pass ────────────────────────────────────────────────────────────────────────────
# The FARMED copy first: it is what a box has after `pi-bootstrap/setup.sh`, and a job pointing at a
# worktree checkout would break the day that worktree is reaped (by this very tool).
REAPER=""
if [ -n "${DISK_REAPER:-}" ] && [ ! -f "$DISK_REAPER" ]; then
    err "\$DISK_REAPER is set to '$DISK_REAPER' but that is not a regular file — refusing to install a job that points at a DIFFERENT copy of the pass"
    exit 2
fi
for cand in "${DISK_REAPER:-}" "${HOME:-}/.pi/agent/scripts/disk-reaper.sh" "$INFRA_ROOT/scripts/disk-reaper.sh"; do
    [ -n "$cand" ] || continue
    if [ -f "$cand" ]; then REAPER="$cand"; break; fi
done

# ── repos: what this box actually has ───────────────────────────────────────────────────────────
# Rendered into the job so the scheduled pass never depends on a shell's environment. A candidate is
# kept only when git answers for it — a job scanning a path that is not a repo fails closed every hour,
# which is how an alarm becomes wallpaper.
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

# ── the Darwin binary-resolution seam ──────────────────────────────────────────────────────────
# The interpreter must be one that HOLDS the TCC access to the repos: the tortoise checkout's own
# .venv python is the one recorded working end-to-end (#1095: WORKTREES=454 GH=ok). A machine with no
# tortoise checkout falls back to `python3` — the job still installs (the uv class needs no repo) and
# --status prints the runner, so a class that fails closed is diagnosable without reading a log.
resolve_python() {
    local cand
    if [ -n "${DISK_REAPER_PYTHON:-}" ]; then printf '%s' "$DISK_REAPER_PYTHON"; return 0; fi
    for cand in "${TORTOISE_REPO:-}/.venv/bin/python" "${HOME:-}/Documents/GitHub/tortoise/.venv/bin/python"; do
        [ -n "$cand" ] && [ -x "$cand" ] && { printf '%s' "$cand"; return 0; }
    done
    command -v python3 2>/dev/null && return 0
    return 1
}

resolve_launcher() { # the farmed launcher first: the farm is the copy a launchd job may read
    local cand
    for cand in "${HOME:-}/.pi/agent/scripts/pi-reap-worktrees-launchd.py" "$INFRA_ROOT/scripts/pi-reap-worktrees-launchd.py"; do
        [ -n "$cand" ] && [ -f "$cand" ] && { printf '%s' "$cand"; return 0; }
    done
    return 1
}

# ── platform ───────────────────────────────────────────────────────────────────────────────────
case "${DISK_REAPER_PLATFORM:-$(uname -s 2>/dev/null)}" in
    linux|Linux)   PLATFORM=linux ;;
    darwin|Darwin) PLATFORM=darwin ;;
    *)             PLATFORM=unknown ;;
esac

# ── render ─────────────────────────────────────────────────────────────────────────────────────
# sed_repl — make a value safe BOTH as the replacement half of `s|…|…|g` and inside the XML text node
# it lands in. Two escapes, and the XML one is not optional: `&` is the entity introducer (an
# unescaped one makes the plist malformed — measured in #1719, `plutil -lint` refused it) and `&`/`\`
# are sed replacement metacharacters (a value carrying either is silently corrupted into the output).
sed_repl() {
    printf '%s' "$1" \
        | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        | sed -e 's/[&\\|]/\\&/g'
}

# render <template> <dest> — one placeholder set for both templates. A leftover {{ is a REFUSAL: it
# would install a job whose argument is the literal token, and the job would be inert while `--status`
# called it scheduled.
render() {
    local tpl="$1" dest="$2"
    sed -e "s|{{USER}}|$(sed_repl "$(id -un)")|g" \
        -e "s|{{HOME}}|$(sed_repl "$HOME")|g" \
        -e "s|{{PATH}}|$(sed_repl "$PATH")|g" \
        -e "s|{{STATE_DIR}}|$(sed_repl "$STATE_DIR")|g" \
        -e "s|{{REPOS}}|$(sed_repl "$REPOS")|g" \
        -e "s|{{AGED_DAYS}}|$(sed_repl "$AGED_DAYS")|g" \
        -e "s|{{INTERVAL}}|$(sed_repl "$INTERVAL_SECONDS")|g" \
        -e "s|{{REAPER}}|$(sed_repl "$REAPER")|g" \
        -e "s|{{MODE_FLAG}}|$(sed_repl "$MODE_FLAG")|g" \
        -e "s|{{LABEL}}|$(sed_repl "$LABEL")|g" \
        -e "s|{{PYTHON_BIN}}|$(sed_repl "${PYTHON_BIN:-}")|g" \
        -e "s|{{LAUNCHER}}|$(sed_repl "${LAUNCHER:-}")|g" \
        "$tpl" >"$dest" || return 1
    if grep -q '{{' "$dest"; then
        err "unresolved placeholder in $tpl — refusing to install a job whose argument is a literal token"
        grep -n '{{' "$dest" >&2
        return 1
    fi
    return 0
}

# ── the schedule stamp: which pass bytes the JOB was installed against (#1738) ────────────────
no_yes() { [ "${1:-0}" = 1 ] && printf 'yes' || printf 'no'; }
stamp_field() { [ -f "$STAMP" ] || return 0; sed -n "s/^$1=//p" "$STAMP" | head -1; }
pass_sha() {
    [ -f "$1" ] || return 0
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | cut -d' ' -f1
    fi
}
write_stamp() { # write_stamp <job>
    local sha tmp
    sha="$(pass_sha "$REAPER")"
    mkdir -p "$STATE_DIR" 2>/dev/null || { err "cannot create state dir $STATE_DIR"; return 1; }
    tmp="$STAMP.tmp.$$"
    {
        printf 'platform=%s\n' "$PLATFORM"
        printf 'scheduler=%s\n' "$SCHEDULER"
        printf 'job=%s\n' "$1"
        printf 'armed=%s\n' "${MODE_FLAG#--}"
        printf 'pass=%s\n' "$REAPER"
        printf 'pass_sha=%s\n' "$sha"
        printf 'installed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$tmp" 2>/dev/null && mv -f "$tmp" "$STAMP" 2>/dev/null \
        || { err "cannot write the schedule stamp $STAMP"; rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

# ── systemd backend ───────────────────────────────────────────────────────────────────────────
SD_TARGET=""; UNIT_DIR=""; SC=""
choose_systemd_target() {
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ]; then
        SD_TARGET="override"; UNIT_DIR="$SYSTEMD_UNIT_DIR"; SC="${SYSTEMCTL:-systemctl}"
        return 0
    fi
    if [ "${SUDO:-sudo -n}" = "" ] || ${SUDO:-sudo -n} true >/dev/null 2>&1; then
        SD_TARGET="system"; UNIT_DIR="/etc/systemd/system"; SC="${SYSTEMCTL:-sudo -n systemctl}"
        return 0
    fi
    if systemctl --user show-environment >/dev/null 2>&1; then
        SD_TARGET="user"; UNIT_DIR="$HOME/.config/systemd/user"; SC="systemctl --user"
        return 0
    fi
    return 1
}

sd_install() {
    local src_svc="$TEMPLATES_DIR/$UNIT_NAME.service" src_tim="$TEMPLATES_DIR/$UNIT_NAME.timer"
    local tmpd changed=0 pass_changed=0 reason="none" installed_sha
    [ -f "$src_svc" ] && [ -f "$src_tim" ] || { err "systemd templates missing under $TEMPLATES_DIR"; return 1; }
    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/disk-reaper-unit.XXXXXX")" || { err "cannot create a temp dir"; return 1; }
    render "$src_svc" "$tmpd/$UNIT_NAME.service" || { rm -rf "$tmpd"; return 1; }
    render "$src_tim" "$tmpd/$UNIT_NAME.timer"   || { rm -rf "$tmpd"; return 1; }
    # A USER unit may not carry User= (systemd rejects it), so drop that line in that mode.
    if [ "$SD_TARGET" = "user" ]; then
        sed -i.bak '/^User=/d' "$tmpd/$UNIT_NAME.service" && rm -f "$tmpd/$UNIT_NAME.service.bak"
    fi

    if [ "${PREVIEW:-0}" = "1" ]; then
        say "preview: would install to $UNIT_DIR (target=$SD_TARGET) and enable $UNIT_NAME.timer"
        say "--- $UNIT_NAME.service ---"; sed 's/^/  /' "$tmpd/$UNIT_NAME.service"
        say "--- $UNIT_NAME.timer ---";   sed 's/^/  /' "$tmpd/$UNIT_NAME.timer"
        rm -rf "$tmpd"
        return 0
    fi

    # Install only when the rendered bytes differ; reload when EITHER the unit or the pass changed.
    cmp -s "$tmpd/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.service" || changed=1
    cmp -s "$tmpd/$UNIT_NAME.timer"   "$UNIT_DIR/$UNIT_NAME.timer"   || changed=1
    installed_sha="$(pass_sha "$REAPER")"
    [ "$(stamp_field pass_sha)" = "$installed_sha" ] || pass_changed=1
    [ -f "$UNIT_DIR/$UNIT_NAME.timer" ] || { changed=1; pass_changed=1; }   # first install

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
    [ "$changed" = 1 ] && reason="unit-changed"
    [ "$pass_changed" = 1 ] && [ "$reason" = none ] && reason="pass-changed"
    if [ "$reason" != none ]; then
        # Restart the TIMER, not the service: the timer carries OnCalendar/Persistent, and a restart of
        # an already-loaded definition is the only way to make an edited definition apply.
        $SC restart "$UNIT_NAME.timer" >/dev/null 2>&1 || true
    fi

    say "installed: platform=linux scheduler=systemd target=$SD_TARGET dir=$UNIT_DIR changed=$changed pass_changed=$(no_yes "$pass_changed") reload_reason=$reason"
    say "  pass:   $REAPER"
    say "  armed:  ${MODE_FLAG#--} (the mode flag is in ExecStart, not an environment default)"
    say "  repos:  ${REPOS:-<none>}  (worktree floor ${AGED_DAYS}d)"
    say "  state:  $STATE_DIR/disk-reaper.status"
    if $SC is-enabled "$UNIT_NAME.timer" >/dev/null 2>&1; then
        say "  timer:  enabled"
    else
        err "timer is NOT enabled after install — the reaper will not run unattended"; return 1
    fi
    write_stamp "$UNIT_NAME.timer" || return 1
    return 0
}

# armed_from_file <installed unit/plist> — apply|dry-run|unknown, read from the ARTIFACT.
# Only the ExecStart (systemd) / <string> (launchd) line is inspected, never the comments: the header
# of each template explains both modes, and a comment match would report an armed job on a report-only
# definition (or the reverse), which is the one answer this verb exists to give.
armed_from_file() {
    local f="$1" line
    [ -f "$f" ] || { printf 'unknown'; return 0; }
    case "$f" in
        *.service) line="$(sed -n 's/^ExecStart=//p' "$f")" ;;
        *)         line="$(sed -nE 's/.*<string>(--apply|--dry-run)<\/string>.*/\1/p' "$f")" ;;
    esac
    case "$line" in
        *--apply*)   printf 'apply' ;;
        *--dry-run*) printf 'dry-run' ;;
        *)           printf 'unknown' ;;
    esac
}

sd_status() {
    local next last_exit svc
    choose_systemd_target || { err "no systemd scheduler available"; return 1; }
    svc="$UNIT_DIR/$UNIT_NAME.service"
    say "platform=linux"
    say "scheduler=systemd"
    say "job=$UNIT_NAME.timer"
    say "job_path=$UNIT_DIR/$UNIT_NAME.timer"
    # PRESENT means the installed file is there. When it is not readable (a sudo-installed unit on an
    # odd box) `systemctl cat` is the second opinion — it exits non-zero for an unknown unit, which is
    # what makes "installed=no" a real answer instead of a fallback that always succeeds.
    if [ ! -f "$svc" ] && ! $SC cat "$UNIT_NAME.service" >/dev/null 2>&1; then
        say "installed=no"
        say "enabled=disabled"
        say "active=inactive"
        return 1
    fi
    say "installed=yes"
    say "enabled=$($SC is-enabled "$UNIT_NAME.timer" 2>/dev/null || echo disabled)"
    say "active=$($SC is-active "$UNIT_NAME.timer" 2>/dev/null || echo inactive)"
    next="$($SC list-timers --all --no-pager 2>/dev/null | awk -v u="$UNIT_NAME.timer" '$0 ~ u {print $1" "$2" "$3; exit}')"
    say "next_run=${next:-unknown}"
    last_exit="$($SC show -p ExecMainStatus --value "$UNIT_NAME.service" 2>/dev/null)"
    case "$last_exit" in ''|*[!0-9]*) last_exit=unknown ;; esac
    say "last_exit=$last_exit"
    say "interval_seconds=$INTERVAL_SECONDS"
    say "armed=$(armed_from_file "$svc")"
    return 0
}

sd_uninstall() {
    if [ "${PREVIEW:-0}" = "1" ]; then
        say "preview: would disable and remove $UNIT_NAME.service/.timer from $UNIT_DIR (nothing was changed)"
        return 0
    fi
    choose_systemd_target || { err "no systemd scheduler available"; return 1; }
    $SC disable --now "$UNIT_NAME.timer" >/dev/null 2>&1 || true
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ]; then
        rm -f "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer"
    else
        ${SUDO:-sudo -n} rm -f "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer"
    fi
    $SC daemon-reload >/dev/null 2>&1 || true
    rm -f "$STAMP"
    say "uninstalled $UNIT_NAME from $UNIT_DIR"
    return 0
}

# ── launchd backend ──────────────────────────────────────────────────────────────────────────
LD_DIR=""; LC=""; LD_DOMAIN=""
choose_launchd_target() {
    LD_DIR="${DISK_REAPER_AGENTS_DIR:-${HOME:?HOME is required}/Library/LaunchAgents}"
    LC="${LAUNCHCTL:-launchctl}"
    LD_DOMAIN="${LAUNCHD_DOMAIN:-gui/$(id -u)}"
    # `command -v` returns 1 for an absolute path in bash, so test executability for a path and PATH
    # lookup for a bare name — a shim passed as /tmp/x/launchctl is a legitimate seam.
    case "$LC" in
        */*) [ -x "$LC" ] || return 1 ;;
        *)   command -v "$LC" >/dev/null 2>&1 || return 1 ;;
    esac
    return 0
}

ld_loaded() { $LC print "$LD_DOMAIN/$LABEL" >/dev/null 2>&1; }

ld_reload() { # (re)bootstrap the plist into the user domain
    local dest="$LD_DIR/$LABEL.plist"
    $LC enable "$LD_DOMAIN/$LABEL" >/dev/null 2>&1 || true
    $LC bootout "$LD_DOMAIN/$LABEL" >/dev/null 2>&1 || true
    if ! $LC bootstrap "$LD_DOMAIN" "$dest"; then
        rm -f "$dest"   # nothing half-installed
        err "launchctl bootstrap exited nonzero for $LABEL — see '$LC print $LD_DOMAIN/$LABEL'"
        return 1
    fi
    return 0
}

ld_install() {
    local tmp changed=0 pass_changed=0 reason="none" installed_sha dest
    [ -f "$LAUNCHD_TEMPLATE" ] || { err "launchd template missing: $LAUNCHD_TEMPLATE"; return 1; }
    choose_launchd_target || { err "no launchctl available (${LC:-launchctl}) — cannot install a launchd job"; return 1; }
    dest="$LD_DIR/$LABEL.plist"

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/disk-reaper-plist.XXXXXX")" || { err "cannot create a temp dir"; return 1; }
    render "$LAUNCHD_TEMPLATE" "$tmp/$LABEL.plist" || { rm -rf "$tmp"; return 1; }
    # A malformed plist is an inert job: launchd accepts nothing of it. Lint where the tool exists.
    if command -v plutil >/dev/null 2>&1 && ! plutil -lint "$tmp/$LABEL.plist" >/dev/null 2>&1; then
        err "rendered plist is MALFORMED — refusing to install it"; plutil -lint "$tmp/$LABEL.plist" >&2 || true
        rm -rf "$tmp"; return 1
    fi

    if [ "${PREVIEW:-0}" = "1" ]; then
        say "preview: would install to $dest and bootstrap $LD_DOMAIN/$LABEL"
        sed 's/^/  /' "$tmp/$LABEL.plist"
        rm -rf "$tmp"
        return 0
    fi

    cmp -s "$tmp/$LABEL.plist" "$dest" 2>/dev/null || changed=1
    installed_sha="$(pass_sha "$REAPER")"
    [ "$(stamp_field pass_sha)" = "$installed_sha" ] || pass_changed=1
    [ -f "$dest" ] || pass_changed=1
    ld_loaded || pass_changed=1          # not loaded: it must be bootstrapped whatever the bytes say

    mkdir -p "$LD_DIR" || { err "cannot create $LD_DIR"; rm -rf "$tmp"; return 1; }
    mv "$tmp/$LABEL.plist" "$dest" || { err "cannot write $dest"; rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"

    if [ "$changed" = 1 ]; then reason="unit-changed"; elif [ "$pass_changed" = 1 ]; then reason="pass-changed"; fi
    if [ "$reason" != none ]; then
        ld_reload || return 1
        ld_loaded || { err "$LABEL is not loaded after bootstrap — the reaper will not run unattended"; return 1; }
    fi

    say "installed: platform=darwin scheduler=launchd job=$LABEL dir=$LD_DIR changed=$changed pass_changed=$(no_yes "$pass_changed") reload_reason=$reason"
    say "  pass:   $REAPER"
    say "  armed:  ${MODE_FLAG#--} (the mode flag is in ProgramArguments, not an environment default)"
    say "  runner: $PYTHON_BIN $LAUNCHER --script <pass> ${MODE_FLAG}"
    say "          (the TCC seam: this interpreter holds the ~/Documents access a launchd bash is denied)"
    say "  repos:  ${REPOS:-<none>}  (worktree floor ${AGED_DAYS}d)"
    say "  state:  $STATE_DIR/disk-reaper.status"
    write_stamp "$LABEL" || return 1
    return 0
}

ld_status() {
    local dest print_out last_exit state
    choose_launchd_target || { err "no launchctl available (${LC:-launchctl})"; return 1; }
    dest="$LD_DIR/$LABEL.plist"
    say "platform=darwin"
    say "scheduler=launchd"
    say "job=$LABEL"
    say "job_path=$dest"
    if [ ! -f "$dest" ]; then
        say "installed=no"
        say "enabled=disabled"
        say "active=inactive"
        return 1
    fi
    say "installed=yes"
    print_out="$($LC print "$LD_DOMAIN/$LABEL" 2>/dev/null)"
    if [ -n "$print_out" ]; then say "enabled=enabled"; else say "enabled=disabled"; fi
    state="$(printf '%s\n' "$print_out" | sed -n 's/^[[:space:]]*state = //p' | head -1)"
    case "$state" in running) say "active=active" ;; *) say "active=inactive" ;; esac
    last_exit="$(printf '%s\n' "$print_out" | sed -n 's/^[[:space:]]*last exit code = //p' | head -1)"
    case "$last_exit" in ''|*[!0-9]*) last_exit=unknown ;; esac
    say "last_exit=$last_exit"
    # launchd does not report the next fire time of a StartInterval job. The interval is what it does
    # give; the pass record supplies the last run — reporting a computed "next" would be a guess.
    say "next_run=unknown"
    say "interval_seconds=$INTERVAL_SECONDS"
    say "armed=$(armed_from_file "$dest")"
    return 0
}

ld_uninstall() {
    local dest
    if [ "${PREVIEW:-0}" = "1" ]; then
        say "preview: would bootout ${LAUNCHD_DOMAIN:-gui/$(id -u)}/$LABEL and remove the plist (nothing was changed)"
        return 0
    fi
    choose_launchd_target || { err "no launchctl available (${LC:-launchctl})"; return 1; }
    dest="$LD_DIR/$LABEL.plist"
    $LC bootout "$LD_DOMAIN/$LABEL" >/dev/null 2>&1 || true
    rm -f "$dest"
    rm -f "$STAMP"
    say "uninstalled $LABEL from $LD_DIR"
    return 0
}

# ── the shared status tail: the pass record, the same file on both platforms ───────────────────
# Everything above says WHO schedules the pass. This says what the pass DID — read from
# `disk-reaper.sh --print-status`, i.e. the same record, in the same vocabulary, on a cell and on a
# Mac. The drift line answers #1738's question: are the bytes on disk the ones the JOB was installed
# against?
status_tail() {
    local sha stamp_sha drift pass_rc
    say "pass=$REAPER"
    say "pass_exists=$([ -f "$REAPER" ] && echo yes || echo no)"
    sha="$(pass_sha "$REAPER")"; stamp_sha="$(stamp_field pass_sha)"
    say "pass_sha=${sha:-unknown}"
    if [ -z "$stamp_sha" ]; then drift="no-stamp (installed by an older installer — re-run --install)"
    elif [ "$sha" = "$stamp_sha" ]; then drift="in-sync"
    else drift="CHANGED since install (re-run --install to reload the job)"; fi
    say "pass_drift=$drift"
    if [ ! -f "$REAPER" ]; then
        say "pass_status=unknown"
        return 1
    fi
    say "--- pass record ---"
    bash "$REAPER" --print-status 2>&1 | sed 's/^/  /'
    pass_rc=${PIPESTATUS[0]:-1}
    # `--print-status` exits 0 ok · 3 failed/stale/never. It is REPORTED, not folded into this verb's
    # exit code: whether the JOB is scheduled is a different question from whether the last pass was
    # clean, and conflating them would fail a fresh box whose first pass has not fired yet.
    say "pass_status_rc=$pass_rc"
    return 0
}

# ── main ───────────────────────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --install)   MODE=--install ;;
        --apply)     MODE_FLAG=--apply ;;
        --dry-run)   MODE_FLAG=--dry-run ;;
        --preview)   PREVIEW=1 ;;
        --status)    MODE=--status ;;
        --uninstall) MODE=--uninstall ;;
        --help|-h)   sed -n '2,81p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) usage ;;
    esac
    shift
done

if [ -z "$REAPER" ]; then
    err "disk-reaper.sh not found — looked at \$DISK_REAPER, \$HOME/.pi/agent/scripts, and $INFRA_ROOT/scripts. Farm it first: bash pi-bootstrap/setup.sh"
    exit 1
fi

REPOS="$(resolve_repos)"
if [ -z "$REPOS" ]; then
    warn "no repo resolved on this box — the venv and worktree classes will fail closed every pass. Set DISK_REAPER_REPOS or \$REPO."
fi

case "$PLATFORM" in
    linux)
        SCHEDULER=systemd
        choose_systemd_target || SD_UNAVAILABLE=1
        ;;
    darwin)
        SCHEDULER=launchd
        choose_launchd_target || { err "no launchctl available (${LC:-launchctl}) — cannot install a launchd job"; exit 1; }
        PYTHON_BIN="$(resolve_python)" || { err "no interpreter for the launchd launcher — install python3, or set \$DISK_REAPER_PYTHON"; exit 1; }
        LAUNCHER="$(resolve_launcher)" || { err "pi-reap-worktrees-launchd.py not found — looked at \$HOME/.pi/agent/scripts and $INFRA_ROOT/scripts. It is farmed by pi-bootstrap/setup.sh; a launchd-spawned bash cannot read a ~/Documents script (TCC), so it is required"; exit 1; }
        ;;
    *)
        err "no scheduler on this platform (uname=$(uname -s 2>/dev/null)) — this installer knows systemd (Linux) and launchd (Darwin). NOT silently skipping: a reaper that never runs is the failure this exists to remove."
        exit 1
        ;;
esac

# launchd addresses the USER domain by UID (#446): a run with a throwaway HOME bootstraps into the LIVE
# session, registering a job whose plist path dies with the temp dir. Refuse it unless a test opts in
# WITH a launchctl shim (same contract as install-launchd.sh).
# ⛔ DISCLOSED RESIDUAL — this guard is PLATFORM-GATED, and its probe is `dscl`. On a host without it
# (a Linux CI runner that FORCES DISK_REAPER_PLATFORM=darwin) the real home is UNKNOWN and the guard
# SKIPS, i.e. it fails OPEN. That state is unreachable in production (this installer manages launchd
# only on real Darwin, where `dscl` ships with the OS), and install-launchd.sh records the same
# residual for the same reason — but it is why the suite supplies a `dscl` SHIM: the refusal path is
# EXERCISED on every platform instead of being skipped on CI. A test that omits the shim gets the
# fail-open, not the refusal.
if [ "$PLATFORM" = darwin ] && [ "${ELDATO_ALLOW_TEST_HOME:-}" != "1" ]; then
    real_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p' | head -1 || true)"
    if [ -n "$real_home" ] && [ "$HOME" != "$real_home" ]; then
        err "refusing to manage launchd jobs: HOME=$HOME is not the real home ($real_home)."
        err "       A temp-HOME run registers jobs against plist paths that vanish (#446)."
        err "       Tests: put a launchctl shim on PATH and set ELDATO_ALLOW_TEST_HOME=1"
        exit 1
    fi
fi

# A pass that cannot complete yet is named at INSTALL time rather than discovered an hour later: on
# Darwin the pass's watchdog needs a `timeout` binary macOS does not ship (agent-infra#2046). The job is
# still installed — the schedule is what this verb owes — and both the installer and --status tolerate
# the pass exiting non-zero with a `fail-closed` verdict instead of hiding it.
if [ "$PLATFORM" = darwin ] && ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    warn "no 'timeout' binary on this Mac — disk-reaper.sh cannot complete a class until agent-infra#2046 lands. The job IS installed; every pass will report fail-closed (rc=3) with a named detail until it does."
fi

if [ "${SD_UNAVAILABLE:-0}" = 1 ] && [ "$PLATFORM" = linux ]; then
    err "no scheduler available: no passwordless sudo for a system unit, and no systemd user manager."
    err "       Install by hand, or give the box sudo. NOT silently skipping — a reaper that never runs is the failure this exists to remove."
    exit 1
fi

case "$MODE" in
    --install)
        case "$SCHEDULER" in
            systemd) sd_install ;;
            launchd) ld_install ;;
        esac
        ;;
    --status)
        case "$SCHEDULER" in
            systemd) sd_status; rc=$? ;;
            launchd) ld_status; rc=$? ;;
        esac
        status_tail || true
        exit "$rc"
        ;;
    --uninstall)
        case "$SCHEDULER" in
            systemd) sd_uninstall ;;
            launchd) ld_uninstall ;;
        esac
        ;;
esac
exit $?
