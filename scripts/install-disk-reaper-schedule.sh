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
# ⛔ AND AN ARMING SURVIVES A NO-FLAG RE-INSTALL. `pi-bootstrap/setup.sh` (which `sync.sh` runs) calls
# this installer with `--install` and NO mode flag on every run, so an arming that existed only in the
# previous invocation was silently reverted at the next sync — the Mac could never stay armed, which is
# the disk-fill incident #2048 exists to prevent. The arming is therefore PERSISTED in the schedule
# stamp this installer writes ($STATE_DIR/disk-reaper.schedule, key `armed=`), and a no-flag install
# adopts it. An EXPLICIT `--apply`/`--dry-run` always wins and rewrites the stamp. This is still not an
# environment default: the stamp is state THIS TOOL wrote, arming still requires an explicit owner
# invocation at least once, `--status` reads the arming off the installed artifact, and `--uninstall`
# deletes the stamp so a fresh install starts report-only again.
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
# `scheduler=`, `job=`, `installed=`, `enabled=`, `active=`, `armed=`, `armed_at=`, `armed_by=`,
# `next_run=`, `interval_seconds=`,
# `last_exit=`, `pass_drift=`, `repos=`, and then the pass record itself — the SAME file, written by the
# SAME pass, so "what did it free and did it succeed" cannot drift between a cell and a laptop. `armed=`
# is read from the INSTALLED artifact, never from the flags this invocation was given; `repos=` likewise
# says what the SCHEDULED job will scan, not what this shell happens to export.
# ⛔ THE EXIT CODE IS A CONTRACT, NOT DECORATION: `cloud-cell-bringup.sh` gates on it. 0 means
# scheduled AND loaded (systemd: the timer is enabled and active; launchd: the plist exists and the job
# is bootstrapped into the domain). A present-but-disabled timer, or a plist left behind after a
# `bootout`, is NOT scheduled — it used to answer 0 here, which certified a box whose reaper never fires.
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
#                                   [--status]
#                                   [--uninstall [--preview]] [--help]
#
#   (no mode flag)  install a REPORT-ONLY job (the shipped stance, #1678)
#   --apply         install the ARMED job (owner decision; visible in the installed unit)
#   --dry-run       install the report-only job (the default, said explicitly)
#   --preview       render and print what WOULD be installed; with --uninstall: show what WOULD be
#                   removed. Either way: write nothing, install nothing, remove nothing
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
#   SYSTEMD_SYSTEM_DIR       the SYSTEM unit dir (default /etc/systemd/system; a test seam for the
#                            system branch, which was previously reachable only with real sudo)
#   SYSTEMCTL                `systemctl` to call (default `sudo -n systemctl`)
#   SYSTEMCTL_USER           `systemctl` for the USER manager (default `systemctl --user`)
#   SUDO                     `sudo` probe (default `sudo -n`); EMPTY means "we already are root" (so the
#                            substitution is `${SUDO-…}`, never `${SUDO:-…}` — see choose_systemd_target)
#   DISK_REAPER_AGENTS_DIR   launchd install dir (default $HOME/Library/LaunchAgents)
#   LAUNCHCTL                `launchctl` to call (tests: a shim)
#   LAUNCHD_DOMAIN           launchd domain (default gui/$(id -u))
#   DISK_REAPER_LABEL        launchd label override (tests: a throwaway label)
#   DISK_REAPER_PYTHON       interpreter for the Darwin launcher (default: a tortoise checkout's
#                            .venv python — the binary that HOLDS the TCC access — else python3)
#   ELDATO_ALLOW_TEST_HOME   permit launchd management when $HOME is not the real home (tests ONLY;
#                            requires a launchctl shim — same contract as install-launchd.sh, #446)
#
# Exit codes: 0 ok · 1 failure (named) · 2 usage · 3 DECLINED, this is not the box (a temp-HOME
# launchd run, #446) — the caller must not treat a decline as a failure of the box it was handed ·
# 4 the real home could not be DETERMINED (getent/dscl/~user all failed).
# ⛔ 3 AND 4 ARE DIFFERENT FACTS (#2048 review, P2): 3 says "this run is about another machine, so
# nothing here is a failure"; 4 says "this IS the box and I could not verify it", which the caller MUST
# report. Folding both into 3 let an account no probe can resolve (an AD/OD-bound Mac) install nothing
# and still end with `setup.sh` printing SKIPPED and exiting 0 — the exact false PASS this installer
# exists to remove, one layer up.
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

usage_body() {
    # The header IS the help text: line 2 down to the `set` line, uncommented. The end is DERIVED, not
    # a fixed line range, so a header edit can never silently truncate --help.
    awk 'NR > 1 { if ($0 ~ /^set -uo pipefail$/) exit; sub(/^# ?/, ""); print }' "$0"
}
usage() { usage_body; exit 2; }

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
#
# ⛔ THE CANDIDATE LIST IS NOT "WHATEVER THE INSTALLING SHELL EXPORTS" (#2048 review, P1). `setup.sh`,
# `sync.sh`, a bring-up and a cron all invoke this installer from different shells, and a Mac that
# exported only $AGENT_INFRA_PATH used to install a job that scanned agent-infra while
# `resolve_python` handed it the TORTOISE checkout's interpreter — one box, two answers, and the big
# repo never scanned (the `disk-reaper.sh` empty-list refusal does not fire on ONE non-empty repo, so
# it exited 0 while doing it). Explicit env first, then the canonical checkouts this fleet has on both
# platforms; BOTH resolvers read this ONE list, so the interpreter and the repos cannot disagree.
candidate_checkouts() {
    printf '%s\n' \
        "${TORTOISE_REPO:-}" "${REPO:-}" "${WORKDIR:-}" "${AGENT_INFRA_PATH:-}" \
        "${HOME:-}/Documents/GitHub/tortoise" \
        "${HOME:-}/Documents/GitHub/agent-infra"
}

