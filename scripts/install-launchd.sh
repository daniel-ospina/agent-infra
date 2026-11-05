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
# `kind` is `exec` for what the job actually RUNS and `data` for every absolute value its work merely
# READS. That split is the difference between "launchd cannot EXECUTE this job" and "this job's work
# cannot read its input": only the former is a reason not to install the unit (see verify_targets).
#
# ⛔ DERIVED FROM THE COMMAND, NOT FROM "BEFORE THE FIRST DASH". A rule that closed the command
# prefix at the first option put `/bin/bash -e ~/Documents/dead.sh` in the DATA class — the job's own
# script, warned about instead of refused, which is the armed-and-dead class this guard exists for.
# The executed set is: argv[0], plus — when argv[0] is an interpreter — the first non-option token it
# will READ (one extra hop for `/usr/bin/env`, whose next token is the program). `-c` and friends take
# an inline program, so that token is then not a path and simply closes the prefix.
#
# ⛔ A RETURN OF NON-ZERO MEANS "COULD NOT READ", NEVER "NO TARGETS" (#1743). An unparseable plist and
# a plist with no absolute argument must not arrive at the caller as the same empty string — that was
# an empty-as-PASS, where a rendered plist launchd could not parse installed UNVERIFIED. They are now
# separated: non-zero = unreadable, zero + empty output = read but nothing to verify (and
# verify_targets refuses on ITS OWN zero-iteration count, so neither half depends on the other).
plist_program_args() {
    local plist="$1" out rc=0 py
    if py="$(plist_python)"; then
        out="$("$py" - "$plist" 2>/dev/null <<'PY'
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as f:
        d = plistlib.load(f)
except Exception:
    sys.exit(3)                      # UNREADABLE — not "no targets"
args = d.get("ProgramArguments")
if not isinstance(args, list):
    sys.exit(4)                      # no ProgramArguments array to verify
INTERPRETERS = {"bash", "sh", "zsh", "dash", "ksh", "fish", "python", "python2", "python3",
                "perl", "ruby", "node", "env"}
argv0 = args[0] if args and isinstance(args[0], str) else ""
base = argv0.rsplit("/", 1)[-1]
is_interp = base in INTERPRETERS
is_env = base == "env"
script_seen = not is_interp          # a non-interpreter argv[0] runs nothing else
env_prog_seen = False
for i, a in enumerate(args):
    if not isinstance(a, str):
        continue
    if i == 0:
        if a.startswith("/"):
            print("exec\t" + a)
        continue
    if not script_seen:
        if a.startswith("-"):
            continue                                     # an option in the command prefix
        if is_env and not env_prog_seen and "=" in a and not a.startswith("/"):
            continue                                     # `env NAME=VALUE …`, still the prefix
        if is_env and not env_prog_seen:
            env_prog_seen = True                         # `env … <program>`: the program is next
            if a.startswith("/"):
                print("exec\t" + a)
            continue
        script_seen = True                               # the script the interpreter will READ
        if a.startswith("/"):
            print("exec\t" + a)
        continue
    if a.startswith("/"):
        print("data\t" + a)
PY
)" || rc=$?
        if [ "$rc" -eq 0 ]; then
            [ -n "$out" ] && printf '%s\n' "$out"
            return 0
        fi
        # rc=3/4 (unparseable / no array) → try the other guaranteed reader before giving up.
    fi
    local buddy=/usr/libexec/PlistBuddy raw
    [ -x "$buddy" ] || return 1
    raw="$("$buddy" -c 'Print :ProgramArguments' "$plist" 2>/dev/null)" || return 1
    [ -n "$raw" ] || return 1
    # ⛔ WITHOUT python3 THE ROLES CANNOT BE DERIVED, so EVERY absolute element is treated as the
    # executed command. That is the fail-closed direction and it costs little: the TCC verdict for an
    # `exec` target is a loud SKIP of that one unit (never an install), so a PlistBuddy-only host
    # skips a unit it might have installed rather than arming one launchd cannot read.
    out="$(printf '%s\n' "$raw" | awk '
        BEGIN { seen = 0 }
        # PlistBuddy wraps an array in `Array {` / `}` on their own lines.
        /^[[:space:]]*(Array)?[[:space:]]*\{[[:space:]]*$/ { next }
        /^[[:space:]]*\}[[:space:]]*$/ { next }
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            sub(/^(Arg)?[0-9]+[[:space:]]*=[[:space:]]*/, "", line)
            if (line == "") next
            seen = 1
            if (line ~ /^\//) printf "exec\t%s\n", line
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
# WHAT THIS GUARD DOES **NOT** COVER, stated so it is not read as a clean bill of health: a job whose
# *work* touches a `~/Documents` checkout (a `--repo` argument, a `WorkingDirectory`, a `git` call)
# is just as dead from launchd's context even when its own script is farmed and readable. That is the
# same root, it is NOT fixable by a path swap here, and it is recorded on #427 rather than papered
# over.
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

# is_tcc_protected <absolute path> → 0 when launchd cannot read it.
#
# TWO resolutions are compared, and BOTH are required:
#   * the PHYSICAL path of the target (symlinks included), for the reason `launchd_path` does — it is
#     the TARGET that TCC gates, so a symlink pointing INTO the protected tree is dead while one
#     pointing OUT of it is fine;
#   * the PHYSICAL path of each ROOT, because the roots are built from `$HOME` and `$HOME` itself is
#     commonly reached through a symlinked ancestor (`/tmp` → `/private/tmp` on macOS). Measured on
#     this suite's own fixture: HOME=/tmp/… resolved to /private/tmp/…, the literal prefix never
#     matched, and the guard PASSED the exact TCC-dead target it exists to refuse.
# A path whose directory cannot be resolved falls back to the literal, and the literal `case` still
# matches — an unresolvable path must never be the way past this guard.
is_tcc_protected() {
    local arg="$1" arg_phys="" root root_phys candidate
    arg_phys="$(physical_path "$arg" 2>/dev/null)" || arg_phys=""
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        for candidate in "$arg" "$arg_phys"; do
            [ -n "$candidate" ] || continue
            case "$candidate" in "$root" | "$root"/*) return 0 ;; esac
        done
        root_phys=""
        if root_phys="$(physical_path "$root" 2>/dev/null)" && [ "$root_phys" != "$root" ]; then
            for candidate in "$arg" "$arg_phys"; do
                [ -n "$candidate" ] || continue
                case "$candidate" in "$root_phys" | "$root_phys"/*) return 0 ;; esac
            done
        fi
    done < <(tcc_protected_roots)
    return 1
}

# Verify every absolute path in ProgramArguments resolves AND is readable from the launchd context
# (catches broken symlinks — e.g. provider-latency-tripwire.sh pointing at a not-yet-pulled checkout,
# fixed by re-running setup.sh — and TCC-protected targets, fixed by farming).
#
# ⛔ THREE VERDICTS, because the three failure classes have different REMEDIES — and folding them into
# one exit status conflated "fix the install" with "this box can never run this unit":
#
#   0  every target resolves and is reachable from launchd
#   1  a target is MISSING, or the plist cannot be read — fixable by re-running setup.sh/sync.sh, so
#      the install FAILS and the operator is told to repair the farm
#   2  every target exists, and an EXECUTED target sits in a TCC root — NOT fixable by any install step
#      (#427), so that ONE unit is skipped loudly and the rest of the install proceeds
#
# ⛔ AND ONLY THE EXECUTED COMMAND IS VERDICT-2; A TCC-PROTECTED DATA ARGUMENT WARNS. The guard exists
# so that a job launchd cannot START is never armed — not so that a job whose INPUT is unreachable is
# treated as uninstallable. THREE shipped templates pass `--repo {{TORTOISE_REPO}}` (plus
# `corruption-canary` passing `--root {{SWARM_ROOT}}`), and TORTOISE_REPO defaults to
# `~/Documents/GitHub/tortoise` on the documented box, so refusing data arguments reddened the whole
# installer there: `install_job … || fail=1` → exit 1, and `sync.sh` (`set -euo pipefail`, installer
# run unguarded) died before its cost-config and parity gates. A unit that installs but cannot read
# its `--repo` is DEAD WORK, which is #427's recorded class — a named WARN on a passing install.
#
# ⛔ THE SAME DISTINCTION IS WHY VERDICT 2 IS A SKIP AND NOT A FAILURE. Two `com.tortoise.*` reapers
# put `{{TORTOISE_REPO}}/.venv/bin/python` at argv[0] — an EXECUTED target, correctly verdicted, and
# on the documented default box it is inside `~/Documents`. Failing the install there reproduces
# P1-A exactly (installer exit 1 → `sync.sh` dies). Every missing target is still a hard FAIL: that
# is the class an install step can repair.
# The existence check stays unconditional (pre-existing behaviour, and a missing target is a broken
# install whoever reads it).
# $1 = rendered plist FILE. Prints offending targets. Returns 0 / 1 / 2 as above.
verify_targets() {
    # ⛔ THE ITERATION COUNT IS PART OF THE CHECK, not decoration: "the feeder emitted nothing" and
    # "every target verified" were the same observable before #1743, and the repo's own detector
    # reported this function as an empty-as-PASS for exactly that reason. Zero verified entries is a
    # refusal now — the feeder's return code covers "could not read", and this covers "read, and had
    # nothing verifiable in it", which are different failures of the same check.
    local kind arg args_out bad=0 tcc_exec=0 n=0
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
        if is_tcc_protected "$arg"; then
            if [ "$kind" = "data" ]; then
                echo "    WARN TCC-protected data argument: $arg" >&2
                echo "        launchd cannot read ~/Documents, ~/Desktop, ~/Downloads or iCloud (#427), so" >&2
                echo "        the part of this job's work that reads this value is dead. The unit still" >&2
                echo "        installs: this is not the executable, and refusing here blocked every" >&2
                echo "        other job on the documented default box (#427, --repo under ~/Documents)." >&2
                continue
            fi
            echo "    TCC-protected target: $arg" >&2
            echo "        launchd cannot read ~/Documents, ~/Desktop, ~/Downloads or iCloud (#427);" >&2
            echo "        it starts this job and bash exits 126 'Operation not permitted', which" >&2
            echo "        reads as 'installed' to every instrument that only checks existence." >&2
            echo "        Render the FARMED copy ({{HOME}}/.pi/agent/scripts/…) and declare it in" >&2
            echo "        pi-bootstrap/setup.sh's farm array, so the copy is what actually executes." >&2
            tcc_exec=1
        fi
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
            echo "        Nothing is installed for this unit: an armed unit that exits 126 'Operation" >&2
            echo "        not permitted' reads as 'installed' to every instrument that only checks" >&2
            echo "        existence, which is worse than an absent unit. No install step changes this" >&2
            echo "        box's layout — fix it by farming the target, or on #427 for the job's WORK." >&2
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
