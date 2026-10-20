#!/usr/bin/env bash
# scheduled-jobs.sh — ONE command for the WHOLE scheduled set, on BOTH platforms (agent-infra#2048).
#
# BEFORE THIS FILE, there was no single verb. The cells got a systemd timer from a shell function in
# `cloud-cell-bringup.sh`; the Mac got nothing (`launchctl list | grep -i reap` was empty, and the box
# reached 90% used / 45 GB free before anyone noticed); and the schedules that DID exist on the Mac —
# 35 of them — were machine state, installed by four different mechanisms in four report formats. The
# requirement is the owner's standing one: ONE system that works across the laptop and the clouds,
# self-heals, and needs no per-platform manual step.
#
# THIS IS THE ONE INSTALLER. Everything about a schedule is declared once in
# `config/scheduled-jobs.declaration`; this command renders and converges it:
#
#   scheduled-jobs.sh install            # render + install + enable the set for THIS platform
#   scheduled-jobs.sh status             # is the set installed, loaded, and did its last pass succeed
#   scheduled-jobs.sh start|stop|restart # act on the SET (every declared job for this platform)
#   scheduled-jobs.sh uninstall          # remove only what this command installed
#   scheduled-jobs.sh parity             # the gate: declaration vs live host, both directions
#   scheduled-jobs.sh list               # the declaration, as this platform sees it
#
# IDEMPOTENT. A second `install` changes nothing and reloads nothing: a job is re-rendered only when
# its bytes differ, and reloaded only when its artifact OR the script it runs changed (#1738 — an edit
# to a scheduled script is INERT until the job is reloaded; the loaded job keeps the program and
# environment it was bootstrapped with).
#
# ⛔ ARMING IS AN OWNER DECISION AND IT IS VISIBLE (#1678, owner ruling 2026-10-11). The declaration's
# `arming=` is the SHIPPED stance; `--apply` arms the selected jobs for this run and the flag lands
# INSIDE the rendered unit/plist, so "is this armed" is answered by reading the installed artifact.
# `--report-only` puts it back. Nothing about arming hides in an environment default.
#
# ⛔ AN UNSCHEDULED BOX IS A FAILURE, NOT AN ABSENCE. `install` ends by running the parity gate, and
# `status` exits non-zero when a declared job for this platform is absent, inert, or last exited
# non-zero. There is no code path here that reports success for "nothing installed".
#
# ⛔ THIS COMMAND DOES NOT TAKE ANOTHER OWNER'S JOB. A `managed=no` record names the installer that
# owns it; `install` DELEGATES to that installer (one command for the whole set — you do not have to
# know which jobs are whose) and fails loudly if the named owner cannot be found. It never renders a
# second artifact for a job it does not own.
#
# Usage:
#   scheduled-jobs.sh [install|status|start|stop|restart|uninstall|parity|list]
#                     [--only <id[,id]>] [--apply] [--report-only] [--preview] [--quiet]
#
#   --only <ids>    act on these records only (comma-separated)
#   --apply         arm the selected jobs: the mode flag is rendered INTO the artifact
#   --report-only   the opposite stance (the shipped default)
#   --preview       render and show what WOULD be installed; write nothing, install nothing
#   --no-parity     skip the closing parity gate (for a host that cannot measure its own scheduler)
#
# Exit codes: 0 ok · 1 failure (named) · 2 usage · 3 could not measure the scheduler.
#
# Env seams (tests, and a box with an unusual layout):
#   SJ_DECLARATION / SJ_UNMANAGED_REGISTER   file overrides
#   PORTABLE_PLATFORM                        linux | darwin
#   SJ_FARM            farmed-script dir (default $HOME/.pi/agent/scripts)
#   SJ_STATE_DIR       state/log/stamp dir (default $HOME/.pi/agent/state)
#   SJ_REPOS           colon-separated repos the pass scans (rendered as @repos)
#   SJ_TORTOISE_REPO   tortoise checkout (rendered as @tortoise)
#   SJ_PYTHON_BIN      interpreter for `python`/`python-launcher` runners
#   SJ_LAUNCHER        the macOS TCC launcher (default the farmed pi-reap-worktrees-launchd.py)
#   SJ_OWNER_DIR       where a `managed=no` owner installer is resolved (default this repo's scripts/)
#   SJ_SYSTEMD_UNIT_DIR / SJ_SYSTEMCTL       systemd surface + tool (tests: a temp dir + a shim)
#   SJ_SUDO            the sudo probe for a SYSTEM-scope install (default `sudo -n`; tests: `true`)
#   SJ_EXTRA_SCOPES    colon-separated EXTRA unit dirs that `uninstall` REPORTS but does not touch
#                      (tests: a decoy scope; production sets nothing)
#   SJ_LAUNCHD_DIR / SJ_LAUNCHCTL / SJ_LAUNCHD_DOMAIN   launchd surface + tool + domain
#   ELDATO_ALLOW_TEST_HOME   permit launchd management when $HOME is not the real home (#446; tests ONLY)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/scheduled-jobs.sh
. "$HERE/lib/scheduled-jobs.sh" || { echo "scheduled-jobs: cannot load the declaration library" >&2; exit 1; }

SJ_STATE_DIR="${SJ_STATE_DIR:-${HOME:?HOME is required}/.pi/agent/state}"
SJ_FARM="${SJ_FARM:-${HOME:-}/.pi/agent/scripts}"
SJ_OWNER_DIR="${SJ_OWNER_DIR:-$SJ_REPO_ROOT/scripts}"
STAMP="$SJ_STATE_DIR/scheduled-jobs.stamp"
INTERVAL_LABEL=""

VERB=""
ONLY=""
ARM=""
PREVIEW=0
QUIET=0
RUN_PARITY=1
PLATFORM_ARG=""

