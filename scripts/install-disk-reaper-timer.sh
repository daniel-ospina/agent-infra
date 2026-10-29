#!/usr/bin/env bash
# install-disk-reaper-timer.sh — put the disk reaper on the box's clock, on BOTH platforms
# (agent-infra#2032, #2048, #2058).
#
# WHY THIS IS AN INSTALLER AND NOT A LINE IN THE BRING-UP. The artifact has to be rendered from
# machine state (HOME, PATH, the repos this box actually has, the state dir the supervisor reads) and
# installed idempotently; the bring-up is the TRIGGER, this is the policy of WHERE and HOW. Same
# split as install-launchd.sh on macOS — one place renders and converges, everything else calls it.
#
# ⛔ ONE INSTALL VERB, THE PLATFORM'S OWN SCHEDULER (#2048/#2058). The consolidated pass
# (disk-reaper.sh, ONE entry point over the three sinks) was scheduled on Linux only, so the Mac had
# no consolidated pass at all and the venv class had NO periodic owner there — the exact gap this
# consolidates. This installer now converges the same pass on either platform:
#   Linux  eldato-disk-reaper.service + .timer   — hourly (OnCalendar=hourly, Persistent=true)
#   macOS  com.eldato.disk-reaper LaunchAgent    — hourly (StartInterval=3600)
# It does NOT re-implement either scheduler: the plist is rendered here and bootstrapped with
# launchctl, exactly as the systemd units are rendered here and enabled with systemctl.
#
# ⛔ ARMING IS THE OWNER'S DECISION, AND IT WAS MADE. The general rule (#1678, owner ruling
# 2026-10-11) is that deletion tools ship DRY-RUN and arming is a separate, dated, reversible owner
# step. This feature was explicitly instructed to run unattended on the cell, so BOTH artifacts carry
# `--apply` through {{MODE_FLAG}} and the arming is visible in the artifact itself. Nothing about the
# arming is hidden in an environment default. `--report-only` renders the same artifact with
# `--dry-run` instead, which is the reversal of that decision and needs no hand-edit of an installed
# file.
# ⛔ `--dry-run` IS *NOT* THAT. `--dry-run` sets DRY_RUN=1, and do_install then RENDERS AND PRINTS the
# artifact and returns without touching anything — so an operator who read the old sentence as
# "disarm this cell" got exit 0 and an unchanged, still-armed unit (T12 pins the same no-op on the
# `--uninstall` path). A false claim about arming on a deletion tool is the worst kind of false PASS.
#   TO PREVIEW WHAT WOULD BE INSTALLED: `--dry-run`. TO DISARM an armed cell: `--report-only`
#   (re-installs the same artifact rendering `--dry-run`). Disarming by hand still works and is the
#   documented fallback: `systemctl disable --now eldato-disk-reaper.timer`.
#   TO INSTALL/ARM: `--install` (idempotent; a second install with unchanged bytes is a no-op apart
#   from `daemon-reload`).
#
# INSTALL TARGETS. systemd, tried in this order, and the reason is named in the output:
#   1. a SYSTEM unit via passwordless sudo (/etc/systemd/system) — the cell's normal shape; the
#      service runs as the invoking user, so the uv cache and state dir are the lane's, not root's.
#   2. a USER unit (~/.config/systemd/user) when systemd's user manager actually answers — a cell
#      without sudo still gets a clock.
#   3. nothing — a loud FAILURE with the remedy, never a silent no-op. A reaper that was "installed"
#      but never fires is the false PASS this repo keeps removing.
# macOS has exactly one: ~/Library/LaunchAgents (a LaunchAgent, in the user's GUI domain).
#
# Usage:
#   install-disk-reaper-timer.sh [--install] [--dry-run] [--report-only]
#                                [--status] [--uninstall] [--help]
#
# Env seams (tests + unusual cells):
#   DISK_REAPER            the entry point to install (default: the farmed copy, else beside this)
#   DISK_REAPER_RUN        the SCHEDULED wrapper beside the reaper (default: disk-reaper-run.sh). It
#                          supplies HOME/keys, resolves the REAL gh and unsets AGENT_GH_REAL, so a
#                          timer-started pass is not parked in the interactive pacing queue (#2354)
#   (The worktree class's own floors — REAP_WT_SCRATCH_AGE_DAYS/REAP_WT_SCRATCH_GLOB — are NOT
#    rendered here: the reaper's defaults (1 day, wt-*|cell-wt-*) are what a unit runs with. To pin
#    one, add it to the templates and render it, the way DISK_REAPER_WT_AGED_DAYS is.)
#   DISK_REAPER_STATE_DIR  status/log dir the unit exports (default $HOME/.pi/agent/state)
#   DISK_REAPER_REPOS      colon-separated repos the venv/worktree classes scan
#   DISK_REAPER_WT_AGED_DAYS  worktree age floor for the scheduled pass (default 7)
#   TEMPLATES_DIR          template dir (default: this repo's templates/systemd)
#   LAUNCHD_TEMPLATES_DIR  plist template dir (default: this repo's templates/launchd/reaper)
#   SYSTEMD_UNIT_DIR       install dir OVERRIDE (tests: a temp dir, with SYSTEMCTL a fake)
#   LAUNCHD_AGENTS_DIR     LaunchAgents dir OVERRIDE (tests: a temp dir, with LAUNCHCTL a fake)
#   ELDATO_PLATFORM        override `uname -s` (tests render the Darwin artifact on any host)
#   ELDATO_LAUNCHER_PY     the interpreter a launchd job is started with (TCC; see below)
#   SYSTEMCTL              `systemctl` to call (tests: a shim; default `sudo -n systemctl`)
#   LAUNCHCTL              `launchctl` to call (tests: a shim; default `launchctl`)
#   SUDO                   `sudo` probe (default `sudo -n`)
#   DISK_REAPER_EXTRA_SCOPES  colon-separated EXTRA dirs to scan in `--uninstall`'s "another scope" note
#                             (TEST SEAM: it only adds read-only scan paths; production sets nothing)
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
# The plist lives OUTSIDE templates/launchd/ on purpose — install-launchd.sh installs every
# `templates/launchd/*.plist` with no arguments, and its substitution set does not carry this
# template's placeholders (see the plist's own header). Resolved the same way the systemd templates
# are: a FARMED copy of this installer has no ../templates at all, so the checkout that installed the
# layer must be consulted first.
if [ -z "${LAUNCHD_TEMPLATES_DIR:-}" ]; then
    for _cand in "${AGENT_INFRA_PATH:-}/templates/launchd/reaper" \
                 "${TEMPLATES_DIR%/systemd}/launchd/reaper" \
                 "$INFRA_ROOT/templates/launchd/reaper"; do
        [ -n "$_cand" ] && [ -d "$_cand" ] && { LAUNCHD_TEMPLATES_DIR="$_cand"; break; }
    done
fi
LAUNCHD_TEMPLATES_DIR="${LAUNCHD_TEMPLATES_DIR:-$INFRA_ROOT/templates/launchd/reaper}"
PLATFORM="${ELDATO_PLATFORM:-$(uname -s 2>/dev/null || printf 'unknown')}"
STATE_DIR="${DISK_REAPER_STATE_DIR:-${HOME:?HOME is required}/.pi/agent/state}"
AGED_DAYS="${DISK_REAPER_WT_AGED_DAYS:-7}"
UNIT_NAME="eldato-disk-reaper"
# The launchd label is the unit name in reverse-DNS form, so `--status` can name ONE job on a Mac that
# carries ~35 of them, and the plist's Label is not a second, drifting spelling of the same thing.
LABEL="com.eldato.${UNIT_NAME#eldato-}"
MODE=--install
# {{MODE_FLAG}} — the arming decision, in ONE place, rendered into whichever artifact this platform
# uses. --apply by default (the recorded owner instruction, see the header); --report-only flips it.
MODE_FLAG="--apply"
# {{MODE_SUCCESS_EXIT}} — the rendered SuccessExitStatus (systemd only; launchd has no such field). It
# is MODE-dependent because the codes mean different things in the two modes: an armed pass exits 5 for
# "a class is still over its bound", which is a condition a human must see, while a dry run exits 5 for
# "here is the work I would do", which IS the dry run's whole job. Rendering one hard-coded set for both
# is what let a "succeeding" hourly reaper sit on cells at 94-96% used (see the unit template).
MODE_SUCCESS_EXIT="0 6"

log_line() { printf '%s\n' "$*"; }
err() { printf '%s: %s\n' "${0##*/}" "$*" >&2; }

# help_text — print the header comments. The range is DERIVED from the `set -uo pipefail` line, never a
# hand-maintained constant: a constant silently truncated the header whenever a line was added to it
# (measured: `sed -n '2,45p'` dropped SYSTEMCTL, SUDO and Exit codes after this file grew).
help_text() {
    local n
    n="$(grep -n '^set -uo pipefail' "$0" 2>/dev/null | head -1 | cut -d: -f1)"
    # ⛔ NO CONSTANT FALLBACK. When `$0` is not this file (invoked from a pipe: `curl … | bash`,
    # `bash -c "$(cat …)"`), the derivation fails and a magic range silently reinstates exactly the
    # truncation this replaced (it would drop SYSTEMCTL/SUDO/Exit codes again). Refuse and say how.
    if [ -z "$n" ]; then
        err "cannot derive the help range (invoke this FILE, not a pipe: 'bash $(basename "${BASH_SOURCE[0]:-$0}") --help')"
        return 2
    fi
    sed -n "2,$(( n - 1 ))p" "$0" | sed 's/^# \{0,1\}//'
}

usage() { help_text; exit 2; }

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
# #2354: prefer the WRAPPER beside the resolved reaper. A timer-started pass inherits no HOME, no
# keys and no usable `gh`, and the raw script then fails its open-PR gate closed and reaps NOTHING
# (measured on a cell at 99% used: REMOVE=0 PRESERVE=0 REMOVED=0, hourly). The wrapper supplies exactly
# that environment — and it is a REPO artifact (farmed by pi-bootstrap), so it cannot drift into a
# hand-maintained file on one box, which is the failure this whole installer exists to prevent.
if [ -n "${DISK_REAPER_RUN:-}" ] && [ ! -f "$DISK_REAPER_RUN" ]; then
    err "\$DISK_REAPER_RUN is set to '$DISK_REAPER_RUN' but that is not a regular file — refusing to install a unit that points at a DIFFERENT scheduled wrapper (the beside-copy would be installed silently, and the rendered plist/unit is the only place that would have said so)"
    exit 2
fi
if [ -n "$REAPER" ]; then
    for cand in "${DISK_REAPER_RUN:-}" "$(dirname "$REAPER")/disk-reaper-run.sh"; do
        [ -n "$cand" ] || continue
        [ -f "$cand" ] || continue
        REAPER="$cand"; break
    done
fi

