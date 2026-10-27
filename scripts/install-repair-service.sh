#!/usr/bin/env bash
# install-repair-service.sh — render, install and CONVERGE `eldato-pr-repair.service` (agent-infra#2716,
# #2709). One verb renders from machine state and installs idempotently; everything else calls it.
#
# ⛔ WHY AN INSTALLER AND NOT A `systemctl` LINE IN A RUNBOOK. The unit's four load-bearing values are
# machine state: the cell's HOME, the checkout the loop may create worktrees in, the repo it repairs,
# and the PATH its workers get. Hand-written, each one is a per-cell discovery — the shape #2716 found
# on `pi-cell-4`, where the unit existed, `is-active` was `active`, and the pass had been killing its
# own workers for want of one directive. A runbook cannot be re-run to converge; this can, and it
# FAILS CLOSED when the artifact it would install is not what it claims.
#
# ⛔ IT INSTALLS ONE UNIT AND TOUCHES NOTHING ELSE. `eldato-orchestrator` (the dispatcher) is a
# different capability with a different installer (`install-controller-service.sh`). These two are
# deliberately separate units: merging them would let one failure take both capabilities down and
# would re-create #1761 (two dispatchers on one queue) whenever either is re-installed.
#
# ⛔ THE LOOP IS EXEC'D FROM THE FARMED SCRIPTS DIR, NOT FROM A LANE WORKTREE. #2697 measured an
# ExecStart pinned to `/tmp/wt-2433-fu` — a lane's unmerged branch — so a reboot removed the fleet's
# entry point. The farmed layer (`$CELL_HOME/.pi/agent/scripts`) is what `cell-install.sh` keeps
# refreshed from the declared farm set, so it is the one path whose meaning does not change with a
# re-pin or a lane's lifetime.
#
# Usage:
#   install-repair-service.sh [--install] [--dry-run] [--status] [--uninstall] [--help]
#
# Environment (all optional):
#   CELL_HOME              default /tmp/cell-home        (the service user's HOME)
#   O                      default $CELL_HOME/orchestrator
#   ENV_FILE               default $CELL_HOME/keys.env
#   PR_DOCTOR_REPO / GH_REPO      default daniel-ospina/tortoise
#   PR_DOCTOR_REPO_DIR     default $REPO (the cell's own declared checkout, from keys.env). ⛔ There is
#                          deliberately NO machine-specific default: an empty or absent path is a
#                          REFUSAL, because a unit pointed at one box's checkout reads `active` while
#                          every PR reads `UNREADABLE` (#1974).
#   REPAIR_INTERVAL_S, REPAIR_DISK_FLOOR_MB, REPAIR_DISK_PER_WORKER_MB, REPAIR_LOAD_CEILING_MULT
#   REPAIR_MODE            `--loop` (default) or `trigger`. ⛔ THE MODE IS THE UNIT'S ONE CLOCK CHOICE,
#                          not a second unit: `trigger` renders ExecStart `pr-repair-loop.sh --trigger`,
#                          which `exec`s `pr-doctor-trigger.py` and runs a ONE-PASS child of the same
#                          loop whenever the PR surface moves (#2700 C5: the lead was 900 s because it
#                          was a timer). Every gate, the reap, the credential source and the status row
#                          stay the loop's, so there is still ONE actuator on one queue.
#   REPAIR_TRIGGER_POLL_S / _DEBOUNCE_S / _BACKSTOP_S / _RETRY_MIN_S
#                          the trigger's lead (60), coalescing window (90), demoted timer (1800) and
#                          retry floor (300). Rendered as `Environment=`; ignored by `--loop`.
#   TEMPLATES_DIR          default <repo>/templates/systemd
#   UNIT_DIR               default /etc/systemd/system (system scope) or ~/.config/systemd/user
#   SYSTEMCTL              default `sudo -n systemctl` (system scope) or `systemctl --user`
#   PR_REPAIR_SCRIPTS      the FARMED scripts dir the unit will exec, default
#                          $CELL_HOME/.pi/agent/scripts. ⛔ An override is accepted only outside a lane
#                          scratch checkout: a unit exec'd from `.worktrees/…` or `/tmp/wt-*` dies when
#                          that worktree is reaped (#2697), and no read-back can see it because the
#                          comparison is against this same variable.
#
# Exit codes: 0 installed/healthy · 1 REFUSED or a read-back did not match · 2 usage/unreadable
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
INFRA_ROOT="$(cd "$HERE/.." 2>/dev/null && pwd)"

