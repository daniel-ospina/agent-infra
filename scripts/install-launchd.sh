#!/usr/bin/env bash
# install-launchd.sh — idempotent installer for agent-infra launchd templates
# (agent-infra #304).
#
# Renders templates/launchd/*.plist with machine env, diffs the rendered
# output against the installed copy in ~/Library/LaunchAgents, and only
# reloads (enable → bootout → bootstrap) on change. Byte-identical → skip.
# Converges any machine to the canonical scheduled state; safe to run on
# every sync (this is the propagation trigger: a merged template bump applies
# on the next run).
#
# Placeholders substituted from env (with machine defaults):
#   {{HOME}}              $HOME (required)
#   {{PATH}}              the installer's PATH (launchd's default PATH lacks
#                         homebrew/bin — the alert jobs need `gh` on it), with the
#                         pi shim directory removed: launchd cannot exec into
#                         ~/.pi/agent/shims (symlinks into ~/Documents, TCC EPERM,
#                         #427/#1719)
#   {{AGENT_INFRA_PATH}}  this repo's MAIN checkout (env overrides; worktree-safe)
#   {{TORTOISE_REPO}}     env, else ~/Documents/GitHub/tortoise, else sibling ../tortoise
#   {{SWARM_ROOT}}        env only ("if present" — no auto-detect; canary is
#                         skipped on machines without one)
#   {{SWARM_ENV_FILE}}    env, else $HOME/.swarm.env
#   {{PYTHON_BIN}}        $SWARM_ROOT/.venv/bin/python, else `command -v python3`
#   {{PI_BIN_DIR}}        dirname of `command -v pi`, else /usr/local/bin
#
# A template that still contains an unresolved {{PLACEHOLDER}} is skipped with
# a loud warning (e.g. corruption-canary on a machine with no swarm root).
# A template whose script target does not resolve (broken symlink / missing
# file) is a HARD FAILURE — a dead job must never be installed.
#
# Usage:
#   install-launchd.sh               install/refresh all templates (idempotent)
#   install-launchd.sh --status      per-job: installed? loaded? version? drift?
#   install-launchd.sh --uninstall   bootout + remove installed plists
#   install-launchd.sh --arm-worktree-hygiene [--reason TEXT]
#                                    ARM the worktree-hygiene sweep on THIS box
#                                    (writes a dated record, refuses unless the
#                                    sweep's prerequisites resolve, then
#                                    installs). Ships DISARMED — see #1678.
#   install-launchd.sh --disarm-worktree-hygiene
#                                    reverse it: the job goes back to --dry-run
#   install-launchd.sh --arm-orphan-reaper [--reason TEXT]
#                                    ARM the orphan reaper on THIS box (#1863):
#                                    writes the dated record that renders
#                                    REAP_ORPHAN_DRY_RUN=0, refuses unless the
#                                    farmed script the job execs is present,
#                                    then reinstalls. Ships DISARMED — #1142.
#   install-launchd.sh --disarm-orphan-reaper
#                                    reverse it: the job goes back to dry-run
#   install-launchd.sh --help
#
# Env overrides (also used by install-launchd.test.sh):
#   TEMPLATES_DIR   template dir (default: this repo's templates/launchd)
#   AGENTS_DIR      install dir   (default: $HOME/Library/LaunchAgents)
#   WORKTREE_HYGIENE_ARM_FILE   the arming record (default:
#                   $HOME/.pi/agent/state/worktree-hygiene.armed)
#   REAP_ORPHAN_ARM_FILE        the arming record (default:
#                   $HOME/.pi/agent/state/pi-reap-orphans.armed)
#   ELDATO_ALLOW_TEST_HOME   permit launchd management when $HOME is not the
#                            real user home (tests ONLY — requires a launchctl
#                            shim on PATH so nothing reaches the real domain)
#
# Exit codes: 0 = ok (or clean skip), 1 = failure (loud), 2 = usage error.
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES_DIR="${TEMPLATES_DIR:-$INFRA_ROOT/templates/launchd}"
AGENTS_DIR="${AGENTS_DIR:-${HOME:?HOME is required}/Library/LaunchAgents}"
DOMAIN="gui/$(id -u)"