resolve_repos() {
    local r seen=" " out=""
    local list="${DISK_REAPER_REPOS:-}"
    if [ -z "$list" ]; then
        list="$(candidate_checkouts)"
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
    local cand r
    if [ -n "${DISK_REAPER_PYTHON:-}" ]; then printf '%s' "$DISK_REAPER_PYTHON"; return 0; fi
    # The SAME candidate list the repos come from: an interpreter and a repo list that disagree about
    # which box this is would scan one checkout with another one's binary.
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        cand="$r/.venv/bin/python"
        [ -x "$cand" ] && { printf '%s' "$cand"; return 0; }
    done <<<"$(candidate_checkouts)"
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

# ── the REAL home, portably ─────────────────────────────────────────────────────────────────────
# #446's hazard is launchd-specific, but the PROBE was not portable: `dscl` is macOS-only, so on Linux
# this guard resolved nothing and a temp-HOME run installed into a domain it should have refused — the
# #446 assertion in the suite was red on CI and could not be reproduced on a Mac (where dscl answers).
# One resolver, both platforms, and an UNKNOWN answer is a REFUSAL: the probe exists to keep a job
# whose plist path dies with a throwaway HOME out of the live domain, so "cannot tell" is not "fine".
resolve_real_home() {
    local u home=""
    u="$(id -un 2>/dev/null)" || return 0
    case "$u" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac   # never eval an unexpected name
    # Linux / any NSS-backed box (macOS has no getent by default, hence the dscl arm below).
    # ⛔ THE FIELD INDEX IS THE WHOLE POINT: a passwd line is name:passwd:uid:gid:GECOS:home:shell, so
    # the home is the SIXTH field — five leading groups skipped, not four. Skipping four captures GECOS,
    # which on every box with a full name returns "Daniel Ospina" instead of a path and makes the guard
    # decline every correctly-configured Mac (#2048 review, P1).
    if command -v getent >/dev/null 2>&1; then
        home="$(getent passwd "$u" 2>/dev/null | sed -n '1s/^[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\([^:]*\):.*$/\1/p')"
    fi
    # macOS.
    if [ -z "$home" ] && command -v dscl >/dev/null 2>&1; then
        home="$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p' | head -1)"
    fi
    # Last resort: the shell's own getpwnam expansion (~user). An unresolved name stays literal, and a
    # literal token is reported as UNKNOWN rather than mistaken for a home.
    if [ -z "$home" ]; then
        home="$(eval printf '%s' "~$u" 2>/dev/null || true)"
        case "$home" in "~"*) home="" ;; esac
    fi
    printf '%s' "$home"
}

# norm_path <path> — a comparable form of a directory path. A trailing slash and a symlinked home are
# the two ordinary spellings that made a healthy Mac decline (HOME=/Users/x/ vs the passwd entry
# /Users/x), and a guard that refuses a CORRECT box is not safe — it is silent under `setup.sh`, which
# turns a decline into SKIPPED and a green exit (#2048 review).
norm_path() {
    local p="${1:-}"
    while [ "${p%/}" != "$p" ] && [ "$p" != "/" ]; do p="${p%/}"; done
    if [ -n "$p" ] && [ -d "$p" ]; then (cd "$p" 2>/dev/null && pwd -P) || printf '%s' "$p"
    else printf '%s' "$p"; fi
}

# ── render ─────────────────────────────────────────────────────────────────────────────────────
# sed_repl — make a value safe BOTH as the replacement half of `s|…|…|g` and inside the XML text node
# it lands in. Two escapes, and the XML one is not optional: `&` is the entity introducer (an
# unescaped one makes the plist malformed — measured in #1719, `plutil -lint` refused it) and `&`/`\`
# are sed replacement metacharacters (a value carrying either is silently corrupted into the output).
# ⛔ TWO ESCAPERS, because the two templates are two languages (#2048 review, P3). XML entities are
# NOT decoded by systemd, so routing the systemd unit through the XML escaper corrupted it: a PATH or
# state dir carrying `&` rendered as `…/rd&amp;d`, i.e. a directory that does not exist, and a corrupted
# `DISK_REAPER_REPOS` entry is a repo list that silently scans the wrong place. Each renderer takes the
# escaper its target language needs.
sed_repl_sed() { # sed replacement metacharacters only — for systemd units (plain text)
    printf '%s' "$1" | sed -e 's/[&\\|]/\\&/g'
}
sed_repl() { # XML text node + sed replacement — for launchd plists
    printf '%s' "$1" \
        | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        | sed -e 's/[&\\|]/\\&/g'
}