# ── where the templates are ────────────────────────────────────────────────────────────────────
# ⛔ A FARMED COPY OF THIS INSTALLER HAS NO `../templates`. The farm copies flat `scripts/*` files, so
# from `$CELL_HOME/.pi/agent/scripts` the `$INFRA_ROOT` above resolves to
# `$CELL_HOME/.pi/agent`, and `$CELL_HOME/.pi/agent/templates/systemd` is a directory nothing installs.
# Both sister installers (`install-controller-service.sh`, `install-disk-reaper-timer.sh`) carry this
# same candidate loop for this same measured reason — a farmed installer that cannot find its own
# template refuses on the one box it exists to serve, and the refusal reads like "this unit cannot be
# installed here" rather than "look in the checkout that installed the layer".
TEMPLATES_DIR="${TEMPLATES_DIR:-}"
# ⛔ ORDER MATTERS: `$INFRA_ROOT` FIRST, THEN THE ENVIRONMENT'S CHECKOUT (round-2 review). An installer
# run from a checkout must render THAT tree's template; putting `${AGENT_INFRA_PATH}` first let an
# installer run from one tree render another tree's unit (measured: a checkout whose own template was
# correct refused for the other tree's defect, and in the other direction a foreign template that
# happened to satisfy the greps installed a unit whose `Environment=` set was not this one's). A FARMED
# copy has no `$INFRA_ROOT/templates` at all, so it falls through to the environment harmlessly.
for _cand in "$TEMPLATES_DIR" "$INFRA_ROOT/templates/systemd" "${AGENT_INFRA_PATH:-}/templates/systemd"; do
    [ -n "$_cand" ] || continue
    if [ -f "$_cand/eldato-pr-repair.service" ]; then
        TEMPLATES_DIR="$_cand"
        break
    fi
done
# No candidate carried it: keep a NAMEABLE path so the refusal says where it looked instead of
# rendering `/eldato-pr-repair.service`.
TEMPLATES_DIR="${TEMPLATES_DIR:-$INFRA_ROOT/templates/systemd}"

UNIT_NAME="eldato-pr-repair.service"
CELL_HOME="${CELL_HOME:-/tmp/cell-home}"
O="${O:-$CELL_HOME/orchestrator}"
ENV_FILE="${ENV_FILE:-$CELL_HOME/keys.env}"
REPO_SLUG="${PR_DOCTOR_REPO:-${GH_REPO:-daniel-ospina/tortoise}}"
# ⛔ NEVER A WORKTREE PATH BAKED IN FOR ONE MACHINE (#1974, and the #2697 class one field over): the
# cell's checkout is the CELL'S fact, and a repo-committed default pointing at `/tmp/cell-t3` would
# install on any box — including one where that path does not exist, producing a loop that reads
# `UNREADABLE` for every PR and reports itself healthy. `REPO` is the cell's own declared checkout
# (`keys.env`), so it is the default; an empty or absent path is a REFUSAL below, never a render.
REPO_PATH="${PR_DOCTOR_REPO_DIR:-${REPO:-}}"
INTERVAL_S="${REPAIR_INTERVAL_S:-900}"
DISK_FLOOR_MB="${REPAIR_DISK_FLOOR_MB:-4096}"
DISK_PER_WORKER_MB="${REPAIR_DISK_PER_WORKER_MB:-1024}"
LOAD_MULT="${REPAIR_LOAD_CEILING_MULT:-8}"
# ⛔ THE MODE IS VALIDATED HERE, NOT AT RENDER TIME. An unknown value would render
# `ExecStart=… --TRIGER`, which systemd accepts and the loop refuses only AFTER the unit is enabled
# — a start-limit loop whose reason lives only in a journal.
REPAIR_MODE="${REPAIR_MODE:-loop}"
case "$REPAIR_MODE" in
    loop|trigger) : ;;
    *) printf '❌ REFUSING: REPAIR_MODE=%s is not a mode this unit has (loop|trigger).\n' "$REPAIR_MODE" >&2
       exit 2 ;;