say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
err()  { printf 'scheduled-jobs: %s\n' "$*" >&2; }
# ⛔ `warn` IS DEFINED HERE BECAUSE THIS PROGRAM CALLS IT (#2058 review, P1). `uninstall` announced a
# failed `disable --now` through a `warn` that only ever existed in check-scheduled-parity.sh — a
# DIFFERENT process — so on the Linux arm the announcement was `bash: line 657: warn: command not found`
# and the operator, at the one moment a disarm did not disarm, read a shell error instead of the
# diagnostic. Unconditional (never silenced by `--quiet`) and on stderr, because it is a note about a
# step that did not do what it was asked, not a row of the machine-readable report on stdout.
warn() { printf 'scheduled-jobs: WARN %s\n' "$*" >&2; }
fatal() { err "$*"; exit 1; }

usage() { sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        install|uninstall|start|stop|restart|status|parity|list) VERB="$1" ;;
        # Flag aliases for the verb: the pre-#2048 installer took `--install`/`--status`, and a caller
        # that silently did nothing because its verb was renamed would be a false PASS of its own.
        --install)   VERB=install ;;
        --status)    VERB=status ;;
        --uninstall) VERB=uninstall ;;
        --list)      VERB=list ;;
        --only)      ONLY="${2:-}"; shift ;;
        --apply)     ARM=armed ;;
        --report-only) ARM=report-only ;;
        --preview)   PREVIEW=1 ;;
        --quiet|-q)  QUIET=1 ;;
        --no-parity) RUN_PARITY=0 ;;
        --platform)  PLATFORM_ARG="${2:-}"; shift ;;
        --help|-h)   usage ;;
        *) err "unknown argument '$1'"; usage ;;
    esac
    shift
done
[ -n "$VERB" ] || usage

PLATFORM="$(_portable_platform)"
[ -n "$PLATFORM_ARG" ] && PLATFORM="$PLATFORM_ARG"
case "$PLATFORM" in linux|darwin) ;; *) fatal "this command knows systemd (linux) and launchd (darwin); this box reports '$PLATFORM'. NOT silently skipping — a schedule that never fires is the failure this exists to remove." ;; esac

# ── selection ────────────────────────────────────────────────────────────────────────────────
# `--only` is a typo-trap on purpose: an id that is not declared is a FAILURE, because a silently
# empty selection would make `install` (or worse, `status`) a green no-op.
selected_ids() {
    local id want
    if [ -z "$ONLY" ]; then
        sj_ids
        return 0
    fi
    for want in $(printf '%s' "$ONLY" | tr ',' ' '); do
        [ -n "$want" ] || continue
        id="$(sj_ids | grep -Fx -- "$want" || true)"
        [ -n "$id" ] || { err "--only names '$want', which the declaration does not define"; return 1; }
        printf '%s\n' "$id"
    done
}

platform_ids() { # ids declared for this platform, filtered by --only
    local id sel
    sel="$(selected_ids)" || return 1
    for id in $sel; do
        sj_has_platform "$id" "$PLATFORM" && printf '%s\n' "$id"
    done
}

# require_ids — the selection, or a REFUSAL. ⛔ A `for id in $(platform_ids)` silently iterates
# NOTHING when the selection failed, which would make `install`/`status` a green no-op — the exact
# false PASS this feature exists to remove. Every verb goes through here.
require_ids() {
    IDS="$(platform_ids)" || { err "no records selected — refusing to act on an empty set"; exit 1; }
    if [ -z "$IDS" ]; then
        err "no declared record for platform '$PLATFORM' matched the selection — refusing to report success for an empty set"
        exit 1
    fi
}

# ── stamp: which script bytes the JOB was installed against (#1738) ──────────────────────────
# The stamp line carries more than the digest (platform, timestamp), so the value must be CUT at the
# first space — otherwise every second install sees a "changed pass" and reloads a job that did not
# change (measured by S3, which is why this is asserted rather than assumed).
stamp_sha() { sed -n "s/^job=$1 sha=//p" "$STAMP" 2>/dev/null | head -1 | cut -d' ' -f1; }
artifact_sha() { # the script this record actually runs; EMPTY + rc 1 when it cannot be measured
    local s out
    s="$(sj_resolve_script "$1" 2>/dev/null)" || return 1
    # ⛔ ASK THE BOX, NOT AN ENV SEAM, and try BOTH spellings. Branching on `_portable_platform` (which
    # honours PORTABLE_PLATFORM / a forwarded DISK_REAPER_PLATFORM) called `shasum` on a slim Linux
    # image that does not carry it — and an empty digest was read as "unchanged", so an edited script
    # never reloaded (#1738) and the pass reported success over an inert job.
    if command -v sha256sum >/dev/null 2>&1; then
        out="$(sha256sum "$s" 2>/dev/null | cut -d' ' -f1)"
    elif command -v shasum >/dev/null 2>&1; then
        out="$(shasum -a 256 "$s" 2>/dev/null | cut -d' ' -f1)"
    fi
    case "$out" in
        ????????????????????????????????????????????????????????????????) printf '%s\n' "$out"; return 0 ;;
        *) return 1 ;;
    esac
}
write_stamp() { # write_stamp <id>
    local id="$1" sha tmp
    sha="$(artifact_sha "$id")"
    mkdir -p "$SJ_STATE_DIR" 2>/dev/null || { err "cannot create the state dir $SJ_STATE_DIR"; return 1; }
    tmp="$STAMP.tmp.$$"
    { grep -v "^job=$id " "$STAMP" 2>/dev/null || true
      printf 'job=%s sha=%s platform=%s installed_at=%s\n' "$id" "${sha:-unknown}" "$PLATFORM" "$(_date --iso)"
    } >"$tmp" 2>/dev/null && mv -f "$tmp" "$STAMP" 2>/dev/null \
        || { err "cannot write the stamp $STAMP"; rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

# armed_from_file — apply | dry-run | unknown, read from the INSTALLED artifact, never from the flags
# this invocation was given. Comments are excluded on purpose: both templates explain both modes, and
# a comment match would answer "armed" for a report-only definition.
# The arming this run should render for a record: an explicit flag wins; otherwise the stance already
# on the box holds (the artifact IS the decision of record, #1678); otherwise the declared stance.
# ⛔ WITHOUT THIS, `--apply` IS NOT DURABLE: a cell armed by bring-up was silently disarmed by any
# later convergent `install` (setup.sh, a repair, an orchestrator pass) — `changed=1 armed=dry-run` and
# a reaper that only reports, with every instrument green.
effective_arm() { # effective_arm <id> <installed-artifact>
    local id="$1" cur="$2"
    [ -n "$ARM" ] && { printf '%s\n' "$ARM"; return 0; }
    case "$(armed_from_file "$cur")" in
        apply)   printf 'armed\n'; return 0 ;;
        dry-run) printf 'report-only\n'; return 0 ;;
    esac
    sj_field "$id" arming
}