# The range is literal and moves with the header: it ends on `set -uo pipefail`,
# exactly as it did before the {{PATH}} note above was added.
usage() { sed -n '2,64p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

# ── THE PLACEHOLDER CONTRACT ──────────────────────────────────────────────────────────────────
# ONE list, TWO consumers: `render` substitutes every name here, and `install_job` SKIPS a template
# whose name resolves empty. Before this array existed those were two hand-kept lists in this file,
# and `scripts/fleet-schedule.py` (the cell/Linux renderer) held a third — so a name added here and
# not there turned the same shipped template into a hard ERROR on every cell.
#
# ⛔ THAT IS NOT HYPOTHETICAL. #2639 added AI_DRAINER_* / AI_MULTI_REPO_* to this file only. On
# 2026-10-27 cell4 (vm-ce2c2fc9fd844a32851d46c3723b903e) refused to start a scheduler at all —
# `systemctl start eldato-orchestrator` → active (activating), MainPID=0, no controller, no reap,
# no liveness, no canary — because the shipped ai-drainer template carried two names the cell
# runtime did not know.
#
# The tuple in scripts/fleet-schedule.py is the other half of the contract, and
# `scripts/fleet-schedule.test.sh` COMPARES the two (plus the {{NAME}} tokens actually present in
# templates/launchd/*.plist) so drift reddens. Add a name in BOTH files, or the suite fails.
PLIST_PLACEHOLDERS=(
    HOME
    PATH
    AGENT_INFRA_PATH
    TORTOISE_REPO
    SWARM_ROOT
    SWARM_ENV_FILE
    PYTHON_BIN
    PI_BIN_DIR
    WORKTREE_HYGIENE_MODE
    REAP_ORPHAN_MODE
    AI_DRAINER_O
    AI_DRAINER_STATE
    AI_MULTI_REPO_SLUG
    AI_MULTI_REPO_REPO
    AI_MULTI_REPO_STATE
)

# Resolve this repo's MAIN checkout (not a worktree) so installed jobs point
# at a stable path that survives worktree teardown. `git worktree list
# --porcelain` lists the main checkout first.
resolve_infra_main() {
    local main
    if command -v git >/dev/null 2>&1; then
        main="$(git -C "$INFRA_ROOT" worktree list --porcelain 2>/dev/null \
            | sed -n 's/^worktree //p' | head -1 || true)"
    fi
    if [ -n "${main:-}" ] && [ -d "$main" ]; then
        echo "$main"
    else
        echo "$INFRA_ROOT"
    fi
}

resolve_env() {
    AGENT_INFRA_PATH="${AGENT_INFRA_PATH:-$(resolve_infra_main)}"
    TORTOISE_REPO="${TORTOISE_REPO:-}"
    if [ -z "$TORTOISE_REPO" ] || [ ! -d "$TORTOISE_REPO" ]; then
        for cand in "$HOME/Documents/GitHub/tortoise" "$INFRA_ROOT/../tortoise" "$HOME/tortoise"; do
            if [ -d "$cand" ] && [ -d "$cand/.git" ]; then
                TORTOISE_REPO="$(cd "$cand" && pwd)"
                break
            fi
        done
    fi
    SWARM_ROOT="${SWARM_ROOT:-}"   # env-only: a machine with no swarm root has no canary job
    SWARM_ENV_FILE="${SWARM_ENV_FILE:-$HOME/.swarm.env}"
    if [ -x "${SWARM_ROOT:-}/.venv/bin/python" ]; then
        PYTHON_BIN="${PYTHON_BIN:-$SWARM_ROOT/.venv/bin/python}"
    else
        PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
    fi
    if [ -n "${PI_NODE_BIN:-}" ]; then
        PI_BIN_DIR="$(dirname "$PI_NODE_BIN")"
    elif command -v pi >/dev/null 2>&1; then
        PI_BIN_DIR="$(dirname "$(command -v pi)")"
    else
        PI_BIN_DIR="/usr/local/bin"
    fi
    # Materialised here (never an env default the job reads at run time) so that
    # --status and the installed unit both say plainly whether this box deletes.
    WORKTREE_HYGIENE_MODE="$(wt_hygiene_mode)"
    REAP_ORPHAN_MODE="$(reap_orphan_mode)"
    # ⛔ ENV-ONLY, NO DEFAULTS, like {{SWARM_ROOT}} above — and here the reason is stronger than
    # "which host has the canary": `install-launchd.sh` with no arguments installs EVERY template in
    # templates/launchd/, and pi-bootstrap/setup.sh runs exactly that on every Darwin box. A default
    # for these two jobs would (a) put a lane DISPATCHER on the whole fleet and (b) start a SECOND
    # CONTROLLER per box, which double-dispatches every queue. Unset → the template is SKIPPED with a
    # loud warning naming the variable, so activation is an explicit, per-box operator step:
    #   AI_DRAINER_O=… AI_DRAINER_STATE=… bash scripts/install-launchd.sh
    #   AI_MULTI_REPO_SLUG=… AI_MULTI_REPO_REPO=… AI_MULTI_REPO_STATE=… bash scripts/install-launchd.sh
    AI_DRAINER_O="${AI_DRAINER_O:-}"
    AI_DRAINER_STATE="${AI_DRAINER_STATE:-}"
    AI_MULTI_REPO_SLUG="${AI_MULTI_REPO_SLUG:-}"
    AI_MULTI_REPO_REPO="${AI_MULTI_REPO_REPO:-}"
    AI_MULTI_REPO_STATE="${AI_MULTI_REPO_STATE:-}"
}

# launchd_path — the PATH a rendered plist receives: {{PATH}} minus the pi SHIM directory.
#
# agent-infra#1719. `~/.pi/agent/shims` holds symlinks INTO ~/Documents (e.g.
# shims/gh -> <repo>/scripts/gh-shim/gh), a tree launchd cannot read: macOS TCC refuses the exec
# with EPERM (#427). It is FIRST on an interactive session's PATH — and sync.sh runs this installer
# FROM such a session — so every plist rendered from {{PATH}} began with a directory no launchd job
# can execute from, and a job's `gh` resolved to an unrunnable symlink. A scheduled job must never
# be handed a PATH element launchd cannot use, so the shim dir is dropped at render time; the real
# binaries later in PATH are what the jobs are meant to find.
#
# ⛔ RESOLVE THE PHYSICAL PATH, do not match the NAME (review E2). It is the shim's TARGET that
# launchd cannot read, so a PATH entry that is a SYMLINK to the shim directory matches no literal
# pattern and would be rendered verbatim into every job — re-creating the EPERM the helper exists
# to prevent. `scripts/orchestrator-harness/install.sh:add_dir()` resolves `pwd -P` for exactly
# this reason and warns against a name test; this mirrors it.
# ⛔ But only `*/shims`/`*/shims/*` are dropped, NOT all of `*/.pi/*`: `~/.pi/agent/bin` holds the
# REAL `fd`/`rg` binaries and is outside the TCC-protected tree, so install.sh's blanket `.pi`
# exclusion (harmless there — it adds resolved tool paths selectively) would cost these jobs
# tools they use. The LOGICAL path is kept so the version-independent pi symlink is not pinned.
# An entry that does not resolve is dropped too — launchd cannot resolve a tool from it.
launchd_path() {
    local out="" p phys glob_was_off=0
    local IFS=:
    # ⛔ A PATH entry is a path, never a glob pattern (review D3). `for p in $PATH` splits on IFS=:
    # as intended, but it ALSO pathname-expands each entry, so an entry containing `*`/`?`/`[...]`
    # was silently expanded into whatever it matched (`/a*` → `/aa:/ab`) or dropped when it matched
    # nothing — a job PATH the installer's own shell never had. The base renderer substituted the
    # QUOTED `$PATH`, so this expansion arrived with this helper; suppress it here rather than
    # relying on the caller's `set -f`, and restore the caller's own setting on the way out.
    case "$-" in *f*) glob_was_off=1 ;; esac
    set -f
    for p in $PATH; do
        case "$p" in "") continue ;; esac
        # ⛔ `CDPATH= cd` and not a bare `cd` (review B4-2): `cd` honours the CDPATH search path, so an
        # entry that does NOT resolve could still be kept — contradicting this function's own contract
        # ("an entry that does not resolve is dropped too"). Measured: with CDPATH exported and
        # containing `phantom`, `PATH=phantom:/real` rendered `phantom` into the plist.
        phys="$(CDPATH= cd -- "$p" 2>/dev/null && pwd -P)" || continue
        case "$phys" in */shims | */shims/*) continue ;; esac
        out="${out:+$out:}$p"
    done
    [ "$glob_was_off" = 1 ] || set +f
    printf '%s' "$out"
}

# sed_repl — make a string safe as the REPLACEMENT half of `s|…|…|g` AND safe in the XML text node it
# lands in.
#
# agent-infra#1719 (review D2-3). TWO escapes are needed, and the XML one is not optional:
#   * `&` in a sed replacement expands to the WHOLE MATCH and `\` starts an escape, so a value
#     carrying either is silently corrupted into the rendered plist (a PATH entry containing `&`
#     rendered as `a{{PATH}}b`, with nothing to catch it — `verify_targets` inspects ProgramArguments
#     only, and the pre-render placeholder guard greps the TEMPLATE, not the output).
#   * the value lands inside `<string>`, so `&` is the XML entity introducer: an unescaped one makes
#     the plist MALFORMED. Measured — a `&` in a PATH entry failed `plutil -lint`, i.e. the installer
#     would have written a plist launchd cannot parse.
# XML-escape FIRST (so the entity's own `&` is then sed-escaped, not re-expanded), then sed-escape.
# The `|` delimiter must be escaped too, since that is the separator this file's sed uses.
sed_repl() {
    printf '%s' "$1" \
        | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        | sed -e 's/[&\\|]/\\&/g'
}

# ── worktree-hygiene ARMING (#1678; PR #2053 review finding 1) ──────────────
#
# com.tortoise.worktree-hygiene is a DELETION tool: on a 6-hourly timer it runs
# pi-reap-worktrees.sh (removes worktree CHECKOUTS) and branch_reaper.py
# (removes local BRANCH REFS). The recorded rule (#1678, owner ruling
# 2026-10-11: "the reaper may run unattended; arming it may not") is that such a
# tool SHIPS DRY-RUN and that arming is a separate, dated, reversible step.
#
# WHY A PLACEHOLDER AND NOT A LITERAL `--dry-run`: a literal cannot be armed by
# anything, so the "separate step" would be a hand-edit of the installed plist —
# invisible to git, unreproducible on the next box, and silently reverted by the
# next sync (the gap #1678 requirement 3 names). A literal `--apply` is worse:
# `install-launchd.sh` with NO ARGUMENTS installs EVERY template, and
# pi-bootstrap/setup.sh runs exactly that on every Darwin box, so a literal arms
# a fleet from a merged template with no human step at all. Hence:
#
#   * the template carries {{WORKTREE_HYGIENE_MODE}}, which renders --dry-run;
#   * --apply is renderable only from a DATED RECORD in this box's own state dir,
#     written by --arm-worktree-hygiene and removed by --disarm-worktree-hygiene;
#   * there is NO environment default that can arm it (an env var is ambient: it
#     would arm the job from a stray export, and nothing on disk would show it);
#   * the armed state IS the installed unit's ProgramArguments, so a `cat` of
#     ~/Library/LaunchAgents/com.tortoise.worktree-hygiene.plist and
#     `install-launchd.sh --status` both answer "is this box deleting?" without
#     reading code.
#
# ⛔ ARMING REFUSES A BOX THAT CANNOT RUN THE SWEEP. The failure that makes this
# loader inert is silent: the engine is a FARMED script that sources sibling
# libraries from its own directory, and when one did not land the engine exits 3
# on every pass — an armed 6-hourly job that deletes nothing and (because launchd
# records an exit code nobody reads) looks installed and healthy. So arming runs
# the sweep's OWN `--preflight` first and refuses, naming the missing file. A
# record whose lines do not both survive a truncation renders DISARMED: a
# half-written arming file must never count as an arming.
WT_HYGIENE_ARM_FILE="${WORKTREE_HYGIENE_ARM_FILE:-$HOME/.pi/agent/state/worktree-hygiene.armed}"
wt_hygiene_mode() {
    if [ -f "$WT_HYGIENE_ARM_FILE" ] \
        && grep -q '^armed-by=.' "$WT_HYGIENE_ARM_FILE" 2>/dev/null \
        && grep -q '^armed-date=.' "$WT_HYGIENE_ARM_FILE" 2>/dev/null; then
        printf '%s' '--apply'
    else
        printf '%s' '--dry-run'
    fi
}

# The script the INSTALLED unit executes. The farmed copy is what launchd runs
# (#427: launchd cannot read a ~/Documents checkout), so it is also what must be
# preflighted — preflighting the repo copy on a box that never farmed this sweep
# would bless a job pointed at a file that does not exist.
wt_hygiene_target() {
    local farmed="$HOME/.pi/agent/scripts/worktree-hygiene-sweep.sh"
    if [ -f "$farmed" ]; then printf '%s' "$farmed"; else printf '%s' "$INFRA_ROOT/scripts/worktree-hygiene-sweep.sh"; fi
}

arm_worktree_hygiene() { # $1 = optional reason
    local reason="${1:-}" target rc
    target="$(wt_hygiene_target)"
    if [ -f "$WT_HYGIENE_ARM_FILE" ]; then
        echo "  worktree-hygiene: ALREADY ARMED — $(sed -n 's/^armed-date=/since /p' "$WT_HYGIENE_ARM_FILE" | head -1)"
        echo "    record: $WT_HYGIENE_ARM_FILE (not re-dated: the date is the audit datum)"
        return 0
    fi
    # ⛔ The farmed copy must exist: it is what ProgramArguments names.
    if [ ! -f "$HOME/.pi/agent/scripts/worktree-hygiene-sweep.sh" ]; then
        echo "ERROR: refusing to arm worktree-hygiene: the farmed copy the job executes is absent" >&2
        echo "       ($HOME/.pi/agent/scripts/worktree-hygiene-sweep.sh)." >&2
        echo "       Run pi-bootstrap/setup.sh first — arming a unit whose target does not exist" >&2
        echo "       produces a job launchd cannot start (an inert 6-hourly 'success')." >&2
        return 1
    fi
    echo "  worktree-hygiene: preflight before arming ($target)"
    if ! bash "$target" --preflight --repo "${TORTOISE_REPO:-}" ; then
        rc=$?
        echo "ERROR: refusing to arm worktree-hygiene: its prerequisites do not resolve (see above)." >&2
        echo "       An armed pass would exit 6 every 6h and delete nothing. Fix the named" >&2
        echo "       prerequisite (usually: re-run pi-bootstrap/setup.sh to refresh the farm)," >&2
        echo "       then re-run this command. Nothing was armed (rc=$rc)." >&2
        return 1
    fi
    mkdir -p "$(dirname "$WT_HYGIENE_ARM_FILE")" 2>/dev/null || {
        echo "ERROR: cannot create $(dirname "$WT_HYGIENE_ARM_FILE") — refusing to arm" >&2; return 1; }
    {
        printf 'armed-by=%s\n' "$(id -un 2>/dev/null || printf 'unknown')"
        printf 'armed-date=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
        printf 'armed-host=%s\n' "$(hostname 2>/dev/null || printf 'unknown')"
        printf 'repo=%s\n' "${TORTOISE_REPO:-<unset>}"
        printf 'reason=%s\n' "${reason:-<none given>}"
    } > "$WT_HYGIENE_ARM_FILE" || {
        echo "ERROR: cannot write $WT_HYGIENE_ARM_FILE — refusing to arm" >&2; rm -f "$WT_HYGIENE_ARM_FILE"; return 1; }
    echo "  worktree-hygiene: ARMED ($WT_HYGIENE_ARM_FILE) — the installed unit now passes --apply"
    return 0
}

disarm_worktree_hygiene() {
    if [ -f "$WT_HYGIENE_ARM_FILE" ]; then
        echo "  worktree-hygiene: disarming — the record being removed:"
        sed 's/^/    /' "$WT_HYGIENE_ARM_FILE"
        rm -f "$WT_HYGIENE_ARM_FILE" || {
            echo "ERROR: cannot remove $WT_HYGIENE_ARM_FILE — the job is STILL ARMED" >&2; return 1; }
        echo "  worktree-hygiene: DISARMED — the installed unit goes back to --dry-run"
    else
        echo "  worktree-hygiene: not armed (no $WT_HYGIENE_ARM_FILE)"
    fi
    return 0
}

# ── orphan-reaper ARMING (#1863 review ISSUE 2, P2) ────────────────────────
#
# com.eldato.pi-reap-orphans is a KILLER on an hourly timer. #1142's acceptance
# criterion is that it "exists, is scheduled, and logs what it kills; dry-run by
# default", and the reaper policy forbids an unowned always-on killer — so the
# template shipped `<key>REAP_ORPHAN_DRY_RUN</key><string>1</string>` as a
# LITERAL. That literal made the documented arming step UNREACHABLE, which is
# the defect this block fixes: the plist note, README §6.5.5 and the PR body all
# described arming as a per-machine, owned, dated decision — while nothing could
# perform it. The only lever was hand-editing the installed plist, which the
# next `install_job()` render silently reverted (`mv "$tmp" "$installed"`), so
# an operator who "armed" a box would believe a killer was running while every
# pass still wrote `MODE=dry-run` — the installed-but-inert shape #1862 exists to
# eliminate.
#
# The mechanism is the one this repo already ruled for deletion tools (#1678,
# PR #2053): a PLACEHOLDER that renders the SAFE value, plus a DATED RECORD in
# the box's own state dir as the only way to render the armed value.
#
#   * the template carries {{REAP_ORPHAN_MODE}}, which renders `1` (= dry-run);
#   * `0` (= armed) is renderable ONLY from `$REAP_ORPHAN_ARM_FILE` carrying BOTH
#     `armed-by=` and `armed-date=`, written by --arm-orphan-reaper and removed
#     by --disarm-orphan-reaper;
#   * there is NO environment default that can arm it (an ambient export would
#     arm a fleet with nothing on disk to show for it);
#   * the armed state IS the installed unit's EnvironmentVariables, so `cat` of
#     the plist and `--status` both answer "is this box killing?" without
#     reading code;
#   * a half-written record renders DISARMED — a truncated arming file must never
#     count as an arming (fail-closed, same as the worktree record).
#
# ⛔ ARMING REFUSES A BOX THAT CANNOT RUN THE PASS. `ProgramArguments` execs the
# FARMED copy (`~/.pi/agent/scripts/pi-reap-orphans.sh`; launchd cannot read
# ~/Documents under macOS TCC, #427), so arming a box that never farmed it
# produces a unit launchd cannot start and whose failure nobody reads. The repo
# copy is NOT an acceptable substitute: it is not what the job runs.
REAP_ORPHAN_ARM_FILE="${REAP_ORPHAN_ARM_FILE:-$HOME/.pi/agent/state/pi-reap-orphans.armed}"
reap_orphan_mode() {
    if [ -f "$REAP_ORPHAN_ARM_FILE" ] \
        && grep -q '^armed-by=.' "$REAP_ORPHAN_ARM_FILE" 2>/dev/null \
        && grep -q '^armed-date=.' "$REAP_ORPHAN_ARM_FILE" 2>/dev/null; then
        printf '%s' '0'      # REAP_ORPHAN_DRY_RUN=0 => --apply passes
    else
        printf '%s' '1'      # the shipped, default, safe value
    fi
}

arm_orphan_reaper() { # $1 = optional reason
    local reason="${1:-}" farmed="$HOME/.pi/agent/scripts/pi-reap-orphans.sh"
    if [ -f "$REAP_ORPHAN_ARM_FILE" ]; then
        echo "  orphan-reaper: ALREADY ARMED — $(sed -n 's/^armed-date=/since /p' "$REAP_ORPHAN_ARM_FILE" | head -1)"
        echo "    record: $REAP_ORPHAN_ARM_FILE (not re-dated: the date is the audit datum)"
        return 0
    fi
    # ⛔ The FARMED copy must exist: it is what ProgramArguments names.
    if [ ! -f "$farmed" ]; then
        echo "ERROR: refusing to arm the orphan reaper: the farmed copy the job execs is absent" >&2
        echo "       ($farmed). Run pi-bootstrap/setup.sh first — arming a unit whose" >&2
        echo "       target does not exist produces an hourly job launchd cannot start." >&2
        return 1
    fi
    # ⛔ The script must PARSE as what the job execs. A syntax error here is a
    # silent hourly failure (launchd records an exit code nobody reads), so it is
    # refused at arming time rather than discovered in the log afterwards.
    if ! bash -n "$farmed" 2>/dev/null; then
        echo "ERROR: refusing to arm the orphan reaper: $farmed does not parse (bash -n)." >&2
        echo "       An armed pass would fail hourly and kill nothing." >&2
        return 1
    fi
    mkdir -p "$(dirname "$REAP_ORPHAN_ARM_FILE")" 2>/dev/null || {
        echo "ERROR: cannot create $(dirname "$REAP_ORPHAN_ARM_FILE") — refusing to arm" >&2; return 1; }
    {
        printf 'armed-by=%s\n' "$(id -un 2>/dev/null || printf 'unknown')"
        printf 'armed-date=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
        printf 'armed-host=%s\n' "$(hostname 2>/dev/null || printf 'unknown')"
        printf 'repo=%s\n' "${TORTOISE_REPO:-<unset>}"
        printf 'reason=%s\n' "${reason:-<none given>}"
    } > "$REAP_ORPHAN_ARM_FILE" || {
        echo "ERROR: cannot write $REAP_ORPHAN_ARM_FILE — refusing to arm" >&2; rm -f "$REAP_ORPHAN_ARM_FILE"; return 1; }
    echo "  orphan-reaper: ARMED ($REAP_ORPHAN_ARM_FILE) — every hourly pass now signals"
    return 0
}

disarm_orphan_reaper() {
    if [ -f "$REAP_ORPHAN_ARM_FILE" ]; then
        echo "  orphan-reaper: disarming — the record being removed:"
        sed 's/^/    /' "$REAP_ORPHAN_ARM_FILE"
        rm -f "$REAP_ORPHAN_ARM_FILE" || {
            echo "ERROR: cannot remove $REAP_ORPHAN_ARM_FILE — the job is STILL ARMED" >&2; return 1; }
        echo "  orphan-reaper: DISARMED — every hourly pass goes back to reporting only"
    else
        echo "  orphan-reaper: not armed (no $REAP_ORPHAN_ARM_FILE)"
    fi
    return 0
}

render() {
    # $1 = template path → stdout rendered plist
    # ⛔ BOTH THIS AND install_job()'s unset-placeholder check read PLIST_PLACEHOLDERS, so a name can
    # no longer be rendered here and forgotten there (or vice versa). {{PATH}} is rendered through
    # the launchd_path transform, not the raw env value — see the TCC note above launchd_path().
    local -a args=()
    local ph
    for ph in "${PLIST_PLACEHOLDERS[@]}"; do
        if [ "$ph" = PATH ]; then
            args+=(-e "s|{{PATH}}|$(sed_repl "$(launchd_path)")|g")
        else
            args+=(-e "s|{{$ph}}|$(sed_repl "${!ph:-}")|g")
        fi
    done
    sed "${args[@]}" "$1"
}

version_of() {
    sed -n 's/.*agent-infra-plist-version: \([0-9][0-9.]*\).*/\1/p' "$1" | head -1
}