# ── repos: what this box actually has ───────────────────────────────────────────────────────────
# Rendered into the unit so the scheduled pass never depends on a shell's environment. A candidate
# is kept only when git answers for it — a unit scanning a path that is not a repo fails closed every
# hour, which is how an alarm becomes wallpaper.
resolve_repos() {
    # `_g` is LOCAL: it holds the captured git error, and without `local` this function writes a GLOBAL
    # from inside a $( ) call site — a latent clobber for any future direct caller (review cycle 3).
    local r seen=" " out="" _g=""
    local list="${DISK_REAPER_REPOS:-}"
    if [ -z "$list" ]; then
        list="$(printf '%s\n' "${REPO:-}" "${TORTOISE_REPO:-}" "${WORKDIR:-}" "${AGENT_INFRA_PATH:-}")"
    fi
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        case "$seen" in *" $r "*) continue ;; esac
        seen="$seen$r "
        # ⛔ ABSOLUTE ONLY, AND CHECKED FIRST. systemd resolves a relative Environment value against
        # the SERVICE's working directory, not this shell's, so a relative candidate (or a bare
        # `owner/repo` slug, which the ambient REPO sometimes carries) would render a unit whose two
        # repo classes fail closed every tick. This arm is HOISTED above the git probe deliberately
        # (review cycle 2): with the probe first, a relative candidate git cannot answer for was
        # reported as "not a git checkout" — pointing the operator at a missing checkout instead of at
        # the slug — and `git@github.com:owner/repo.git` was split on ':' by the line below into two
        # entries, each warned about with the wrong reason. Each candidate is now dropped with the
        # reason that ACTUALLY applies to it.
        case "$r" in
            /*) ;;
            *) err "WARNING: ignoring repo '$r' — not an absolute path, so a unit cannot use it"; continue ;;
        esac
        # ⛔ A CANDIDATE GIT DOES NOT ANSWER FOR IS DROPPED **OUT LOUD** — never silently (2026-10-30).
        # MEASURED on pi-cell-1: the installed unit carried
        #     Environment=DISK_REAPER_REPOS=/tmp/cell-t3:/tmp/cell-ai
        # (the cell layout, #2878 — and `cloud-cell-bringup.sh` passes the operator's list verbatim,
        # colon-joined, so MULTI-ENTRY lists are the normal shape). Once that box's checkout moved to
        # /home/cmux/tortoise, this loop dropped the vanished entry with NO output, the install returned
        # 0, and the rendered unit named only what survived. The result is indistinguishable from
        # success while a configured scan target is silently not scanned — the same inert shape as a
        # unit that scans nothing, which the empty-list refusal below already catches. A single
        # surviving entry is exactly what hid the incident for days.
        # ⛔ QUOTE GIT'S OWN LINE, never assert a cause (review cycle 2). `rev-parse --git-dir` fails for
        # MANY reasons — a missing checkout, `chmod 000`, and the fleet's own dominant shape,
        # `fatal: detected dubious ownership in repository at …` (a checkout owned by a different uid).
        # Stamping all of them "not a git checkout" sends the operator after the one cause that cannot
        # explain the fault, and the refusal's advice ("set DISK_REAPER_REPOS to a checkout path") is
        # useless for a permission/ownership one. The wording choice changes no outcome: the entry is
        # dropped either way, and the CALLER'S result is the same whichever message is used — a single
        # dead entry in a longer list still installs (T62 (d) asserts rc=0 deliberately), and the
        # all-dead case still refuses. This costs no safety; it recovers the one actionable signal the
        # fix exists to give. (Review cycle 3 corrected an earlier sentence here that claimed a refusal
        # the PARTIAL-list path never performs.)
        if ! _g="$(git -C "$r" rev-parse --git-dir 2>&1 >/dev/null)"; then
            # `${_g:-…}` guards the empty-stderr shape (a silent git shim exits non-zero and says
            # nothing): an empty "(...)" would name no datum at all, so say so explicitly.
            err "WARNING: ignoring repo '$r' — git cannot use it here ($(printf '%s' "${_g:-<git gave no message>}" | head -1)), so the venv/worktree classes cannot scan it (the rendered unit will NOT cover it)"
            continue
        fi
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
    # ── ALWAYS enforced, override or not ─────────────────────────────────────────────────────────
    # `${TARGET:-…}`: this guard runs BEFORE choose_target on purpose (a box with no scheduler must
    # still be told its HOME is scratch), so $TARGET is unset here and `set -u` would abort.
    local t="${TARGET:-scheduled}" bad="" v p r
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
    for d in pi-cache-reap.sh reap-lane-venvs.sh pi-reap-worktrees.sh \
             reap-abandoned-worktrees.sh reap-duplicate-installs.sh reap-runner-work.sh \
             lib/live-paths.sh; do
        # #2542 adds the two new owners AND the census library they share. The library is in this list
        # rather than in the REFUSING arm below because a missing library breaks TWO classes, not the
        # pass: a red unit that names them is a worse failure than a refusal, but a silent one is worse
        # again — so it is named at install time, exactly like a missing delegate.
        [ -f "${REAPER%/*}/$d" ] || err "WARNING: ${REAPER%/*}/$d is missing — the unit pins it, so $([ "${d%%/*}" = lib ] && printf 'the abandoned-worktree arm and the duplicate-install class' || printf 'that class') will fail closed (exit 3, red) every pass"
    done
    # ⛔ AND THE BOUNDED-EXECUTION LIBRARY, WHICH IS WORSE THAN A CLASS: both artifacts pin it, and
    # without it the WHOLE pass refuses at startup (exit 3, every hour) — no class runs at all. That is
    # the inert-enforcer shape, so this one REFUSES rather than warning.
    if [ ! -f "${REAPER%/*}/lib/bounded.sh" ]; then
        err "REFUSING: ${REAPER%/*}/lib/bounded.sh is missing — both artifacts pin the bounded-execution library and without it every pass refuses at startup (exit 3) without running a single class (agent-infra#2046)"
        return 1
    fi
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
        [ -e "$STATE_DIR" ] || log_line "dry-run: would create the state dir $STATE_DIR"
    elif ! mkdir -p "$STATE_DIR" 2>/dev/null || [ ! -w "$STATE_DIR" ]; then
        err "REFUSING: state dir '$STATE_DIR' is not writable by $(id -un) — the unit runs as this user and every pass would fail closed (exit 3)"
        return 1
    fi
    # ⛔ AGED_DAYS IS VALIDATED ON BOTH PLATFORMS. It is rendered into the artifact, it was the ONE
    # value with no check at all, and a bad one is BAKED INTO A PERSISTENT UNIT: measured with
    # DISK_REAPER_WT_AGED_DAYS="7 days" the installer exited 0, systemd-analyze verify answered "Invalid
    # environment assignment, ignoring: days" AND STILL EXITED 0 (systemd keeps `7` and drops the
    # rest), while a non-numeric value like `abc` makes the pinned delegate exit 2 on every pass — which
    # disk-reaper maps to a RED unit, every hour, until someone hand-edits the unit.
    case "$AGED_DAYS" in ''|*[!0-9]*) err "REFUSING: DISK_REAPER_WT_AGED_DAYS='$AGED_DAYS' is not a whole number of days — it is rendered into the unit's Environment= and baked into a persistent unit"; return 1 ;; esac
    # ⛔ AND THE RENDERER ITSELF. Every substituted value goes through `sed -e "s|{{X}}|$v|g"`, so a
    # BACKSLASH in a value is a sed ESCAPE: measured `s|{{HOME}}|/tmp/a\b|` → `/tmp/ab`, installer rc 0,
    # no `{{` left for the post-render guard to catch, and the unit points at a path that does not
    # exist — the measured "127 every tick while list-timers shows it scheduled" shape. `&` and `|` are
    # already refused by the render (they leave or break the pattern); the backslash is the silent one,
    # so it is refused here with the rest of the unrepresentable values. `xml_sed_repl` escapes `&`, `<`,
    # `>` and `\` for the plist; the backslash refusal stays because a path that differs after escaping
    # is still a unit pointing somewhere else.
    for v in "HOME=$HOME" "PATH=$PATH" "STATE_DIR=$STATE_DIR" "REPOS=$REPOS" "REAPER=$REAPER" "AGED_DAYS=$AGED_DAYS"; do
        case "${v#*=}" in
            *\\*) err "REFUSING: ${v%%=*} contains a backslash — the artifact is rendered with sed, where a backslash is an escape, so the rendered path would silently differ from the real one"; return 1 ;;
        esac
    done
    # ⛔ THE WHITESPACE RULE IS SYSTEMD-ONLY, so it is NOT here: it needs $TARGET, which is decided
    # later, and a plist value is a <string> of its own — `my home` is a legitimate path on macOS.
    # See refuse_systemd_unsafe_values, called by the systemd arm after choose_target.
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

# refuse_systemd_unsafe_values — the whitespace rule, which is a SYSTEMD rule and not a launchd one:
# systemd SPLITS unquoted Environment=/ExecStart= values, so a path containing a space renders a unit
# that cannot run (measured: HOME="…/bg/my home"). A plist value is a <string> of its own, so
# `my home` is a legitimate path there and refusing it would be a false block on the Mac. It needs
# $TARGET, so it runs AFTER choose_target; every other guard runs BEFORE it, because a box that cannot
# say which scheduler it has must still be told its HOME is transient scratch.
refuse_systemd_unsafe_values() {
    local v
    [ "${TARGET:-}" = "launchd" ] && return 0
    for v in "HOME=$HOME" "PATH=$PATH" "STATE_DIR=$STATE_DIR" "REPOS=$REPOS" "REAPER=$REAPER"; do
        case "${v#*=}" in
            *[[:space:]]*) err "REFUSING: ${v%%=*} contains whitespace — systemd splits the rendered unit on it, so it would never run"; return 1 ;;
        esac
    done
    return 0
}

# xml_sed_repl — make a value safe as the REPLACEMENT half of `s|…|…|g` AND safe in the XML text node
# it lands in. Both escapes are needed and the XML one is not optional: `&` in a sed replacement expands
# to the WHOLE MATCH and `\` starts an escape, and the same `&` is the XML entity introducer — an
# unescaped one makes the plist MALFORMED, which launchd then refuses. scripts/install-launchd.sh
# documents the measured defect (`sed_repl`) and this mirrors it rather than inventing a second rule.
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
        -e "s|{{REPOS}}|$(xml_sed_repl "$REPOS")|g" \
        -e "s|{{AGED_DAYS}}|$AGED_DAYS|g" \
        -e "s|{{REAPER}}|$(xml_sed_repl "$REAPER")|g" \
        -e "s|{{REAPER_DIR}}|$(xml_sed_repl "${REAPER%/*}")|g" \
        -e "s|{{MODE_FLAG}}|$MODE_FLAG|g" \
        -e "s|{{MODE_SUCCESS_EXIT}}|$MODE_SUCCESS_EXIT|g" \
        -e "s|{{BOUNDED_LIB}}|$(xml_sed_repl "${REAPER%/*}/lib/bounded.sh")|g" \
        -e "s|{{LABEL}}|$LABEL|g" \
        -e "s|{{PY_BIN}}|$(xml_sed_repl "${PY_BIN:-}")|g" \
        -e "s|{{LAUNCHER}}|$(xml_sed_repl "${LAUNCHER:-}")|g" \
        "$tpl" >"$dest" || return 1
    grep -q '{{' "$dest" && { err "unresolved placeholder in $tpl"; grep -n '{{' "$dest" >&2; return 1; }
    return 0
}

# plist_is_valid <path> — REFUSE a rendered plist launchd cannot parse. The systemd path gets this for
# free (a malformed unit fails `enable`); launchd's `bootstrap` also fails, but by then the artifact is
# installed and the failure reads like a scheduler problem. `plutil -lint` is the host's own parser where
# it exists; python's expat is the fallback so a Linux test can prove the shape too.
plist_is_valid() {
    local f="$1"
    if command -v plutil >/dev/null 2>&1; then
        plutil -lint "$f" >/dev/null 2>&1 && return 0
        return 1
    fi
    command -v python3 >/dev/null 2>&1 || return 0   # no parser available: do not invent a refusal
    python3 -c 'import sys,xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$f" >/dev/null 2>&1
}

# ── launchd: the interpreter that can read the repo (macOS TCC) ────────────────────────────────
# macOS TCC is per-binary: a launchd-spawned `bash` cannot read a script under ~/Documents, and a
# launchd-spawned `git` cannot read a repo there. This pass's venv and worktree classes ARE `git -C
# <repo>`, so a `bash <reaper> --apply` agent would fail those two classes closed EVERY hour while
# `launchctl list` showed a healthy job — the inert-enforcer shape, produced by the installer. The
# binary that holds the access is the checkout's own interpreter; it reads the script and hands it to
# bash on stdin (pi-reap-worktrees-launchd.py, which com.tortoise.worktree-reaper already runs
# end-to-end). No interpreter or no launcher is a REFUSAL, never a degraded `bash` job.
resolve_launcher() {
    local cand
    PY_BIN="${ELDATO_LAUNCHER_PY:-}"
    if [ -z "$PY_BIN" ]; then
        for cand in "${TORTOISE_REPO:-}/.venv/bin/python" \
                    "${AGENT_INFRA_PATH:-}/.venv/bin/python" \
                    "${HOME:-}/.pi/agent/.venv/bin/python"; do
            [ -n "$cand" ] && [ -x "$cand" ] && { PY_BIN="$cand"; break; }
        done
    fi
    if [ -z "$PY_BIN" ]; then
        PY_BIN="$(command -v python3 2>/dev/null || true)"
        # ⛔ A SYSTEM INTERPRETER IS NOT THE INTERPRETER THE TCC EVIDENCE POINTS AT. TCC is per-binary:
        # the recorded working configuration is a CHECKOUT's `.venv/bin/python` (which has been granted
        # ~/Documents access). A `/usr/bin/python3` may or may not be able to read the repos, so this is
        # LOUD — the operator is told which binary the job will run and how to pin the checkout's — but
        # it is not a refusal: a Mac whose repos live outside ~/Documents needs no laundering at all, and
        # refusing there would be a false block on a working box.
        [ -n "$PY_BIN" ] && err "WARNING: no checkout .venv/bin/python resolved — the job will run with $PY_BIN. If this box's repos are under ~/Documents, pin the checkout's interpreter with ELDATO_LAUNCHER_PY=<repo>/.venv/bin/python, or the venv and worktree classes will fail closed (TCC is per-binary)."
    fi
    [ -n "$PY_BIN" ] || { err "REFUSING: no interpreter resolved for the launchd job — set ELDATO_LAUNCHER_PY to the checkout's .venv/bin/python, which is the binary that holds the TCC access this pass needs"; return 1; }
    [ -x "$PY_BIN" ] || { err "REFUSING: the launchd interpreter '$PY_BIN' is not executable"; return 1; }

    LAUNCHER="${ELDATO_LAUNCHER:-}"
    if [ -z "$LAUNCHER" ]; then
        for cand in "${HOME:-}/.pi/agent/scripts/pi-reap-worktrees-launchd.py" \
                    "${REAPER%/*}/pi-reap-worktrees-launchd.py" \
                    "$INFRA_ROOT/scripts/pi-reap-worktrees-launchd.py"; do
            [ -n "$cand" ] && [ -f "$cand" ] && { LAUNCHER="$cand"; break; }
        done
    fi
    [ -n "$LAUNCHER" ] && [ -f "$LAUNCHER" ] || { err "REFUSING: the launchd TCC launcher (pi-reap-worktrees-launchd.py) was not found beside the reaper, in \$HOME/.pi/agent/scripts, or in $INFRA_ROOT/scripts — without it the venv and worktree classes cannot read a repo under ~/Documents"; return 1; }
    return 0
}

# ── choose a target ─────────────────────────────────────────────────────────────────────────────
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
        # ⛔ the SCOPE FLAG MUST SURVIVE A PIN. The header documents SYSTEMCTL as "the systemctl to
        # call", so a pinned shim used alone here would run `daemon-reload`/`enable --now` against the
        # SYSTEM manager while the unit was written to ~/.config/systemd/user — the inverse of the
        # defect fixed above for the system target ("a pinned path silently ignored").
        TARGET="user"; UNIT_DIR="$HOME/.config/systemd/user"; SC="${SYSTEMCTL:-systemctl} --user"
        return 0
    fi
    return 1
}

# ── the worktree class's gh prerequisite, NAMED AT INSTALL TIME ────────────────
# ⛔ MEASURED (2026-10-23, a cell at 95% used): the installed unit renders `Environment=HOME={{HOME}}`,
# the pass ran with a HOME that has no `~/.config/gh`, so its PR query exited 4 ("requires
# authentication" per that tool's own exit-code documentation) and the worktree class aborted for
# EVERY repo — `freed_df=0MB` every hour, on a box where the tool itself was installed and working.
# The unit pins the delegates, the bounded library and GH_TIMEOUT; the one dependency it CANNOT pin is
# the credential store, which is per-HOME. This installer is the only component that knows the HOME it
# is rendering, so it is the only place that can say the class will be inert BEFORE an operator waits
# an hour for a red unit and then reads a message about the wrong cause.
# ⛔ NOT A REFUSAL. A box with no working credentials still wants its uv and venv classes to run, and
# refusing would leave it with NO reaper at all — worse than a reaper whose third class skips every
# repo BY NAME. The answer is kept in GH_PREFLIGHT so the install summary carries it too.
GH_PREFLIGHT=""
gh_preflight() { # gh_preflight <home> -> "" (fine) | missing | unauthenticated
    local home="$1" ghbin="${GH_BIN:-gh}"
    # ⛔ GH_BIN IS THE SAME SEAM THE DELEGATE USES, and it is what makes the `missing` arm testable
    # without doctoring PATH (a suite that asserts an AMBIENT host property — "gh happens to be in
    # /usr/bin" — goes red for an environment reason unrelated to the change). A pin also lets an
    # operator install a unit for a gh that is not on the unit's PATH.
    command -v "$ghbin" >/dev/null 2>&1 || { printf 'missing'; return 0; }
    # Run it with the SAME HOME the unit will carry, and with any inherited token removed, so the
    # answer is about the UNIT's environment rather than this shell's.
    if HOME="$home" env -u GH_TOKEN -u GITHUB_TOKEN "$ghbin" auth status >/dev/null 2>&1; then
        printf ''
    else
        printf 'unauthenticated'
    fi
}

warn_gh_prerequisite() { # warn_gh_prerequisite <home> <user>
    local home="$1" user="$2" why
    why="$(gh_preflight "$home")"
    GH_PREFLIGHT="$why"
    [ -n "$why" ] || return 0
    case "$why" in
        missing)
            err "WARNING: the worktree class WILL SKIP EVERY REPO — gh is not installed, so its PR-state gate cannot be evaluated"
            err "  install gh (or point GH_BIN at it), or accept that only the uv and venv classes run on this box" ;;
        *)
            err "WARNING: the worktree class WILL SKIP EVERY REPO — gh is installed but NOT AUTHENTICATED for the HOME this unit will run with ($home)"
            err "  the credential store is per-HOME (\$HOME/.config/gh, or GH_TOKEN), and the rendered HOME decides it"
            err "  remedy: sudo -u $user -H gh auth login   (or install with the HOME the lanes actually use), then re-run this installer" ;;
    esac
    err "  the uv and venv classes are unaffected; each pass reports skipped=<repo> reason=<why> (#2443)"
    return 0
}


# ── actions ────────────────────────────────────────────────────────────────────────────────────
# do_install dispatches to the platform's own installer. Both refuse rather than skip: a reaper that
# was "installed" but never fires is the false PASS this installer exists to remove.
do_install() {
    # ⛔ A NUMERIC VALUE THAT BECOMES A DELEGATE ARGUMENT MUST BE A NUMBER — ON BOTH PLATFORMS. Render it
    # as `7d` and the worktree delegate refuses (exit 2), the pass records `ok=0 rc=6` ("busy box, retry
    # later") and the artifact stays GREEN while `--aged-days 7d` can never work. This lives in
    # do_install, not in the systemd arm, because the Darwin arm rendered the same bad value.
    case "${AGED_DAYS:-}" in
        ''|*[!0-9]*) err "REFUSING: DISK_REAPER_WT_AGED_DAYS must be a whole number of days (got '$AGED_DAYS')"; return 1 ;;
    esac
    # The worktree class's ONE unpinnable dependency, named before the unit is written (#2443).
    warn_gh_prerequisite "$HOME" "$(id -un)"
    if [ "$PLATFORM" = "Darwin" ]; then do_install_launchd; else do_install_systemd; fi
}


# ── the installed ARTIFACT, read back ────────────────────────────────────────────────────────────
# WHY A READ-BACK AND NOT A COMPARISON. The render path validates its INPUTS (refuse_transient_target)
# and compares the rendered temp copy byte-for-byte, but neither is the artifact systemd LOADS:
#   * a `*.service.d/*.conf` drop-in overrides/replaces `ExecStart=` and the rendered bytes still match;
#   * a truncated or partially-written unit has no `ExecStart=` at all and nothing notices;
#   * `install(1)` can leave a pre-existing file in place on some failures and the installer still
#     reports `changed=1`.
# MEASURED (2026-10-18, pi-cell-2/-3): the INSTALLED unit executed
#   ExecStart=/bin/bash /tmp/tmp.XXXX/bg/home/.pi/agent/scripts/disk-reaper.sh --apply
# and exited 127 every hour while `list-timers` showed it healthy. A pruner whose unit exists but
# 127s is worse than no pruner: it satisfies every "is it installed?" check. The next `--status`
# does catch it (ExecMainStatus) — but an unattended cell may never run `--status` again.
#
# WHAT IS READ, PER TARGET (the three arms differ because the truth sources differ):
#   system   — `systemctl cat` is REQUIRED. Only systemd knows about `/run/systemd/system/*.d` and
#              `/usr/lib/systemd/system/*.d`, and an unreadable answer there is indistinguishable from
#              "no drop-in". Unreadable => REFUSE (fail-closed).
#   user     — `systemctl --user cat`, else the installed file plus its own `<unit>.d/*.conf` (the
#              user manager's drop-in dir is the one `$UNIT_DIR` names, so it IS readable).
#   override — the documented test seam: no systemd knows this directory, so the file plus its
#              `<unit>.d/*.conf` is merged the way systemd merges it (lexical order, later wins, a
#              bare `ExecStart=` resets the list).
# macOS/launchd has no ExecStart/EnvironmentFile at all — `verify_installed_artifact_plist` asserts the
# PROGRAM ARGUMENTS identity instead, which is the equivalent fact for that platform.
unit_dropins() { # <dir> — cat every drop-in, lexical order (systemd's order)
    local d
    for d in "$1"/*.conf; do
        [ -f "$d" ] || continue
        printf '### %s\n' "$d"
        cat "$d"
    done
}

service_effective_unit() { # prints the bytes systemd will load; rc 1 when that cannot be known
    local f="$UNIT_DIR/$UNIT_NAME.service" out=""
    case "$TARGET" in
        override)
            [ -f "$f" ] || return 1
            { cat "$f"; unit_dropins "$UNIT_DIR/$UNIT_NAME.service.d"; }
            return 0 ;;
        user)
            out="$($SC cat "$UNIT_NAME.service" 2>/dev/null)"
            if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
            [ -f "$f" ] || return 1
            { cat "$f"; unit_dropins "$UNIT_DIR/$UNIT_NAME.service.d"; }
            return 0 ;;
        *)
            out="$($SC cat "$UNIT_NAME.service" 2>/dev/null)"
            [ -n "$out" ] || return 1
            printf '%s\n' "$out"
            return 0 ;;
    esac
}

# The ExecStart argv lines systemd will actually run: everything AFTER the last bare `ExecStart=`
# reset. ⛔ Not "the last ExecStart line": `Type=oneshot` may carry several, and a drop-in that ADDS a
# pre-flight command is a healthy unit — refusing it would be a false block on a working cell.
# effective_env <unit text> — the Environment= map systemd will ACTUALLY hand the process, printed as
# `NAME=VALUE` lines (one per variable, last assignment wins).
#
# ⛔ A LINE-ANCHORED `^Environment=HOME=` MATCH IS DEFEATABLE, and a gate that reads one line and then
# reports "verified" is the false PASS this whole read-back exists to remove (measured: a drop-in with
# `Environment=PATH=/usr/bin:/bin HOME=/tmp/tmp.deadbeef/bg/home`, and another with
# `Environment="HOME=/tmp/tmp.deadbeef/bg/home"`, both left the plain assignment intact and the install
# printed "verify: … read back" over a unit whose HOME was the dead tree). systemd parses the whole
# file in order, accepts several space-separated assignments per line, honours double and single
# quotes, and lets a LATER assignment of the same name win; a bare `Environment=` RESETS the list
# (the same reset semantics `effective_execstarts` already implements for `ExecStart=`).
# `env -i`-style edge cases (empty values, `NAME=` with no value) are preserved verbatim, because an
# empty HOME is not the HOME the install rendered and must be refused by the caller.
# normalize_unit_lines — systemd's OWN reading of `Key = value`: it strips whitespace AROUND the key,
# around the `=`, and before the value, and it accepts indented lines. A parser anchored on
# `^ExecStart=` therefore MISSES a legal `ExecStart =` — and a drop-in that spells BOTH the reset and
# the replacement that way is invisible to the read-back, which then certifies the BASE unit's command
# while systemd runs the drop-in's.
# ⛔ MEASURED (review pass): with a drop-in carrying `ExecStart =` + `ExecStart = /bin/true` and
# `Environment = HOME=/tmp/tmp.deadbeef/bg/home`, `effective_execstarts` still reported the base
# `/bin/bash <reaper> --apply` and `effective_env` still reported the base HOME — the install printed
# `verify: ExecStart + HOME read back`, exited 0 and armed the timer over a unit that ran /bin/true.
# `systemd-analyze verify` ACCEPTS these spellings (a genuinely unknown key draws "Service has no
# ExecStart= … Refusing."), so the unit really would run the drop-in's command. The indented spelling
# (`  ExecStart=`) reproduces identically.
# Normalising the TEXT once, rather than teaching every parser the grammar, keeps one definition.
normalize_unit_lines() {
    sed -E 's/^[[:space:]]+//; s/^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*/\1=/'
}