# A stance change is ANNOUNCED, so "the reaper stopped running" is never a silent one-way door.
announce_arm_change() { # announce_arm_change <id> <installed-artifact>
    local before after
    [ -n "$ARM" ] || return 0
    before="$(armed_from_file "$2")"
    case "$ARM" in armed) after=apply ;; *) after=dry-run ;; esac
    # ⛔ AN UNREADABLE STANCE IS ANNOUNCED, NOT ASSUMED AWAY. Returning quietly rewrote an artifact whose
    # mode flag this command could not read (a legacy unit, a different flag spelling) to the DECLARED
    # stance — a silent arming or disarming, which the comment above says must never happen one-way.
    if [ "$before" = unknown ]; then
        say "⛔ ARMING UNREADABLE $1: the installed artifact carries no readable mode flag; applying the DECLARED stance ($after) — verify with 'scheduled-jobs.sh status'"
        return 0
    fi
    [ "$before" = "$after" ] && return 0
    say "⛔ ARMING CHANGED $1: $before → $after (explicit flag; the artifact is the record)"
}

armed_from_file() {
    local f="$1" line
    [ -f "$f" ] || { printf 'unknown'; return 0; }
    case "$f" in
        *.service) line="$(sed -n 's/^ExecStart=//p' "$f")" ;;
        *)         line="$(tr -d '\n' <"$f" | sed -nE 's/.*<string>(--apply|--dry-run)<\/string>.*/\1/p')" ;;
    esac
    case "$line" in
        *--apply*)   printf 'apply' ;;
        *--dry-run*) printf 'dry-run' ;;
        *)           printf 'unknown' ;;
    esac
}

# ── systemd backend ─────────────────────────────────────────────────────────────────────────
SD_SCOPE=""; UNIT_DIR=""; SC=""
choose_systemd() {
    UNIT_DIR="$(sj_systemd_units_dir)"; SC="$(sj_systemctl)"
    if [ -n "${SJ_SYSTEMD_UNIT_DIR:-}" ]; then SD_SCOPE=override; return 0; fi
    if [ "${SJ_SUDO:-sudo -n}" = "" ] || ${SJ_SUDO:-sudo -n} true >/dev/null 2>&1; then
        SD_SCOPE=system; UNIT_DIR=/etc/systemd/system; SC="${SJ_SYSTEMCTL:-sudo -n systemctl}"; return 0
    fi
    if systemctl --user show-environment >/dev/null 2>&1; then
        # ⛔ THE PROBE IS BARE, THE TOOL IS PINNED. Reachability is asked of the plain `systemctl`
        # (that is what decides whether a user manager answers at all), but every MUTATING call must use
        # the operator's pinned tool — dropping it here made `SJ_SYSTEMCTL` honoured for a system-scope
        # install and silently ignored for a user-scope one, so a test double (and any unusual cell) saw
        # no calls at all and the scope was lost.
        SD_SCOPE=user; UNIT_DIR="$HOME/.config/systemd/user"; SC="${SJ_SYSTEMCTL:-systemctl} --user"; return 0
    fi
    return 1
}

# ⛔ A SYSTEM UNIT RENDERED FROM SCRATCH SPACE IS A JOB THAT CAN NEVER RUN (#2071, measured
# 2026-10-18 on pi-cell-2/3). A harness ran the installer with HOME=/tmp/tmp.XXXX/bg/home and no unit-dir
# override, so the policy took the SYSTEM target and wrote
# `ExecStart=/bin/bash /tmp/tmp.XXXX/bg/home/.pi/agent/scripts/disk-reaper.sh --apply` into
# /etc/systemd/system. The mktemp dir was deleted before the first tick, so every hourly pass exited 127
# forever, while `systemctl list-timers` kept the job looking scheduled and healthy and the disks sat at
# 94–96%. The installer is the ONLY component that can see the path is transient by construction.
is_transient_scratch() { # is_transient_scratch <path> — true if any ancestor is a mktemp -d scratch dir
    local p="$1" base
    [ -n "$p" ] || return 1
    while [ -n "$p" ] && [ "$p" != / ] && [ "$p" != . ]; do
        base="$(basename "$p" 2>/dev/null)"
        # `mktemp -d "$TMPDIR/tmp.XXXXXXXXXX"` → `tmp.` + 10 random characters.
        case "$base" in
            tmp.??????????) case "$(dirname "$p")" in
                    /tmp|/var/tmp|/private/tmp|/private/var/tmp|*/T|/var/folders) return 0 ;;
                esac ;;
        esac
        p="$(dirname "$p" 2>/dev/null)"
    done
    return 1
}

# ⛔ A USER TIMER ON A BOX WITHOUT LINGERING IS A TIMER THAT STOPS AT LOGOUT. `systemctl --user` runs a
# per-session manager, so a cell nobody stays logged into needs `loginctl enable-linger`; installing the
# unit and reporting success would be a schedule that silently stops (the class of false PASS this
# feature exists to remove).
sd_linger_ok() {
    local ans
    command -v loginctl >/dev/null 2>&1 || return 1
    ans="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)"
    [ "$ans" = yes ]
}

sd_last_exit() { # sd_last_exit <unit> -> <n> | never | unknown
    local started rc_s rc
    started="$($SC show -p ExecMainStartTimestamp --value "$1.service" 2>/dev/null)"; rc_s=$?
    rc="$($SC show -p ExecMainStatus --value "$1.service" 2>/dev/null)"
    # ⛔ "COULD NOT ASK" IS NOT "NEVER RAN". Both used to print `never`, and `never` sits on the healthy
    # list — so a `systemctl show` that failed (a bus error, a masked unit, a broken shim) answered the
    # question "did the last pass succeed?" with OK from a surface it never read. `unknown` is a
    # MEASUREMENT GAP and is reported as one.
    [ "$rc_s" -eq 0 ] || { printf 'unknown\n'; return 0; }
    case "$rc" in ''|*[!0-9]*) printf 'unknown\n'; return 0 ;; esac
    # A unit that has never run reports rc=0, which would read as "healthy". Say `never` instead: the
    # question this verb answers is "did the last pass succeed", and there is no last pass.
    case "$started" in ''|n/a|'n/a') printf 'never\n' ;; *) printf '%s\n' "$rc" ;; esac
}