# render <template> <dest> — one placeholder set for both templates. A leftover {{ is a REFUSAL: it
# would install a job whose argument is the literal token, and the job would be inert while `--status`
# called it scheduled.
render() {
    local tpl="$1" dest="$2" esc=sed_repl
    # A plist is XML (entities required); a unit is plain text (entities would be literal garbage).
    case "$tpl" in *.plist*) esc=sed_repl ;; *) esc=sed_repl_sed ;; esac
    sed -e "s|{{USER}}|$($esc "$(id -un)")|g" \
        -e "s|{{HOME}}|$($esc "$HOME")|g" \
        -e "s|{{PATH}}|$($esc "$PATH")|g" \
        -e "s|{{STATE_DIR}}|$($esc "$STATE_DIR")|g" \
        -e "s|{{REPOS}}|$($esc "$REPOS")|g" \
        -e "s|{{AGED_DAYS}}|$($esc "$AGED_DAYS")|g" \
        -e "s|{{INTERVAL}}|$($esc "$INTERVAL_SECONDS")|g" \
        -e "s|{{REAPER}}|$($esc "$REAPER")|g" \
        -e "s|{{MODE_FLAG}}|$($esc "$MODE_FLAG")|g" \
        -e "s|{{LABEL}}|$($esc "$LABEL")|g" \
        -e "s|{{PYTHON_BIN}}|$($esc "${PYTHON_BIN:-}")|g" \
        -e "s|{{LAUNCHER}}|$($esc "${LAUNCHER:-}")|g" \
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
# ONE token, whatever the tool printed and whatever it exited. Two defects live here (#2048 review):
# `systemctl is-enabled` prints `disabled` AND exits 1, so the shape `$(… || echo disabled)` emitted
# `disabled` TWICE on a real systemd box — invisible to a test whose shim echoed the token and exited 0;
# and a diagnostic line printed BEFORE the token (a wrapper, an override, an odd systemd) became the
# value, so a genuinely scheduled timer read as "NOT scheduled". So: select the token, not the line.
first_token() {
    printf '%s\n' "${1:-}" | awk '/^[a-z][a-z-]*$/{t=$0} END{if (t != "") print t}'
}
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
    # ⛔ ARMING PROVENANCE (#2048 review, P3). `installed_at=` is re-dated by EVERY install, including
    # the no-flag one `setup.sh`/`sync.sh` runs, so it cannot answer "since when has this box been
    # DELETING?". Arming is the one irreversible-ish act in this file, and the docs call it a dated
    # owner step — so the date is recorded when the arming is DECIDED and carried forward unchanged when
    # a later install merely adopts it (the `armed-date` discipline install-launchd.sh uses for
    # worktree-hygiene). `armed_by=` names who/where, because the same box can be armed by a cell's
    # bring-up or by an owner's shell.
    local armed_at armed_by previous_stance previous_armed_at now_stance
    now_stance="${MODE_FLAG#--}"
    previous_stance="$(stamp_field armed)"
    previous_armed_at="$(stamp_field armed_at)"
    # ⛔ THE DATE BELONGS TO THE STANCE, NOT TO THE FLAG THAT RESTATED IT (#2048 review, P2). A cell's
    # bring-up calls `--install --apply` on EVERY check, so "an explicit flag is a new decision" re-dated
    # the arming at each check and turned `armed_at=` into "the last --check" — contradicting what the
    # field exists to answer. Worse, it silently re-armed a box whose recorded stance an owner had
    # reversed to `--dry-run`: the destructive direction of the P1 this file already fixed.
    # The rule: the flag still WINS on the stance (an explicit flag is authoritative, and `--dry-run`
    # remains the reversal), but the DATE moves only when the STANCE changes.
    if [ "${MODE_EXPLICIT:-0}" = 1 ] && [ "$now_stance" != "$previous_stance" ]; then
        armed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        armed_by="${SUDO_USER:-$(id -un)}@$(hostname 2>/dev/null || printf 'unknown')"
        if [ -n "$previous_stance" ] && [ "$now_stance" = "apply" ] && [ "$previous_stance" = "dry-run" ]; then
            # Say it out loud: a caller that passes --apply unconditionally (the cell bring-up) has just
            # overridden a recorded reversal, and silence is how the owner never learns.
            warn "RE-ARMING: the recorded stance was dry-run (since ${previous_armed_at:-unknown}), and this invocation passes --apply — the job will now DELETE. Pass --dry-run to keep it report-only."
        fi
    else
        # An ADOPTION (no flag, or a flag restating the recorded stance) must not move the date.
        armed_at="$(stamp_field armed_at)"
        armed_by="$(stamp_field armed_by)"
        [ -n "$armed_at" ] || armed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        [ -n "$armed_by" ] || armed_by="${SUDO_USER:-$(id -un)}@$(hostname 2>/dev/null || printf 'unknown')"
    fi
    mkdir -p "$STATE_DIR" 2>/dev/null || { err "cannot create state dir $STATE_DIR"; return 1; }
    tmp="$STAMP.tmp.$$"
    {
        printf 'platform=%s\n' "$PLATFORM"
        printf 'scheduler=%s\n' "$SCHEDULER"
        printf 'job=%s\n' "$1"
        printf 'armed=%s\n' "${MODE_FLAG#--}"
        printf 'armed_at=%s\n' "$armed_at"
        printf 'armed_by=%s\n' "$armed_by"
        printf 'pass=%s\n' "$REAPER"
        printf 'pass_sha=%s\n' "$sha"
        printf 'installed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        # ⛔ WHERE it was installed. `choose_systemd_target` re-derives the target on EVERY run from the
        # sudo probe and the user-manager answer, so a box whose probe changed (installed as root, later
        # uninstalled by a sudo-less user — or the reverse) made `--uninstall` remove from a directory the
        # install never wrote and `--status` read `installed=no` for a scheduled box (#2048 review, P2).
        # Recording the location turns both verbs into a READ of where the artifact actually went.
        printf 'target=%s\n' "${INSTALLED_TARGET:-}"
        printf 'dir=%s\n' "${INSTALLED_DIR:-}"
    } >"$tmp" 2>/dev/null && mv -f "$tmp" "$STAMP" 2>/dev/null \
        || { err "cannot write the schedule stamp $STAMP"; rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

# ── systemd backend ───────────────────────────────────────────────────────────────────────────
SD_TARGET=""; UNIT_DIR=""; SC=""
# The system unit dir is a SEAM, not a literal: with `SUDO=""` (root, or a test) the `install` arm below
# writes to it unprivileged, and nothing else could reach that branch without real sudo (#2048 review).
SYSTEMD_SYSTEM_DIR="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
SYSTEMCTL_USER="${SYSTEMCTL_USER:-systemctl --user}"
# ⛔ `${SUDO-…}`, NOT `${SUDO:-…}`. With `:-`, a SET-BUT-EMPTY `SUDO=""` expanded to `sudo -n` anyway,
# so the "we already are root" arm was DEAD CODE — no test could reach it and a root/container run took
# the sudo probe's answer instead of its own (#2048 review). `SUDO=""` now means exactly what it says.
choose_systemd_target() {
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ]; then
        SD_TARGET="override"; UNIT_DIR="$SYSTEMD_UNIT_DIR"; SC="${SYSTEMCTL:-systemctl}"
        return 0
    fi
    if [ "${SUDO-sudo -n}" = "" ] || ${SUDO-sudo -n} true >/dev/null 2>&1; then
        SD_TARGET="system"; UNIT_DIR="$SYSTEMD_SYSTEM_DIR"; SC="${SYSTEMCTL:-sudo -n systemctl}"
        return 0
    fi
    if $SYSTEMCTL_USER show-environment >/dev/null 2>&1; then
        SD_TARGET="user"; UNIT_DIR="$HOME/.config/systemd/user"; SC="$SYSTEMCTL_USER"
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
    # A USER unit dir is ours by definition (no privilege is involved), so it is written directly. The
    # SYSTEM dir needs sudo — or none at all when `SUDO=""` says we are already root.
    if [ -n "${SYSTEMD_UNIT_DIR:-}" ] || [ "$SD_TARGET" = "user" ]; then
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
    # ⛔ THE STAMP IS AN OPTIMISATION, NOT THE INSTALL. By the time it can fail the unit is written,
    # enabled and read back — so failing the verb here would tell `setup.sh` "this Mac has NO disk-reaper
    # schedule" about a Mac that IS scheduled, and (on a cell) send the bring-up hunting sudo for a state
    # dir problem (#2048 review). Degrade visibly instead: no stamp = no pass-SHA reload protection and a
    # no-flag re-install falls back to report-only.
    INSTALLED_TARGET="$SD_TARGET"; INSTALLED_DIR="$UNIT_DIR"
    write_stamp "$UNIT_NAME.timer" \
        || warn "the schedule stamp $STAMP could not be written — the job IS installed and enabled. Two things follow from the missing stamp: every later install looks like a changed pass and reloads the timer, and a no-flag re-install (setup.sh/sync.sh) falls back to report-only"
    return 0
}

# recorded_dir — the directory the INSTALL wrote its artifacts into, from the stamp; empty when the
# stamp is absent (an older install, or after --uninstall). The verbs that must not lie use it: the
# live `choose_systemd_target` re-derives from the sudo probe, so trusting only the probe is what made
# `--uninstall` remove from a directory the install never used and still exit 0 (#2048 review, P2).
recorded_dir() { stamp_field dir; }