effective_env() {
    printf '%s\n' "$1" | normalize_unit_lines | awk '
        function emit(tok,   eq, name) {
            eq = index(tok, "=")
            if (eq <= 1) return                     # not a NAME=VALUE assignment: systemd ignores it
            name = substr(tok, 1, eq - 1)
            vals[name] = substr(tok, eq + 1)
            if (!(name in seen)) { seen[name] = 1; order[++n] = name }
        }
        /^Environment=/ {
            rest = substr($0, 13)
            if (rest == "") { n = 0; split("", order); split("", vals); split("", seen); next }
            tok = ""; inq = 0; q = ""
            for (i = 1; i <= length(rest); i++) {
                ch = substr(rest, i, 1)
                # A BACKSLASH ESCAPES THE NEXT CHARACTER inside a quoted value: systemd accepts
                # `Environment="HOME=/tmp/q\\"uo"`, so treating the escaped quote as the terminator made
                # this parser refuse a line systemd is happy with (an over-block with a false reason).
                if (esc) { tok = tok ch; esc = 0; continue }
                if (inq) {
                    if (ch == "\\") { esc = 1; continue }
                    if (ch == q) { inq = 0; continue }
                    tok = tok ch; continue
                }
                if (ch == "\"" || ch == "\047") { inq = 1; q = ch; continue }
                if (ch == " " || ch == "\t") { if (tok != "") { emit(tok); tok = "" }; continue }
                tok = tok ch
            }
            # NOTE (apostrophes are ILLEGAL here: this is a single-quoted awk program):
            # AN UNTERMINATED QUOTE IS AN UNPARSEABLE LINE, NOT A VALUE. systemd returns EINVAL,
            # logs, and ABANDONS the whole line — the service starts WITHOUT those variables.
            # Emitting `HOME=<rest of line>` would certify a HOME the unit never gets (a fail-open
            # the pre-fix line match did not have, because it compared the value with the quote
            # still attached). systemd rule applied: discard the line, and REPORT it so the caller
            # can refuse instead of guessing.
            if (inq || esc) { bad[++b] = rest; next }
            if (tok != "") emit(tok)
            next
        }
        END { for (i = 1; i <= b; i++) print "!unparseable:" bad[i]
              for (i = 1; i <= n; i++) print order[i] "=" vals[order[i]] }'
}