sd_install() { # sd_install <id>
    local id="$1" unit tmpd changed=0 pass_changed=0 reason=none sha insha
    unit="$(sj_unit "$id")"
    # ⛔ THE TRANSIENT-SCRATCH REFUSAL COMES FIRST, before anything is rendered or written (#2071).
    # A system unit outlives the shell that installed it, so a path under a mktemp dir is a job that
    # will exit 127 on every tick while `list-timers` reports it healthy. Refusing is the only honest
    # answer; the explicit unit-dir override is the documented way to install from scratch space.
    if [ "$SD_SCOPE" = system ]; then
        local _s
        _s="$(sj_resolve_script "$id" 2>/dev/null || true)"
        if is_transient_scratch "${_s:-$HOME}" || is_transient_scratch "$HOME"; then
            err "REFUSING to install $id as a SYSTEM unit from transient scratch space:"
            err "       HOME=$HOME  script=${_s:-unresolved}"
            err "       That directory is deleted before the first tick, so every pass would exit 127 while"
            err "       the timer still reads as scheduled. Install from a durable location, or pass an"
            err "       explicit unit dir (SJ_SYSTEMD_UNIT_DIR) if you really mean a scratch target."
            return 1
        fi
    fi
    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/sj-unit.XXXXXX")" || { err "cannot create a temp dir"; return 1; }
    announce_arm_change "$id" "$UNIT_DIR/$(sj_unit "$id").service"
    sj_render_systemd "$id" "$tmpd" "$SD_SCOPE" "$(effective_arm "$id" "$UNIT_DIR/$(sj_unit "$id").service")" \
        || { err "$id: rendering failed"; rm -rf "$tmpd"; return 1; }
    # A USER unit may not carry User= (systemd rejects it).
    if [ "$SD_SCOPE" = user ]; then
        sed -e '/^User=/d' "$tmpd/$unit.service" >"$tmpd/$unit.service.u" && mv "$tmpd/$unit.service.u" "$tmpd/$unit.service"
    fi
    if [ "$PREVIEW" = 1 ]; then
        say "preview: $id → $UNIT_DIR (target=$SD_SCOPE)"
        sed 's/^/  /' "$tmpd/$unit.service"; sed 's/^/  /' "$tmpd/$unit.timer"
        rm -rf "$tmpd"
        return 0
    fi
    cmp -s "$tmpd/$unit.service" "$UNIT_DIR/$unit.service" 2>/dev/null || changed=1
    cmp -s "$tmpd/$unit.timer"   "$UNIT_DIR/$unit.timer"   2>/dev/null || changed=1
    # ⛔ AN UNMEASURABLE DIGEST IS `pass_changed`, NOT "unchanged". The old `[ -n "$sha" ] &&` test made
    # a missing sha256 tool (or an unreadable script) mean "the script did not change", so an edited
    # job sat inert with a success report and no reload.
    if ! sha="$(artifact_sha "$id")"; then
        err "$id: cannot digest the script it runs — the job is UNVERIFIABLE, so it is reloaded rather than assumed unchanged"
        pass_changed=1; sha=""
    fi
    insha="$(stamp_sha "$id")"
    [ -n "$sha" ] && [ "$sha" != "$insha" ] && pass_changed=1
    [ -f "$UNIT_DIR/$unit.timer" ] || { changed=1; pass_changed=1; }
    mkdir -p "$UNIT_DIR" 2>/dev/null || true
    if [ -n "${SJ_SYSTEMD_UNIT_DIR:-}" ] || [ "$SD_SCOPE" = user ]; then
        cp -f "$tmpd/$unit.service" "$tmpd/$unit.timer" "$UNIT_DIR/" || { err "$id: copy failed"; rm -rf "$tmpd"; return 1; }
    else
        ${SJ_SUDO:-sudo -n} install -m 0644 "$tmpd/$unit.service" "$UNIT_DIR/$unit.service" \
            && ${SJ_SUDO:-sudo -n} install -m 0644 "$tmpd/$unit.timer" "$UNIT_DIR/$unit.timer" \
            || { err "$id: install failed (sudo/systemd)"; rm -rf "$tmpd"; return 1; }
    fi
    rm -rf "$tmpd"
    $SC daemon-reload >/dev/null 2>&1 || { err "$id: daemon-reload failed"; return 1; }
    # The files are on disk and the manager has re-read them — MEASURED, not assumed. Only now can the
    # linger question be answered, and a user-scope timer that cannot survive a logout must not report
    # success (#2071).
    if [ "$SD_SCOPE" = user ] && ! sd_linger_ok; then
        err "$id: the unit is installed in $UNIT_DIR but this user has NO lingering, so the user manager"
        err "       (and this timer) stops at logout — the job would never fire on a box nobody stays"
        err "       logged into. Fix: sudo loginctl enable-linger $(id -un)"
        return 1
    fi
    $SC enable --now "$unit.timer" >/dev/null 2>&1 || { err "$id: could not enable/start $unit.timer"; return 1; }
    [ "$changed" = 1 ] && reason=unit-changed
    [ "$pass_changed" = 1 ] && [ "$reason" = none ] && reason=pass-changed
    if [ "$reason" != none ]; then
        # Restart the TIMER, not the service: the timer carries the calendar/persistent state, and a
        # reload of an already-loaded definition is the only way to make an edited one apply.
        $SC restart "$unit.timer" >/dev/null 2>&1 || true
    fi
    if ! $SC is-enabled "$unit.timer" >/dev/null 2>&1; then
        err "$id: the timer is NOT enabled after install — it will not run unattended"; return 1
    fi
    write_stamp "$id" || return 1
    say "installed $id: scheduler=systemd target=$SD_SCOPE unit=$unit.timer changed=$changed pass_changed=$pass_changed reload_reason=$reason armed=$(armed_from_file "$UNIT_DIR/$unit.service")"
    return 0
}