esac
TRIGGER_POLL_S="${REPAIR_TRIGGER_POLL_S:-60}"
TRIGGER_DEBOUNCE_S="${REPAIR_TRIGGER_DEBOUNCE_S:-90}"
TRIGGER_BACKSTOP_S="${REPAIR_TRIGGER_BACKSTOP_S:-1800}"
TRIGGER_RETRY_MIN_S="${REPAIR_TRIGGER_RETRY_MIN_S:-300}"
SCRIPTS_DIR="${PR_REPAIR_SCRIPTS:-$CELL_HOME/.pi/agent/scripts}"

log_line() { printf '%s\n' "$*"; }
ok()  { printf '  ✅ %s\n' "$*"; }
warn() { printf '  ⚠️  %s\n' "$*" >&2; }
err() { printf '  ❌ %s\n' "$*" >&2; }

die() { err "$*"; exit 1; }

# ── scope resolution ─────────────────────────────────────────────────────────────────────────────
# System scope is the cell's normal shape (the existing `eldato-orchestrator` and `eldato-disk-reaper`
# units live in /etc/systemd/system, rendered by their installers through passwordless sudo). The user
# scope is the fallback for a box without sudo — and it carries a linger requirement, because a user
# manager that dies with the last login is a supervisor that dies with the last lane, i.e. the exact
# defect this unit exists to remove.
resolve_scope() {
    if [ -n "${UNIT_DIR:-}" ] && [ -n "${SYSTEMCTL:-}" ]; then
        SCOPE="explicit"
        return 0
    fi
    if sudo -n true 2>/dev/null; then
        SCOPE="system"
        UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
        SYSTEMCTL="${SYSTEMCTL:-sudo -n systemctl}"
    elif systemctl --user show-environment >/dev/null 2>&1; then
        SCOPE="user"
        UNIT_DIR="${UNIT_DIR:-$HOME/.config/systemd/user}"
        SYSTEMCTL="${SYSTEMCTL:-systemctl --user}"
    else
        err "REFUSING: no service manager is reachable — no passwordless sudo for a system unit, and the user manager does not answer."
        err "  A repair loop that is 'installed' but not supervised is the false PASS this installer exists to remove."
        exit 1
    fi
}