effective_execstarts() {
    printf '%s\n' "$1" | normalize_unit_lines | awk '
        /^ExecStart=$/ { n=0; next }
        /^ExecStart=/  { L[++n] = substr($0, 11); next }
        END            { for (i = 1; i <= n; i++) print L[i] }'
}

# split_words <line> — systemd's OWN word splitting for one command line: double and single quotes
# group, a backslash escapes the next character inside quotes, runs of whitespace separate. One token
# per line on stdout.
# rc 3 = an UNTERMINATED QUOTE. systemd returns EINVAL, logs, and ABANDONS the whole directive, so
# such a line is NOT a command this gate may read as a pass — the caller refuses naming it. (Same
# rule `effective_env` applies to Environment=, and for the same measured reason.)
split_words() {
    printf '%s\n' "$1" | awk '
        {
            tok = ""; inq = 0; q = ""; esc = 0; started = 0; ntok = 0
            n = length($0)
            for (i = 1; i <= n; i++) {
                ch = substr($0, i, 1)
                if (esc) { tok = tok ch; esc = 0; started = 1; continue }
                if (inq) {
                    if (ch == "\\") { esc = 1; continue }
                    if (ch == q) { inq = 0; continue }
                    tok = tok ch; continue
                }
                if (ch == "\"" || ch == "\047") { inq = 1; q = ch; started = 1; continue }
                if (ch == " " || ch == "\t") { if (started) { T[++ntok] = tok; tok = ""; started = 0 }; continue }
                tok = tok ch; started = 1
            }
            if (started) T[++ntok] = tok
            if (inq || esc) exit 3
            for (i = 1; i <= ntok; i++) print T[i]
        }'
}

# json_array_words <json-array-text> — one element per line, for the plist's ProgramArguments.
# Not a JSON parser: it walks the ONE shape `plutil -extract … json` and the python3 fallback both
# emit (an array of strings), which is all this gate is ever handed.
json_array_words() {
    printf '%s' "$1" | awk '
        {
            s = $0
            sub(/^[[:space:]]*\[/, "", s); sub(/\][[:space:]]*$/, "", s)
            n = length(s); i = 1; cur = ""; started = 0
            while (i <= n) {
                ch = substr(s, i, 1)
                if (ch == "\"") {
                    i++; started = 1
                    while (i <= n) {
                        c2 = substr(s, i, 1)
                        if (c2 == "\\") { cur = cur substr(s, i + 1, 1); i += 2; continue }
                        if (c2 == "\"") { i++; break }
                        cur = cur c2; i++
                    }
                    continue
                }
                if (ch == ",") { if (started) { print cur; cur = ""; started = 0 }; i++; continue }
                i++
            }
            if (started) print cur
        }'
}

# plist_program_arguments_textual <plist-file> — the `ProgramArguments` array's <string> elements, in
# order, one per line. This is the NO-PARSER arm of the plist read-back: it reads the array POSITIONALLY
# so the same program-position rule applies (a bare "the path appears in the file" passes a stale or
# masked job — the defect the parsed arm was fixed for). Prints nothing when the array is absent.
plist_program_arguments_textual() {
    awk '
        {
            s = $0
            if (done) next
            if (!inarr) {
                if (!match(s, /<key>[[:space:]]*ProgramArguments[[:space:]]*<\/key>/)) next
                s = substr(s, RSTART + RLENGTH)
                if (!match(s, /<array>/)) next
                inarr = 1
                s = substr(s, RSTART + 7)
            }
            if (match(s, /<\/array>/)) { done = 1; s = substr(s, 1, RSTART - 1) }
            buf = buf s "\n"
        }
        END {
            while (match(buf, /<string>[^<]*<\/string>/)) {
                print substr(buf, RSTART + 8, RLENGTH - 17)
                buf = substr(buf, RSTART + RLENGTH)
            }
        }' "$1"
}

# plist_argv_runs_reaper — does this launchd ProgramArguments argv LAUNCH the reaper this install
# rendered? Two shapes are legitimate, and each is pinned by its own identity:
#   • the TCC launcher shape this installer renders (`<PY_BIN> <LAUNCHER> --script <REAPER> …`): the
#     launcher must be in program position AND `--script` must carry THIS install's reaper;
#   • a job that runs the reaper directly (a shell in program position, as the systemd unit does).
# ⛔ Anything else is refused. `/bin/true --script <REAPER> --apply` matches neither: the launcher
# identity is not there, and the program does not execute the reaper. That was the accepted case
# before this check existed (a membership test over the JSON text), i.e. the same fail-open, in the
# arm whose comment claimed to assert "the equivalent fact" for launchd.
# rc 0 = launches the reaper · 1 = does not · 2 = empty argv.
plist_argv_runs_reaper() {
    local -a t=()
    local line i
    while IFS= read -r line; do t[${#t[@]}]="$line"; done
    [ "${#t[@]}" -gt 0 ] || return 2
    if [ -n "${LAUNCHER:-}" ] && [ "${#t[@]}" -ge 2 ] && [ "${t[1]}" = "$LAUNCHER" ]; then
        # ⛔ argv[0] IS THE PROGRAM launchd EXECS — and it was not checked. Requiring only the launcher
        # in argv[1] certified `[/bin/true, <launcher>, --script, <reaper>, --apply]`: launchd runs
        # /bin/true and nothing else while the install reports success (found in review, reproduced).
        # It also certified a STALE interpreter — the TCC class this installer warns about, where the
        # rendered PY_BIN cannot read the repos — because only the launcher path was compared.
        if [ -n "${PY_BIN:-}" ]; then
            [ "${t[0]}" = "$PY_BIN" ] || return 1
        else
            case "${t[0]##*/}" in python*) : ;; *) return 1 ;; esac
        fi
        i=2
        while [ "$i" -lt "${#t[@]}" ]; do
            if [ "${t[$i]}" = "--script" ]; then
                i=$((i + 1))
                [ "${t[$i]:-}" = "$REAPER" ] && return 0
                return 1
            fi
            i=$((i + 1))
        done
        return 1
    fi
    printf '%s\n' "${t[@]}" | argv_executes_reaper
}