# retarget_from_record — re-point UNIT_DIR and the systemctl command at the install the STAMP records.
# `choose_systemd_target` re-derives both from the sudo probe on every run, so a box whose probe moved
# between install and uninstall sent `disable --now` and `daemon-reload` to a manager that never owned
# the unit: the files were removed, "uninstalled" was printed, and the SYSTEM manager kept the timer
# enabled+active in memory with its `timers.target.wants/` symlink intact — it kept firing until a
# reboot (#2048 review, P2). Returns 1 when no location was recorded (an older install).
retarget_from_record() {
    local rec_target rec_dir
    rec_target="$(stamp_field target)"; rec_dir="$(stamp_field dir)"
    [ -n "$rec_dir" ] || return 1
    UNIT_DIR="$rec_dir"
    case "$rec_target" in
        system)   SD_TARGET="system";   SC="${SYSTEMCTL:-${SUDO-sudo -n} systemctl}" ;;
        user)     SD_TARGET="user";     SC="$SYSTEMCTL_USER" ;;
        override) SD_TARGET="override"; SC="${SYSTEMCTL:-systemctl}" ;;
        *)        return 1 ;;
    esac
    return 0
}

# dirs_to_consider <live-dir> — EVERY directory this installer can install into, deduplicated:
#   * the directory the STAMP records (where the last install actually went),
#   * the one this invocation derived,
#   * and every other target this tool can reach (the system dir, the user dir, and any override).
# ⛔ RECORDED + LIVE IS NOT ENOUGH (#2048 review, P2). A re-install whose probe moved OVERWRITES the
# stamp with the new target, so the earlier target's unit becomes invisible to a caller that only
# unions those two: install with root into the system dir, re-install as a sudo-less user, then
# `--uninstall` → files removed from the user dir, "uninstalled", exit 0, and an ENABLED system timer
# still deleting hourly with its stamp (the only record of both the arming and the location) deleted.
# The read-back has to cover every place a unit could be, or "uninstalled" is a guess.
dirs_to_consider() {
    local live="${1:-}" rec seen=" " d
    rec="$(recorded_dir)"
    # `${HOME:-}` like the rest of this file: root/container runs (SUDO="", no HOME) are a supported
    # configuration, and `$HOME` here made `set -u` abort MID-LIST inside a process substitution — a
    # truncated candidate list is indistinguishable from a complete one, so the read-back that makes
    # "uninstalled" a verified claim degraded silently (#2048 review, P3).
    for d in "$rec" "$live" "${SYSTEMD_UNIT_DIR:-}" "$SYSTEMD_SYSTEM_DIR" "${HOME:-}/.config/systemd/user"; do
        [ -n "$d" ] || continue
        case "$seen" in *" $d "*) continue ;; esac
        seen="$seen$d "
        printf '%s\n' "$d"
    done
    return 0
}

# ── which MANAGER owns which candidate directory ────────────────────────────────────────────────
# `choose_systemd_target` answers "which manager should I use", and the answer moves with the sudo
# probe. The artifacts do not move with it: a unit installed as root lives in the system dir and is
# owned by the SYSTEM manager whatever this run's probe says. So the verbs that remove or report on an
# install ask this instead — one row per candidate directory, `<target> <command>`.
managers_in_play() { # <live-dir>
    local d rec live
    rec="$(recorded_dir)"; live="${1:-}"
    for d in "$rec" "$live" "${SYSTEMD_UNIT_DIR:-}" "$SYSTEMD_SYSTEM_DIR" "${HOME:-}/.config/systemd/user"; do
        [ -n "$d" ] || continue
        case "$d" in
            "${SYSTEMD_UNIT_DIR:-__none__}") printf 'override %s\n' "${SYSTEMCTL:-systemctl}" ;;
            "$SYSTEMD_SYSTEM_DIR")           printf 'system %s\n' "${SYSTEMCTL:-${SUDO-sudo -n} systemctl}" ;;
            "${HOME:-}/.config/systemd/user") printf 'user %s\n' "$SYSTEMCTL_USER" ;;
            *) printf 'recorded %s\n' "${SYSTEMCTL:-systemctl}" ;;
        esac
    done | awk '!seen[$1]++'
}

# notify_managers <live-dir> — disable the timer through every manager that could own it.
notify_managers() {
    local t cmd
    while IFS=' ' read -r t cmd; do
        [ -n "$cmd" ] || continue
        $cmd disable --now "$UNIT_NAME.timer" >/dev/null 2>&1 || true
    done < <(managers_in_play "${1:-}")
}

# notify_managers_reload <live-dir> — and make each of them forget the unit it just lost.
notify_managers_reload() {
    local t cmd
    while IFS=' ' read -r t cmd; do
        [ -n "$cmd" ] || continue
        $cmd daemon-reload >/dev/null 2>&1 || true
    done < <(managers_in_play "${1:-}")
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

# repos_from_file <installed unit/plist> — what the SCHEDULED job will scan, read from the ARTIFACT.
# The installing shell's exports answer a different question (what THIS invocation saw), which is how a
# Mac that exported only $AGENT_INFRA_PATH ended up with a job pointed at the wrong repo (#2048 review,
# P1). Answering it from the installed job makes "does this box reap the big repo?" readable.
repos_from_file() {
    local f="$1"
    [ -f "$f" ] || return 0
    case "$f" in
        *.service) sed -n 's/^Environment=DISK_REAPER_REPOS=//p' "$f" | head -1 ;;
        *)         awk '/<key>DISK_REAPER_REPOS<\/key>/{f=1;next} f && /<string>/{sub(/.*<string>/,"");sub(/<\/string>.*/,"");print;exit}' "$f" ;;
    esac
}

# sd_is_scheduled <enabled> <active> — polarity, not vocabulary, and the ONLY enabled-ish state this
# installer's own `enable --now` can produce is `enabled`. `enabled-runtime` means "until reboot",
# `static`/`indirect` mean "no [Install] section, never pulled in at boot", `transient` is runtime-only:
# accepting any of them would exit 0 for a timer that disappears at the next reboot, which is the
# delayed form of the false PASS this contract exists to remove (#2048 review). Everything else,
# including a token systemd has not documented, is NOT scheduled.
sd_is_scheduled() {
    [ "$1" = "enabled" ] || return 1
    [ "$2" = "active" ]
}

# runner_from_file <installed unit/plist> — WHAT the scheduler actually starts. On macOS this is the
# TCC seam (the checkout's interpreter on the farmed launcher), and "no tortoise .venv, so it fell back
# to python3" is the single most likely reason a Mac pass fails closed — so the verb that exists to
# diagnose the job has to answer it (#2048 review). Read off the artifact, like armed= and repos=.
runner_from_file() {
    local f="$1"
    [ -f "$f" ] || { printf 'unknown'; return 0; }
    case "$f" in
        *.service)
            awk '/^ExecStart=/{sub(/^ExecStart=/,""); split($0,a," "); print a[1]" "a[2]; exit}' "$f" ;;
        *)
            awk '/<key>ProgramArguments<\/key>/{f=1;next}
                 f && /<string>/{sub(/.*<string>/,""); sub(/<\/string>.*/,"");
                                n++; if (n<=2) printf "%s%s", (n>1?" ":""), $0; if (n==2) { print ""; exit }}' "$f" ;;
    esac
}