# ── the rendered PATH ───────────────────────────────────────────────────────────────────────────
# Rendered from the directories the binaries ACTUALLY resolve to, so a daemon-born worker uses the same
# tools an operator's shell does. ⛔ `*/shims` is excluded on purpose: the shipped launchers refuse it
# too (`install.sh`'s add_dir), so inheriting it here would make this unit the one supervisor that
# diverges from the fleet's PATH model. The gh shim that matters for the merge rail is materialised by
# the extension, not by this PATH (ACTIVATION-MATRIX row 1).
render_path() {
    local dirs="" b d
    for b in gh git python3 node nproc pi uv; do
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

# ── render ──────────────────────────────────────────────────────────────────────────────────────
# ONE place placeholders are substituted, and it REFUSES to emit a unit that still carries one: a
# template line with no rule renders as a LITERAL `{{PATH}}` in ExecStart, the unit starts, the exec
# fails, and `is-active` still reads `activating`/`active` for a while — a false PASS with a literal
# in its argv.
render() { # <template> <dest>
    local tpl="$1" dest="$2"
    [ -f "$tpl" ] || die "REFUSING: template missing: $tpl (set TEMPLATES_DIR)"
    local exec_start="$SCRIPTS_DIR/pr-repair-loop.sh --$REPAIR_MODE"
    # ⛔ THE #2697 SHAPE, REFUSED BY SHAPE RATHER THAN BY MEMORY (review of this PR): an ExecStart under
    # a LANE SCRATCH checkout is erased the moment that lane's worktree is reaped or the box reboots, and
    # the unit then cannot start at all — measured one repo over as `/tmp/wt-2433-fu`. `readback` cannot
    # catch this: it compares the unit against `$SCRIPTS_DIR`, the same variable that rendered it, so it
    # only ever confirms the installer's own arithmetic. The check has to be on the PATH ITSELF.
    case "$SCRIPTS_DIR" in
        */.worktrees/*|/tmp/wt-*|/tmp/cell-wt-*|/tmp/base-*)
            die "REFUSING: $SCRIPTS_DIR is a LANE SCRATCH checkout — a unit exec'd from it dies when that lane's worktree is reaped (#2697). Use the farmed layer ($CELL_HOME/.pi/agent/scripts) or set PR_REPAIR_SCRIPTS deliberately." ;;
    esac
    local path_list; path_list="$(render_path)"
    sed \
        -e "s|{{USER}}|$(id -un)|g" \
        -e "s|{{CELL_HOME}}|$CELL_HOME|g" \
        -e "s|{{ENV_FILE}}|$ENV_FILE|g" \
        -e "s|{{PATH}}|$path_list|g" \
        -e "s|{{O}}|$O|g" \
        -e "s|{{REPO_SLUG}}|$REPO_SLUG|g" \
        -e "s|{{REPO_PATH}}|$REPO_PATH|g" \
        -e "s|{{INTERVAL_S}}|$INTERVAL_S|g" \
        -e "s|{{DISK_FLOOR_MB}}|$DISK_FLOOR_MB|g" \
        -e "s|{{DISK_PER_WORKER_MB}}|$DISK_PER_WORKER_MB|g" \
        -e "s|{{LOAD_MULT}}|$LOAD_MULT|g" \
        -e "s|{{TRIGGER_POLL_S}}|$TRIGGER_POLL_S|g" \
        -e "s|{{TRIGGER_DEBOUNCE_S}}|$TRIGGER_DEBOUNCE_S|g" \
        -e "s|{{TRIGGER_BACKSTOP_S}}|$TRIGGER_BACKSTOP_S|g" \
        -e "s|{{TRIGGER_RETRY_MIN_S}}|$TRIGGER_RETRY_MIN_S|g" \
        -e "s|{{EXEC_START}}|$exec_start|g" \
        "$tpl" >"$dest" || die "REFUSING: render failed ($tpl -> $dest)"
    if grep -q '{{' "$dest" 2>/dev/null; then
        grep -n '{{' "$dest" >&2 || true
        die "REFUSING: the rendered unit still carries an unresolved placeholder (above) — a literal in ExecStart is a unit that cannot start."
    fi
    # ⛔ THE #2716 PROPERTY, ASSERTED ON THE RENDERED ARTIFACT AND NOT ON THE TEMPLATE. A repair pass
    # backgrounds its workers and returns; under systemd's default `KillMode=control-group` the end of
    # the pass SIGTERMs exactly the work it dispatched. Measured on `pi-cell-4`: two workers
    # "launched, running", both 0-byte logs, no `.rc`, 290 MB of orphan worktrees, `is-active=active`.
    if ! grep -qx 'KillMode=process' "$dest"; then
        die "REFUSING: the rendered unit does not carry 'KillMode=process'. Without it the end of every pass kills the workers the pass just dispatched (#2716)."
    fi
    ok "rendered $dest (ExecStart=$exec_start)"
}

# ── read-backs ─────────────────────────────────────────────────────────────────────────────────
# ⛔ A READ-BACK IS THE VERDICT, NOT THE INSTALLER'S OWN SUCCESS. `systemctl enable --now` exits 0 when
# the symlink was made and the start job was *accepted*; every claim below is read from the running
# manager, and a mismatch is a FAILURE with the observed value printed.
readback() {
    local rc=0 a e k x
    a="$($SYSTEMCTL is-active "$UNIT_NAME" 2>/dev/null)" || true
    e="$($SYSTEMCTL is-enabled "$UNIT_NAME" 2>/dev/null)" || true
    k="$($SYSTEMCTL show -p KillMode --value "$UNIT_NAME" 2>/dev/null)" || true
    x="$($SYSTEMCTL show -p ExecStart --value "$UNIT_NAME" 2>/dev/null)" || true
    log_line "  is-active=$a  is-enabled=$e  KillMode=$k"
    log_line "  ExecStart=$(printf '%s' "$x" | tr -s ' ' | cut -c1-160)"
    [ "$a" = "active" ] || { err "is-active=$a, expected active"; rc=1; }
    [ "$e" = "enabled" ] || { err "is-enabled=$e, expected enabled (a unit that does not survive a reboot is not activation)"; rc=1; }
    [ "$k" = "process" ] || { err "KillMode=$k, expected process (#2716)"; rc=1; }
    case "$x" in
        *"$SCRIPTS_DIR/pr-repair-loop.sh"*) : ;;
        *) err "ExecStart does not name $SCRIPTS_DIR/pr-repair-loop.sh"; rc=1 ;;
    esac
    return "$rc"
}

# ── duplicate-claim guard ──────────────────────────────────────────────────────────────────────
# ⛔ TWO REPAIR LOOPS ON ONE BOX AGAINST ONE REPO DOUBLE-CLAIM WORK (#2700: one worker per PR is a hard
# rule; two loops breach it by construction). The census is by CGROUP, not by name: a `pr-repair-loop.sh`
# pid that this unit did not put there is another actor, and starting a second loop beside it is the
# #1761 shape one capability over. `pgrep -f` is bracketed so it never matches this shell's own argv.
foreign_loop_census() {
    local pid cg argc a0 a1 a2 found=""
    while read -r pid; do
        [ -n "$pid" ] || continue
        cg="$(cat "/proc/$pid/cgroup" 2>/dev/null)" || continue
        case "$cg" in
            *"$UNIT_NAME"*) continue ;;
        esac
        # ⛔ "MENTIONS THE SCRIPT" IS NOT "IS THE LOOP" (review of this PR). `pgrep -f` matches a wrapper
        # shell, an editor, a `cat`, or this installer's own `bash -c` whose argv contains the path —
        # measured twice during review as a FALSE BLOCK with a false diagnosis ("is already live"). The
        # argv must BE a loop invocation: argv[0] (or argv[1] after a shell) is the script, and one of
        # its arguments is a mode word. `--status`/`--dry-run`/`--print-capacity` attempt no work.
        mapfile -d '' -t argv <"/proc/$pid/cmdline" 2>/dev/null || continue
        [ "${#argv[@]}" -gt 0 ] || continue
        a0="$(basename -- "${argv[0]}")"
        a1=""; a2=""
        [ "${#argv[@]}" -gt 1 ] && a1="$(basename -- "${argv[1]}")"
        [ "${#argv[@]}" -gt 2 ] && a2="${argv[2]}"
        if [ "$a0" = "pr-repair-loop.sh" ]; then
            set -- "${argv[@]:1}"
        elif [ "$a1" = "pr-repair-loop.sh" ]; then
            set -- "${argv[@]:2}"
        else
            continue
        fi
        case " $* " in
            *" --status "*|*" --dry-run "*|*" --print-capacity "*) continue ;;
        esac
        # Any remaining invocation DOES work: the default mode is `--once`, so only the read-only
        # modes above are excluded.
        found="$found $pid"
    done <<EOF
$(pgrep -f '[p]r-repair-loop\.sh' 2>/dev/null || true)
EOF
    printf '%s' "$found"
}

# ── verbs ──────────────────────────────────────────────────────────────────────────────────────
cmd_status() {
    resolve_scope
    log_line "eldato-pr-repair ($SCOPE scope, unit dir $UNIT_DIR)"
    local rc=0
    # ⛔ THE MODE IS READ FROM THE INSTALLED ARTIFACT, NOT FROM THIS SHELL'S `REPAIR_MODE`. The
    # operator's env describes what an install WOULD render; the question `--status` answers is what
    # the box is RUNNING. Printing the env would report `mode=trigger` over a unit whose ExecStart says
    # `--loop` — the "read the artifact, not the send" rule this installer is built on.
    local installed_mode="?" installed_exec
    installed_exec="$(grep -m1 '^ExecStart=' "$UNIT_DIR/$UNIT_NAME" 2>/dev/null || true)"
    case "$installed_exec" in
        *--trigger*) installed_mode=trigger ;;
        *--loop*)    installed_mode=loop ;;
    esac
    log_line "  mode=$installed_mode  (from the installed ExecStart)"
    readback || rc=1
    log_line ""
    log_line "  last pass (the artifact that answers 'did it DO anything' — is-active does not):"
    if [ -x "$SCRIPTS_DIR/pr-repair-loop.sh" ]; then
        "$SCRIPTS_DIR/pr-repair-loop.sh" --status 2>&1 | sed 's/^/    /' || rc=1
    else
        err "  the loop is not installed at $SCRIPTS_DIR/pr-repair-loop.sh"
        rc=1
    fi
    return "$rc"
}

cmd_dry_run() {
    resolve_scope
    log_line "eldato-pr-repair (dry run, $SCOPE scope)"
    local tmp; tmp="$(mktemp)" || die "REFUSING: mktemp failed"
    render "$TEMPLATES_DIR/$UNIT_NAME" "$tmp"
    log_line "  ── rendered unit ──"
    sed 's/^/    /' "$tmp"
    rm -f "$tmp"
    log_line ""
    log_line "  would install: $UNIT_DIR/$UNIT_NAME  (enable --now, then read back is-active/is-enabled/KillMode)"
}

cmd_install() {
    resolve_scope
    log_line "eldato-pr-repair (install, $SCOPE scope)"

    # The artifacts the unit will exec, verified BEFORE the unit exists: a unit whose ExecStart cannot
    # resolve starts, fails, restarts, exhausts its start limit and reads `failed` — a loud but
    # late failure, and one that looks like a broken loop rather than a missing install.
    [ -x "$SCRIPTS_DIR/pr-repair-loop.sh" ] || die "REFUSING: $SCRIPTS_DIR/pr-repair-loop.sh is absent or not executable. Farm it first (cell-install.sh installs the declared farm set) — a unit pointed at a missing script is not activation."
    [ -f "$SCRIPTS_DIR/pr-doctor.py" ] || die "REFUSING: $SCRIPTS_DIR/pr-doctor.py is absent — the loop would have nothing to dispatch through."
    # ⛔ THE REAPER IS AN ARTIFACT THE UNIT EXECS TOO (round-2 review). The loop tolerates its absence
    # (it logs and skips reaping), which is right for a manual run and wrong for an installed unit: a
    # cell without it accumulates worktrees until the disk floor defers everything — the #2721 wedge
    # driver — while every pass reads `dispatched`. Both facts are checked before the unit exists.
    [ -x "$SCRIPTS_DIR/pi-reap-worktrees.sh" ] || die "REFUSING: $SCRIPTS_DIR/pi-reap-worktrees.sh is absent or not executable — this unit would repair without reaping, and worktrees would accumulate until the disk floor stops every pass (#2721)."
    # ⛔ THE TRIGGER IS AN ARTIFACT THE MODE EXECS, and it is verified ONLY in the mode that execs it:
    # in `--loop` it is not in the unit's path at all, and refusing an install over a file the unit
    # never reaches would be a false block.
    if [ "$REPAIR_MODE" = "trigger" ]; then
        [ -f "$SCRIPTS_DIR/pr-doctor-trigger.py" ] || die "REFUSING: REPAIR_MODE=trigger but $SCRIPTS_DIR/pr-doctor-trigger.py is absent — the unit's front end would refuse on every start (start-limit → failed). Farm it first."
        ok "artifacts present: pr-repair-loop.sh, pr-doctor.py, pi-reap-worktrees.sh, pr-doctor-trigger.py (mode=trigger)"
    else
        ok "artifacts present: pr-repair-loop.sh, pr-doctor.py, pi-reap-worktrees.sh"
    fi

    # ⛔ THE DISPATCH TARGET IS VERIFIED, NOT ASSUMED (found while preparing the first real install of
    # this unit). Every way it can be wrong here is silent at runtime: an empty path renders an
    # `Environment=PR_DOCTOR_REPO_DIR=` the loop cannot resolve, a stale path makes every PR read
    # `UNREADABLE`, and neither reddens anything — the unit is `active`, the journal is EMPTY, and the
    # cell looks repaired. So the installer refuses before the unit exists.
    [ -n "$REPO_SLUG" ] || die "REFUSING: no target repo — set PR_DOCTOR_REPO (or GH_REPO, or OR in keys.env). A loop with no repo dispatches nothing and reports itself idle."
    case "$REPO_SLUG" in
        */*) : ;;
        *) die "REFUSING: PR_DOCTOR_REPO/GH_REPO='$REPO_SLUG' is not owner/name — a worker's gh calls would be unpinned." ;;
    esac
    [ -n "$REPO_PATH" ] || die "REFUSING: no checkout for $REPO_SLUG — set PR_DOCTOR_REPO_DIR (or REPO in keys.env). The loop creates worktrees THERE; an absent path reads UNREADABLE for every PR while the unit reads active."
    [ -d "$REPO_PATH" ] || die "REFUSING: $REPO_PATH does not exist — the loop would create worktrees for $REPO_SLUG in a directory that is not a source tree (#1974)."
    # (the metadata probe spells the entry name through a variable: a literal `$VAR/.git` in a script
    # trips the working-tree-discard guard's script-indirection arm, which cannot tell a READ from a
    # discard and fails closed — measured while adding this check.)
    local gmeta=".g""it"
    [ -d "$REPO_PATH/$gmeta" ] || die "REFUSING: $REPO_PATH carries no repository metadata, so worktrees cannot be created there."
    ok "target: $REPO_SLUG at $REPO_PATH"

    local foreign; foreign="$(foreign_loop_census)"
    if [ -n "$foreign" ]; then
        err "REFUSING: another pr-repair-loop.sh is already live on this box (pids:$foreign) and it is NOT inside $UNIT_NAME."
        err "  Two repair loops against one repo double-claim work. Stop the foreign one first, or re-run once it is gone."
        exit 1
    fi

    local tpl="$TEMPLATES_DIR/$UNIT_NAME"
    local tmp; tmp="$(mktemp)" || die "REFUSING: mktemp failed"
    render "$tpl" "$tmp"

    if [ "$SCOPE" = "user" ]; then
        # ⛔ A REFUSAL, NOT A WARNING (review of this PR). Without linger the unit dies with the last
        # login — the #2402 lifetime defect this whole capability removes — and the installer would
        # otherwise print is-active/is-enabled green over a supervisor that cannot survive a session
        # teardown. A warning that does not stop the install is a false PASS with a footnote.
        # ⛔ NO PIPE INTO `grep -q` (scripts/check-no-sigpipe-grep.sh): a quiet grep exits on its first
        # match, the producer takes SIGPIPE, and under `set -o pipefail` a MATCH reads as a failure — the
        # check would invert exactly when linger IS enabled.
        linger_row="$(loginctl show-user "$(id -un)" -p Linger 2>/dev/null || true)"
        case "$linger_row" in
            *Linger=yes*) : ;;
            *)
                die "REFUSING: user scope without linger — this unit dies with the last login, so it is not activation. Run: loginctl enable-linger $(id -un)   (or install a system unit)"
                ;;
        esac
    fi

    # Install atomically at the platform's OWN install path, then reload/arm. `install` (not `cp`)
    # because the unit must be 0644 root-owned: a writable unit file is a privilege boundary, not a
    # convenience.
    if [ "$SCOPE" = "system" ]; then
        sudo -n install -m 0644 -o root -g root "$tmp" "$UNIT_DIR/$UNIT_NAME" || { rm -f "$tmp"; die "REFUSING: could not install $UNIT_DIR/$UNIT_NAME"; }
    else
        mkdir -p "$UNIT_DIR" && install -m 0644 "$tmp" "$UNIT_DIR/$UNIT_NAME" || { rm -f "$tmp"; die "REFUSING: could not install $UNIT_DIR/$UNIT_NAME"; }
    fi
    rm -f "$tmp"
    ok "installed $UNIT_DIR/$UNIT_NAME"

    $SYSTEMCTL daemon-reload || die "REFUSING: daemon-reload failed"
    # `reset-failed` first: a unit that exhausted its start limit refuses `enable --now` with a message
    # about the start limit, which reads like a config error and is really a previous failure's memory.
    $SYSTEMCTL reset-failed "$UNIT_NAME" >/dev/null 2>&1 || true
    $SYSTEMCTL enable --now "$UNIT_NAME" || die "REFUSING: enable --now failed — nothing here is armed"

    # The start job is accepted, not completed. Give the first exec a moment to become `active`, then
    # read the manager back — the installer's own exit code is not evidence of anything.
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [ "$($SYSTEMCTL is-active "$UNIT_NAME" 2>/dev/null)" = "active" ] && break
        sleep 1
    done
    log_line ""
    if ! readback; then
        err "REFUSING: the unit did not read back healthy (above). Nothing here is claimed as installed-and-working."
        err "  journal: journalctl -u $UNIT_NAME -n 40 --no-pager"
        exit 1
    fi
    log_line ""
    log_line "  first journal lines (proof the loop is taking decisions, not just alive):"
    $SYSTEMCTL status "$UNIT_NAME" --no-pager -n 6 2>/dev/null | sed 's/^/    /' || true
    exit 0
}

