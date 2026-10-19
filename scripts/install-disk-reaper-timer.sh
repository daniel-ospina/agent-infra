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
# carries `--apply` and the arming is visible in the unit file itself. Nothing about the arming is
# hidden in an environment default.
# ⛔ `--dry-run` IS *NOT* A REPORT-ONLY INSTALL, and this header used to say it was. `--dry-run`
# sets DRY_RUN=1, and do_install then RENDERS AND PRINTS the unit and returns without touching
# anything — so an operator who followed the old sentence to disarm a cell's hourly DELETION pass got
# exit 0 and an unchanged, still-armed unit (T12 pins the same no-op on the `--uninstall` path). A
# false claim about arming on a deletion tool is the worst kind of false PASS, so it is corrected
# here: there is no disarm flag. Disarm by hand (`systemctl disable --now
# eldato-disk-reaper.timer`) and say so in the cell's record.
#   TO PREVIEW WHAT WOULD BE INSTALLED: `--dry-run`. TO INSTALL: `--install` (idempotent; a second
#   install with unchanged bytes is a no-op apart from `daemon-reload`).
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

# ── refuse to install a unit that points into transient scratch space ───────────────────────────
# MEASURED FAILURE (2026-10-18, pi-cell-2 and pi-cell-3). A harness invoked this installer with
# HOME=/tmp/tmp.XXXX/bg/home and no SYSTEMD_UNIT_DIR, so it took the SYSTEM target and wrote
#   ExecStart=/bin/bash /tmp/tmp.XXXX/bg/home/.pi/agent/scripts/disk-reaper.sh --apply
# into /etc/systemd/system. The mktemp dir was gone before the first tick, so EVERY hourly pass
# exited 127 (command not found) while `systemctl list-timers` kept showing the job as scheduled and
# healthy — an inert enforcer produced by the INSTALLER itself. The disks sat at 94-96% for hours
# with a "reaper" nominally on the clock. `init=...`/127 is invisible to a timer listing, so the
# installer is the only place that can see the path is transient, and it must not write it.
#
# WHY THE TEST IS A MKTEMP SHAPE AND NOT "/tmp". A cell legitimately runs with HOME=/tmp/cell-home
# and repos under /tmp/cell-ai; banning /tmp would refuse the real target. What is transient by
# CONSTRUCTION is a `mktemp -d` name (`tmp.` + random suffix), which is what leaked into the units.
is_transient_scratch() { # is_transient_scratch <path>
    # ⛔ NORMALISE FIRST. macOS sets TMPDIR with a TRAILING SLASH, so `mktemp -d "$TMPDIR/tmp.X"`
    # yields `/var/folders/.../T//tmp.X` — a DOUBLE slash. A naive prefix test against
    # `${TMPDIR%/}/tmp.` therefore MISSES it, and the guard silently allows the exact install it
    # exists to refuse (measured while writing this guard). Collapse duplicate slashes before any
    # comparison, and keep the comparison on path components rather than string prefixes.
    local p="$1" t t2
    [ -n "$p" ] || return 1
    # Collapse duplicate slashes (`tr -s /`). NOTE: the bash replacement form for this inserts a
    # LITERAL backslash and leaves the path unmatched — measured, do not "simplify" this back.
    p="$(printf '%s' "$p" | tr -s '/')"
    case "$p" in
        /tmp/tmp.?*|/var/tmp/tmp.?*|/private/tmp/tmp.?*|/private/var/tmp/tmp.?*) return 0 ;;
        # macOS's OWN temp root is /var/folders/<a>/<b>/T/ — NOT /tmp — so it must be named, or the
        # guard misses the very platform it was written on once TMPDIR is unset in its environment.
        /var/folders/*/*/T/tmp.?*|/private/var/folders/*/*/T/tmp.?*) return 0 ;;
    esac
    # TMPDIR may be somewhere else entirely. Compare BOTH spellings: macOS reports /var/folders/...
    # while the physical path (what `pwd -P` and a fixture actually carry) is /private/var/folders/...
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