sd_status() {
    local next last_exit svc en act
    # ⛔ THE RECORD DECIDES THE MANAGER, because the EXIT CODE is the contract `cloud-cell-bringup.sh`
    # gates on (#2048 review, P2/P3): reading `is-enabled`/`is-active` off a re-derived manager answered
    # `disabled inactive` for a unit that was installed, enabled and armed — exit 1 on a correctly
    # scheduled box — and a probe that no longer resolves refused the question entirely. The live probe
    # is the fallback, never the first answer.
    retarget_from_record || choose_systemd_target || { err "no systemd scheduler available"; return 1; }
    svc="$UNIT_DIR/$UNIT_NAME.service"
    say "platform=linux"
    say "scheduler=systemd"
    say "job=$UNIT_NAME.timer"
    say "job_path=$UNIT_DIR/$UNIT_NAME.timer"
    # PRESENT means the installed file is there. When it is not readable (a sudo-installed unit on an
    # odd box) `systemctl cat` is the second opinion — it exits non-zero for an unknown unit, which is
    # what makes "installed=no" a real answer instead of a fallback that always succeeds.
    if [ ! -f "$svc" ] && ! { local _rd; _rd="$(recorded_dir)"; [ -n "$_rd" ] && [ -f "$_rd/$UNIT_NAME.service" ]; } \
       && ! $SC cat "$UNIT_NAME.service" >/dev/null 2>&1; then
        say "installed=no"
        say "enabled=disabled"
        say "active=inactive"
        return 1
    fi
    say "installed=yes"
    en="$(first_token "$($SC is-enabled "$UNIT_NAME.timer" 2>/dev/null)")"
    act="$(first_token "$($SC is-active "$UNIT_NAME.timer" 2>/dev/null)")"
    [ -n "$en" ] || en=disabled
    [ -n "$act" ] || act=inactive
    say "enabled=$en"
    say "active=$act"
    next="$($SC list-timers --all --no-pager 2>/dev/null | awk -v u="$UNIT_NAME.timer" '$0 ~ u {print $1" "$2" "$3; exit}')"
    say "next_run=${next:-unknown}"
    last_exit="$($SC show -p ExecMainStatus --value "$UNIT_NAME.service" 2>/dev/null)"
    case "$last_exit" in ''|*[!0-9]*) last_exit=unknown ;; esac
    say "last_exit=$last_exit"
    say "interval_seconds=$INTERVAL_SECONDS"
    say "armed=$(armed_from_file "$svc")"
    # Since WHEN, and by whom — the stamp's own record (never this invocation's flags). A no-flag
    # re-install adopts both unchanged, so this is the date the box started deleting, not the date of
    # the last sync (#2048 review, P3).
    say "armed_at=$(stamp_field armed_at)"
    say "armed_by=$(stamp_field armed_by)"
    # THE EXIT CODE IS THE CONTRACT (`cloud-cell-bringup.sh` gates on it): 0 only when the timer is
    # actually scheduled. A present-but-disabled timer (or a loaded-but-not-enabled one) is not
    # scheduled in the sense being asserted, and this used to answer 0 for it — a false PASS.
    if ! sd_is_scheduled "$en" "$act"; then
        err "$UNIT_NAME.timer is present but NOT scheduled (enabled=$en active=$act) — it will not fire unattended. Re-run --install, or enable it by hand"
        return 1
    fi
    return 0
}

sd_uninstall() {
    if [ "${PREVIEW:-0}" = "1" ]; then
        say "preview: would disable and remove $UNIT_NAME.service/.timer from $UNIT_DIR (nothing was changed)"
        return 0
    fi
    local dirs=() d found=0 live_dir recorded
    # What THIS run derives first (the probe may still answer, and its directory is a real candidate)…
    live_dir=""
    choose_systemd_target && live_dir="$UNIT_DIR"
    # …then the RECORD, which decides the directory AND the manager the artifact is actually under. On a
    # box whose probe no longer resolves the stamp is the only thing that knows either, and refusing
    # there left an armed reaper un-uninstallable through the tool (#2048 review, P3).
    recorded="$(recorded_dir)"
    retarget_from_record || { [ -n "$live_dir" ] || { err "no systemd scheduler available"; return 1; }; }
    [ -n "$live_dir" ] || live_dir="$UNIT_DIR"
    # EVERY directory that may hold it — that is the READ-BACK's population, so a survivor anywhere
    # still fails the verb. The DELETION population is narrower on purpose (see below).
    local candidates=()
    while IFS= read -r d; do [ -n "$d" ] && candidates+=("$d"); done < <(dirs_to_consider "$live_dir")
    [ "${#candidates[@]}" -gt 0 ] || candidates=("$UNIT_DIR")
    # ⛔ DELETE ONLY WHERE THE RECORD (or this invocation) SAYS THE INSTALL WENT (#2048 review, P3).
    # Removing from every candidate directory turned a stamp-less run into a wildcard uninstall of the
    # machine-global unit — a state dir with NO record of it deleted a unit some other install owned.
    dirs=()
    for d in "$(recorded_dir)" "$live_dir"; do
        [ -n "$d" ] || continue
        case " ${dirs[*]-} " in *" $d "*) continue ;; esac
        dirs+=("$d")
    done
    [ "${#dirs[@]}" -gt 0 ] || dirs=("$UNIT_DIR")
    # …and tell EVERY manager that owns a directory in play, not just the recorded one: with the probe
    # flipped, the files were removed but the manager that actually held the timer was never asked to
    # disable or reload it, so it kept firing until a reboot while the verb printed "uninstalled"
    # (#2048 review, P2).
    notify_managers "$live_dir"
    local want_priv
    for d in "${dirs[@]}"; do
        # ⛔ THE PRIVILEGE IS CHOSEN PER DIRECTORY, NOT FROM THE RECORD (#2048 review, P3). Deciding it
        # from `SD_TARGET` meant a probe flip made a SYSTEM unit get a plain `rm -f`: the operator held
        # the sudo the tool refused to use, the removal failed, and NO RE-RUN COULD COMPLETE IT — the
        # record kept saying `user`, so the leftover system unit was unremovable except by hand. A
        # directory outside the user's reach is exactly what ${SUDO-…} is for.
        case "$d" in
            "${SYSTEMD_UNIT_DIR:-__none__}"|"${HOME:-}/.config/systemd/user") want_priv=0 ;;
            *) want_priv=1 ;;
        esac
        if [ "$want_priv" = 0 ] || [ -w "$d" ]; then
            rm -f "$d/$UNIT_NAME.service" "$d/$UNIT_NAME.timer"
        else
            ${SUDO-sudo -n} rm -f "$d/$UNIT_NAME.service" "$d/$UNIT_NAME.timer"
        fi
    done
    notify_managers_reload "$live_dir"
    # READ IT BACK. A denied `rm` (a sudo-less user over a root-owned unit) used to print "uninstalled"
    # and exit 0, and systemd reloads the surviving unit at the next boot — the removal is the claim, so
    # the removal is what gets verified (#2048 review). The read-back covers EVERY candidate directory:
    # a probe flip between install and uninstall used to check only the re-derived one, so a unit left
    # enabled in the recorded directory was reported as removed while still deleting hourly.
    for d in "${candidates[@]}"; do
        [ -f "$d/$UNIT_NAME.service" ] || [ -f "$d/$UNIT_NAME.timer" ] && { found=1; err "uninstall INCOMPLETE: $UNIT_NAME is still installed under $d"; }
    done
    # …and every manager that owns one of them is asked too, not only `$SC`: a file removed while the
    # manager still knows the unit is exactly the survivor this read-back exists to catch.
    local mc mc_target
    while IFS=' ' read -r mc_target mc; do
        [ -n "$mc" ] || continue
        $mc cat "$UNIT_NAME.service" >/dev/null 2>&1 && { found=1; err "uninstall INCOMPLETE: $UNIT_NAME is still known to the $mc_target manager"; }
    done < <(managers_in_play "$live_dir")
    if [ "$found" -eq 1 ]; then
        err "uninstall INCOMPLETE — nothing is claimed beyond what was read back"
        return 1
    fi
    rm -f "$STAMP"
    say "uninstalled $UNIT_NAME from ${dirs[*]}"
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