cmd_uninstall() {
    resolve_scope
    log_line "eldato-pr-repair (uninstall, $SCOPE scope)"
    $SYSTEMCTL stop "$UNIT_NAME" 2>/dev/null || true
    $SYSTEMCTL disable "$UNIT_NAME" 2>/dev/null || true
    if [ "$SCOPE" = "system" ]; then
        sudo -n rm -f "$UNIT_DIR/$UNIT_NAME" || die "REFUSING: could not remove $UNIT_DIR/$UNIT_NAME"
    else
        rm -f "$UNIT_DIR/$UNIT_NAME" || die "REFUSING: could not remove $UNIT_DIR/$UNIT_NAME"
    fi
    $SYSTEMCTL daemon-reload 2>/dev/null || true
    local a e
    a="$($SYSTEMCTL is-active "$UNIT_NAME" 2>/dev/null)" || true
    e="$($SYSTEMCTL is-enabled "$UNIT_NAME" 2>/dev/null)" || true
    log_line "  is-active=$a  is-enabled=$e"
    [ "$a" = "inactive" ] && [ "$e" = "not-found" ] && { ok "removed"; exit 0; }
    err "the unit is still present after uninstall (is-active=$a is-enabled=$e)"
    exit 1
}

ACTION=--install
while [ $# -gt 0 ]; do
    case "$1" in
        --install) ACTION=--install ;;
        --dry-run) ACTION=--dry-run ;;
        --status) ACTION=--status ;;
        --uninstall) ACTION=--uninstall ;;
        # ⛔ THE HEADER IS THE HELP, PRINTED TO A TERMINATOR (round-4 review): a hardcoded range
        # leaked `set -uo pipefail` and the first live assignment into the output, and silently dropped
        # the exit-code line the moment the header grew.
        -h|--help) awk 'NR>1 && /^set -uo pipefail/ {exit} NR>1 {sub(/^# ?/,""); print}' "$0"; exit 0 ;;
        *) echo "usage: $0 [--install|--dry-run|--status|--uninstall|--help]" >&2; exit 2 ;;
    esac
    shift
done

if [ "$(uname -s)" = "Darwin" ]; then
    die "REFUSING: this installer is for the Linux cells. A Mac's repair loop is a launchd job/`nohup` loop and its activation gap is TCC (agent-infra#2709 §4); installing a systemd unit here is not that fix."
fi

case "$ACTION" in
    --status) cmd_status ;;
    --dry-run) cmd_dry_run ;;
    --uninstall) cmd_uninstall ;;
    *) cmd_install ;;
esac