# ── launchd backend ─────────────────────────────────────────────────────────────────────────
LD_DIR=""; LC=""; LD_DOMAIN=""
choose_launchd() {
    LD_DIR="$(sj_launchd_dir)"
    LC="$(sj_launchctl)"
    LD_DOMAIN="${SJ_LAUNCHD_DOMAIN:-gui/$(id -u)}"
    case "$LC" in
        */*) [ -x "$LC" ] || return 1 ;;
        *)   command -v "$LC" >/dev/null 2>&1 || return 1 ;;
    esac
    return 0
}
ld_loaded() { $LC print "$LD_DOMAIN/$1" >/dev/null 2>&1; }

# launchd addresses the USER domain by UID: a run with a throwaway HOME bootstraps into the LIVE
# session, registering a job whose plist path dies with the temp dir (#446).
guard_test_home() {
    [ "$PLATFORM" = darwin ] || return 0
    [ "${ELDATO_ALLOW_TEST_HOME:-}" = 1 ] && return 0
    local real
    real="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p' | head -1 || true)"
    # ⛔ AN UNMEASURABLE HOME IS A REFUSAL, NOT A PASS. `dscl` is macOS-only, so on any other host — and
    # on a Mac where dscl fails — `$real` came back empty and the `[ -n "$real" ]` fence fell through:
    # `install` then bootstrapped a temp-HOME plist into the LIVE `gui/<uid>` domain, which is exactly
    # the #446 artifact this guard exists to prevent, arriving through the guard's own dependency.
    if [ -z "$real" ]; then
        err "refusing to manage launchd jobs: the real home directory could not be determined (dscl)."
        err "       An unverified HOME must not reach the live launchd domain (#446)."
        err "       Tests: put a launchctl shim on PATH and set ELDATO_ALLOW_TEST_HOME=1"
        return 1
    fi
    if [ "$HOME" != "$real" ]; then
        err "refusing to manage launchd jobs: HOME=$HOME is not the real home ($real)."
        err "       A temp-HOME run registers jobs against plist paths that vanish (#446)."
        err "       Tests: put a launchctl shim on PATH and set ELDATO_ALLOW_TEST_HOME=1"
        return 1
    fi
    return 0
}

ld_last_exit() { # ld_last_exit <label> -> <n> | never | unknown
    local out src rc
    out="$($LC print "$LD_DOMAIN/$1" 2>/dev/null)"; src=$?
    # ⛔ "COULD NOT ASK" IS NOT "NEVER RAN" — the same distinction the systemd reader was fixed for, and
    # only that half was fixed: `never` sits on the HEALTHY list, so a `launchctl print` that failed
    # published a clean-looking `last_exit=never` from a surface it never read (and `cloud-cell-bringup`
    # scrapes this field).
    [ "$src" -eq 0 ] || { printf 'unknown\n'; return 0; }
    rc="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*last exit code = //p' | head -1)"
    case "$rc" in ''|*[!0-9]*) printf 'never\n' ;; *) printf '%s\n' "$rc" ;; esac
}

ld_install() { # ld_install <id>
    local id="$1" label tmp dest changed=0 pass_changed=0 reason=none sha insha
    label="$(sj_label "$id")"
    [ -n "$label" ] || { err "$id: declared for darwin with no label"; return 1; }
    dest="$LD_DIR/$label.plist"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/sj-plist.XXXXXX")" || { err "cannot create a temp dir"; return 1; }
    announce_arm_change "$id" "$dest"
    sj_render_launchd "$id" "$tmp/$label.plist" "$(effective_arm "$id" "$dest")" \
        || { err "$id: rendering failed"; rm -rf "$tmp"; return 1; }
    if command -v plutil >/dev/null 2>&1 && ! plutil -lint "$tmp/$label.plist" >/dev/null 2>&1; then
        err "$id: the rendered plist is MALFORMED — refusing to install a job launchd will ignore"
        plutil -lint "$tmp/$label.plist" >&2 || true
        rm -rf "$tmp"; return 1
    fi
    if [ "$PREVIEW" = 1 ]; then
        say "preview: $id → $dest (domain=$LD_DOMAIN)"
        sed 's/^/  /' "$tmp/$label.plist"
        rm -rf "$tmp"
        return 0
    fi
    cmp -s "$tmp/$label.plist" "$dest" 2>/dev/null || changed=1
    # ⛔ AN UNMEASURABLE DIGEST IS `pass_changed`, NOT "unchanged". The old `[ -n "$sha" ] &&` test made
    # a missing sha256 tool (or an unreadable script) mean "the script did not change", so an edited
    # job sat inert with a success report and no reload.
    if ! sha="$(artifact_sha "$id")"; then
        err "$id: cannot digest the script it runs — the job is UNVERIFIABLE, so it is reloaded rather than assumed unchanged"
        pass_changed=1; sha=""
    fi
    insha="$(stamp_sha "$id")"
    [ -n "$sha" ] && [ "$sha" != "$insha" ] && pass_changed=1
    [ -f "$dest" ] || pass_changed=1
    ld_loaded "$label" || pass_changed=1
    mkdir -p "$LD_DIR" || { err "$id: cannot create $LD_DIR"; rm -rf "$tmp"; return 1; }
    mv "$tmp/$label.plist" "$dest" || { err "$id: cannot write $dest"; rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    [ "$changed" = 1 ] && reason=unit-changed
    [ "$pass_changed" = 1 ] && [ "$reason" = none ] && reason=pass-changed
    if [ "$reason" != none ]; then
        $LC enable "$LD_DOMAIN/$label" >/dev/null 2>&1 || true
        $LC bootout "$LD_DOMAIN/$label" >/dev/null 2>&1 || true
        if ! $LC bootstrap "$LD_DOMAIN" "$dest" >/dev/null 2>&1; then
            rm -f "$dest"   # nothing half-installed
            err "$id: launchctl bootstrap failed for $label (see '$LC print $LD_DOMAIN/$label')"
            return 1
        fi
        ld_loaded "$label" || { err "$id: $label is not loaded after bootstrap — it will not run unattended"; return 1; }
    fi
    write_stamp "$id" || return 1
    say "installed $id: scheduler=launchd label=$label changed=$changed pass_changed=$pass_changed reload_reason=$reason armed=$(armed_from_file "$dest")"
    return 0
}

# ── the owner delegation (managed=no) ────────────────────────────────────────────────────────
delegate_install() { # delegate_install <id>
    local id="$1" owner path
    owner="$(sj_field "$id" owner)"
    [ -n "$owner" ] || { err "$id: managed=no and no owner is named — refusing to skip it silently"; return 1; }
    case "$owner" in
        scheduled-jobs.sh|scheduled-jobs) return 0 ;;   # this command owns it after all
    esac
    path="$SJ_OWNER_DIR/$owner"
    [ -f "$path" ] || { err "$id: its owner installer '$owner' was not found in $SJ_OWNER_DIR — the job is NOT installed, and this is a FAILURE, not a skip"; return 1; }
    # ⛔ THE STANCE IS NOT OURS TO SET on a record another installer owns: `--apply` over the whole set
    # armed this declaration's jobs and left the delegated ones at their owner's default, while the
    # output read as a whole-set success. Say it per job.
    if [ -n "$ARM" ]; then
        say "$id: arming NOT applied — $owner owns this artifact; it stays at its owner's stance (use that installer for its mode)"
    fi
    if [ "$PREVIEW" = 1 ]; then
        say "preview: $id is owned by $owner — would run: bash $path"
        return 0
    fi
    local out
    if ! out="$(bash "$path" 2>&1)"; then
        err "$id: its owner installer '$owner' FAILED — the job is not installed"
        # Never swallow the owner's reason: it is the only thing that says WHICH half is missing.
        printf '%s\n' "$out" | tail -20 | sed 's/^/       │ /' >&2
        return 1
    fi
    say "delegated $id → $owner"
    return 0
}

# ── verbs ───────────────────────────────────────────────────────────────────────────────────
do_install() {
    local id rc=0 qflag=""
    [ "$QUIET" = 1 ] && qflag="--quiet"
    case "$PLATFORM" in
        linux)  choose_systemd || fatal "no systemd target: no passwordless sudo for a system unit, and no systemd user manager. Give the box sudo, or set SJ_SYSTEMD_UNIT_DIR. NOT skipping — a reaper that never runs is the failure this exists to remove." ;;
        darwin) choose_launchd || fatal "no launchctl ($(sj_launchctl)) — cannot install a launchd job"; guard_test_home || exit 1 ;;
    esac
    require_ids
    for id in $IDS; do
        if [ "$(sj_field "$id" managed)" = yes ]; then
            case "$PLATFORM" in
                linux)  sd_install "$id" || rc=1 ;;
                darwin) ld_install "$id" || rc=1 ;;
            esac
        else
            delegate_install "$id" || rc=1
        fi
    done
    [ "$PREVIEW" = 1 ] && return "$rc"
    # The set is only installed if the HOST agrees it is. One command, one verdict.
    if [ "$rc" -eq 0 ] && [ "$RUN_PARITY" = 1 ]; then
        # ONE SELECTION, ONE VERDICT: the gate is scoped to the records this run acted on, so a
        # deliberately scoped install cannot be failed by a record it was never asked to touch.
        bash "$HERE/check-scheduled-parity.sh" --platform "$PLATFORM" ${ONLY:+--only "$ONLY"} $qflag || {
            err "install finished but the parity gate FAILED — the set on this host does not match the declaration (see above)"
            rc=1
        }
    fi
    return "$rc"
}

do_status() {
    local id rc=0 unit label installed active enabled last armed drift sha insha sched next=
    case "$PLATFORM" in
        linux)  choose_systemd || { err "no systemd target to read"; return 3; } ;;
        darwin) choose_launchd || { err "no launchctl to read"; return 3; }
                # Reading the live domain from a temp HOME reports a DIFFERENT box's jobs as this
                # one's — the #446 rule applies to every verb that touches launchd, not just install.
                guard_test_home || return 1 ;;
    esac
    require_ids
    for id in $IDS; do
        local verdict=OK
        sched="$(sj_field "$id" schedule)"
        if [ "$PLATFORM" = linux ]; then
            unit="$(sj_unit "$id")"
            # ⛔ BOTH HALVES ARE THE JOB. A timer alone fires a unit that does not exist: systemd
            # reports the TIMER as active and enabled, and the box reclaims nothing. So `installed` is
            # the pair, and a missing service is its own verdict.
            if [ -f "$UNIT_DIR/$unit.timer" ] && [ -f "$UNIT_DIR/$unit.service" ]; then installed=yes
            elif [ -f "$UNIT_DIR/$unit.timer" ]; then installed=partial
            else installed=no; fi
            active="$($SC is-active "$unit.timer" 2>/dev/null || true)"; [ -n "$active" ] || active=unknown
            enabled="$($SC is-enabled "$unit.timer" 2>/dev/null || true)"; [ -n "$enabled" ] || enabled=unknown
            last="$(sd_last_exit "$unit")"
            next="$($SC list-timers --all --no-pager 2>/dev/null | awk -v u="$unit.timer" '$0 ~ u {print $1" "$2" "$3; exit}')"
            armed="$(armed_from_file "$UNIT_DIR/$unit.service")"
            drift="$(pass_drift_for "$id")"
            say "job=$id platform=linux scheduler=systemd unit=$unit.timer installed=$installed active=$active enabled=$enabled last_exit=$last armed=$armed schedule=$sched next_run=${next:-unknown} pass_drift=$drift"
            case "$installed" in
                yes) ;;
                partial) verdict=ABSENT-UNIT ;;   # the timer is there; the thing it triggers is not
                *) verdict=ABSENT ;;
            esac
            [ "$active" = active ] || { [ "$verdict" = OK ] && verdict=INERT; }
            # `systemctl disable <timer>` without `--now`, or a mask, leaves it loaded and firing until
            # the next boot and then silent forever; `enabled` was printed and never judged.
            case "$enabled" in
                enabled|enabled-runtime|static|alias|indirect) ;;
                *) [ "$verdict" = OK ] && verdict=INERT ;;
            esac
            case "$last" in
                ''|0|never) ;;
                unknown) [ "$verdict" = OK ] && verdict=UNKNOWN ;;
                *) verdict=FAILED ;;
            esac
            # ⛔ A CHANGED SCRIPT IS A FAILURE, not a note. The job is loaded and active — and runs
            # DIFFERENT bytes than the stamp recorded, so "installed" is true and "what I installed" is
            # false. `pass_drift` was published in the row and judged nowhere, which is the shape this
            # repo keeps removing: a measurement that cannot change a verdict.
            case "$drift" in
                'CHANGED since install'*) [ "$verdict" = OK ] && verdict=STALE-SCRIPT ;;
                unknown) [ "$verdict" = OK ] && verdict=UNVERIFIABLE ;;
            esac
        else
            label="$(sj_label "$id")"
            if [ -f "$LD_DIR/$label.plist" ]; then installed=yes; else installed=no; fi
            if ld_loaded "$label"; then active=active; else active=inactive; fi
            last="$(ld_last_exit "$label")"
            armed="$(armed_from_file "$LD_DIR/$label.plist")"
            drift="$(pass_drift_for "$id")"
            # launchd does not report the next fire time of a StartInterval job; the interval is what it
            # gives, and inventing a "next" would be a guess in a field read as a measurement.
            say "job=$id platform=darwin scheduler=launchd label=$label installed=$installed active=$active last_exit=$last armed=$armed schedule=$sched next_run=unknown pass_drift=$drift"
            [ "$installed" = yes ] || verdict=ABSENT
            [ "$active" = active ] || { [ "$verdict" = OK ] && verdict=INERT; }
            case "$last" in
                ''|0|never) ;;
                unknown) [ "$verdict" = OK ] && verdict=UNKNOWN ;;   # could not ask, not "healthy"
                *) verdict=FAILED ;;
            esac
            # Same rule as the linux arm: the bytes on disk are not the bytes that were installed, so
            # the job that is running is not the job that was verified.
            case "$drift" in
                'CHANGED since install'*) [ "$verdict" = OK ] && verdict=STALE-SCRIPT ;;
                unknown) [ "$verdict" = OK ] && verdict=UNVERIFIABLE ;;
            esac
        fi
        say "  verdict=$verdict"
        [ "$verdict" = OK ] || rc=1
    done
    if [ "$PLATFORM" = darwin ] && [ -f "$LD_DIR/$(sj_label eldato-disk-reaper).plist" ] && [ -f "$SJ_STATE_DIR/disk-reaper.status" ]; then
        say "--- last pass record (the same file a cell writes) ---"
        sed 's/^/  /' "$SJ_STATE_DIR/disk-reaper.status"
    fi
    if [ "$rc" -eq 0 ]; then say "verdict=OK platform=$PLATFORM"; else say "verdict=FAIL platform=$PLATFORM"; fi
    return "$rc"
}

pass_drift_for() { # managed=no records were installed by ANOTHER owner: no stamp exists to compare
    if [ "$(sj_field "$1" managed)" != yes ]; then printf 'n/a (owned by %s)\n' "$(sj_field "$1" owner)"; return 0; fi
    pass_drift "$1"
}

pass_drift() { # pass_drift <id> — are the bytes on disk the ones the JOB was installed against (#1738)
    local sha insha
    sha="$(artifact_sha "$1" 2>/dev/null)"; insha="$(stamp_sha "$1")"
    [ -n "$sha" ] || { printf 'unknown\n'; return 0; }
    if [ -z "$insha" ]; then printf 'no-stamp (re-run install)\n'
    elif [ "$sha" = "$insha" ]; then printf 'in-sync\n'
    else printf 'CHANGED since install (re-run install to reload the job)\n'; fi
}

do_scheduler_verb() { # do_scheduler_verb start|stop|restart
    local verb="$1" id rc=0 unit label
    # ⛔ THE TEMP-HOME GUARD IS NOT AN INSTALL-ONLY RULE. `stop|restart|uninstall` reach the same live
    # `gui/<uid>` domain, and `restart` BOOTSTRAPS a plist that lives inside the temp HOME — the exact
    # artifact #446 describes. Measured before this: all three ran happily from a throwaway HOME.
    if [ "$PLATFORM" = darwin ]; then guard_test_home || return 1; fi
    case "$PLATFORM" in
        linux)  choose_systemd || { err "no systemd target"; return 3; } ;;
        darwin) choose_launchd || { err "no launchctl"; return 3; } ;;
    esac
    require_ids
    for id in $IDS; do
        case "$PLATFORM" in
            linux)
                unit="$(sj_unit "$id")"
                case "$verb" in
                    start)   $SC start "$unit.timer"   >/dev/null 2>&1 || { err "$id: start failed"; rc=1; } ;;
                    stop)    $SC stop "$unit.timer"    >/dev/null 2>&1 || { err "$id: stop failed"; rc=1; } ;;
                    restart) $SC restart "$unit.timer" >/dev/null 2>&1 || { err "$id: restart failed"; rc=1; } ;;
                esac
                say "$verb $id: unit=$unit.timer"
                ;;
            darwin)
                label="$(sj_label "$id")"
                case "$verb" in
                    stop)    $LC bootout "$LD_DOMAIN/$label" >/dev/null 2>&1 || { err "$id: bootout failed"; rc=1; } ;;
                    start|restart)
                        if ! ld_loaded "$label"; then
                            $LC bootstrap "$LD_DOMAIN" "$LD_DIR/$label.plist" >/dev/null 2>&1 \
                                || { err "$id: bootstrap failed"; rc=1; }
                        fi
                        $LC kickstart -k "$LD_DOMAIN/$label" >/dev/null 2>&1 || { err "$id: kickstart failed"; rc=1; }
                        ;;
                esac
                say "$verb $id: label=$label"
                ;;
        esac
    done
    return "$rc"
}

do_uninstall() {
    local id rc=0 unit label
    case "$PLATFORM" in
        linux)  choose_systemd || { err "no systemd target"; return 3; } ;;
        darwin) choose_launchd || { err "no launchctl"; return 3; }
                # `bootout` from a temp HOME boots out the REAL box's jobs (#446).
                guard_test_home || return 1 ;;
    esac
    require_ids
    for id in $IDS; do
        if [ "$(sj_field "$id" managed)" != yes ]; then
            say "skip $id: managed=no, owned by $(sj_field "$id" owner) — not ours to remove"
            continue
        fi
        if [ "$PREVIEW" = 1 ]; then say "preview: would remove $id"; continue; fi
        # ⛔ "uninstalled" IS A MEASUREMENT, NOT AN ANNOUNCEMENT (#2048 review, BLOCK). Every step here
        # used to discard its status (`|| true`, an unchecked `rm`), so a read-only unit dir printed
        # `uninstalled` and exited 0 with both artifacts still present and the timer still ENABLED — a
        # disarm that did not disarm, on a job whose whole purpose is deleting things.
        if [ "$PLATFORM" = linux ]; then
            unit="$(sj_unit "$id")"
            # ⛔ THE READ-BACK IS THE ONLY SOURCE OF THE CLAIM. A failed `disable` is NOT proof that the
            # artifact survives: measured with a systemd stub that refuses to disable an absent unit,
            # uninstalling a box with NOTHING installed printed `INCOMPLETE … still installed` and exited
            # 1 over two files it had just proven absent — a false disarm-failure no re-run could clear.
            $SC disable --now "$unit.timer" >/dev/null 2>&1 \
                || warn "$id: 'disable --now' did not confirm — the artifact read-back below decides"
            if [ -n "${SJ_SYSTEMD_UNIT_DIR:-}" ] || [ "$SD_SCOPE" = user ]; then
                rm -f "$UNIT_DIR/$unit.service" "$UNIT_DIR/$unit.timer" 2>/dev/null || true
            else
                ${SJ_SUDO:-sudo -n} rm -f "$UNIT_DIR/$unit.service" "$UNIT_DIR/$unit.timer" 2>/dev/null || true
            fi
            if [ -f "$UNIT_DIR/$unit.service" ] || [ -f "$UNIT_DIR/$unit.timer" ]; then
                err "uninstall INCOMPLETE: $id is still installed at $UNIT_DIR/$unit.{service,timer} — nothing is claimed beyond what was read back"
                rc=1
                continue
            fi
            $SC daemon-reload >/dev/null 2>&1 || true
        else
            label="$(sj_label "$id")"
            $LC bootout "$LD_DOMAIN/$label" >/dev/null 2>&1 || true
            rm -f "$LD_DIR/$label.plist" 2>/dev/null || true
            if [ -f "$LD_DIR/$label.plist" ]; then
                err "uninstall INCOMPLETE: $id is still installed at $LD_DIR/$label.plist — nothing is claimed beyond what was read back"
                rc=1
                continue
            fi
            # …and a job launchd still HOLDS keeps firing on its in-memory definition even with the
            # plist gone, so "removed from disk" is not "disarmed" until logout (#2048 review).
            ld_loaded "$label" && {
                err "uninstall INCOMPLETE: $id is still LOADED as $LD_DOMAIN/$label — it keeps firing until logout"
                rc=1
                continue
            }
        fi
        # The stamp line goes with the job: a stamp for an absent job would report pass_drift=in-sync.
        grep -v "^job=$id " "$STAMP" >"$STAMP.tmp.$$" 2>/dev/null && mv -f "$STAMP.tmp.$$" "$STAMP" 2>/dev/null || true
        say "uninstalled $id"
        # ⛔ A DIFFERENT SCOPE HOLDING THE SAME UNIT IS A NOTE, NOT A FAILURE (#2071). Scanning
        # /etc/systemd/system unconditionally made this verb return 1 on every host that legitimately
        # carries a system-scope install — a false block on the only way to remove the user one. But
        # silence is not the answer either: a second ARMED timer is a second hourly deletion pass, so it
        # is named. `SJ_EXTRA_SCOPES` (colon-separated) is the documented seam for a scope this run did
        # not resolve; the two real scopes are always inspected.
        if [ "$PLATFORM" = linux ]; then
            local _sc _scopes
            # A COLON-SEPARATED list, like every other path list in this repo (never space-split: a
            # directory with a space in it would silently become two scopes that do not exist).
            _scopes="$(printf '%s\n' /etc/systemd/system "$HOME/.config/systemd/user"; printf '%s' "${SJ_EXTRA_SCOPES:-}" | tr ':' '\n')"
            while IFS= read -r _sc; do
                [ -n "$_sc" ] || continue
                [ "$_sc" = "$UNIT_DIR" ] && continue
                if [ -f "$_sc/$unit.timer" ] || [ -f "$_sc/$unit.service" ]; then
                    say "note: $id is ALSO installed in $_sc — a second armed copy this verb did not touch"
                fi
            done <<<"$_scopes"
        fi
    done
    return "$rc"
}

do_list() {
    local id
    require_ids
    for id in $IDS; do
        printf '%s\tplatforms=%s\tschedule=%s\tmanaged=%s\towner=%s\n' \
            "$id" "$(sj_field "$id" platforms)" "$(sj_field "$id" schedule)" \
            "$(sj_field "$id" managed)" "$(sj_field "$id" owner)"
    done
}

# ── main ────────────────────────────────────────────────────────────────────────────────────
if [ "$VERB" != list ]; then
    vout="$(sj_validate 2>&1)" || { printf '%s\n' "$vout" >&2; exit 1; }
fi

case "$VERB" in
    install)   do_install ;;
    status)    do_status ;;
    start|stop|restart) do_scheduler_verb "$VERB" ;;
    uninstall) do_uninstall ;;
    parity)    if [ "$QUIET" = 1 ]; then exec bash "$HERE/check-scheduled-parity.sh" --platform "$PLATFORM" --quiet; fi
               exec bash "$HERE/check-scheduled-parity.sh" --platform "$PLATFORM" ;;
    list)      do_list ;;
esac
exit $?