job_label() {
    basename "$1" .plist
}

# The plist READER, resolved independently of the CALLER'S PATH. The installer deliberately PINS a
# PATH for the jobs it renders and a caller may hand it a filtered one (§ the all-shim fixture), so a
# reader that only answers `command -v` disappears exactly when the install is being verified. That
# is not a hypothetical: it turned every job into a FAIL in that fixture once "could not read" became
# a refusal. python3 lives in a standard location on every supported box; PlistBuddy is the fallback.
plist_python() {
    local c
    for c in "$(command -v python3 2>/dev/null)" /usr/bin/python3 /usr/local/bin/python3 \
             /opt/homebrew/bin/python3; do
        [ -n "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

# Print absolute-path ProgramArguments entries as `<kind>\t<path>`, one per line
# (python3 plistlib; PlistBuddy fallback — macOS guarantees one of them).
#
# `kind` is one of THREE VALUES, and the third is what the TCC logic hinges on:
#   launcher \u2014 the binary launchd actually execs (`Program`, else argv[0]; plus env's program token);
#   exec     \u2014 a path the job will EXECUTE (the script handed to an interpreter, `--script <path>`);
#   data     \u2014 an absolute value the job's work only READS (the value of `--repo` / `--root`).
# That split is the difference between "launchd cannot EXECUTE this job" and "this job's work cannot
# read its input": only the first two are a reason not to install the unit (see verify_targets).
#
# \u2b1b THE DATA CLASS IS NARROW ON PURPOSE: an absolute element is `data` ONLY when it is the VALUE of
# one of a FEW KNOWN long options that carry something the job's work only READS (`DATA_OPTIONS`
# below: `--repo`, `--root`). `--script <path>` is deliberately NOT one of them \u2014 the reaper launcher
# OPENS that path and pipes it to `bash -s`, so the value IS the executed code and a TCC-protected one
# is a dead unit rather than dead work. Everything else absolute is EXECUTED. The asymmetry is the
# point: a data argument misread as `exec` costs a loud SKIP of one unit (friction), while an executed
# script misread as `data` arms a unit launchd cannot start \u2014 the exact defect this guard exists for.
# Two cheaper rules were falsified in review: "before the first `-`" filed `/bin/bash -e <script>` as
# data, and "the first non-option token is the script" filed `python3 -W error <script>` and
# `bash -o pipefail <script>` as data, because an option's VALUE looked like the script. No positional
# rule can tell `-W error` from `-e script` without knowing each option's arity, so this one does not
# guess.
#
# \u2b1b `Program` IS READ, and it is not optional detail: launchd execs `Program` when that key exists and
# passes `ProgramArguments[0]` as argv[0], so a `Program` pointing into a TCC tree is armed-and-dead
# even when every argv element is farmed and readable (measured, review P3 round 5). The reverse also
# matters: a `Program`-only unit is a VALID launchd unit and must not be refused for having no
# ProgramArguments array.
#
# \u2b1b AND `/usr/bin/env <program> <script>`: `env` is a trampoline, not the executed binary, so its
# program token is promoted to `launcher` \u2014 the same binary at argv[0] and after `env` must be judged
# the same way, or the guard SKIPs and DISARMS a unit it would otherwise install (review P3 round 5).
#
# \u2b1b A RETURN OF NON-ZERO MEANS "COULD NOT READ", NEVER "NO TARGETS" (#1743). An unparseable plist and
# a plist with no absolute argument must not arrive at the caller as the same empty string \u2014 that was
# an empty-as-PASS, where a rendered plist launchd could not parse installed UNVERIFIED. They are now
# separated: non-zero = unreadable, zero + empty output = read but nothing to verify (and
# verify_targets refuses on ITS OWN zero-iteration count, so neither half depends on the other).
# The python reader, emitted on stdout: a FILE, never a here-doc inside a command substitution.
# bash 3.2's `$( )` scanner does not know about here-documents, so the body of a here-doc nested in a
# substitution is walked as ordinary text and one unbalanced quote/paren/backtick desynchronises the
# whole file (#2248/#2930 — `check-bash32-parse.sh` reds it). Keeping the program in a function and
# materialising it into a temp file removes the shape entirely.
plist_reader_py() {
    cat <<'PY'
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as f:
        d = plistlib.load(f)
except Exception:
    sys.exit(3)                      # UNREADABLE — not "no targets"
prog = d.get("Program")
pargs = d.get("ProgramArguments")
def absolute(v):
    return isinstance(v, str) and v.startswith("/")
def env_split(str_):
    # `env -S`'s own grammar: whitespace separates arguments and a BACKSLASH escapes the next character
    # (`\\_` is a literal space, env's documented way to embed one). A plain str.split() leaves
    # `bash\\_/path/x.sh` as ONE token that does not start with "/", so the executed script goes
    # unclassified (fresh review of #3413, P3).
    out = []
    cur = ""
    i = 0
    while i < len(str_):
        ch = str_[i]
        if ch == "\\" and i + 1 < len(str_):
            cur += " " if str_[i + 1] == "_" else str_[i + 1]
            i += 2
            continue
        if ch.isspace():
            if cur:
                out.append(cur)
                cur = ""
            i += 1
            continue
        cur += ch
        i += 1
    if cur:
        out.append(cur)
    return out
if not isinstance(pargs, list) and not absolute(prog):
    sys.exit(4)                      # neither key names anything verifiable
argv = pargs if isinstance(pargs, list) else []
DATA_OPTIONS = {"--repo", "--root"}  # long options whose VALUE the job's work only READS
launchers = []                       # what launchd actually execs
skipped = set()                      # argv indices already reported as a launcher
if absolute(prog):
    launchers.append(prog)           # Program wins; ProgramArguments[0] is then only argv[0]
    if argv:
        skipped.add(0)
elif argv and absolute(argv[0]):
    launchers.append(argv[0])
    skipped.add(0)
# env [OPTS] [NAME=VALUE]... COMMAND [ARG]... — COMMAND is the executed binary, not env.
#
# AND `-S` / `--split-string` IS A COMMAND LINE, not an option value: `env -S '<prog> <script>'` execs
# `<prog>` on `<script>`, so its absolute tokens are EXECUTED and are classified as such. Without this
# the guard saw only an option, skipped the string, and installed a unit whose script lives in a TCC
# tree with NO verdict at all (fresh review of #3413, P3).
if launchers and launchers[-1].rsplit("/", 1)[-1] == "env":
    i = 1
    while i < len(argv):
        a = argv[i]
        if isinstance(a, str):
            if a in ("-S", "--split-string") or a.startswith("--split-string=") or a.startswith("-S"):
                if a in ("-S", "--split-string"):
                    i += 1
                    cmd = argv[i] if i < len(argv) and isinstance(argv[i], str) else ""
                elif a.startswith("--split-string="):
                    cmd = a.split("=", 1)[1]
                    # the ELEMENT carries the command line: mark it consumed, or the loop below
                    # re-reads it as `--opt=<value>` and emits the whole string as ONE path
                    # ("broken target: /bin/bash /x.sh").
                else:
                    cmd = a[2:]         # getopt's JOINED spelling: `-S'<cmd>'` is `-S '<cmd>'`, and
                                        # it is how the form is usually copied out of a shell.
                                        # Without this the string fell into the generic option branch,
                                        # was dropped, and the unit installed with NO verdict at all
                                        # (review of #3413, round 9).
                skipped.add(i)
                # ⛔ THE SAME THREE RULES THE argv LOOP APPLIES, because `-S` IS a command line and a
                # separate `startswith("/")` test made it disagree with the space form in BOTH
                # directions (measured, review of #3413 rounds 8-9):
                #   `-S '/bin/bash --script=<TCC>'`      → no verdict at all, unit INSTALLED
                #   `-S '/bin/bash <ok> --repo <TCC>'`   → filed as EXEC, unit SKIPPED and DISARMED
                #   `-S '<TCC binary> <script>'`         → no launcher promotion, so SKIPPED+DISARMED
                #                                          while the space form WARNs and installs
                #   `-S '<non-executable program>'`      → installed, though launchd cannot exec it
                toks = env_split(cmd)
                seen_prog = False
                for j, tok in enumerate(toks):
                    if not isinstance(tok, str) or not tok:
                        continue
                    if not seen_prog:
                        # env's FIRST POSITIONAL token is the program it execs, so it is a LAUNCHER —
                        # exactly what the space form promotes at argv[1]. An option or a NAME=VALUE
                        # is not the program and does not end the search.
                        if tok.startswith("-") or ("=" in tok and not tok.startswith("/")):
                            continue
                        seen_prog = True
                        if tok.startswith("/"):
                            print("launcher\t" + tok)
                        continue
                    if tok.startswith("--") and "=" in tok:
                        name, val = tok.split("=", 1)
                        if val.startswith("/"):
                            print("%s\t%s" % ("data" if name in DATA_OPTIONS else "exec", val))
                        continue
                    if not tok.startswith("/"):
                        continue
                    prev = toks[j - 1] if j and isinstance(toks[j - 1], str) else ""
                    print("%s\t%s" % ("data" if prev in DATA_OPTIONS else "exec", tok))
                break
            if a.startswith("-") or ("=" in a and not a.startswith("/")):
                i += 1
                continue
            # the FIRST positional token is env's program, absolute or not. A RELATIVE one (bash,
            # python3) is resolved through PATH and cannot be checked here, so it is not promoted —
            # but the scan still STOPS here, because the next absolute token is that program's script,
            # not a second program.
            if a.startswith("/"):
                launchers.append(a)
                skipped.add(i)
            break
        i += 1
for l in launchers:
    print("launcher\t" + l)
for i, a in enumerate(argv):
    if i in skipped or not isinstance(a, str):
        continue
    # --opt=<path> carries its value INSIDE the token, so it is split before the starts-with-"/"
    # test — otherwise the shipped --script=<path> / --repo=<path> spellings are invisible here.
    if a.startswith("--") and "=" in a:
        name, val = a.split("=", 1)
        if val.startswith("/"):
            print("%s\t%s" % ("data" if name in DATA_OPTIONS else "exec", val))
        continue
    if not a.startswith("/"):
        continue
    prev = argv[i - 1] if i and isinstance(argv[i - 1], str) else ""
    print("%s\t%s" % ("data" if prev in DATA_OPTIONS else "exec", a))
PY
}

plist_program_args() {
    local plist="$1" out rc=0 py src
    if py="$(plist_python)"; then
        src="$(mktemp)" || return 1
        if ! plist_reader_py > "$src"; then
            rm -f "$src"
            return 1
        fi
        out="$("$py" "$src" "$plist" 2>/dev/null)" || rc=$?
        rm -f "$src"
        if [ "$rc" -eq 0 ]; then
            [ -n "$out" ] && printf '%s\n' "$out"
            return 0
        fi
        # rc=3/4 (unparseable / no usable key) → try the other guaranteed reader before giving up.
    fi
    # ⛔ THE FALLBACK CANNOT KNOW MOST ROLES, so it emits `unknown` and says so: without python3 there
    # is no `env` hop. `unknown` still carries the TCC verdict (a unit launchd cannot read must never
    # be armed) but NOT the file-type verdict — a directory-valued `--repo` is legitimate, and calling
    # it an "unreadable executed target" aborted the whole install on a PlistBuddy-only host, which is
    # the #3413 P1-A failure all over again. The cost of `unknown` is a false SKIP there (a unit that
    # might have installed is skipped loudly).
    # ⛔ THE THREE ROLES IT **CAN** DERIVE, AND MUST — every one of them is a POSITIONAL FACT, not
    # python knowledge, so there is no reason for the two readers to disagree:
    #   1. `launcher` — `Program` when that key exists (`Print :Program`), else element 0. launchd
    #      execs a BINARY in a TCC root with a grant (#1311), so a reader that called it `unknown`
    #      skipped-and-DISARMED the two `com.tortoise.*` reapers whose argv[0] is
    #      `{{TORTOISE_REPO}}/.venv/bin/python` — measured on this head (fresh review of #3413, P1):
    #      python emitted `launcher` → WARN TCC-root launcher → installed, the fallback emitted
    #      `unknown` → tcc_exec=1 → verdict 2 → `launchctl bootout` + `rm -f` of a working unit, exit 0.
    #   2. `data` — the VALUE of a `DATA_OPTIONS` long option in the PRECEDING element (`--repo`,
    #      `--root`). Leaving it `unknown` did the same to five shipped units on the documented box.
    #   3. `data`/`exec` for the `--opt=<value>` JOINED spelling, which carries its value inside the
    #      token — python splits it (`:649-654`) and the fallback used to drop it silently, so a
    #      `--script=<TCC>` installed armed-and-dead with NO verdict at all.
    # Reachable on any Mac whose `/usr/bin/python3` shim is executable but exits non-zero (no Command
    # Line Tools), because `plist_python` accepts it on `-x` alone. A guard that silently UNINSTALLS
    # working units on the fallback path is the same fail-open/fail-wrong family as `[ -e ]`.
    # WHAT IS STILL `unknown`: an absolute element that is neither the launcher nor a data-option's
    # value (an interpreter's script argument, an `env` program, a second positional). Those keep the
    # TCC verdict and the directory escape — conservative in the SKIP direction, never in the arm one.
    # ⛔ THE DATA_OPTIONS TABLE IS DUPLICATED IN THE PYTHON READER ABOVE (`DATA_OPTIONS = {"--repo",
    # "--root"}`) and this awk cannot share it, so the two must be edited together. Pinned by §7c:
    # (c22b) the data role, (c22c) the launcher role, (c22d) `Program`-only legality and (c22e) the
    # joined `--opt=<value>` spelling; (c22f) the `Program`-wins skip. (c12b) pins the element-index
    # alignment the launcher rule depends on — an empty element still counts.
    # THE SEAM (`INSTALL_LAUNCHD_PLISTBUDDY`) exists so this arm is reachable from a test at all — on
    # Linux `/usr/libexec/PlistBuddy` does not exist, and a branch no test can reach is a branch nobody
    # knows still works.
    local buddy="${INSTALL_LAUNCHD_PLISTBUDDY:-/usr/libexec/PlistBuddy}" raw prog=""
    [ -x "$buddy" ] || return 1
    # `Program` FIRST, and only when it is an absolute path: launchd execs it when the key exists and
    # ProgramArguments[0] is then only argv[0] — exactly the python reader's rule. A missing key makes
    # PlistBuddy exit non-zero, which is "no Program", not "cannot read".
    prog="$("$buddy" -c 'Print :Program' "$plist" 2>/dev/null)" || prog=""
    case "$prog" in /*) ;; *) prog="" ;; esac
    raw="$("$buddy" -c 'Print :ProgramArguments' "$plist" 2>/dev/null)" || raw=""
    # A `Program`-only unit is a legal launchd job (python accepts it: `argv = []`, the `Program` is
    # the launcher), so an absent/empty array is only unusable when there is no `Program` either.
    [ -n "$raw" ] || [ -n "$prog" ] || return 1
    out="$(printf '%s\n' "$raw" | awk -v prog="$prog" '
        BEGIN {
            seen = 0; prev = ""; idx = -1
            # The launcher is emitted BEFORE the argument walk, as the python reader does: the exec
            # arm consults the grant this record establishes, so an order flip changes its verdict.
            if (prog != "") { printf "launcher\t%s\n", prog; seen = 1 }
        }
        # PlistBuddy wraps an array in `Array {` / `}` on their own lines.
        /^[[:space:]]*(Array)?[[:space:]]*\{[[:space:]]*$/ { next }
        /^[[:space:]]*\}[[:space:]]*$/ { next }
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            sub(/^(Arg)?[0-9]+[[:space:]]*=[[:space:]]*/, "", line)
            # ⛔ EVERY ELEMENT ROW ADVANCES idx, EMPTY ONES INCLUDED — the python reader enumerates
            # every element of the list. Skipping an empty row WITHOUT advancing made the next element
            # land at `idx == 0`, where the launcher rule below excused it as argv[0] — so a shape the
            # python reader refused as EXEC was WARNed and INSTALLED on the fallback path, i.e. a new
            # fail-open in exactly the class this change exists to close (fresh review of #3413,
            # round 3 P2). A row IS an element when it carries the PlistBuddy index prefix; a stray
            # blank line does not, and is skipped without counting.
            if (line == "" && $0 !~ /^[[:space:]]*(Arg)?[0-9]+[[:space:]]*=/) next
            seen = 1
            idx++
            if (line == "") next
            # ⛔ `Program` WINS, so element 0 is ONLY argv[0] and is not verdicted at all — exactly the
            # python reader (its `skipped.add(0)`). This test comes BEFORE the joined `--opt=` branch,
            # because with `Program` set python emits nothing for a `--script=<TCC>` at argv[0] while
            # the fallback used to emit `exec` there and SKIP a unit python installs (round 3 P2).
            if (idx == 0 && prog != "") { prev = line; next }
            # `--opt=<path>` carries its value INSIDE the token (python splits it at `:649-654`);
            # dropping it made a `--script=<TCC>` install with no verdict at all.
            if (line ~ /^--/ && index(line, "=") > 0) {
                name = substr(line, 1, index(line, "=") - 1)
                val = substr(line, index(line, "=") + 1)
                if (val ~ /^\//)
                    printf "%s\t%s\n", (name == "--repo" || name == "--root") ? "data" : "exec", val
                prev = line
                next
            }
            if (line ~ /^\//) {
                if (idx == 0) {
                    printf "launcher\t%s\n", line
                } else if (prev == "--repo" || prev == "--root") {
                    printf "data\t%s\n", line
                } else {
                    printf "unknown\t%s\n", line
                }
            }
            prev = line
        }
        END { if (!seen) exit 1 }
    ')" || return 1
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
}

# ── the TCC-protected tree (#427) ─────────────────────────────────────────
#
# MEASURED 2026-11-03T23:30Z on the orchestrator box: FOUR launchd jobs were armed, loaded and
# unable to do anything, because their ProgramArguments named a script inside `~/Documents`.
#
#   com.eldato.worker-supply        runs=1766  last exit code=126
#   com.eldato.objective-reminder   runs=44    last exit code=126
#   com.eldato.controller-watchdog  runs=1     last exit code=126
#   com.tortoise.queue-reconcile    runs=n/a   last exit code=2
#
# and every one of them logged the same sentence, 27,322 times for the first:
#
#   /bin/bash: /Users/…/Documents/GitHub/agent-infra/scripts/…/worker-supply.sh: Operation not permitted
#
# `126` reads like "interpreter missing" or "not executable". It is neither: every one of those
# paths existed and was `-rwxr-xr-x`. macOS TCC denies EVERY launchd-spawned process access to
# ~/Documents, ~/Desktop, ~/Downloads and the iCloud tree, `bash` maps the EPERM to 126, and the
# only way to tell the two apart is to read `launchctl print` (`runs`, `last exit code`) and the
# job's own log. So the check below exists for the class, not the four instances:
#
#   verified with a probe job submitted INTO the launchd bootstrap domain (`launchctl submit`,
#   ppid=1, uid=501 — the same context the agents run in):
#     ~/.pi/agent/scripts/objective-reminder.sh                          → would-be READ=ok
#     ~/harness/<sha12>/scripts/orchestrator-harness/launchd-controller.sh → READ=ok
#     ~/Documents/GitHub/agent-infra/scripts/objective-reminder.sh       → READ=DENIED
#     ls ~/Documents/GitHub/agent-infra/scripts                          → listdir DENIED
#     ~/Documents/GitHub/tortoise/pyproject.toml                         → READ=DENIED (blanket tree)
#
# ⛔ THE FARM IS THE REMEDY, NOT A PLIST EDIT. A job must execute the FARMED copy
# (`~/.pi/agent/scripts/…`, declared in `pi-bootstrap/setup.sh`'s farm arrays) — the same rule this
# file already applies to `worktree-hygiene-sweep.sh`, `pi-reap-orphans.sh` and the lane-liveness
# tools. Pointing ProgramArguments at `{{AGENT_INFRA_PATH}}` looks correct on a box whose checkout
# sits outside the TCC tree and is silently dead on the documented default
# (`~/Documents/GitHub/agent-infra`), which is why `verify_targets` used to pass it.
#
# WHAT THIS GUARD DOES **NOT** COVER, stated so it is not read as a clean bill of health:
#   * a job whose *work* touches a `~/Documents` checkout (a `--repo` argument, a `WorkingDirectory`,
#     a `git` call) is just as dead from launchd's context even when its own script is farmed and
#     readable — the same root, NOT fixable by a path swap here, recorded on #427 rather than papered
#     over. Those arguments get a WARN (verdict 0), never a refusal.
#   * a TCC path hidden INSIDE a non-absolute token (`python3 -c 'exec(open("…/Documents/x").read())'`)
#     is invisible to this check: it classifies ProgramArguments ELEMENTS, not payloads. Measured
#     (review P3, round 4): such a unit installs with no WARN at all. No shipped template does it.
#   * what a job's WORK can read once it is running (a `git` call into the checkout, a `gh` it
#     spawns): #427's measured class, unchanged by this guard.
tcc_protected_roots() {
    printf '%s\n' \
        "$HOME/Documents" \
        "$HOME/Desktop" \
        "$HOME/Downloads" \
        "$HOME/Library/Mobile Documents"
}

# physical_path <path> → the path with every symlink component resolved, or non-zero.
#
# `pwd -P` alone resolves only the DIRECTORY, which was the first draft's hole: a farm entry that is
# itself a symlink into the protected tree (`~/.pi/agent/scripts/x.sh -> ~/Documents/…/x.sh`, the
# shape `pi-bootstrap/setup.sh` deliberately replaces with real copies) has an unresolvable-by-pwd
# basename and passed the guard. `readlink` is POSIX (macOS ships it without `-f`), so the loop is
# explicit rather than a `realpath -f` dependency; the hop bound stops a symlink cycle from hanging
# the installer.
physical_path() {
    local p="$1" n=0 t d b
    while [ -L "$p" ]; do
        [ "$n" -lt 40 ] || return 1
        t="$(readlink "$p" 2>/dev/null)" || return 1
        [ -n "$t" ] || return 1
        case "$t" in
            /*) p="$t" ;;
            *)  d="$(CDPATH= cd -- "$(dirname -- "$p")" 2>/dev/null && pwd -P)" || return 1
                p="$d/$t" ;;
        esac
        n=$((n + 1))
    done
    d="$(CDPATH= cd -- "$(dirname -- "$p")" 2>/dev/null && pwd -P)" || return 1
    b="$(basename -- "$p")"
    printf '%s/%s\n' "$d" "$b"
}

# tcc_protected_root <absolute path> → prints the PHYSICAL protected ROOT that matched; non-zero when
# none. Printing the root (not a boolean) is what lets verify_targets ask "does this unit's LAUNCHER
# hold a grant for THAT tree", and printing the PHYSICAL form is what stops a symlinked target from
# being judged by the tree it APPEARS to be in (review P3, round 5: a `~/Documents/alias -> ~/Desktop/x`
# was read as "same tree" and installed).
#
# TWO resolutions are compared, and BOTH are required:
#   * the PHYSICAL path of the target (symlinks included), for the reason `launchd_path` does — it is
#     the TARGET that TCC gates, so a symlink pointing INTO the protected tree is dead while one
#     pointing OUT of it is fine;
#   * the PHYSICAL path of each ROOT, because the roots are built from `$HOME` and `$HOME` itself is
#     commonly reached through a symlinked ancestor (`/tmp` → `/private/tmp` on macOS). Measured on
#     this suite's own fixture: HOME=/tmp/… resolved to /private/tmp/…, the literal prefix never
#     matched, and the guard PASSED the exact TCC-dead target it exists to refuse.
# A path whose directory cannot be resolved falls back to the literal (and the case-insensitive
# `case` still matches) — an unresolvable path must never be the way past this guard. A path that DOES
# resolve is judged ONLY by where it resolves to: the literal spelling is a fallback, never a second
# chance to match, or a `~/Documents/alias -> ~/outside/live.sh` would be refused as well as refused
# never (both are wrong: that unit starts fine).
# And the comparison is CASE-INSENSITIVE (`nocasematch`, saved and restored): APFS is
# case-insensitive by default, so `~/documents/x` is `~/Documents/x` to the kernel while a literal
# `case` read them as different paths — measured, both spellings PASSED the guard.
tcc_protected_root() {
    local arg="$1" arg_phys="" root root_phys candidate found="" _nm=0
    # ⛔ CASE-INSENSITIVE, because APFS is case-insensitive by DEFAULT: `~/documents/x` IS
    # `~/Documents/x` on the volume every Mac in this fleet runs, and a literal-prefix `case` let the
    # variant through — measured (fresh review of #3413): `$HOME/Documents/x` REFUSED while
    # `$HOME/documents/x` and `$HOME/DOCUMENTS/x` both PASSED, with `[ -e ]` satisfied and TCC still
    # denying them. `nocasematch` is bash 3.1+ (macOS ships 3.2, so `${v,,}` is not available), and it
    # is SAVED AND RESTORED so the caller's matching semantics are unchanged. The loop sets a result
    # instead of returning early, so there is no path that skips the restore.
    shopt -q nocasematch && _nm=1
    shopt -s nocasematch
    arg_phys="$(physical_path "$arg" 2>/dev/null)" || arg_phys=""
    # ⛔ THE LITERAL SPELLING IS A FALLBACK, NOT AN ALTERNATIVE (fresh review of #3413, P2). When the
    # path RESOLVES, WHERE it resolves to is the only thing TCC gates — so `~/Documents/alias` ->
    # `~/outside/live.sh` is READABLE, and matching the literal spelling as well skipped that unit AND
    # disarmed it: a working unit booted out and deleted because of how its path was spelled. The
    # literal is used only when nothing could be resolved (an unresolvable path must never be a way
    # past the guard).
    candidate="${arg_phys:-$arg}"
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        [ -z "$found" ] || continue
        root_phys="$(physical_path "$root" 2>/dev/null)" || root_phys="$root"
        case "$candidate" in
            "$root_phys" | "$root_phys"/*) found="$root_phys" ;;
        esac
    done < <(tcc_protected_roots)
    [ "$_nm" -eq 1 ] || shopt -u nocasematch
    [ -n "$found" ] || return 1
    printf '%s\n' "$found"
}

# is_tcc_protected <absolute path> → 0 when launchd cannot read it (the boolean form of the above).
is_tcc_protected() { tcc_protected_root "$1" >/dev/null; }

# is_readable_file <path> → 0 when the path is a readable, non-empty regular file.
#
# ⬛ "CANNOT READ" FAILS CLOSED, and it is checked BEFORE the magic bytes (review P2, round 5). The
# first version asked only for the two magic bytes, so an UNREADABLE launcher yielded "" → "not a
# script" → "a binary that holds a grant" → WARN + INSTALL: the fail-open this whole check exists
# to close, reached by a chmod.
is_readable_file() { [ -f "$1" ] && [ -r "$1" ] && [ -s "$1" ]; }

# is_binary_file <path> → 0 when the file does NOT start with `#!` (call is_readable_file first).
is_binary_file() {
    local magic
    magic="$(head -c 2 -- "$1" 2>/dev/null)" || return 1
    [ -n "$magic" ] || return 1
    [ "$magic" != "#!" ]
}

# shebang_interpreter <path> → the first word of a `#!` line (non-zero when it has none).
shebang_interpreter() {
    local line
    line="$(head -n 1 -- "$1" 2>/dev/null)" || return 1
    case "$line" in '#!'*) ;; *) return 1 ;; esac
    line="${line#\#!}"
    line="${line#"${line%%[![:space:]]*}"}"
    set -- $line
    [ -n "${1:-}" ] || return 1
    printf '%s\n' "$1"
}

# launcher_grant_root <path> → prints the TCC root this LAUNCHER can hold a grant for; non-zero when
# it cannot hold one (so a TCC-protected target under it is dead).
#
# THE GRANT BELONGS TO THE PROCESS THAT READS THE FILE, which is why this is not a path test:
#   * a BINARY holds its own grant — #1311 measured `{{TORTOISE_REPO}}/.venv/bin/python` running from
#     inside `~/Documents` and reading a checkout there (`WORKTREES=454 … GH=ok`);
#   * a `#!` SCRIPT is handed by the kernel to its INTERPRETER, so its grant is the INTERPRETER's: a
#     `#!/bin/bash` script in the tree is read by `/bin/bash`, which #427 measured IS denied → dead;
#     one whose interpreter is itself a binary in the tree (`#!…/.venv/bin/python`) is read by a
#     granting binary → alive. Both measured in review, rounds 4 and 5.
# A relative interpreter, a chain deeper than three hops, or an unreadable/empty file is unknowable
# → non-zero, i.e. the refusal direction.
launcher_grant_root() {
    local p="$1" hop=0
    while [ "$hop" -lt 3 ]; do
        is_readable_file "$p" || return 1
        # ⛔ EVERY HOP IS `execve`d, so every hop needs the x bit: the launcher itself, and — for a
        # `#!` script — the interpreter the kernel hands it to. A readable-but-non-executable file is
        # EACCES on every tick while the install says `installed + loaded`, which is the false PASS
        # this guard exists to remove (review of #3413 round 9: a 644 `notes.txt` named by `Program`
        # INSIDE a TCC root WARNed and installed; the identical file outside a TCC root was refused).
        [ -x "$p" ] || return 1
        if is_binary_file "$p"; then
            tcc_protected_root "$p" || return 1    # prints the root when the binary is inside one
            return 0
        fi
        p="$(shebang_interpreter "$p")" || return 1
        case "$p" in /*) ;; *) return 1 ;; esac
        hop=$((hop + 1))
    done
    return 1
}

# Verify every absolute path in ProgramArguments resolves AND is readable from the launchd context
# (catches broken symlinks — e.g. provider-latency-tripwire.sh pointing at a not-yet-pulled checkout,
# fixed by re-running setup.sh — and TCC-protected targets, fixed by farming).
#
# ⛔ THREE VERDICTS, because the three failure classes have different REMEDIES — and folding them into
# one exit status conflated "fix the install" with "this box can never run this unit":
#
#   0  every target resolves and is reachable from launchd (possibly with WARNs, below)
#   1  a target is MISSING, or the plist cannot be read — fixable by re-running setup.sh/sync.sh, so
#      the install FAILS and the operator is told to repair the farm
#   2  every target exists, and an EXECUTED target sits in a TCC root that this unit's LAUNCHER holds
#      no grant for — NOT fixable by any install step (#427), so that ONE unit is skipped loudly (and
#      any copy a previous run armed is disarmed) while the rest of the install proceeds
#
# ⛔ THE LAUNCHER IS THE DISCRIMINATOR, AND BOTH HALVES ARE MEASURED, not inferred: #427 (a launchd
# `bash` cannot READ a `~/Documents` script — exit 126, 27,322 log lines) and #1311 (the checkout's own
# interpreter DOES run from there). TCC is PER-BINARY. So a TCC-root path is only known-DEAD when the
# process that must read it holds no grant for that tree; a unit whose launcher does is installed with
# a loud WARN. Refusing or deleting it would take a working daily reaper off the box.
#
# ⛔ AND ONLY EXECUTED PATHS ARE VERDICT-2; A TCC-PROTECTED DATA ARGUMENT WARNS. THREE shipped templates
# pass `--repo {{TORTOISE_REPO}}` (plus `corruption-canary` passing `--root {{SWARM_ROOT}}`), and
# TORTOISE_REPO defaults to `~/Documents/GitHub/tortoise` on the documented box, so refusing data
# arguments reddened the whole installer there: `install_job … || fail=1` → exit 1, and `sync.sh`
# (`set -euo pipefail`, installer run unguarded) died before its cost-config and parity gates.
# The existence check stays unconditional (pre-existing behaviour, and a missing target is a broken
# install whoever reads it).
# $1 = rendered plist FILE. Prints offending targets. Returns 0 / 1 / 2 as above.
verify_targets() {
    # ⛔ THE ITERATION COUNT IS PART OF THE CHECK, not decoration: "the feeder emitted nothing" and
    # "every target verified" were the same observable before #1743, and the repo's own detector
    # reported this function as an empty-as-PASS for exactly that reason. The feeder's return code
    # covers "could not read"; this covers "read, and had nothing verifiable in it".
    local kind arg root grant args_out bad=0 tcc_exec=0 grants=" " n=0
    if ! args_out="$(plist_program_args "$1")"; then
        echo "    cannot read ProgramArguments: $1" >&2
        echo "        a plist that does not parse is NOT an empty target list — nothing was" >&2
        echo "        verified, so the job cannot be armed." >&2
        return 1
    fi
    while IFS=$'\t' read -r kind arg; do
        [ -n "$arg" ] || continue
        n=$((n + 1))
        if [ ! -e "$arg" ]; then
            echo "    broken target: $arg" >&2
            bad=1
            continue
        fi
        # ⛔ THE TCC VERDICT COMES FIRST. A 0-byte or non-regular file INSIDE a TCC root is verdict 2
        # (skip that unit, disarm any copy) — the class this whole change exists for — not verdict 1:
        # a FAIL aborts the install and takes `sync.sh` with it.
        if is_tcc_protected "$arg"; then
            case "$kind" in
                unknown)
                    # role unknown (PlistBuddy fallback): the TCC verdict applies, the file-type one
                    # cannot. `--repo`/`--root` VALUES are no longer in this class (the fallback
                    # derives `data` for them), so what lands here is an absolute element at a
                    # genuinely undecidable position — an `env` program, a script handed to an
                    # interpreter, a second positional — and the conservative arm is the right one.
                    echo "    TCC-protected target: $arg" >&2
                    echo "        the role cannot be derived without python3, so this is treated as" >&2
                    echo "        EXECUTED: launchd cannot read it (#427) and arming it would exit 126." >&2
                    tcc_exec=1
                    ;;
                *) ;;   # launcher/exec/data handled below, in the same block
            esac
            [ "$kind" = "unknown" ] && continue
        fi
        case "$kind" in
            launcher)
                # ⛔ THE X BIT IS CHECKED IN BOTH ARMS, BEFORE the TCC branch. A readable file with no
                # x bit is EACCES on every tick whatever tree it lives in, and the remedy (a chmod, or
                # a re-farm) IS an install step — so it FAILS, which is verdict 1's own definition.
                # Left inside the non-TCC arm, the same file installed with only a WARN whenever it
                # happened to sit in a TCC root (review of #3413, round 9).
                if [ -f "$arg" ] && [ -r "$arg" ] && [ -s "$arg" ] && [ ! -x "$arg" ]; then
                    echo "    unreadable or not an executable regular file: $arg" >&2
                    echo "        launchd execs this path directly (Program / argv[0]), so a file with" >&2
                    echo "        no x bit is EACCES on every tick whatever its contents. It reads as" >&2
                    echo "        'installed' to every instrument that only checks existence." >&2
                    bad=1
                    continue
                fi
                if ! is_tcc_protected "$arg"; then
                    # ⛔ A LAUNCHER IS `execve`d BY launchd, so it must be an EXECUTABLE REGULAR FILE.
                    # The grant model below is about READABILITY from a TCC context and says nothing
                    # about this. Without this arm a `Program` — or a `ProgramArguments[0]` with no
                    # `Program` — that is a DIRECTORY, a 0-byte file, or a file with no `x` bit
                    # installed as `installed + loaded` and then died 126/127 on every tick: the same
                    # category-A false PASS as `[ -e ]` in the exec arm. Measured on the previous head
                    # for all four shapes, rc=0 `installed + loaded` each (review of #3413, round 8).
                    # ⛔ `-x` IS NOT duplicated onto the `exec` arm: `bash <script>` only READS its
                    # argument, so a readable non-executable script is legitimately runnable there,
                    # while launchd READS this one and hands it to the kernel instead.
                    # A non-reader was already refused above; what remains is the missing/empty/
                    # non-regular class (the `-x` half is handled in the arm above).
                    if [ ! -f "$arg" ] || [ ! -r "$arg" ] || [ ! -s "$arg" ]; then
                        echo "    unreadable or not an executable regular file: $arg" >&2
                        echo "        launchd execs this path directly (Program / argv[0]); a" >&2
                        echo "        directory, an empty file or a non-executable one exits 126/127" >&2
                        echo "        on every tick, which reads as 'installed' to every instrument" >&2
                        echo "        that only checks existence." >&2
                        bad=1
                    fi
                    continue
                fi
                if grant="$(launcher_grant_root "$arg")"; then
                    case "$grants" in *" $grant "*) ;; *) grants="$grants$grant " ;; esac
                    echo "    WARN TCC-root launcher: $arg" >&2
                    echo "        this unit RUNS a binary from inside $grant, and #1311 measured that" >&2
                    echo "        the checkout's own interpreter does run from there (the worktree" >&2
                    echo "        reaper logs WORKTREES=454 … GH=ok), while #427 measured that a launchd" >&2
                    echo "        \`bash\` cannot READ such a path (exit 126). TCC is PER-BINARY, so" >&2
                    echo "        this is NOT a refusal: the unit installs. Verify with \`launchctl print\`." >&2
                    continue
                fi
                echo "    TCC-protected target: $arg" >&2
                echo "        this unit's LAUNCHER is inside a TCC root and CANNOT hold a grant for it." >&2
                echo "        What was checked: a BINARY there holds the grant (#1311); a SHEBANG" >&2
                echo "        script holds only what its INTERPRETER holds, and this launcher" >&2
                echo "        resolved to no readable binary inside a granting tree (a #!/bin/bash" >&2
                echo "        script in the tree lands here, because #427 measured a launchd bash is" >&2
                echo "        denied). Unreadable and empty files land here too. launchd starts it" >&2
                echo "        and it dies with exit 126 'Operation not permitted'." >&2
                tcc_exec=1
                ;;
            data)
                if ! is_tcc_protected "$arg"; then continue; fi
                echo "    WARN TCC-protected data argument: $arg" >&2
                echo "        launchd is measured to deny a non-granted binary this path (#427), and" >&2
                echo "        this value is one the job's work READS (not the code it runs), so the" >&2
                echo "        unit still installs: the part of its work that reads this value is dead." >&2
                echo "        That is #427's recorded class, and refusing here blocked every other" >&2
                echo "        job on the documented default box (--repo under ~/Documents)." >&2
                continue
                ;;
            *)
                # NON-TCC executed target: the file-type/readability guarantee applies here (existence
                # is not readability). A TCC one was already verdicted above.
                if ! is_tcc_protected "$arg"; then
                    # `unknown` (no python3) + a DIRECTORY: a directory cannot be executed, so this is
                    # a data value the fallback could not name. Failing it aborted the whole install on
                    # a PlistBuddy-only host (the #3413 P1-A failure again). Narrowed, not widened: an
                    # `--repo`/`--root` value is derived as `data` by the fallback now, so it no longer
                    # relies on this escape (fresh review of #3413, P2).
                    if [ "$kind" = "unknown" ] && [ -d "$arg" ]; then continue; fi
                    if [ ! -f "$arg" ] || [ ! -r "$arg" ] || [ ! -s "$arg" ]; then
                        echo "    unreadable or not a regular file: $arg" >&2
                        echo "        launchd would start this unit and the interpreter would die" >&2
                        echo "        (126/127), which reads as 'installed' to every instrument that" >&2
                        echo "        only checks existence." >&2
                        bad=1
                    fi
                    continue
                fi
                root="$(tcc_protected_root "$arg")"
                case "$grants" in
                    *" $root "*)
                        echo "    WARN TCC-protected target: $arg" >&2
                        echo "        inside $root, the SAME tree this unit's launcher holds a grant" >&2
                        echo "        for (#1311) — installing, not skipping. A DIFFERENT tree is a" >&2
                        echo "        different grant and IS refused." >&2
                        continue
                        ;;
                esac
                echo "    TCC-protected target: $arg" >&2
                echo "        launchd cannot read ~/Documents, ~/Desktop, ~/Downloads or iCloud (#427);" >&2
                echo "        it starts this job and bash exits 126 'Operation not permitted', which" >&2
                echo "        reads as 'installed' to every instrument that only checks existence." >&2
                echo "        Render the FARMED copy ({{HOME}}/.pi/agent/scripts/…) and declare it in" >&2
                echo "        pi-bootstrap/setup.sh's farm array, so the copy is what actually executes." >&2
                tcc_exec=1
                ;;
        esac
    done <<< "$args_out"
    if [ "$n" -eq 0 ]; then
        echo "    no absolute ProgramArguments entry was verified: $1" >&2
        return 1
    fi
    [ "$bad" -eq 0 ] || return 1
    [ "$tcc_exec" -eq 0 ] || return 2
    return 0
}

job_loaded() {
    launchctl print "$DOMAIN/$1" >/dev/null 2>&1
}

install_job() {
    local template="$1" label installed rendered tmp left ph unset_ph=""
    label="$(job_label "$template")"
    installed="$AGENTS_DIR/$label.plist"

    # Unresolved placeholder → legitimate skip (e.g. no swarm root), loud.
    # Checked on the TEMPLATE against resolved env values (not the rendered
    # output — sed would substitute the empty string and hide the gap).
    for ph in "${PLIST_PLACEHOLDERS[@]}"; do
        if grep -q "{{$ph}}" "$template" && [ -z "${!ph:-}" ]; then
            unset_ph="$unset_ph {{$ph}}"
        fi
    done
    if [ -n "$unset_ph" ]; then
        echo "  SKIP $label: unresolved placeholder(s)$unset_ph — is this a swarm host?" >&2
        return 0
    fi

    # ⛔ {{PATH}} is RENDERED THROUGH A TRANSFORM, so test the value that will actually be written
    # (review D3). The loop above tests `${!ph}` — the RAW `$PATH` — but `render` substitutes
    # `launchd_path`. A PATH composed only of shim/resolvable-less entries is non-empty raw and
    # EMPTY rendered, so the guard above passes and the job installs with
    # `<key>PATH</key><string></string>`: an installed-but-inert job whose own log line cannot even
    # run (`mkdir: command not found`). Refuse to install it, like any other unresolved placeholder.
    if grep -q '{{PATH}}' "$template" && [ -z "$(launchd_path)" ]; then
        echo "  SKIP $label: unresolved placeholder(s) {{PATH}} — every PATH entry is unreadable" >&2
        return 0
    fi

    rendered="$(render "$template")"
    # Broken / unreadable target → FAIL (fixable: re-run setup.sh). A TCC-protected EXEC target →
    # SKIP this unit loudly (not fixable on this box, #427) and keep installing the rest.
    tmp="$(mktemp)" || return 1
    printf '%s' "$rendered" > "$tmp"
    verify_targets "$tmp"
    local vrc=$?
    if [ "$vrc" -ne 0 ]; then
        rm -f "$tmp"
        if [ "$vrc" -eq 2 ]; then
            echo "  SKIP $label: launchd cannot READ this unit's target — a macOS TCC root (#427)." >&2
            echo "        It must not stay ARMED: an installed unit that exits 126 'Operation not" >&2
            echo "        permitted' reads as 'installed' to every instrument that only checks" >&2
            echo "        existence, which is worse than an absent one. No install step changes this" >&2
            echo "        box's layout — fix it by farming the target, or on #427 for the job's WORK." >&2
            # A SKIP MUST DISARM WHAT A PREVIOUS RUN ARMED (review P2). Returning before the
            # install/remove path left an already-installed+loaded plist in place, so the unit kept
            # exiting 126 on every tick while this run reported "nothing is installed for it" -- the
            # exact divergence between the report and reality that the guard exists to remove.
            # REACHABLE BY CONSTRUCTION, and this PR's own measurement is the proof: a box running
            # the PREVIOUS installer armed worker-supply / objective-reminder / controller-watchdog
            # from `{{AGENT_INFRA_PATH}}` (inside `~/Documents`) and they exited 126 for 7 hours.
            # Reverting any of the three farmed paths, or any future template edit that points a
            # bash-launched script back into the tree, lands in exactly that state -- installed,
            # loaded, dead -- and this run must take it OFF. (The two `com.tortoise.*` reapers are
            # NOT that case: their argv[0] is a BINARY inside the tree, which #1311 measured holds
            # the grant.)
            if [ -f "$installed" ]; then
                launchctl bootout "$DOMAIN" "$installed" 2>/dev/null || true
                rm -f "$installed"
                echo "        The previously installed unit was UNLOADED and removed." >&2
            else
                echo "        Nothing is installed for this unit." >&2
            fi
            return 0
        fi
        echo "  FAIL $label: script target(s) above are missing or unreachable from launchd —" >&2
        echo "        fix the farm/checkout first (run sync.sh / pi-bootstrap setup.sh), then re-run." >&2
        echo "        Refusing to install: a unit launchd cannot start reads as 'armed' and does" >&2
        echo "        nothing, which is worse than no unit at all." >&2
        return 1
    fi

    if [ -f "$installed" ] && cmp -s "$installed" "$tmp"; then
        rm -f "$tmp"
        echo "  $label: unchanged (skip)"
        return 0
    fi

    mkdir -p "$AGENTS_DIR"
    mv "$tmp" "$installed"
    # Clear any disabled override, then reload. bootout is tolerated (a job
    # that was never loaded exits nonzero — fine). bootstrap must succeed.
    launchctl enable "$DOMAIN/$label" 2>/dev/null || true
    launchctl bootout "$DOMAIN" "$installed" 2>/dev/null || true
    if ! launchctl bootstrap "$DOMAIN" "$installed"; then
        rm -f "$installed"   # nothing half-installed
        echo "  FAIL $label: launchctl bootstrap exited nonzero — see 'launchctl print $DOMAIN/$label'" >&2
        return 1
    fi
    echo "  $label: installed + loaded (v$(version_of "$template" || echo unknown))"
    return 0
}

status_job() {
    local template="$1" label installed rendered version state drift
    label="$(job_label "$template")"
    installed="$AGENTS_DIR/$label.plist"
    rendered="$(render "$template")"
    version="$(version_of "$template" || echo "?")"

    if [ ! -f "$installed" ]; then
        echo "  $label: NOT INSTALLED (template v$version)"
        return 0
    fi
    if job_loaded "$label"; then
        state="loaded"
    else
        state="not loaded"
    fi
    if cmp -s "$installed" <(printf '%s' "$rendered"); then
        drift="in sync"
    else
        drift="DRIFTED (template changed — re-run installer)"
    fi
    echo "  $label: installed=$state version=v$version ($drift)"
}

uninstall_job() {
    local template="$1" label installed
    label="$(job_label "$template")"
    installed="$AGENTS_DIR/$label.plist"
    if [ -f "$installed" ]; then
        launchctl bootout "$DOMAIN" "$installed" 2>/dev/null || true
        rm -f "$installed"
        echo "  $label: unloaded + removed"
    else
        echo "  $label: not installed"
    fi
}

# Retired launchd jobs (#432 — Option C): labels listed in
# templates/launchd/RETIRED. Their work moved to extensions/session-checks.ts
# (session_start, age-gated) because launchd cannot run them — macOS TCC
# blocks launchd-spawned processes from ~/Documents regardless of interpreter
# (#427/#431). The installer unloads + removes retired jobs on machines that
# installed them pre-retirement (the template loop only manages PRESENT
# templates, so a removed template would otherwise strand installed jobs
# forever). A retired label must NOT also have a *.plist template.
retired_labels() {
    local manifest="$TEMPLATES_DIR/RETIRED" label
    [ -f "$manifest" ] || return 0
    while IFS= read -r label; do
        case "$label" in
            ""|"#"*) continue ;;
        esac
        printf '%s\n' "$label"
    done < "$manifest"
}

is_retired() { # $1 = label → 0 when it is listed in RETIRED
    # Capture, then grep a here-string — never `retired_labels | grep -q`: under
    # `pipefail` the label producer takes SIGPIPE when `grep` exits at its first match,
    # and a false negative here installs a RETIRED launchd job (#864).
    grep -qxF -- "$1" <<<"$(retired_labels || true)"
}

retire_job() { # $1 = label; unload + remove when installed (silent when gone)
    local label="$1" installed
    installed="$AGENTS_DIR/$label.plist"
    if [ -f "$installed" ]; then
        launchctl bootout "$DOMAIN" "$installed" 2>/dev/null || true
        rm -f "$installed"
        echo "  $label: RETIRED (unloaded + removed)"
    fi
}

# Unload retired jobs in both flows: the --uninstall path and the idempotent
# install path (so a merged retirement propagates on the next sync).
retire_pass() {
    local label rc=0
    for label in $(retired_labels); do
        if [ -f "$TEMPLATES_DIR/$label.plist" ]; then
            echo "ERROR: $label is in RETIRED but a template still exists — remove one or the other" >&2
            rc=1
            continue
        fi
        retire_job "$label"
    done
    return "$rc"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
fi

# ── temp-HOME guard (#446) ──────────────────────────────────────────────
# A run with HOME ≠ the real user home (pi-bootstrap tests bootstrap the real
# gui domain with throwaway temp-home plists) registers jobs whose plist path
# belongs to a dir that dies with the test — the exact observed failure:
# com.eldato.provider-latency-tripwire registered to a deleted
# pi-setup-test.*/home path, runs=0, dead through the #413 incident window.
# Refuse ALL launchd management (install AND --uninstall) when HOME is not
# the real home. Tests opt in with ELDATO_ALLOW_TEST_HOME=1 AND a launchctl
# shim on PATH (install-launchd.test.sh) so nothing reaches the real domain.
# On non-Darwin (no dscl — CI) the real home is unknown; the guard is
# skipped there and the launchctl shim is the only isolation (no gui domain).
if [ "${ELDATO_ALLOW_TEST_HOME:-}" != "1" ]; then
    # `|| true`: no set -e here, but keep the probe abort-proof against any
    # future hardening (a dscl failure must SKIP the guard, never kill it).
    # sed (not awk $2): NFSHomeDirectory values can contain spaces
    # (e.g. /Users/John Smith) — only the prefix is stripped (cycle 3 P3).
    real_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p' | head -1 || true)"
    if [ -n "$real_home" ] && [ "$HOME" != "$real_home" ]; then
        echo "ERROR: refusing to manage launchd jobs: HOME=$HOME is not the real home ($real_home)." >&2
        echo "       A temp-HOME run registers jobs against plist paths that vanish (#446)." >&2
        echo "       Tests: put a launchctl shim on PATH and set ELDATO_ALLOW_TEST_HOME=1" >&2
        echo "       (see scripts/install-launchd.test.sh)." >&2
        exit 1
    fi
fi

# ── --uninstall must work on a BROKEN machine — before env resolution ──
if [ "${1:-}" = "--uninstall" ]; then
    echo "=== Uninstalling agent-infra launchd agents ==="
    for template in "$TEMPLATES_DIR"/*.plist; do
        [ -f "$template" ] || continue
        uninstall_job "$template"
    done
    retire_pass || exit 1
    echo "Done. Agent-infra jobs removed."
    exit 0
fi

if [ ! -d "$TEMPLATES_DIR" ]; then
    echo "ERROR: template dir not found: $TEMPLATES_DIR" >&2
    exit 1
fi

resolve_env

if [ "${1:-}" = "--status" ]; then
    echo "=== agent-infra launchd status (templates: $TEMPLATES_DIR) ==="
    for template in "$TEMPLATES_DIR"/*.plist; do
        [ -f "$template" ] || continue
        status_job "$template"
    done
    if [ -n "$(retired_labels)" ]; then
        echo "Retired (moved to session-checks, #432): $(retired_labels | tr '\n' ' ')"
    fi
    echo "Env: AGENT_INFRA_PATH=$AGENT_INFRA_PATH"    echo "     TORTOISE_REPO=${TORTOISE_REPO:-<unset — session-checks will use the sibling tortoise or skip the hub leg>}"
    echo "     SWARM_ROOT=${SWARM_ROOT:-<unset — canary job skipped>}"
    if [ "$WORKTREE_HYGIENE_MODE" = '--apply' ]; then
        echo "     worktree-hygiene: ARMED ($WT_HYGIENE_ARM_FILE) — the job DELETES on its timer"
    else
        echo "     worktree-hygiene: DISARMED (dry-run; arm with --arm-worktree-hygiene)"
    fi
    if [ "$REAP_ORPHAN_MODE" = '0' ]; then
        echo "     orphan-reaper: ARMED ($REAP_ORPHAN_ARM_FILE) — hourly passes SIGNAL"
    else
        echo "     orphan-reaper: DISARMED (report-only; arm with --arm-orphan-reaper)"
    fi
    exit 0
fi

if [ $# -gt 0 ]; then
    # The arming verbs are handled here — after resolve_env (they need the repo +
    # the rendered mode) and before the "unknown argument" refusal below, so that
    # each of them falls THROUGH into the normal install loop and the unit is
    # re-rendered + reloaded in the same command.
    case "$1" in
        --arm-worktree-hygiene)
            shift
            arm_reason=""
            if [ "${1:-}" = "--reason" ]; then arm_reason="${2:-}"; shift 2 || true; fi
            if [ $# -gt 0 ]; then
                echo "ERROR: unknown argument: $1 (use --arm-worktree-hygiene [--reason TEXT])" >&2; exit 2
            fi
            arm_worktree_hygiene "$arm_reason" || exit 1
            WORKTREE_HYGIENE_MODE="$(wt_hygiene_mode)"   # the record just changed it
            ;;
        --disarm-worktree-hygiene)
            shift
            if [ $# -gt 0 ]; then
                echo "ERROR: unknown argument: $1 (use --disarm-worktree-hygiene)" >&2; exit 2
            fi
            disarm_worktree_hygiene || exit 1
            WORKTREE_HYGIENE_MODE="$(wt_hygiene_mode)"
            ;;
        --arm-orphan-reaper)
            shift
            arm_reason=""
            if [ "${1:-}" = "--reason" ]; then arm_reason="${2:-}"; shift 2 || true; fi
            if [ $# -gt 0 ]; then
                echo "ERROR: unknown argument: $1 (use --arm-orphan-reaper [--reason TEXT])" >&2; exit 2
            fi
            arm_orphan_reaper "$arm_reason" || exit 1
            REAP_ORPHAN_MODE="$(reap_orphan_mode)"   # the record just changed it
            ;;
        --disarm-orphan-reaper)
            shift
            if [ $# -gt 0 ]; then
                echo "ERROR: unknown argument: $1 (use --disarm-orphan-reaper)" >&2; exit 2
            fi
            disarm_orphan_reaper || exit 1
            REAP_ORPHAN_MODE="$(reap_orphan_mode)"
            ;;
        *)
            echo "ERROR: unknown argument: $1 (use --status, --uninstall, --arm-worktree-hygiene, --disarm-worktree-hygiene, --arm-orphan-reaper, --disarm-orphan-reaper, or nothing)" >&2
            exit 2 ;;
    esac
fi

echo "=== Installing agent-infra launchd agents (idempotent) ==="
fail=0
# Retire first (#432): unload jobs whose work moved to session-checks.
retire_pass || fail=1
for template in "$TEMPLATES_DIR"/*.plist; do
    [ -f "$template" ] || continue
    if is_retired "$(basename "$template" .plist)"; then
        # retire_pass already ERRORED above (fail=1) — don't ALSO install it.
        echo "  $(basename "$template" .plist): skipped (in RETIRED — remove the template)" >&2
        continue
    fi
    install_job "$template" || fail=1
done
if [ "$fail" -ne 0 ]; then
    echo "ERROR: one or more jobs FAILED — see above. Nothing was half-installed; re-run after fixing." >&2
    exit 1
fi
echo ""
echo "Done. Run 'install-launchd.sh --status' to verify; 'launchctl list | grep eldato' to see jobs."