# argv_executes_reaper — read a token list (one per line, PROGRAM FIRST) on stdin and answer the only
# question the read-back is entitled to ask: does this command EXECUTE the reaper?
#
# ⛔ MEMBERSHIP IS NOT EXECUTION. The first cut of this gate asked
#     case " $exec " in *" $REAPER "*) ok=1 ;;
# which is a membership test over the WHOLE command line: a drop-in that REPLACED `ExecStart=` with
# `/bin/true <reaper> --apply` matched, the install printed `verify: ExecStart + HOME read back`,
# exited 0 and ran `enable --now` — a box with no reaper and every check green. That is the exact
# fail-open this read-back exists to remove (found by an adversarial review pass, reproduced against a
# stub `systemctl`). The doc already promised "a drop-in that replaces it is refused"; now the code
# does too.
# What is accepted is systemd's own rule: the FIRST token is the program, after the optional prefixes
# systemd strips before resolving the executable — `-` (ignore failure), `@` (argv[0]), `+`, `!`, `!!`
# (privilege/sandbox overrides) — or a shell/`env` in program position whose first NON-OPTION argument
# is the reaper. `bash -c '<script text>'` never passes: the text is a single argument, and whether it
# runs the reaper is not a fact this gate can prove.
# rc 0 = executes the reaper · 1 = does not · 2 = no tokens at all.
argv_executes_reaper() {
    local -a t=()
    local line prog i tok
    while IFS= read -r line; do t[${#t[@]}]="$line"; done
    [ "${#t[@]}" -gt 0 ] || return 2
    i=0
    prog="${t[0]}"
    while :; do
        # systemd exec prefixes — `-` (ignore failure), `@` (argv[0]), `+`/`!`/`!!` (privilege and
        # sandbox overrides) — stripped in the order systemd applies them.
        while :; do
            case "$prog" in
                '!!'*) prog="${prog#'!!'}" ;;
                '+'*|'!'*|'@'*|'-'*) prog="${prog#?}" ;;
                *) break ;;
            esac
        done
        [ "$prog" = "$REAPER" ] && return 0
        case "${prog##*/}" in
            env)
                # `env [-i] [VAR=value …] <program> …` — resolve THROUGH the wrapper rather than
                # refusing a legal command line (systemd renders `/bin/bash` directly, but a hand-fixed
                # unit or a drop-in that ADDS `/usr/bin/env bash <reaper>` is a healthy one).
                i=$((i + 1))
                while [ "$i" -lt "${#t[@]}" ]; do
                    tok="${t[$i]}"
                    case "$tok" in
                        -*)  i=$((i + 1)); continue ;;
                        *=*) i=$((i + 1)); continue ;;
                    esac
                    prog="$tok"; break
                done
                [ "$i" -lt "${#t[@]}" ] || return 1
                continue ;;
            bash|sh|dash|zsh|ksh)
                i=$((i + 1))
                while [ "$i" -lt "${#t[@]}" ]; do
                    tok="${t[$i]}"
                    i=$((i + 1))
                    case "$tok" in -*) continue ;; esac   # an interpreter FLAG is not the script
                    [ "$tok" = "$REAPER" ] && return 0
                    return 1                               # first non-option arg is not the reaper
                done
                return 1 ;;
        esac
        return 1
    done
}

# argv_has_token <token> — read a token list (one per line) on stdin, rc 0 if the exact token is present.
# Used for the mode flag: a FLAG is an argument by nature, so membership is the right question for it
# (unlike the program, where membership let a replaced ExecStart through).
argv_has_token() {
    local want="$1" line
    while IFS= read -r line; do [ "$line" = "$want" ] && return 0; done
    return 1
}