# lint_plist <file> — is the rendered plist well-formed XML at all? A malformed plist is an INERT job
# (measured in #1719: one unescaped `&` broke it), so it must be refused before it is installed.
# ⛔ THE LINTER IS NOT "plutil OR NOTHING": CI is `ubuntu-latest`, where plutil does not exist, so a
# plutil-gated refusal is a refusal that never runs on the platform this repo's gate lives on (#2048
# review). python3's plistlib parses the same XML and is present on both platforms. No linter at all
# is said out loud rather than passed silently — the render-time `{{` refusal still ran.
lint_plist() {
    local f="$1"
    if command -v plutil >/dev/null 2>&1; then
        plutil -lint "$f" >/dev/null 2>&1; return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "$f" >/dev/null 2>&1
        return $?
    fi
    warn "no plist linter on this box (no plutil, no python3) — the rendered plist was not linted"
    return 0
}

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
    # A malformed plist is an inert job: launchd accepts nothing of it.
    if ! lint_plist "$tmp/$LABEL.plist"; then
        err "rendered plist is MALFORMED — refusing to install it"
        command -v plutil >/dev/null 2>&1 && plutil -lint "$tmp/$LABEL.plist" >&2
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
    else
        # ⛔ AN UNCHANGED, LOADED JOB IS EXACTLY WHERE A DISABLE OVERRIDE HIDES (#2048 review, P3):
        # `launchctl disable` leaves the plist and the load in place, so nothing above fires, the
        # reload (the only caller of `$LC enable`) is skipped, and `--status` keeps reporting a box
        # that will never fire. A re-install must repair it, so `enable` runs on the no-op path too.
        $LC enable "$LD_DOMAIN/$LABEL" >/dev/null 2>&1 || true
    fi

    say "installed: platform=darwin scheduler=launchd job=$LABEL dir=$LD_DIR changed=$changed pass_changed=$(no_yes "$pass_changed") reload_reason=$reason"
    say "  pass:   $REAPER"
    say "  armed:  ${MODE_FLAG#--} (the mode flag is in ProgramArguments, not an environment default)"
    say "  runner: $PYTHON_BIN $LAUNCHER --script <pass> ${MODE_FLAG}"
    say "          (the TCC seam: this interpreter holds the ~/Documents access a launchd bash is denied)"
    say "  repos:  ${REPOS:-<none>}  (worktree floor ${AGED_DAYS}d)"
    say "  state:  $STATE_DIR/disk-reaper.status"
    # Same rule as systemd: the job is installed and loaded by now, so an unwritable stamp is a named
    # degradation, never a failure that mis-describes the machine (#2048 review).
    INSTALLED_TARGET="launchd"; INSTALLED_DIR="$LD_DIR"
    write_stamp "$LABEL" \
        || warn "the schedule stamp $STAMP could not be written — the job IS installed and loaded. Two things follow from the missing stamp: every later install looks like a changed pass and rebootstraps the job, and a no-flag re-install (setup.sh/sync.sh) falls back to report-only"
    return 0
}