# A path systemd can actually execute. systemd resolves a relative ExecStart argument against the
# UNIT's working directory (not this installer's cwd), so `ExecStart=/bin/bash scripts/disk-reaper.sh`
# is a permanent 127 even though it resolves fine HERE — and `[ -f ]` cannot tell the difference.
is_absolute_path() { case "$1" in /*) return 0 ;; *) return 1 ;; esac; }

# A genuine systemd unit directory. If the "test" override names one of these it is pointing at the
# real thing, so it must NOT inherit the override's scratch-friendly bypass.
is_real_systemd_dir() {
    case "$(printf '%s' "${1:-}" | tr -s '/')" in
        /etc/systemd*|/usr/lib/systemd*|/lib/systemd*|/run/systemd*) return 0 ;;
    esac
    return 1
}

refuse_transient_target() {
    local t="$TARGET" bad="" v p r
    # ── ALWAYS enforced, override or not ─────────────────────────────────────────────────────────
    for v in "REAPER=$REAPER" "HOME=$HOME" "STATE_DIR=$STATE_DIR"; do
        p="${v#*=}"
        is_absolute_path "$p" || {
            err "REFUSING: ${v%%=*} '$p' is not an absolute path — systemd resolves ExecStart against the unit's working directory, so the pass would exit 127 every tick"
            return 1
        }
    done
    [ -f "$REAPER" ] && [ -r "$REAPER" ] || {
        err "reaper '$REAPER' does not exist (or is unreadable) — refusing to install a unit that cannot run"
        return 1
    }
    # ── The scratch heuristic: skipped ONLY for a genuine scratch override ───────────────────────
    # ⛔ The override is documented as "tests: a temp dir". Nothing used to stop it naming
    # /etc/systemd/system — which reproduced the measured defect verbatim, one env var away — and it
    # ALSO short-circuited the existence check above. It bypasses only the HEURISTIC, never those —
    # and it used to bypass three MORE checks by returning HERE, above them: the whitespace refusal, the
    # missing-delegate warning and the state-dir writability probe. Every install case in the suite
    # passes a scratch SYSTEMD_UNIT_DIR, so those three guards had NO test that reached them at all.
    # So the bypass is now scoped to the three `is_transient_scratch` calls below and nothing else.
    skip_scratch_heuristic=0
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ] && ! is_real_systemd_dir "$SYSTEMD_UNIT_DIR"; then
        skip_scratch_heuristic=1
    fi
    if [ "$skip_scratch_heuristic" = 1 ]; then
        :   # a scratch override (the documented test seam): the heuristic below is not applied
    else
        is_transient_scratch "$REAPER"      && bad="REAPER=$REAPER"
        is_transient_scratch "$HOME"        && bad="${bad:+$bad; }HOME=$HOME"
        is_transient_scratch "$STATE_DIR"   && bad="${bad:+$bad; }STATE_DIR=$STATE_DIR"
    fi
    if [ -n "$bad" ]; then
        err "REFUSING a $t install rendered from transient scratch space: $bad"
        err "The unit would point at a directory that is deleted before the first tick, so every pass"
        err "exits 127 while 'list-timers' shows the job as scheduled. That is the exact inert-enforcer"
        err "shape this installer must never create (agent-infra#2032, measured on pi-cell-2/-3)."
        err "Re-run from the box's real HOME (a login shell or cloud-cell-bringup.sh), or set"
        err "SYSTEMD_UNIT_DIR to a scratch dir when this is a test."
        return 1
    fi
    # The unit PINS the three delegates beside $REAPER, so a missing one is a class that fails
    # closed (exit 3, red) on every pass — name it at install time rather than after the fact.
    for d in pi-cache-reap.sh reap-lane-venvs.sh pi-reap-worktrees.sh; do
        [ -f "${REAPER%/*}/$d" ] || err "WARNING: ${REAPER%/*}/$d is missing — the unit pins it, so that class will fail closed (exit 3, red) every pass"
    done
    # The service runs as the INVOKING user, so writeability tested here is the service's own. A
    # state dir it cannot write makes every pass exit 3 on a unit that installed cleanly.
    # ⛔ `--dry-run` MUST NOT CREATE IT. This probe used to `mkdir -p` unconditionally, and
    # refuse_transient_target runs before the DRY_RUN branch — so the documented "preview" wrote to the
    # filesystem and, on a box whose HOME was scratch, refused on a path it was only supposed to
    # describe. Under DRY_RUN the probe is read-only: an existing dir is checked for writability, and a
    # missing one is reported as "would create" instead of created.
    if [ "${DRY_RUN:-0}" = "1" ]; then
        if [ -e "$STATE_DIR" ] && [ ! -w "$STATE_DIR" ]; then
            err "REFUSING: state dir '$STATE_DIR' exists and is not writable by $(id -un) — the unit runs as this user and every pass would fail closed (exit 3)"
            return 1
        fi
        [ -e "$STATE_DIR" ] || say "dry-run: would create the state dir $STATE_DIR"
    elif ! mkdir -p "$STATE_DIR" 2>/dev/null || [ ! -w "$STATE_DIR" ]; then
        err "REFUSING: state dir '$STATE_DIR' is not writable by $(id -un) — the unit runs as this user and every pass would fail closed (exit 3)"
        return 1
    fi
    # ── Whitespace: systemd SPLITS unquoted Environment=/ExecStart= values, so a path containing a
    # space renders a unit that cannot run (measured: HOME="…/bg/my home"). Refuse, do not escape.
    for v in "HOME=$HOME" "PATH=$PATH" "STATE_DIR=$STATE_DIR" "REPOS=$REPOS" "REAPER=$REAPER"; do
        case "${v#*=}" in
            *[[:space:]]*) err "REFUSING: ${v%%=*} contains whitespace — systemd splits the rendered unit on it, so it would never run"; return 1 ;;
        esac
    done
    # A transient REPO is deliberately NOT a refusal: it makes that class fail closed (exit 3), which
    # the unit now reports RED, so it is loud rather than silent. Refusing here would be a false block
    # on cells whose only checkout currently lives under a mktemp dir. Read LINE-wise — an unquoted
    # `for` would split a repo path containing a space into fragments and miss the real path.
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        is_transient_scratch "$r" && \
            err "WARNING: repo '$r' is transient scratch — its venv/worktree classes will fail closed (exit 3, red) every pass"
    done <<EOF
$(printf '%s' "$REPOS" | tr ':' '\n')
EOF
    return 0
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
        -e "s|{{REAPER_DIR}}|${REAPER%/*}|g" \
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
    # ⛔ `${SUDO:-sudo -n}` CANNOT BE EMPTY (`:-` substitutes on empty too), so the documented
    # "SUDO= skips the sudo probe" branch was unreachable — and SUDO set to a wrapper was honoured for
    # the file copy but not for `systemctl`, so the unit could be installed by one identity and enabled
    # by another. Both seams now mean what they say: `${SUDO+x}` distinguishes unset from set-to-empty,
    # and the pinned SYSTEMCTL is used on the SYSTEM target too (it used to be hardcoded away there —
    # "a pinned path silently ignored", the defect find_delegate refuses).
    if [ -z "${SUDO+x}" ] && sudo -n true >/dev/null 2>&1; then
        TARGET="system"; UNIT_DIR="/etc/systemd/system"; SC="${SYSTEMCTL:-sudo -n systemctl}"
        return 0
    fi
    if [ -n "${SUDO+x}" ] && { [ -z "$SUDO" ] || $SUDO true >/dev/null 2>&1; }; then
        TARGET="system"; UNIT_DIR="/etc/systemd/system"; SC="${SYSTEMCTL:-${SUDO:+$SUDO }systemctl}"
        return 0
    fi
    if systemctl --user show-environment >/dev/null 2>&1; then
        TARGET="user"; UNIT_DIR="$HOME/.config/systemd/user"; SC="${SYSTEMCTL:-systemctl --user}"
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
    # ⛔ RUNNING THIS AS ROOT INSTALLS A GREEN REAPER THAT REAPS NOTHING. {{USER}} is `id -un` and
    # {{HOME}} is $HOME, so `sudo bash install-disk-reaper-timer.sh --install` — a plausible reading of
    # the remedy this script itself prints — renders `User=root` / `Environment=HOME=/root`, and the
    # hourly pass then looks after /root while the lane user's caches and worktrees are untouched. It
    # exits 0 every hour, so nothing notices. Refuse and name the two working invocations.
    if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
        err "REFUSING to install as root (SUDO_USER=$SUDO_USER): the unit would run as root and look after"
        err "root's caches, not $SUDO_USER's — a green hourly pass that reclaims nothing."
        err "Run it as the user that owns the lanes:  sudo -u $SUDO_USER -H bash $0 --install"
        return 1
    fi
    choose_target || { err "no scheduler available: no passwordless sudo for a system unit, and no systemd user manager. Install by hand, or give the cell sudo. NOT silently skipping — a reaper that never runs is the failure this exists to remove."; return 1; }

    refuse_transient_target || return 1

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
        ${SUDO-sudo -n} install -m 0644 "$tmpd/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.service" \
            && ${SUDO-sudo -n} install -m 0644 "$tmpd/$UNIT_NAME.timer" "$UNIT_DIR/$UNIT_NAME.timer" \
            || { err "install failed (sudo/systemd)"; rm -rf "$tmpd"; return 1; }
    fi
    rm -rf "$tmpd"

    # ALWAYS re-read unit files (cheap, idempotent), then make sure the timer is enabled+started.
    $SC daemon-reload >/dev/null 2>&1 || { err "daemon-reload failed"; return 1; }
    $SC enable --now "$UNIT_NAME.timer" || { err "could not enable/start $UNIT_NAME.timer"; return 1; }

    # ⛔ A USER UNIT WITHOUT LINGERING IS AN INERT ENFORCER THAT PRINTS GREEN. `user@.service` — which
    # owns `systemctl --user` timers — is stopped when that user's last session ends unless lingering is
    # enabled, and this installer is normally run from a bring-up ssh session on a box nobody stays
    # logged into. `enable --now` succeeds, `--status` says `active`, the bring-up prints "disk reaper
    # scheduled", the session ends, and the timer never fires again — the same false PASS as the
    # transient-HOME unit and the masked exit codes, through the branch advertised as "a cell without
    # sudo still gets a clock". So the check is part of the install, not an exercise for the reader.
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
            err "(The timer IS enabled and will fire while you are logged in — it is the unattended case"
            err " this box exists for that would silently do nothing.)"
            return 1
        fi
        say "  linger: enabled (the user timer survives logout)"
    fi

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
        ${SUDO-sudo -n} rm -f "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer"
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