verify_installed_unit() {
    local unit="" execs="" exec="" tokens="" rc=0 want_home="" got_home="" envmap="" ok=0 bad=""
    if ! unit="$(service_effective_unit)"; then
        err "REFUSING to report this as installed: the installed unit could not be READ BACK from the"
        err "  $TARGET manager (\`$SC cat $UNIT_NAME.service\`). An unreadable artifact is not a"
        err "  verified one, and a unit that runs a path we did not render is the 127 defect itself."
        return 1
    fi
    execs="$(effective_execstarts "$unit")"
    [ -n "$execs" ] || {
        err "REFUSING: the INSTALLED unit carries no ExecStart= — systemd cannot start it (a truncated"
        err "  write, or a drop-in that reset the list). Re-run after fixing $UNIT_DIR/$UNIT_NAME.service"
        return 1
    }
    # Rule: one of OUR effective commands EXECUTES the reaper — the program in program position, or a
    # shell whose first non-option argument is it. A drop-in that REPLACES it (the mask) leaves ours
    # absent, which is the case this catches; a drop-in that merely NAMES it in another program's
    # arguments is the same defect wearing a disguise, and is refused the same way (see
    # argv_executes_reaper for the measured reproduction).
    local found=0
    while IFS= read -r exec; do
        [ -n "$exec" ] || continue
        tokens="$(split_words "$exec")"; rc=$?
        if [ "$rc" -eq 3 ]; then
            err "REFUSING: the installed ExecStart line cannot be tokenized (an unterminated quote), so"
            err "  systemd REJECTS it and abandons the directive — the service would start without it:"
            err "  $exec"
            return 1
        fi
        if printf '%s\n' "$tokens" | argv_executes_reaper; then ok=1; found=1; break; fi
    done <<<"$execs"
    if [ "$ok" != 1 ]; then
        bad="$(printf '%s' "$execs" | head -1)"
        err "REFUSING: the INSTALLED unit does not run the reaper this install rendered."
        err "  rendered: $REAPER"
        err "  installed ExecStart: ${bad:-<none>}"
        # Name the drop-ins that EXIST, not just the directory that could hold one: the operator's next
        # move is to open the file, and systemd-delta is a second command they should not need.
        local drops="" _c
        for _c in "$UNIT_DIR/$UNIT_NAME.service.d"/*.conf; do
            [ -f "$_c" ] && drops="${drops}${drops:+ }$_c"
        done
        if [ -n "$drops" ]; then
            err "  drop-in file(s) present: $drops"
        else
            err "  a drop-in under $UNIT_DIR/$UNIT_NAME.service.d/ can replace ExecStart while the unit"
            err "  still reads as installed and enabled."
        fi
        err "  Remove or fix it, then re-run."
        return 1
    fi
    # The mode flag is the ARMING DECISION and is visible in the artifact (never hidden in a default).
    printf '%s\n' "$tokens" | argv_has_token "$MODE_FLAG" \
        || { err "REFUSING: the installed ExecStart does not carry $MODE_FLAG — the arming decision is not in the artifact"
             return 1; }
    # HOME is what `gh` resolves its auth from; the measured exit-3 class ("gh unavailable") is exactly
    # a service whose HOME is not the cell's home.
    want_home="$HOME"
    envmap="$(effective_env "$unit")"
    # ⛔ A LINE SYSTEMD WOULD REJECT IS NOT A VERIFIED HOME. Refuse and name it: an unbalanced quote
    # makes systemd drop that line (the service runs without the variable), so "verified" would be a
    # claim about a value the unit will never have.
    if grep -q '^!unparseable:' <<<"$envmap"; then
        err "REFUSING: the installed unit carries an Environment= line this parser cannot evaluate"
        err "  (an unterminated quote), so its variables — HOME among them if it sets one — cannot be"
        err "  verified at all:"
        printf '%s\n' "$envmap" | sed -n 's/^!unparseable:/  /p' >&2
        return 1
    fi
    got_home="$(printf '%s\n' "$envmap" | sed -n 's/^HOME=//p')"
    if [ -z "$got_home" ]; then
        err "REFUSING: the installed unit sets no Environment=HOME= — the worktree class needs it for gh auth (exit 3 without it)"
        return 1
    fi
    case "$got_home" in
        /*) : ;;
        *) err "REFUSING: the installed unit's Environment=HOME=$got_home is not absolute"; return 1 ;;
    esac
    if [ "$got_home" != "$want_home" ]; then
        err "REFUSING: the installed unit's HOME ($got_home) is not the home this install rendered ($want_home)"
        err "  A service whose HOME is a different tree cannot see the gh auth it needs, and its state dir moves with it."
        return 1
    fi
    # The three pinned delegates are pinned to files that must EXIST (a pin to a missing path makes that
    # class fail closed every pass — reported as a WARNING at render time, never a refusal, so the
    # classes that CAN run still do; here it is surfaced again on the artifact).
    local miss="" d
    for d in CACHE_REAPER VENV_REAPER WORKTREE_REAPER; do
        local v=""
        v="$(printf '%s\n' "$envmap" | sed -n "s/^$d=//p")"
        [ -n "$v" ] || { miss="${miss}${miss:+, }$d(unset)"; continue; }
        [ -f "$v" ] || miss="${miss}${miss:+, }$d($v)"
    done
    [ -n "$miss" ] && err "WARNING: pinned delegate(s) missing after install: $miss — that class will FAIL CLOSED (exit 3, red) every pass"
    log_line "  verify: ExecStart + HOME read back from the installed artifact (target=$TARGET)"
    return 0
}

verify_installed_artifact_plist() {
    local f="$UNIT_DIR/$LABEL.plist" args=""
    [ -f "$f" ] || { err "REFUSING: the installed plist is missing ($f) — launchd has nothing to load"; return 1; }
    # launchd has no ExecStart; the equivalent fact is ProgramArguments. Read it with a real plist
    # parser when one exists, and say so when only a textual check was possible.
    local perr=""
    if command -v plutil >/dev/null 2>&1; then
        # Keep the parser's OWN error: a parser that is PRESENT but FAILING (a corrupt or hand-edited
        # plist — the stale-artifact class this gate exists for) is a different fact from a parser that
        # is absent, and `|| args=""` threw the only evidence away while the message claimed absence.
        if ! args="$(plutil -extract ProgramArguments json -o - "$f" 2>&1)"; then perr="$args"; args=""; fi
    elif command -v python3 >/dev/null 2>&1; then
        if ! args="$(python3 -c 'import json,sys,plistlib;print(json.dumps(plistlib.load(open(sys.argv[1],"rb")).get("ProgramArguments",[])))' "$f" 2>&1)"; then perr="$args"; args=""; fi
    fi
    if [ -n "$args" ]; then
        # ⛔ A PAIR, NOT A MEMBERSHIP. `*"\"$REAPER\""*` matched if the path appeared ANYWHERE in the
        # JSON text, so `["/bin/true","<reaper>","--apply"]` was certified as launching the reaper —
        # the same fail-open the systemd arm had, in the arm that claims to assert "the equivalent fact"
        # for launchd. The rendered job's identity is a TWO-part fact: the TCC launcher in program
        # position AND `--script <this install's reaper>`. Parsed into argv and checked as such.
        local pargv=""
        pargv="$(json_array_words "$args")"
        if ! printf '%s\n' "$pargv" | plist_argv_runs_reaper; then
            err "REFUSING: the installed plist does not LAUNCH $REAPER (ProgramArguments=$args)"
            err "  a scheduled job that runs a DIFFERENT program — even one that names the reaper as an"
            err "  argument — is the stale-farm/mask defect this pin exists to remove"
            return 1
        fi
        # ⛔ THE SAME TWO FACTS THE SYSTEMD ARM REFUSES ON. A plist whose ProgramArguments carry
        # `--dry-run` reclaims NOTHING while `launchctl list` shows the job loaded, and a plist whose
        # EnvironmentVariables.HOME is another tree cannot see the gh auth — the two shapes a stale
        # (not re-rendered) install produces, and the arm that only checked the executable path
        # reported both as "installed".
        if ! printf '%s\n' "$pargv" | argv_has_token "$MODE_FLAG"; then
            err "REFUSING: the installed plist does not carry $MODE_FLAG — the arming decision is not in the artifact"
            err "  ProgramArguments=$args"
            return 1
        fi
        local ph=""
        if command -v plutil >/dev/null 2>&1; then
            ph="$(plutil -extract EnvironmentVariables.HOME raw -o - "$f" 2>/dev/null || true)"
        elif command -v python3 >/dev/null 2>&1; then
            ph="$(python3 -c 'import sys,plistlib;d=plistlib.load(open(sys.argv[1],"rb"));print((d.get("EnvironmentVariables") or {}).get("HOME",""))' "$f" 2>/dev/null || true)"
        fi
        if [ -z "$ph" ]; then
            # A parsed plist that carries NO EnvironmentVariables.HOME is a real gap (the worktree
            # class needs it for gh), but this arm cannot always read that key on every host — so say
            # WHICH fact went unverified instead of printing one unqualified "verified" line.
            err "WARNING: the installed plist declares no readable EnvironmentVariables.HOME — the gh auth"
            err "  that the worktree class needs is NOT verified for this target ($f)"
        elif [ "$ph" != "$HOME" ]; then
            err "REFUSING: the installed plist's EnvironmentVariables.HOME ($ph) is not the home this install rendered ($HOME)"
            return 1
        fi
        log_line "  verify: ProgramArguments + mode flag read back from the installed plist (target=$TARGET)"
    else
        # ⛔ THE FALLBACK MUST NOT QUIETLY VERIFY LESS THAN THE PARSED ARM. A textual "the path appears
        # somewhere in the file" passes a stale plist (a `--dry-run` argument, or the path inside an
        # unused `EnvironmentVariables` entry) — the exact defect the parsed arm was fixed for — and it
        # is the SAME membership-is-not-execution flaw the parsed arm just had. It also used to claim
        # the parser was ABSENT even when one was present but failed, so the message asserted a reason
        # that was false. The ProgramArguments array is therefore read TEXTUALLY but POSITIONALLY (the
        # elements, in order, are the argv), and the message names what was NOT verified.
        local targv=""
        targv="$(plist_program_arguments_textual "$f")"
        if [ -z "$targv" ]; then
            err "REFUSING: the installed plist carries no readable ProgramArguments array — nothing to verify"
            return 1
        fi
        if ! printf '%s\n' "$targv" | plist_argv_runs_reaper; then
            err "REFUSING: the installed plist does not LAUNCH $REAPER — ProgramArguments[0] is not it and no"
            err "  shell in program position takes it as its first argument:"
            printf '%s\n' "$targv" | sed 's/^/    /' >&2
            return 1
        fi
        if ! printf '%s\n' "$targv" | argv_has_token "$MODE_FLAG"; then
            err "REFUSING: the installed plist does not carry $MODE_FLAG — the arming decision is not in the artifact"
            local _why="no plist parser was available"
            # ⛔ `${perr:-word}` is NOT an else — it expands to `$perr` when `perr` is non-empty,
            # so the old one-liner printed a present-but-failing parser's error TWICE, the second
            # copy unflattened and jammed against the first. A real else, built once.
            [ -n "$perr" ] && _why="the plist parser FAILED — $(printf '%s' "$perr" | tr '\n' ' ')"
            err "  (textual check only: $_why)"
            return 1
        fi
        if [ -n "$perr" ]; then
            err "WARNING: the plist parser FAILED on $f — the text below is the PARSER's own error, and only"
            err "  the TEXTUAL checks (executable + $MODE_FLAG) verified this artifact: $(printf '%s' "$perr" | tr '\n' ' ')"
        fi
        log_line "  verify: plist checked textually — $MODE_FLAG present in ProgramArguments, the reaper is in"
        log_line "    program position; EnvironmentVariables.HOME NOT verified (no usable plist parser)"
    fi
    return 0
}

# Is `gh` resolvable in the environment the SERVICE will get? The worktree class shells out to it to
# veto open PRs and now to read the merged list; with no gh it fails closed (exit 3) and the unit goes
# red. Reported, never assumed — and never a refusal, because a box with no GitHub remote does not
# need it (the class reports `pr_merged=na` there).
report_gh_resolvable() {
    local p=""
    p="$(PATH="$PATH" HOME="$HOME" command -v gh 2>/dev/null || true)"
    if [ -n "$p" ]; then
        log_line "  gh:     $p"
    else
        err "WARNING: no \`gh\` on the PATH this unit renders — the worktree class will FAIL CLOSED (exit 3, red) every pass until it is resolvable. Install/auth gh for the service user."
    fi
}

do_install_launchd() {
    local src_plist="$LAUNCHD_TEMPLATES_DIR/$LABEL.plist"
    local tmpd changed=0 loaded=0
    [ -n "$REAPER" ] || { err "disk-reaper.sh not found — looked at \$DISK_REAPER, \$HOME/.pi/agent/scripts, and $INFRA_ROOT/scripts. Farm it first: bash pi-bootstrap/setup.sh"; return 1; }
    [ -f "$src_plist" ] || { err "plist template missing: $src_plist (set LAUNCHD_TEMPLATES_DIR)"; return 1; }
    REPOS="$(resolve_repos)"
    # ⛔ ZERO REPOS IS A REFUSAL, NOT A WARNING. Both per-worktree classes would fail closed every pass
    # (exit 3), the unit goes red an hour after install, and in the meantime `--status` answers
    # `status=never` with rc 0 — so `cloud-cell-bringup.sh --check` certifies CELL READY for a reaper
    # whose two repo classes can never run. Measured on this box: the installed service carried
    # `Environment=DISK_REAPER_REPOS=` and the first pass recorded `rc=3 detail=no repo to scan`.
    [ -n "$REPOS" ] || { err "REFUSING: no repo resolved on this box — the venv and worktree classes would fail closed every pass (exit 3). Set DISK_REAPER_REPOS or REPO to an absolute checkout path."; return 1; }
    choose_target || { err "no scheduler available"; return 1; }
    resolve_launcher || return 1
    refuse_transient_target || return 1

    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/disk-reaper-plist.XXXXXX")" || { err "cannot create a temp dir"; return 1; }
    render "$src_plist" "$tmpd/$LABEL.plist" || { rm -rf "$tmpd"; return 1; }
    # ⛔ A PLIST THAT DOES NOT PARSE IS NOT INSTALLED. Measured on this PR: a placeholder inside an XML
    # COMMENT rendered `--apply` into it, `--` is forbidden there, and the artifact was not well-formed —
    # launchd would refuse it and the box would silently have no reaper while the installer said OK.
    plist_is_valid "$tmpd/$LABEL.plist" || {
        err "REFUSING: the rendered plist is not well-formed XML — launchd would refuse it and this box would have no reaper"
        err "  rendered: $tmpd/$LABEL.plist"
        # Report the PARSER's own message (line + column), not a grep over the file: an XML comment that
        # carries a doubled dash is not on a line with `<!--`/`-->`, so a delimiter grep misses exactly
        # the line that broke it (measured while writing this guard).
        if command -v python3 >/dev/null 2>&1; then
            python3 -c 'import sys,xml.etree.ElementTree as ET
try:
    ET.parse(sys.argv[1])
except ET.ParseError as e:
    print("  parser: %s" % e, file=sys.stderr)
    ln = getattr(e, "position", (0, 0))[0]
    if ln:
        print("  line %d: %s" % (ln, open(sys.argv[1], errors="replace").read().splitlines()[ln-1].strip()), file=sys.stderr)' "$tmpd/$LABEL.plist" || true
        fi
        err "  hint: an XML comment must not contain a doubled dash — keep option flags out of comments"
        rm -rf "$tmpd"; return 1
    }

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_line "dry-run: would install to $UNIT_DIR (target=$TARGET) and bootstrap $LABEL"
        log_line "--- $LABEL.plist ---"; sed 's/^/  /' "$tmpd/$LABEL.plist"
        rm -rf "$tmpd"
        return 0
    fi

    cmp -s "$tmpd/$LABEL.plist" "$UNIT_DIR/$LABEL.plist" || changed=1
    mkdir -p "$UNIT_DIR" 2>/dev/null || { err "cannot create $UNIT_DIR"; rm -rf "$tmpd"; return 1; }
    cp -f "$tmpd/$LABEL.plist" "$UNIT_DIR/$LABEL.plist" || { err "copy failed"; rm -rf "$tmpd"; return 1; }
    rm -rf "$tmpd"

    # ⛔ THE READ-BACK RUNS BEFORE THE JOB IS ARMED. A plist that launchd would load but that does not
    # launch THIS reaper — a stale one, a `--dry-run` one, one whose `EnvironmentVariables.HOME` is
    # another tree (no gh auth) — must not be left scheduled and firing while the installer exits 1.
    # The systemd arm states the same rule ("the install has to fail before the clock starts, not
    # after"); this arm bootstrapped first and verified second, so a refusal here armed the very job it
    # refused. The artifact is already the copied file at this point, so the check is equally valid.
    # The installed plist is the artifact launchd loads, not the one we rendered: verify the artifact,
    # never the bytes we hoped it would be.
    verify_installed_artifact_plist || return 1

    # Only re-bootstrap when the bytes moved or the job is not loaded: a bootout/bootstrap on every
    # bring-up would reset launchd's start interval bookkeeping for no reason. The loaded test matches
    # the WHOLE label (third field), not a substring — `grep -qF com.eldato.disk-reaper` would also
    # match a job labelled `…-old` and skip the bootstrap this pass needs.
    $SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {found=1} END{exit !found}' && loaded=1
    if [ "$changed" = 1 ] || [ "$loaded" = 0 ]; then
        $SC bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
        $SC bootstrap "gui/$(id -u)" "$UNIT_DIR/$LABEL.plist" >/dev/null 2>&1 \
            || $SC load -w "$UNIT_DIR/$LABEL.plist" >/dev/null 2>&1 \
            || { err "could not bootstrap $LABEL from $UNIT_DIR/$LABEL.plist — the reaper will NOT run unattended"; return 1; }
    fi

    log_line "installed: target=$TARGET dir=$UNIT_DIR changed=$changed"
    log_line "  reaper: $REAPER"
    log_line "  launch: $PY_BIN $LAUNCHER --script $REAPER -- $MODE_FLAG"
    log_line "  repos:  ${REPOS:-<none>}  (worktree floor ${AGED_DAYS}d)"
    log_line "  gh:     ${GH_PREFLIGHT:+$GH_PREFLIGHT — the worktree class will skip every repo (see the WARNING above)}${GH_PREFLIGHT:-authenticated for HOME=$HOME — the PR-state gate can run}"
    log_line "  state:  $STATE_DIR/disk-reaper.status"
    report_gh_resolvable
    if $SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {found=1} END{exit !found}'; then
        log_line "  agent:  loaded"
    else
        err "agent $LABEL is NOT loaded after install — the reaper will not run unattended"; return 1
    fi
    return 0
}

do_install_systemd() {
    local src_svc="$TEMPLATES_DIR/$UNIT_NAME.service" src_tim="$TEMPLATES_DIR/$UNIT_NAME.timer"
    local tmpd changed=0
    [ -n "$REAPER" ] || { err "disk-reaper.sh not found — looked at \$DISK_REAPER, \$HOME/.pi/agent/scripts, and $INFRA_ROOT/scripts. Farm it first: bash pi-bootstrap/setup.sh"; return 1; }
    [ -f "$src_svc" ] && [ -f "$src_tim" ] || { err "templates missing under $TEMPLATES_DIR"; return 1; }
    REPOS="$(resolve_repos)"
    # ⛔ A ROOT INSTALL LOOKS AFTER ROOT'S CACHES, NOT THE LANES'. {{USER}} is `id -un` and {{HOME}} is
    # $HOME, so `sudo bash install-disk-reaper-timer.sh --install` renders `User=root` with
    # `Environment=HOME=/root` and the hourly pass then bounds /root while the lane user's caches and
    # worktrees are untouched — exit 0 every hour, nothing notices. WHAT THIS REFUSES, EXACTLY: an
    # invocation that arrived through sudo (`SUDO_USER` set). A genuine root shell (`sudo -i`, root in a
    # container) has no SUDO_USER and is NOT refused — say what is true rather than claiming a wider
    # guard than the one written.
    if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
        err "REFUSING to install as root (SUDO_USER=$SUDO_USER): the unit would run as root and look after"
        err "root's caches, not $SUDO_USER's — a green hourly pass that reclaims nothing."
        err "Run it as the user that owns the lanes:  sudo -u $SUDO_USER -H bash $0 --install"
        return 1
    fi
    # ⛔ ZERO REPOS IS A REFUSAL, NOT A WARNING. Both per-worktree classes would fail closed every pass
    # (exit 3), the unit goes red an hour after install, and in the meantime `--status` answers
    # `status=never` with rc 0 — so `cloud-cell-bringup.sh --check` certifies CELL READY for a reaper
    # whose two repo classes can never run. Measured on this box: the installed service carried
    # `Environment=DISK_REAPER_REPOS=` and the first pass recorded `rc=3 detail=no repo to scan`.
    [ -n "$REPOS" ] || { err "REFUSING: no repo resolved on this box — the venv and worktree classes would fail closed every pass (exit 3). Set DISK_REAPER_REPOS or REPO to an absolute checkout path."; return 1; }
    # ⛔ THE SCRATCH GUARD RUNS BEFORE TARGET SELECTION. A box whose HOME is transient scratch must be
    # told THAT, not "no scheduler available" — and selection itself can refuse for an unrelated reason
    # on an unusual host, which would mask the defect this guard exists to name.
    refuse_transient_target || return 1
    choose_target || { err "no scheduler available: no passwordless sudo for a system unit, and no systemd user manager. Install by hand, or give the cell sudo. NOT silently skipping — a reaper that never runs is the failure this exists to remove."; return 1; }
    refuse_systemd_unsafe_values || return 1

    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/disk-reaper-unit.XXXXXX")" || { err "cannot create a temp dir"; return 1; }
    render "$src_svc" "$tmpd/$UNIT_NAME.service" || { rm -rf "$tmpd"; return 1; }
    render "$src_tim" "$tmpd/$UNIT_NAME.timer" || { rm -rf "$tmpd"; return 1; }
    # A USER unit may not carry User= (systemd rejects it), so drop that line in that mode.
    if [ "$TARGET" = "user" ]; then
        sed -i.bak '/^User=/d' "$tmpd/$UNIT_NAME.service" && rm -f "$tmpd/$UNIT_NAME.service.bak"
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_line "dry-run: would install to $UNIT_DIR (target=$TARGET) and enable $UNIT_NAME.timer"
        log_line "--- $UNIT_NAME.service ---"; sed 's/^/  /' "$tmpd/$UNIT_NAME.service"
        log_line "--- $UNIT_NAME.timer ---"; sed 's/^/  /' "$tmpd/$UNIT_NAME.timer"
        rm -rf "$tmpd"
        return 0
    fi

    # Install only when the rendered bytes differ: a `daemon-reload` + restart on every bring-up
    # would reset Persistent= bookkeeping and re-run the pass at every check.
    cmp -s "$tmpd/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.service" || changed=1
    cmp -s "$tmpd/$UNIT_NAME.timer" "$UNIT_DIR/$UNIT_NAME.timer" || changed=1
    mkdir -p "$UNIT_DIR" 2>/dev/null || true
    # ⛔ THE FILE OP FOLLOWS THE TARGET, NOT $SUDO. `TARGET=user` is reachable ONLY when the sudo probe
    # FAILED (choose_target tries the system targets first), so routing a user install through
    # `${SUDO-sudo -n} install` into the user's OWN home asked sudo to do what it had just refused: the
    # copy failed, the installer returned 1, and the branch advertised as "a cell without sudo still
    # gets a clock" could never install at all (measured with a failing sudo shim: "install failed
    # (sudo/systemd)"). The linger guard was correct and unreachable behind it.
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

    # ALWAYS re-read unit files (cheap, idempotent), then make sure the timer is enabled+started.
    $SC daemon-reload >/dev/null 2>&1 || { err "daemon-reload failed"; return 1; }
    # ⛔ THE READ-BACK RUNS BEFORE `enable --now`. A unit that systemd would refuse — or that a drop-in
    # points somewhere else — must not be left ARMED and firing hourly while the installer exits 1; the
    # install has to fail before the clock starts, not after.
    verify_installed_unit || return 1
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
        log_line "  linger: enabled (the user timer survives logout)"
    fi

    log_line "installed: target=$TARGET dir=$UNIT_DIR changed=$changed"
    log_line "  reaper: $REAPER"
    log_line "  mode:   $MODE_FLAG"
    log_line "  repos:  ${REPOS:-<none>}  (worktree floor ${AGED_DAYS}d)"
    log_line "  gh:     ${GH_PREFLIGHT:+$GH_PREFLIGHT — the worktree class will skip every repo (see the WARNING above)}${GH_PREFLIGHT:-authenticated for HOME=$HOME — the PR-state gate can run}"
    log_line "  state:  $STATE_DIR/disk-reaper.status"
    report_gh_resolvable
    if $SC is-enabled "$UNIT_NAME.timer" >/dev/null 2>&1; then
        log_line "  timer:  enabled"
    else
        err "timer is NOT enabled after install — the reaper will not run unattended"; return 1
    fi
    return 0
}

do_status() {
    local next last ACTIVE REC="" REC_RC=0 LAST_RUN=""
    choose_target || { err "no scheduler available"; return 1; }
    log_line "target=$TARGET dir=$UNIT_DIR"
    if [ "$TARGET" = "launchd" ]; then
        # `launchctl list` prints `<pid>\t<last exit>\t<label>` for every loaded job on the machine.
        # Match the WHOLE label (grep -x on the third field), or `com.eldato.disk-reaper` also matches
        # a job whose label merely starts with it and the status answers for the wrong one.
        if ! $SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {found=1} END{exit !found}'; then
            log_line "installed=no"
            [ -f "$UNIT_DIR/$LABEL.plist" ] && log_line "note=plist present at $UNIT_DIR/$LABEL.plist but the agent is NOT loaded"
            # ⛔ rc 1, MATCHING THE SYSTEMD BRANCH BELOW. `cloud-cell-bringup.sh --check` gates CELL
            # READY on this exit code; returning 0 for "not installed" would answer "scheduled?" with a
            # success — the false PASS this installer exists to remove.
            return 1
        else
            log_line "installed=yes"
            log_line "loaded=yes"
            last="$($SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {print $2; exit}')"
            log_line "last_exit=${last:-unknown}"
            # ⛔ ALLOW-LIST, THE SAME ONE THE SYSTEMD ARM USES. A blacklist of 3|4 returned 0 for a
            # loaded agent exiting 1/2/127/203 — and 127/203 is the inert-enforcer shape this installer
            # exists to prevent, while `cloud-cell-bringup.sh --check` gates CELL READY on this rc. A
            # Mac whose job fails every other hour still keeps a fresh record, so a blacklist would have
            # certified it for ever. 0/5/6 are the pass's own success codes; 4 is "the lock dir could not
            # be created"; everything else is a box that is not being reaped.
            case "${last:-}" in
                ''|-|0|5|6|unknown) ;;
                *) err "the last pass exited ${last} — the pass is not completing; see the pass log"; return 1 ;;
            esac
            # `launchctl list`'s first column is the running PID, not a cadence: calling it `interval=`
            # put a process id where a schedule belongs — and cloud-cell-bringup prints `next=` from
            # this block, so every Mac check reported `next=?`.
            log_line "pid=$($SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {print $1; exit}' | sed 's/^-$/not-running/')"
            log_line "cadence=StartInterval=3600"
            log_line "next_run=not reported by launchd (fires every 3600s from load)"
        fi
        if [ -z "$REAPER" ] || [ ! -f "$REAPER" ]; then
            # ⛔ "NO REAPER FILE" IS NOT "NO NEWS". The systemd arm reports this state as unjudgeable and
            # fails; this arm used to skip the record block entirely and answer 0 having judged nothing.
            err "no disk-reaper.sh found to read a pass record from — cannot determine whether this box is being reaped"
            return 1
        fi
        if [ -n "$REAPER" ] && [ -f "$REAPER" ]; then
            log_line "--- pass record ---"
            REC="$(bash "$REAPER" --print-status 2>&1)"; REC_RC=$?
            printf '%s\n' "$REC" | sed 's/^/  /'
            # ⛔ GATE THE RECORD'S RC, NOT `ok`. `ok=0` is TRUE for a delegate refusal (rc 6) and for an
            # apply-mode below-floor pass (rc 5) — both of which the unit file and the exit table call
            # GREEN, and both of which are the DOCUMENTED expected state on a busy cell. Gating `ok`
            # failed healthy cells and made the "5 and 6 stay GREEN" rule a few lines above dead.
            # What a human must look at is rc 3 (MISCONFIGURED) or rc 4 (a removal FAILED / the lock
            # could not be taken) — and `stale`, which means the job stopped running.
            _rst="$(printf '%s\n' "$REC" | sed -n 's/^status=//p' | head -1)"
            _rrc="$(printf '%s\n' "$REC" | sed -n 's/^rc=//p' | head -1)"
            case "${_rst:-}" in
                never)
                    # Not a failure BY ITSELF (a fresh install runs a pass at load); it IS one when the
                    # scheduler says the job ran and exited badly.
                    # ALLOW-LIST, not a blacklist of 3|4: any other non-zero (2 usage, 127 not-found,
                    # 203 the inert-enforcer signal) is also a box that is not being reaped. The same
                    # polarity the merge rail uses — an unnamed value must never fall through green.
                    case "${last:-}" in
                        ''|-|0|5|6|unknown) log_line "note=no pass has completed yet (the agent runs one at load, then hourly)" ;;
                        *) err "the job last exited $last and no pass record exists — the pass is refusing before it can record anything"; return 1 ;;
                    esac ;;
                stale) err "the last pass is STALE — the job is loaded but it is not running"; return 1 ;;
                failed|ok) case "${_rrc:-}" in
                        0|5|6) ;;
                        *) err "the last pass exited ${_rrc:-(no rc recorded)} — a human must look; see the pass log"; return 1 ;;
                    esac ;;
                '') err "--print-status exited ${REC_RC:-?} without a status line — cannot determine whether this box is being reaped"; return 1 ;;
            esac
        fi
        return 0
    fi
    if ! $SC cat "$UNIT_NAME.service" >/dev/null 2>&1; then
        log_line "installed=no"
        return 1
    fi
    log_line "installed=yes"
    log_line "enabled=$($SC is-enabled "$UNIT_NAME.timer" 2>/dev/null || echo no)"
    ACTIVE="$($SC is-active "$UNIT_NAME.timer" 2>/dev/null || echo no)"
    log_line "timer_active=$ACTIVE"
    next="$($SC list-timers --all --no-pager 2>/dev/null | awk -v u="$UNIT_NAME.timer" '$0 ~ u {print $1" "$2" "$3; exit}')"
    log_line "next_run=${next:-unknown}"
    LAST_RUN="$($SC show -p ExecMainStatus --value "$UNIT_NAME.service" 2>/dev/null || echo unknown)"
    log_line "last_run=$LAST_RUN"
    REC=""; REC_RC=0
    if [ -n "$REAPER" ] && [ -f "$REAPER" ]; then
        log_line "--- pass record ---"
        REC="$(bash "$REAPER" --print-status 2>&1)"; REC_RC=$?
        printf '%s\n' "$REC" | sed 's/^/  /'
    fi
    # ⛔ AN ENABLED-BUT-INACTIVE TIMER IS NOT A SCHEDULE. This returned 0 whatever it had just printed,
    # and `cloud-cell-bringup.sh --check` dies only on a non-zero rc — so a timer that will never fire
    # certified CELL READY: the inert-enforcer shape, in the verb meant to detect it.
    case "${ACTIVE:-}" in
        active|activating) ;;
        *) err "the timer is '${ACTIVE:-unknown}', not active — the reaper will NOT run unattended"; return 1 ;;
    esac
    # ⛔ AND THE PASS RECORD IS GATED, EXACTLY AS ON THE LAUNCHD ARM — on its RC, not on `ok`, so a
    # delegate refusal (6) or a below-floor pass (5) stays GREEN. Plus the SCHEDULER's own last run: a
    # pass that refuses at STARTUP writes no record at all, so the previous `ok=1` record stays fresh for
    # up to STALE_SECONDS — the unit's own exit status is the only witness in that window.
    # ⛔ ALLOW-LIST. 0 is a clean pass; 6 is a DEFERRAL (a delegate declined, or another pass held this
    # reaper's lock — the documented state of a busy cell); 5 is the dry run's "here is the work I would
    # do", which a `--report-only` install produces by design. Everything else — 3 (a class failed
    # closed), 4 (a removal failed), 2, 127 (the command-not-found of an inert unit), 203 (systemd's
    # exec failure), a signal — is a box that is not being reaped, or one a human must look at.
    case "${LAST_RUN:-}" in
        ''|-|0|5|6) ;;
        unknown)
            # ⛔ "CANNOT READ THE LAST RUN" IS NOT "THE LAST RUN WAS FINE". This arm exists for the window
            # where a pass refuses at STARTUP — it then writes no record, the previous `ok=1` record stays
            # fresh for up to DISK_REAPER_STALE_SECONDS, and the unit's own exit status is the ONLY witness.
            # Discarding that witness certified a box whose every tick had failed.
            err "cannot read the timer's last run (systemctl show refused) — cannot determine whether the pass is completing"; return 1 ;;
        *) err "the timer's last run exited ${LAST_RUN} — the pass is not completing; see the pass log"; return 1 ;;
    esac
    _rst="$(printf '%s\n' "$REC" 2>/dev/null | sed -n 's/^status=//p' | head -1)"
    _rrc="$(printf '%s\n' "$REC" 2>/dev/null | sed -n 's/^rc=//p' | head -1)"
    case "${_rst:-}" in
        never)
            case "${LAST_RUN:-}" in
                # 5/6 are the pass's own success codes: a first tick that lost the lock (5, and it writes
                # NO record) is documented-benign, so it must not fail readiness on a healthy cell — the
                # launchd arm allows exactly the same set.
                ''|-|0|5|6|unknown) log_line "note=no pass has completed yet (the timer's first tick has not run)" ;;
                *) err "the timer's last run exited $LAST_RUN and no pass record exists — the pass is refusing before it can record anything"; return 1 ;;
            esac ;;
        stale) err "the last pass is STALE — the timer is enabled but the pass is not running: $(printf '%s\n' "$REC" | sed -n 's/^detail=//p' | head -1)"; return 1 ;;
        failed|ok) case "${_rrc:-}" in
                0|5|6) ;;
                *) err "the last pass exited ${_rrc:-(no rc recorded)} — a human must look; see the pass log"; return 1 ;;
            esac ;;
        '') err "--print-status exited ${REC_RC:-?} without a status line — cannot determine whether this box is being reaped"; return 1 ;;
    esac
    return 0
}

do_uninstall() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_line "dry-run: would disable and remove the installed schedule (nothing was changed)"
        return 0
    fi
    choose_target || { err "no scheduler available"; return 1; }
    if [ "$TARGET" = "launchd" ]; then
        # ⛔ A DISARM IS NOT DONE BECAUSE `bootout` RETURNED. The plist file can be gone while the LOADED
        # job keeps firing hourly until logout, and `--status` would then answer `installed=no` about a
        # reaper that is still deleting. Prove the label is gone (the same read the install path uses).
        $SC bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || $SC unload "$UNIT_DIR/$LABEL.plist" >/dev/null 2>&1 || true
        rm -f "$UNIT_DIR/$LABEL.plist"
        if $SC list 2>/dev/null | awk -v l="$LABEL" '$NF==l {found=1} END{exit !found}'; then
            err "$LABEL is STILL LOADED after bootout — it will keep firing hourly; log out or reboot, or bootout gui/$(id -u)/$LABEL by hand"
            return 1
        fi
        log_line "uninstalled $LABEL from $UNIT_DIR (not loaded)"
        return 0
    fi
    $SC disable --now "$UNIT_NAME.timer" >/dev/null 2>&1 || true
    # Same rule as the install: the file op follows the TARGET. For a user unit the files are the
    # user's own, so a `rm -f` through `${SUDO-sudo -n}` fails silently and the box reports itself
    # uninstalled while the (armed) unit files remain for the next daemon-reload to resurrect.
    case "$TARGET" in
        user) rm -f "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer" \
                  || { err "cannot remove the unit files from $UNIT_DIR (target=user)"; return 1; } ;;
        override) rm -f "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer" \
                  || { err "cannot remove the unit files from $UNIT_DIR (target=override)"; return 1; } ;;
        *)    ${SUDO-sudo -n} rm -f "$UNIT_DIR/$UNIT_NAME.service" "$UNIT_DIR/$UNIT_NAME.timer" \
                  || { err "cannot remove the unit files from $UNIT_DIR (target=system)"; return 1; } ;;
    esac
    $SC daemon-reload >/dev/null 2>&1 || true
    # ⛔ VERIFY ON EVERY ARM — BUT DO NOT OVER-BLOCK ON A LEGITIMATE OTHER SCOPE. The cycle-2 fix
    # checked survival only for `TARGET=user`, so the other two arms could report "uninstalled" with the
    # files still present (measured: an override rm into a root-owned dir → "Permission denied" →
    # `uninstalled … (target=override)`, rc 0, both files present; and a capability rotation where the
    # install used one scope and `--uninstall` re-derived another, leaving a LIVE ARMED unit at rc 0).
    # So: the RESOLVED scope must be empty or the uninstall FAILS. A different scope holding the same
    # unit is REPORTED, not failed — a cell can legitimately carry a system-scope install while an
    # operator uninstalls a user-scope one, and failing that would be a false block on the only way to
    # remove it (measured: a real /etc/systemd/system install made every user-target uninstall rc=1).
    if [ -e "$UNIT_DIR/$UNIT_NAME.service" ] || [ -e "$UNIT_DIR/$UNIT_NAME.timer" ]; then
        err "NOT reporting this as uninstalled — the unit files are STILL PRESENT in $UNIT_DIR (target=$TARGET)"
        err "(an enabled timer here still fires the armed pass; remove them as the right user, then re-run)"
        return 1
    fi
    # ⛔ AND A DIFFERENT $HOME. The user scope is re-derived from the CURRENT $HOME, so an install made
    # from another context (a bring-up harness, a different login) leaves its unit in a directory this
    # run cannot even see — measured: `HOME=$HOME_B --uninstall` printed `uninstalled … (target=user)`,
    # rc 0, while the ARMED hourly unit from `$HOME_A` kept firing. Scan the other homes too.
    # `DISK_REAPER_EXTRA_SCOPES` (colon-separated) is a TEST SEAM: it only ADDS directories to this read-only
    # scan, so the "another scope is reported" branch can be asserted on a clean CI runner instead of only
    # on a host that happens to carry a system-wide install. Production sets nothing.
    for d in "$HOME/.config/systemd/user" /root/.config/systemd/user /home/*/.config/systemd/user /etc/systemd/system \
             $(printf '%s' "${DISK_REAPER_EXTRA_SCOPES:-}" | tr ':' ' '); do
        [ -n "$d" ] || continue
        [ "$d" = "$UNIT_DIR" ] && continue
        if [ -e "$d/$UNIT_NAME.service" ] || [ -e "$d/$UNIT_NAME.timer" ]; then
            err "note: $UNIT_NAME is ALSO installed in $d (another scope) — this removed $UNIT_DIR only"
            err "      an enabled timer THERE still fires the armed pass; uninstall it from that scope"
        fi
    done
    log_line "uninstalled $UNIT_NAME from $UNIT_DIR (target=$TARGET)"
    return 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --install)   MODE=--install ;;
        --dry-run)   DRY_RUN=1 ;;
        --report-only) MODE_FLAG="--dry-run"; MODE_SUCCESS_EXIT="0 5 6" ;;
        --status)    MODE=--status ;;
        --uninstall) MODE=--uninstall ;;
        --help|-h)   help_text; exit $? ;;
        *) usage ;;
    esac
    shift
done

case "$MODE" in
    --install)   do_install ;;
    --status)    do_status ;;
    --uninstall) do_uninstall ;;
esac