ld_status() {
    local dest print_out last_exit state rec live_dir
    choose_launchd_target || { err "no launchctl available (${LC:-launchctl})"; return 1; }
    # The RECORDED dir wins, and the live one is the fallback: reading only the live environment
    # answered `installed=no` for an installed, loaded, armed box whenever the seam moved (#2048 review).
    live_dir="$LD_DIR"; rec="$(recorded_dir)"
    [ -n "$rec" ] && LD_DIR="$rec"
    dest="$LD_DIR/$LABEL.plist"
    [ -f "$dest" ] || { [ -n "$rec" ] && [ -f "$live_dir/$LABEL.plist" ] && dest="$live_dir/$LABEL.plist"; }
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
    # ⛔ `launchctl print` SUCCEEDS FOR A DISABLED-BUT-LOADED JOB, so it cannot answer "is this enabled".
    # launchd keeps that in its per-user override database (`launchctl print-disabled <domain>`), where a
    # disabled label reads `"<label>" => disabled`. Without this read, `--status` certified a box whose
    # label an operator had disabled: installed=yes, enabled=enabled, exit 0 — and the remedy it printed
    # (`--install`) is a no-op for an unchanged, loaded job, so the override was never cleared
    # (#2048 review, P3). Only a POSITIVE match on THIS label is folded in; an unreadable database (an
    # older launchctl, a sandboxed domain) is reported and never guessed at.
    # ⛔ NO NEW KEY: the vocabulary is IDENTICAL on both platforms (a suite pins the key set), and
    # `enabled=` is exactly the question — a launchd label overridden to `disabled` is not enabled,
    # whatever `print` says. An unreadable database (an older launchctl, a sandboxed domain) leaves the
    # answer to `print` rather than guessing; the disabled state is also named in the failure below.
    DISABLED_OVERRIDE=""
    if disabled_out="$($LC print-disabled "$LD_DOMAIN" 2>/dev/null)"; then
        printf '%s\n' "$disabled_out" \
            | grep -q "\"$LABEL\"[[:space:]]*=>[[:space:]]*disabled" && DISABLED_OVERRIDE="disabled"
    fi
    # ONE `enabled=` line, decided after BOTH reads: a loaded-but-overridden job is not enabled, and a
    # duplicated key would make the answer depend on which line the reader took (the defect #2048 fixed
    # for `systemctl is-enabled` printing `disabled` twice).
    if [ -n "$print_out" ] && [ "$DISABLED_OVERRIDE" != "disabled" ]; then
        say "enabled=enabled"
    else
        say "enabled=disabled"
    fi
    # `active=` is the MOMENTARY state (is a pass running right now). It is not the scheduling answer:
    # a StartInterval job is idle between runs, which is healthy — so it is reported and not folded into
    # the exit code. Liveness here is LOADED (below), which is what `bootout` clears.
    state="$(first_token "$(printf '%s\n' "$print_out" | sed -n 's/^[[:space:]]*state = //p')")"
    case "$state" in running) say "active=active" ;; *) say "active=inactive" ;; esac
    last_exit="$(printf '%s\n' "$print_out" | sed -n 's/^[[:space:]]*last exit code = //p' | head -1)"
    case "$last_exit" in ''|*[!0-9]*) last_exit=unknown ;; esac
    say "last_exit=$last_exit"
    # launchd does not report the next fire time of a StartInterval job. The interval is what it does
    # give; the pass record supplies the last run — reporting a computed "next" would be a guess.
    say "next_run=unknown"
    say "interval_seconds=$INTERVAL_SECONDS"
    say "armed=$(armed_from_file "$dest")"
    say "armed_at=$(stamp_field armed_at)"
    say "armed_by=$(stamp_field armed_by)"
    # THE EXIT CODE IS THE CONTRACT. A plist on disk that launchd does not hold is NOT scheduled — a
    # `launchctl bootout` (or a failed bootstrap) leaves exactly that, and it used to answer 0.
    if [ -z "$print_out" ]; then
        err "$LABEL is installed at $dest but NOT loaded in $LD_DOMAIN — it will not fire unattended. Re-run --install (a bootout leaves exactly this state)"
        return 1
    fi
    if [ "$DISABLED_OVERRIDE" = "disabled" ]; then
        err "$LABEL is loaded but DISABLED in $LD_DOMAIN (launchctl disable) — it will not fire. Re-run --install, which clears the override"
        return 1
    fi
    return 0
}

ld_uninstall() {
    local dest live_dir rec plist_dirs=() d
    if [ "${PREVIEW:-0}" = "1" ]; then
        say "preview: would bootout ${LAUNCHD_DOMAIN:-gui/$(id -u)}/$LABEL and remove the plist (nothing was changed)"
        return 0
    fi
    choose_launchd_target || { err "no launchctl available (${LC:-launchctl})"; return 1; }
    # ⛔ THE RECORDED DIRECTORY, exactly as the systemd verbs do (#2048 review, P2). The plist dir is
    # env-overridable (`DISK_REAPER_AGENTS_DIR`, the documented seam), so an uninstall that only reads
    # the live environment removed from the DEFAULT dir, printed "uninstalled", exited 0 — and left the
    # armed plist where the install put it, for launchd to re-load at the next login.
    live_dir="$LD_DIR"; rec="$(recorded_dir)"
    [ -n "$rec" ] && LD_DIR="$rec"
    dest="$LD_DIR/$LABEL.plist"
    plist_dirs=("$LD_DIR")
    [ -n "$live_dir" ] && [ "$live_dir" != "$LD_DIR" ] && plist_dirs+=("$live_dir")
    $LC bootout "$LD_DOMAIN/$LABEL" >/dev/null 2>&1 || true
    for d in "${plist_dirs[@]}"; do rm -f "$d/$LABEL.plist"; done
    # READ IT BACK: a bootout that did not take, or a plist that survived the `rm`, leaves a job that
    # launchd re-loads at the next login. "uninstalled" is the claim, so the removal is what is read
    # back (#2048 review). BOTH directories are read, so a survivor in the other one cannot hide.
    for d in "${plist_dirs[@]}"; do
        [ -f "$d/$LABEL.plist" ] && { err "uninstall INCOMPLETE: $LABEL is still installed at $d/$LABEL.plist — nothing is claimed beyond what was read back"; return 1; }
    done
    if ld_loaded; then
        err "uninstall INCOMPLETE: $LABEL is still $( [ -f "$dest" ] && printf 'installed at %s' "$dest" || printf 'loaded in %s' "$LD_DOMAIN" ) — nothing is claimed beyond what was read back"
        return 1
    fi
    # ⛔ THE STAMP DIES ONLY WITH A VERIFIED REMOVAL. Deleting it first destroyed the record of the
    # arming on a FAILED uninstall, and the next install `setup.sh`/`sync.sh` runs is no-flag — so it
    # adopted nothing and quietly re-installed REPORT-ONLY on a box the owner had armed (#2048 review,
    # P2). `sd_uninstall` was moved for exactly this; the launchd path was left behind.
    rm -f "$STAMP"
    say "uninstalled $LABEL from ${plist_dirs[*]}"
    return 0
}

# ── the shared status tail: the pass record, the same file on both platforms ───────────────────
# Everything above says WHO schedules the pass. This says what the pass DID — read from
# `disk-reaper.sh --print-status`, i.e. the same record, in the same vocabulary, on a cell and on a
# Mac. The drift line answers #1738's question: are the bytes on disk the ones the JOB was installed
# against?
status_tail() {
    local sha stamp_sha drift pass_rc job_file repos_art
    say "pass=$REAPER"
    say "pass_exists=$([ -f "$REAPER" ] && echo yes || echo no)"
    # What the SCHEDULED job scans, read off the installed artifact — the same discipline as armed=.
    # Falls back to this invocation's resolution, named as such, so an uninstalled box still answers.
    case "$SCHEDULER" in
        systemd) job_file="${UNIT_DIR:-}/$UNIT_NAME.service" ;;
        launchd) job_file="${LD_DIR:-}/$LABEL.plist" ;;
        *)       job_file="" ;;
    esac
    repos_art="$(repos_from_file "$job_file")"
    # `repos=` is decided by the ARTIFACT EXISTING, not by the extracted value being non-empty: an
    # installed job that legitimately scans no repo (every candidate was a non-repo) carries an EMPTY
    # value, and `[ -n "$repos_art" ]` described that box as "not installed" (#2048 review).
    if [ -f "$job_file" ]; then
        if [ -n "$repos_art" ]; then say "repos=$repos_art"
        else say "repos=<none> (the installed job scans no repo — the venv/worktree classes will fail closed every pass)"; fi
        say "runner=$(runner_from_file "$job_file")"
    else
        say "repos=${REPOS:-<none>} (not installed — this is what a fresh install WOULD scan)"
        say "runner=unknown (not installed)"
    fi
    sha="$(pass_sha "$REAPER")"; stamp_sha="$(stamp_field pass_sha)"
    say "pass_sha=${sha:-unknown}"
    if [ -z "$stamp_sha" ]; then
        # An absent stamp has TWO causes and they are not interchangeable (#2048 review): an older
        # installer never wrote one, or THIS one could not (an unwritable state dir — a warn-and-install
        # path since the same review round). Naming the wrong one and prescribing `--install` for it is a
        # diagnostic that loops: the remedy is the one that just failed.
        if [ -f "$job_file" ] && { [ ! -d "$STATE_DIR" ] || [ ! -w "$STATE_DIR" ]; }; then
            drift="no-stamp (cannot write $STATE_DIR — so EVERY install reloads the job, and a no-flag install reverts to report-only; fix the state dir)"
        else
            drift="no-stamp (installed by an older installer — re-run --install)"
        fi
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
        --apply)     MODE_FLAG=--apply; MODE_EXPLICIT=1 ;;
        --dry-run)   MODE_FLAG=--dry-run; MODE_EXPLICIT=1 ;;
        --preview)   PREVIEW=1 ;;
        --status)    MODE=--status ;;
        --uninstall) MODE=--uninstall ;;
        --help|-h)   usage_body; exit 0 ;;
        *) usage ;;
    esac
    shift
done

# ⛔ A FLAG NAMED "DRY RUN" MAY NOT DELETE (#2048 review, P2). `--dry-run` is the MODE flag — "install
# the report-only job" — and every other tool in this repo spells it "change nothing", so combined with
# `--uninstall` it read as a preview while performing the real removal and destroying the arming stamp
# (the next sync then re-installs report-only and the box silently stops deleting). The no-write spelling
# here is `--preview`; refuse the ambiguous combination loudly rather than guessing which one was meant.
# (MODE_EXPLICIT, not MODE_FLAG: MODE_FLAG defaults to --dry-run, so testing the value would refuse a
# plain `--uninstall` too. Only a flag the operator actually TYPED can be ambiguous.)
if [ "$MODE" = "--uninstall" ] && [ "${MODE_EXPLICIT:-0}" = 1 ]; then
    err "--uninstall does not take a mode flag: '${MODE_FLAG}' describes how the JOB would run, not whether to remove it."
    err "       To see what would be removed without changing anything, use --uninstall --preview."
    exit 2
fi

# ── the arming outlives the invocation that made it ─────────────────────────────────────────
# `pi-bootstrap/setup.sh` — which `sync.sh` runs — re-installs with `--install` and NO mode flag on
# every run. With the arming living only in the invocation, the next sync silently reverted an owner's
# `--apply` to report-only and rebootstrapped the job: the Mac could never STAY armed, which is the
# disk-fill incident #2048 exists to prevent (#2048 review, P1). The stamp this installer writes
# records the arming, and a no-flag install adopts it. An EXPLICIT flag still wins and rewrites it, so
# `--dry-run` remains the reversal. Nothing here reads the environment: the stamp is state WE wrote,
# and --uninstall deletes it, so the next install starts report-only again.
if [ "${MODE_EXPLICIT:-0}" != 1 ]; then
    case "$(stamp_field armed)" in
        apply)   MODE_FLAG=--apply ;;
        dry-run) MODE_FLAG=--dry-run ;;
    esac
fi

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
# ⛔ EXIT 3 IS "DECLINED — NOT THIS BOX", and it exists so a caller never has to parse prose:
# `pi-bootstrap/setup.sh` used to duplicate this very probe with its own `dscl` call, which is how two
# implementations of one decision drift apart. 0 = installed, 3 = not the box this run is about,
# 4 = this box, but the probe could not answer (a FAILURE the caller must report), anything else = a
# real failure.
if [ "$PLATFORM" = darwin ] && [ "${ELDATO_ALLOW_TEST_HOME:-}" != "1" ]; then
    real_home="$(resolve_real_home)"
    if [ -z "$real_home" ]; then
        err "refusing to manage launchd jobs: cannot determine the real home for '$(id -un)' (getent, dscl and ~user all failed), so a throwaway HOME cannot be ruled out (#446)."
        err "       A temp-HOME run registers jobs against plist paths that vanish."
        err "       ⛔ This is NOT a decline: an unanswerable probe on the real box leaves it UNSCHEDULED."
        err "       Tests: put a launchctl shim on PATH and set ELDATO_ALLOW_TEST_HOME=1"
        exit 4
    fi
    if [ "$(norm_path "$HOME")" != "$(norm_path "$real_home")" ]; then
        err "refusing to manage launchd jobs: HOME=$HOME is not the real home ($real_home)."
        err "       A temp-HOME run registers jobs against plist paths that vanish (#446)."
        err "       Tests: put a launchctl shim on PATH and set ELDATO_ALLOW_TEST_HOME=1"
        exit 3
    fi
fi

# A pass that cannot complete yet is named at INSTALL time rather than discovered an hour later: on
# Darwin the pass's watchdog needs a `timeout` binary macOS does not ship (agent-infra#2046). The job is
# still installed — the schedule is what this verb owes — and both the installer and --status tolerate
# the pass exiting non-zero with a `fail-closed` verdict instead of hiding it.
if [ "$PLATFORM" = darwin ] && ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    warn "no 'timeout' binary on this Mac — disk-reaper.sh cannot complete a class until agent-infra#2046 lands. The job IS installed; every pass will report fail-closed (rc=3) with a named detail until it does."
fi

# ⛔ ONLY WHEN THE RECORD CANNOT ANSWER EITHER (#2048 review, P3). The gate exists so a box with no
# usable manager is not told "installed" — but it used to fire BEFORE dispatch, so `--status` and
# `--uninstall` refused on the live probe alone and never consulted the stamp's recorded target/dir.
# A box whose sudo probe moved therefore answered "this box has no scheduler" about a timer that was
# enabled and active, and the armed unit became un-uninstallable through the tool.
if [ "${SD_UNAVAILABLE:-0}" = 1 ] && [ "$PLATFORM" = linux ] && [ -z "$(recorded_dir)" ]; then
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
