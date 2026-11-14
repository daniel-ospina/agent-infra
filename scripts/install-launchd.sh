#!/usr/bin/env bash
# install-launchd.sh — idempotent installer for agent-infra launchd templates
# (agent-infra #304).
#
# Renders templates/launchd/*.plist with machine env, diffs the rendered
# output against the installed copy in ~/Library/LaunchAgents, and reloads
# (enable → bootout → bootstrap) on change.
# ⛔ "Byte-identical → skip" is a statement about the FILE, never about the JOB (#4008). A
# byte-identical plist whose job is NOT in the domain is bootstrapped (the reload runs only when the
# job is absent, so a healthy job is still never restarted), and every reload is read back with
# `launchctl print` — `bootstrap` exiting 0 is launchd accepting the request, not the job running.
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
# ⛔ cmux-GATED SCRIPTS REFUSE TO INSTALL (#1867). A template whose ProgramArguments
# name a script listed in templates/launchd/LAUNCHD-INCOMPATIBLE is a HARD FAILURE:
# the cmux control socket (`socketControlMode = cmuxOnly`) gates on launch-chain
# ATTRIBUTION, which a launchd job never has, so such a job would run, log and do
# nothing — the false PASS measured as 1,695 `lane-status: DEGRADED` reads and 0
# delivered nudges. The refusal names the documented launch path instead of widening
# the socket (that is an owner decision, argued on its own issue).
#
# `--status` also reports an INSTALLED plist with NO template as UNMANAGED and exits
# non-zero: that was the blind heartbeat's exact shape — a job on the box that the
# declared set no longer describes, invisible to every content-drift comparison. The
# declared set is resolved RECURSIVELY (`templates/launchd/*/label.plist` counts — the
# four repo templates that ship one directory down are this repo's own jobs, not
# strays, #1867 review P1). Two classes are declared elsewhere and are NOT reported as
# UNMANAGED: labels in RETIRED (declared, pending removal by `retire_pass`) and labels
# in OWNED-BY-OTHER-INSTALLERS (another surface of this repo installs or adopts them —
# every installer in `scripts/`, and the box's own adopted controller job), so the alarm
# stays about jobs nobody declares. ⛔ RETIRED IS NOT "GREEN", THOUGH (round 8): an
# installed RETIRED label is reported as `⛔ RETIRED-INSTALLED` and the verb exits 1
# until an install removes it — `retire_pass` runs on INSTALL, never on `--status`, so
# exempting the class from BOTH the row and the exit code certified a box that was
# still ticking the blind job this change exists to remove.
# Exit codes for `--status`: 0 clean · 1 something on the box is not what this repo declares —
# a per-job verdict on an INSTALLABLE template (NOT INSTALLED, `not loaded`, or `DRIFTED`), an
# installed job with no template (UNMANAGED), or a RETIRED label still installed — · 2 a question
# could NOT be answered (the installed set, or the declared set, could not be read: UNKNOWN, never a
# pass — #1867 review P2). A template the installer would SKIP for an unset placeholder prints
# `NOT APPLICABLE` and is NOT a failure: a Mac with no tortoise checkout is a legitimate box, not a
# broken one. If such a template is ALREADY INSTALLED it prints `⚠️ INSTALLED-SKIPPED` instead (rc 0
# as well): the copy on disk is stale — no install will refresh it while the placeholder stays
# unresolved — but it usually still runs, so it is a disclosure, not a failure. That marker is counted
# by `scripts/fleet-schedule.py --verify` to narrow its verdict; it never makes this verb exit non-zero.
# `2` is ALSO the global usage code; see the second Exit-codes line below the env list.
#
# Usage:
#   install-launchd.sh               install/refresh all templates (idempotent)
#   install-launchd.sh --status      per-job: installed? loaded? version? drift?  (non-zero if an
#                                    INSTALLABLE job is absent, unloaded or drifted, or a job is
#                                    undeclared or retired-installed; NOT APPLICABLE is a skip, not a
#                                    failure)
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
# ⛔ AND `--status` REUSES 2 FOR A THIRD MEANING, so it is spelled here as well as in the
# UNMANAGED paragraph above (#1867 review P3): for THAT verb the three codes are 0 clean · 1 something
# on the box is not what this repo declares (a per-job verdict, UNMANAGED, or RETIRED-INSTALLED) ·
# 2 a question could not be answered (the installed set or the declared set could not be read —
# UNKNOWN, never a pass).
# The two readings of `2` cannot be confused in practice — `usage()` exits before any work
# starts and never prints a status body, while the UNKNOWN arm prints and exits 2 from a
# completed run — but a caller reading only this line would be told the wrong thing, and the
# one caller that gates on the code (`scripts/fleet-schedule.py`) treats any non-zero as
# `SCHEDULE NOT VERIFIED` either way. Read the VERB's own line when the distinction matters.
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES_DIR="${TEMPLATES_DIR:-$INFRA_ROOT/templates/launchd}"
AGENTS_DIR="${AGENTS_DIR:-${HOME:?HOME is required}/Library/LaunchAgents}"
DOMAIN="gui/$(id -u)"

# The range is DERIVED, not literal (#1867). It used to be `sed -n '2,64p'` with a comment saying
# the number "moves with the header" — i.e. every header edit silently truncated `--help`, and an
# earlier one already had. The block still ends on `set -uo pipefail`; the line number is now read
# from the file instead of restated, so a header edit cannot desynchronise it.
usage() {
    local end
    end="$(grep -n '^set -uo pipefail' "$0" | head -1 | cut -d: -f1)"
    [ -n "${end:-}" ] && [ "$end" -gt 2 ] || end=76
    sed -n "2,$((end - 1))p" "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

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
# point: an executed script misread as `data` arms a unit launchd cannot start — the exact defect this
# guard exists for. The OTHER direction is not cheap either, and its cost is stated as MEASURED rather
# than as hoped: a data value misread as `exec` costs a whole-install ABORT (not "a loud SKIP") when it
# is a non-TCC DIRECTORY, because the file-type arm fails it and `sync.sh` then dies under `set -e`
# before its cost-config and parity gates — the #3413 P1-A failure this file already paid for once,
# which is exactly why `--repo`/`--root` are derived as `data` by BOTH readers (#3413 review, round 6).
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
# ⛔ env OPTIONS THAT TAKE A **REQUIRED** VALUE IN THE SPACE FORM. Skipping only the OPTION left its
# VALUE as the first positional, so the VALUE was promoted to launcher and the real program was then
# classified as a TARGET: `env -u PYTHONPATH <TCC venv python> <script>` — the two reapers' shape —
# went from verdict 0 to verdict 2, i.e. SKIP + `launchctl bootout` + `rm -f` of an installed,
# grant-holding unit (review of #3413, round 8 P2).
# The JOINED spellings (`--unset=NAME`) carry their value in the token and are already skipped by the
# `"=" in a` arm below.
# ⛔ AND ONLY THE **REQUIRED** ONES: coreutils declares `--block-signal[=SIG]`,
# `--default-signal[=SIG]` and `--ignore-signal[=SIG]` with an OPTIONAL argument, so the space form
# passes the PROGRAM through (`env --ignore-signal /bin/echo HELLO` echoes HELLO — measured). Listing
# them here consumed the program and turned a working unit into a SKIP + disarm in BOTH readers, which
# no differential test can see (review of #3413, round 9 P2).
ENV_VALUE_OPTIONS = {"-u", "--unset", "-C", "--chdir", "-P"}
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
                seen_val_opt = False
                for j, tok in enumerate(toks):
                    if not isinstance(tok, str) or not tok:
                        continue
                    if not seen_prog:
                        # env's FIRST POSITIONAL token is the program it execs, so it is a LAUNCHER —
                        # exactly what the space form promotes at argv[1]. An option or a NAME=VALUE
                        # is not the program and does not end the search.
                        # ⛔ AND A REQUIRED-VALUE OPTION CONSUMES THE NEXT TOKEN FIRST, the same rule
                        # the space form applies: without it `-S '-u PYTHONPATH <TCC python> <script>'`
                        # promoted the VALUE to launcher, verdicted the real program as a TARGET, and
                        # SKIPped + DISARMED a grant-holding unit that the awk reader installed
                        # (review of #3413, round 9 P1).
                        if tok in ENV_VALUE_OPTIONS:
                            seen_val_opt = True
                            continue
                        if seen_val_opt:
                            seen_val_opt = False
                            continue
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
            if a in ENV_VALUE_OPTIONS:
                # ⛔ THE VALUE IS CONSUMED **AND SKIPPED**. Dropping it from the scan alone left the
                # emission loop below to re-read it as a target: `env -C /tmp /bin/bash <farm>` filed
                # `/tmp` as EXEC → verdict 1 → the WHOLE install aborted (`sync.sh` dies under `set -e`),
                # and a TCC-root value was SKIPped + DISARMED — while the awk reader, which does drop
                # it, installed. A reader disagreement introduced by the round-8 fix (review of #3413,
                # round 9 P1).
                if i + 1 < len(argv):
                    skipped.add(i + 1)
                    i += 2
                else:
                    i += 1
                continue
            if a.startswith("-") or ("=" in a and not a.startswith("/")):
                # ⛔ THE **JOINED** SPELLING OF A REQUIRED-VALUE OPTION CARRIES ITS VALUE IN THE TOKEN,
                # so it must be SKIPPED as well as dropped from the scan: the emission loop's
                # `--opt=<value>` arm split `--chdir=/tmp` into `exec /tmp` and FAILED the whole
                # install (review of #3413, round 9 P1).
                if a.startswith("--") and "=" in a and a.split("=", 1)[0] in ENV_VALUE_OPTIONS:
                    skipped.add(i)
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
    # ⛔ `argv[0]` IS NEVER AN OPTION, so it can never be the `prev` of element 1. With `Program` set it
    # is only the argv[0] NAME launchd passes — an arbitrary string, and `--repo` is a legal one — and
    # without it, a relative program name. Either way element 1 is an EXECUTED positional.
    # Reading `--repo` out of argv[0] filed a TCC-tree script as `data` → WARN + INSTALL of an
    # ARMED-AND-DEAD unit, which is the exact class this change exists to close. MEASURED (fresh review
    # of #3413, round 10 P2), driving the real parsers: `Program=/bin/bash` with
    # `ProgramArguments=(--repo <TCC script>)` went `exec`/verdict 2 → `data`/verdict 0, and
    # `Program=/usr/bin/python3` with `(--root <TCC dir>)` the same. Both readers shared the rule, so no
    # differential case could see it: the fix must be here and in the awk mirror, not in one of them.
    prev = argv[i - 1] if i >= 2 and isinstance(argv[i - 1], str) else ""
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
    # ⛔ THE FALLBACK CANNOT KNOW MOST ROLES, so for the residue it emits `unknown` and says so: there
    # is no `env` hop. On the TCC axis `unknown` is treated as EXECUTED (a unit launchd cannot read
    # must never be armed); on the file-type axis it is held to the SAME regular-file rule the python
    # reader applies to `exec`. Both arms are conservative in the SKIP/FAIL direction. There is NO
    # directory exemption: an earlier version had one, written when this reader could not name
    # `--repo`/`--root` and a directory-valued `--repo` aborted the whole install on a PlistBuddy-only
    # host (the #3413 P1-A failure). Those values are `data` now and never reach the escape, so it
    # protected nothing and only ARMED a directory at an executed position (review of #3413, round 5 P2).
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
    #      token — python splits it in the emission loop's joined `--opt=<value>` arm, and the fallback
    #      used to drop it silently, so a `--script=<TCC>` installed armed-and-dead with NO verdict at
    #      all.
    # Reachable on any Mac whose `/usr/bin/python3` shim is executable but exits non-zero (no Command
    # Line Tools), because `plist_python` accepts it on `-x` alone. A guard that silently UNINSTALLS
    # working units on the fallback path is the same fail-open/fail-wrong family as `[ -e ]`.
    # WHAT IS STILL `unknown`: an absolute element that is neither the launcher nor a data-option's
    # value (an interpreter's script argument, an `env` program, a second positional). Those keep the
    # TCC verdict AND the file-type one — a DIRECTORY there fails the install exactly as the python
    # reader's `exec` arm does, because a directory at an executed position is not a data value in any
    # reading and `bash <dir>` exits 126 EISDIR on every tick. (An EARLIER version excused it "in the
    # skip direction"; that was only true while this reader could not name `--repo`/`--root`, and it
    # armed the unit instead — review of #3413, round 5 P2.)
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
        # env -S own grammar: whitespace separates, BACKSLASH escapes the next char and `\\_` is a
        # literal space (env documented way to embed one). Mirrors the python `env_split`.
        function env_split(s,   n, i, c, cur) {
            n = 0; i = 1; cur = ""
            while (i <= length(s)) {
                c = substr(s, i, 1)
                if (c == "\\" && i < length(s)) {
                    c = substr(s, i + 1, 1)
                    cur = cur ((c == "_") ? " " : c)
                    i += 2
                    continue
                }
                if (c == " " || c == "\t" || c == "\r") {
                    if (cur != "") { SPLIT[++n] = cur; cur = "" }
                    i += 1
                    continue
                }
                cur = cur c
                i += 1
            }
            if (cur != "") SPLIT[++n] = cur
            return n
        }
        # The three rules of the argv loop, applied to the tokens of an `env -S` command line.
        function classify_cmd(cmd,   n, j, tok, prv, seenp, nm, val, vwant) {
            n = env_split(cmd)
            seenp = 0; vwant = 0
            for (j = 1; j <= n; j++) {
                tok = SPLIT[j]
                if (tok == "") continue
                if (!seenp) {
                    if (vwant) { vwant = 0; continue }
                    if (tok in VALUE_OPTS) { vwant = 1; continue }
                    if (tok ~ /^-/ || (index(tok, "=") > 0 && tok !~ /^\//)) continue
                    seenp = 1
                    if (tok ~ /^\//) printf "launcher\t%s\n", tok
                    continue
                }
                if (tok ~ /^--/ && index(tok, "=") > 0) {
                    nm = substr(tok, 1, index(tok, "=") - 1)
                    val = substr(tok, index(tok, "=") + 1)
                    if (val ~ /^\//)
                        printf "%s\t%s\n", (nm == "--repo" || nm == "--root") ? "data" : "exec", val
                    continue
                }
                if (tok !~ /^\//) continue
                prv = (j > 1) ? SPLIT[j - 1] : ""
                printf "%s\t%s\n", (prv == "--repo" || prv == "--root") ? "data" : "exec", tok
            }
        }
        BEGIN {
            seen = 0; prev = ""; idx = -1; envmode = 0; wantcmd = 0; wantval = 0
            # the same table the python reader carries (ENV_VALUE_OPTIONS): an option whose VALUE is
            # the next element, or the value is mistaken for env program and the real program becomes a
            # TARGET (review of #3413, round 8 P2).
            # ONLY the REQUIRED-value options (the python table is the same set): coreutils declares
            # `--block-signal[=SIG]` / `--default-signal[=SIG]` / `--ignore-signal[=SIG]` with an
            # OPTIONAL argument, so the space form passes the PROGRAM through and listing them here
            # consumed it — turning a working unit into a SKIP + disarm in both readers (review of
            # #3413, round 9 P2).
            VALUE_OPTS["-u"] = 1; VALUE_OPTS["--unset"] = 1; VALUE_OPTS["-C"] = 1
            VALUE_OPTS["--chdir"] = 1; VALUE_OPTS["-P"] = 1
            if (prog ~ /(^|\/)env$/) envmode = 1
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
            # ⛔ AND `prev` IS UPDATED TO THE EMPTY VALUE — python takes `prev = argv[i - 1]`, which for
            # an element after an empty one IS `""`. Leaving `prev` untouched made the fallback keep
            # seeing `--repo` as the preceding element and call the next path `data` — WARNed and
            # INSTALLED a unit the python reader refuses as EXEC (fresh review of #3413, round 4 P2).
            if (line == "") {
                # ⛔ AN EMPTY ROW *IS* THE FIRST POSITIONAL OF `env`, SO IT CAN END THAT SCAN. The python
                # reader reaches its `if a.startswith("/")` test, finds `""` relative, and `break`s —
                # the scan is OVER, so the next absolute element is the SCRIPT that program runs, not a
                # second program. `next`ing here before the `env` hop left `envmode` set, so the next row
                # was promoted to LAUNCHER, `$grants` was populated for its tree, and the unit installed
                # with only a WARN — while `env "" <prog>` exits 127 ENOENT on every tick. Measured:
                # `[env, "", <TCC binary>]` was SKIPped + DISARMED by python (rc 2) and WARNed +
                # INSTALLED by this reader (rc 0). A role disagreement IS a verdict difference, and
                # this one was in the fail-open direction (fresh review of #3413, round 11 P2).
                # ⛔ THE OTHER TWO PENDING STATES ARE NOT THE SAME CASE, and the python shape is copied
                # exactly: after a required-value option the empty element is the VALUE of that option
                # (python marks it `skipped` and keeps scanning), while after `-S` it is the command
                # LINE (python reads it, finds no tokens, and `break`s). Only those two end the scan.
                if (envmode) {
                    if (wantval) wantval = 0
                    else { wantcmd = 0; envmode = 0 }
                }
                prev = line
                next
            }
            # ⛔ `Program` WINS, so element 0 is ONLY argv[0] and is not verdicted at all — exactly the
            # python reader (its `skipped.add(0)`). This test comes BEFORE the joined `--opt=` branch,
            # because with `Program` set python emits nothing for a `--script=<TCC>` at argv[0] while
            # the fallback used to emit `exec` there and SKIP a unit python installs (round 3 P2).
            # ⛔ `prev = ""`, NOT `prev = line`: argv[0] is never an option, so an element at index 1
            # must not inherit a `--repo` argv[0] as its data context (fresh review of #3413, round 10
            # P2 — see the matching arm in the python reader above).
            if (idx == 0 && prog != "") { prev = ""; next }
            # ⛔ THE `env` HOP, MIRRORED FROM THE PYTHON READER (the `launchers[-1] == "env"` block,
            # from its first positional through its `ENV_VALUE_OPTIONS` consume arm). It is not decoration: the
            # first POSITIONAL after `env` is the program launchd execs, and `-S` / `--split-string`
            # carries a WHOLE COMMAND LINE inside one element. Without this the fallback classified
            # `-S "/bin/bash <script>"` as one path ("broken target: /bin/bash /x.sh" -> verdict 1, the
            # whole install aborts) and DROPPED the `-S<joined>` spelling entirely (the element starts
            # with `-S`, is not absolute, so it got no verdict at all) — a TCC-tree script inside it
            # then installed ARMED AND DEAD, the one direction this change exists to close (fresh
            # review of #3413, round 6 P2).
            if (envmode && idx >= 1) {
                if (wantcmd) { wantcmd = 0; classify_cmd(line); envmode = 0; prev = line; next }
                if (line == "-S" || line == "--split-string") { wantcmd = 1; prev = line; next }
                if (line ~ /^--split-string=/) { classify_cmd(substr(line, 16)); envmode = 0; prev = line; next }
                if (line ~ /^-S/) { classify_cmd(substr(line, 3)); envmode = 0; prev = line; next }
                if (line in VALUE_OPTS) { wantval = 1; prev = line; next }
                if (wantval) { wantval = 0; prev = line; next }

                # an option or a NAME=VALUE is not the program and does not end the search
                if (line ~ /^-/ || (index(line, "=") > 0 && line !~ /^\//)) { prev = line; next }
                # the FIRST positional is the env program: a LAUNCHER, exactly what the space form
                # promotes at argv[1]. An absolute one is emitted; a relative one is resolved through
                # PATH and cannot be checked, so it is consumed without a record.
                if (line ~ /^\//) printf "launcher\t%s\n", line
                envmode = 0
                prev = line
                next
            }
            # `--opt=<path>` carries its value INSIDE the token (python splits it in the emission
            # loop, joined `--opt=<value>` arm); dropping it made a `--script=<TCC>` install with no
            # verdict at all.
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
                    envmode = (line ~ /(^|\/)env$/) ? 1 : 0
                } else if (prev == "--repo" || prev == "--root") {
                    printf "data\t%s\n", line
                } else {
                    printf "unknown\t%s\n", line
                }
            }
            # ⛔ argv[0] IS NEVER AN OPTION, in every arm — including the arms above that `next` before
            # reaching here (each sets `prev` itself for the same reason). Element 0 keeps `prev` EMPTY,
            # so element 1 is EXEC rather than inheriting a `--repo` argv[0] as data context (fresh
            # review of #3413, round 10 P2).
            prev = (idx == 0) ? "" : line
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
        # ⛔ THE cmux GATE, BEFORE THE TCC AND FILE-TYPE VERDICTS (#1867). A cmux-gated script is
        # not "protected" and it is not "broken" — it is a job that will install cleanly, load
        # cleanly, tick cleanly and be BLIND for its whole life. Every other arm here answers "can
        # launchd execute this file"; this one answers "may the result see anything", which no
        # content comparison can. Measured cost of not having it: 1,695 degraded reads, 0 nudges.
        if is_cmux_gated "$arg"; then
            echo "    cmux-GATED script cannot run under launchd: $arg" >&2
            echo "        the cmux socket (socketControlMode = cmuxOnly) gates on launch-chain" >&2
            echo "        attribution, which a launchd job never has — this job would install, load," >&2
            echo "        tick and deliver NOTHING while its log read as activity (#1867)." >&2
            echo "        Documented launch path: bash scripts/heartbeat-launch.sh start" >&2
            echo "        See docs/ops/heartbeat-launch-path.md. Relaxing the socket is an owner" >&2
            echo "        decision and is NOT the fix." >&2
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
                    # ⛔ BUT IT STILL CONSULTS THE GRANT, exactly as the `exec` arm below does. The
                    # fallback derives the LAUNCHER role now, so `$grants` is populated on this path:
                    # without this branch, `[<TCC-root BINARY>, <script in the SAME TCC root>]` — the
                    # shape the two `com.tortoise.*` reapers render whenever the farmed entry resolves
                    # into the tree — was WARNed and installed by the python reader and SKIPped +
                    # DISARMED here, i.e. a working unit silently removed from the box (fresh review of
                    # #3413, round 7 P2).
                    root="$(tcc_protected_root "$arg")"
                    case "$grants" in
                        *" $root "*)
                            # ⛔ THE GRANT PROVES READABILITY, NOT THAT THE ARGUMENT IS USABLE. `$grants`
                            # says this unit's launcher can READ the tree; it says nothing about whether
                            # the value handed on is a file at all. THIS branch ARMS the unit, so an
                            # unusable value here is exactly the armed-and-dead state the whole change
                            # exists to remove: `bash <dir>` is 126 EISDIR on every tick, a 0-byte script
                            # runs and does nothing, an unreadable one is 126 — whatever tree it is in.
                            # ⛔ IT DOES NOT SHADOW THE `tcc_exec=1` PATH BELOW. That path SKIPS AND
                            # DISARMS, so verdict 2 is already the safe answer there and a FAIL would
                            # only take `sync.sh` down with it — the "TCC VERDICT COMES FIRST" note at
                            # the top of this loop is where that rule is recorded and justified. Here
                            # the choice is narrower and the two ends are not symmetric: arming a dead
                            # unit is a SILENT false PASS (category A), while declining to arm one is
                            # loud and repairable by an install step (a re-farm, a chmod — verdict 1's
                            # own definition).
                            # ⛔ AND IT IS WHY THE TWO READERS STAY IN STEP: python derives `exec` for
                            # `--script <dir>` and this arm derives `unknown`, so a predicate applied to
                            # only the `exec` arm is a reader divergence — the class round 7 fixed on
                            # the launcher role (fresh review of #3413, round 10 P2).
                            if [ ! -f "$arg" ] || [ ! -r "$arg" ] || [ ! -s "$arg" ]; then
                                echo "    unreadable or not a regular file: $arg" >&2
                                echo "        inside a TCC tree this unit's launcher holds a grant for, so" >&2
                                echo "        the unit WOULD be armed — but a directory, an empty file or an" >&2
                                echo "        unreadable one is dead on every tick whatever tree it lives in," >&2
                                echo "        which reads as 'installed' to every instrument that only" >&2
                                echo "        checks existence." >&2
                                bad=1
                                continue
                            fi
                            echo "    WARN TCC-protected target: $arg" >&2
                            echo "        inside $root, the SAME tree this unit's launcher holds a" >&2
                            echo "        grant for (#1311) — installing, not skipping." >&2
                            continue
                            ;;
                    esac
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
                    # ⛔ NO DIRECTORY ESCAPE FOR `unknown`. One used to live here, on the argument that
                    # a directory is "a data value the fallback could not name" — true only while the
                    # fallback could not name `--repo`/`--root`. It can now (they are `data`, and the
                    # `data` arm above returns before this one), so the escape no longer protects the
                    # class it was written for and only ARMED a directory at an executed position on
                    # the fallback path while the python reader REFUSED it — measured on this head:
                    # py rc=1 nothing installed / fallback rc=0 `installed + loaded`, then `bash`
                    # exits 126 EISDIR every tick. That is the armed-and-dead state this change
                    # exists to remove (fresh review of #3413, round 5 P2).
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
                        # ⛔ SAME PREDICATE, SAME REASON, IN THE `exec` ARM. `$grants` proves the launcher
                        # can READ this tree; it says nothing about whether `$arg` is a usable file. This
                        # branch ARMS the unit, so a directory (`bash <dir>` → 126 EISDIR every tick), a
                        # 0-byte script (runs, does nothing) or an unreadable one installed as
                        # `installed + loaded` and read as healthy to every existence-checking
                        # instrument — the category-A false PASS this change exists to remove. The
                        # `launcher` arm already made this call for the x bit in round 9, for the same
                        # stated reason: a property that is dead on every tick WHATEVER TREE IT LIVES
                        # IN belongs above the TCC branch. The file-type predicate is such a property;
                        # the TCC branch only decides whether the unit is skipped (verdict 2), so it
                        # still governs the `tcc_exec=1` path below (fresh review of #3413, round 10 P2).
                        if [ ! -f "$arg" ] || [ ! -r "$arg" ] || [ ! -s "$arg" ]; then
                            echo "    unreadable or not a regular file: $arg" >&2
                            echo "        inside a TCC tree this unit's launcher holds a grant for, so the" >&2
                            echo "        unit WOULD be armed — but a directory, an empty file or an unreadable" >&2
                            echo "        one is dead on every tick whatever tree it lives in, which reads as" >&2
                            echo "        'installed' to every instrument that only checks existence." >&2
                            bad=1
                            continue
                        fi
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

# ── reload_job: PUT THE JOB IN THE DOMAIN, then READ IT BACK ────────────────────────────────────
# ⛔ `enable` COMES FIRST AND IS NOT DECORATION. A `launchctl disable` override is stored OUTSIDE the
# plist and survives `bootout` AND `bootstrap` (launchctl(1): "a disabled service cannot be loaded in
# that domain until re-enabled"), so a bare bootstrap on a box where anything ever disabled the label
# fails for a reason that reads as a launchd fault. The reload path has always done this; #4008's new
# path must too, or the fix would converge every box except the one that needs it.
# ⛔ `bootout` IS TOLERATED ON FAILURE because a job that was never loaded exits nonzero — but it is
# still issued, so `bootstrap` always starts from a free slot rather than racing an existing job.
# ⛔ AND THE READ-BACK IS THE POINT: `bootstrap` exiting 0 is launchd ACCEPTING the request, not the
# job being in the domain. Reading `job_loaded` back is what makes "installed + loaded" a measurement
# instead of an assumption — the #4008 probe in install_job depends on it.
reload_job() { # <label> <installed-plist>; 0 = loaded (read back), 1 = not
    local label="$1" installed="$2"
    launchctl enable "$DOMAIN/$label" 2>/dev/null || true
    launchctl bootout "$DOMAIN" "$installed" 2>/dev/null || true
    if ! launchctl bootstrap "$DOMAIN" "$installed"; then
        echo "  FAIL $label: launchctl bootstrap exited nonzero — see 'launchctl print $DOMAIN/$label'" >&2
        return 1
    fi
    if ! job_loaded "$label"; then
        echo "  FAIL $label: launchctl bootstrap exited 0, but 'launchctl print $DOMAIN/$label' does not list the job — it is STILL NOT LOADED and will never run" >&2
        return 1
    fi
    return 0
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
    # ⛔ THE REASON, CAPTURED BEFORE THE TEMP FILE GOES (#3826 review P3). `vrc` cannot distinguish a
    # cmux refusal from a farm gap, so this arm told the operator to "fix the farm/checkout first (run
    # sync.sh / pi-bootstrap setup.sh)" for a cmux-gated template — a remedy that provably cannot clear
    # it, printed directly beneath the correct diagnosis. On `origin/main` that sentence was only ever
    # emitted for genuinely missing targets.
    local cmux_target=""
    cmux_target="$(plist_cmux_gated_target "$tmp" || true)"
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
        if [ -n "$cmux_target" ]; then
            echo "  REFUSING $label: this template names a cmux-gated script ($cmux_target) —" >&2
            echo "        it is not a farm gap and no install step fixes it: under launchd it would" >&2
            echo "        install, load, tick and deliver NOTHING (#1867)." >&2
            echo "        Remove the template from the set (templates/launchd/LAUNCHD-INCOMPATIBLE)," >&2
            echo "        and run the heartbeat through its documented launch path instead:" >&2
            echo "        bash scripts/heartbeat-launch.sh start" >&2
            return 1
        fi
        echo "  FAIL $label: script target(s) above are missing or unreachable from launchd —" >&2
        echo "        fix the farm/checkout first (run sync.sh / pi-bootstrap setup.sh), then re-run." >&2
        echo "        Refusing to install: a unit launchd cannot start reads as 'armed' and does" >&2
        echo "        nothing, which is worse than no unit at all." >&2
        return 1
    fi

    # ⛔ BYTE-IDENTICAL IS NOT CONVERGED — THE FILE IS NOT THE JOB (agent-infra#4008).
    # This branch used to return 0 on `cmp -s` ALONE, so the installer converged the FILE and never
    # asked whether the job was IN THE DOMAIN. The two are independent: `launchctl bootout` removes a
    # job from its domain and LEAVES THE PLIST FILE IN PLACE (launchctl(1) — measured), a `disable`
    # override survives both, and a bootstrap that failed after an earlier bootout leaves exactly this
    # shape. So `~/Library/LaunchAgents/com.eldato.worker-supply.plist` existed,
    # `launchctl list | grep -c worker-supply` printed 0, and every run of this installer answered
    # "unchanged (skip)" — forever. Not one install verb in the repo could bring that job back, while
    # BOTH readers (`status_job` below, and `fleet-schedule.py --verify`) named it "not loaded": the
    # box was diagnosed correctly and repaired by nothing, which is #4008's measured state exactly.
    # ⛔ THE LINUX HALF ALREADY LEARNED THIS AND THE MAC HALF DID NOT. `install-worker-supply.sh`'s
    # byte-identical branch says: "the read-back still runs, because 'unchanged file + not running' is
    # a real state that must not read as healthy" — and then starts the unit. Same capability, same
    # convergence contract, one backend missing the read-back. This closes that asymmetry rather than
    # inventing a rule: the no-churn property (a healthy job is NOT restarted on every sync) survives
    # untouched, because the reload only happens when the job is absent from the domain.
    if [ -f "$installed" ] && cmp -s "$installed" "$tmp"; then
        rm -f "$tmp"
        if job_loaded "$label"; then
            echo "  $label: unchanged (skip)"
            return 0
        fi
        echo "  $label: unchanged on disk but NOT LOADED — bootstrapping it (a booted-out job keeps its plist)"
        if ! reload_job "$label" "$installed"; then
            return 1
        fi
        echo "  $label: reloaded + loaded (v$(version_of "$template" || echo unknown))"
        return 0
    fi

    mkdir -p "$AGENTS_DIR"
    mv "$tmp" "$installed"
    if ! reload_job "$label" "$installed"; then
        rm -f "$installed"   # nothing half-installed
        return 1
    fi
    echo "  $label: installed + loaded (v$(version_of "$template" || echo unknown))"
    return 0
}

status_job() {
    local template="$1" label installed rendered version state drift ph unset_ph
    label="$(job_label "$template")"
    installed="$AGENTS_DIR/$label.plist"
    rendered="$(render "$template")"
    version="$(version_of "$template" || echo "?")"

    # ⛔ A TEMPLATE THE INSTALLER WOULD SKIP IS `NOT APPLICABLE`, NOT A FAILURE (#1867 review, round 9).
    # `install_job` deliberately SKIPs a template whose placeholder resolves empty ("is this a swarm
    # host?") and a {{PATH}} that renders empty. Those boxes are LEGITIMATE — a Mac with no tortoise
    # checkout is the common case — and calling them failures would make this verb permanently red on
    # a healthy box, which is the anti-pattern that produced the OWNED-BY-OTHER-INSTALLERS exemption in
    # the first place. The two guards below are the install path's own, mirrored verbatim; one list,
    # one meaning, so a template cannot be skipped at install time and demanded by `--status`.
    unset_ph=""
    for ph in "${PLIST_PLACEHOLDERS[@]}"; do
        if grep -q "{{$ph}}" "$template" && [ -z "${!ph:-}" ]; then
            unset_ph="$unset_ph {{$ph}}"
        fi
    done
    # `install_job`'s SECOND skip guard, tested on the value that will actually be WRITTEN: a PATH
    # composed only of unreadable entries is non-empty RAW and empty RENDERED, so the loop above passes
    # and the unit would install with `<key>PATH</key><string></string>` (an installed-but-inert job).
    if [ -z "$unset_ph" ] && grep -q '{{PATH}}' "$template" && [ -z "$(launchd_path)" ]; then
        unset_ph=" {{PATH}}"
    fi
    if [ -n "$unset_ph" ]; then
        # ⛔ THE SKIP PREDICATE OUTRANKS "IS IT INSTALLED" (#1867 review, round 10). Round 9 put this
        # arm inside the `[ ! -f "$installed" ]` branch, so it only fired for an ABSENT plist: a job
        # installed while the placeholder still resolved, on a box that has since stopped qualifying
        # (SWARM_ROOT unset, the tortoise checkout removed), fell through to the `cmp` below and was
        # reported `DRIFTED … re-run installer` — with a remedy that provably cannot clear it, because
        # the installer SKIPs that very template. MEASURED: install with SWARM_ROOT set → `in sync` rc
        # 0; unset SWARM_ROOT → `(DRIFTED …)` rc 1; re-run the printed remedy → `SKIP … unresolved
        # placeholder(s) {{SWARM_ROOT}}`, plist still installed, status still `DRIFTED` rc 1. That is a
        # PERMANENT red on a legitimate box — the anti-pattern the OWNED-BY-OTHER-INSTALLERS exemption
        # exists to remove.
        if [ -f "$installed" ]; then
            # Still INSTALLED, so say so — this is not silently a clean box: the copy on disk is
            # neither refreshed nor removed by an install, so whatever renders today is what runs.
            # rc 0 because the box did not break: it stopped qualifying, which is the documented
            # SKIP arm of the install path. The row is the disclosure; the exit code is not the place
            # to keep a red that no install can clear.
            # ⛔ AND THE ROW NEEDS A MARKER, NOT JUST WORDS (#1867 review, round 11). The ONLY
            # consumer that gates on this verb is `scripts/fleet-schedule.py --verify`, and it decides
            # its sentence by COUNTING MARKERS — so a row of plain prose reached it as no row at all
            # and the verdict said `SCHEDULE VERIFIED — launchd job set matches templates/launchd` over
            # a box whose installed copy is provably not what the template describes. MEASURED with a
            # delegate emitting this row plus one `in sync` job: rc 0, `SCHEDULE VERIFIED … matches`.
            # The state is NOT disarmed on purpose: unlike the TCC arm, the plist on disk still holds
            # the value it was installed with, so it usually still WORKS — removing it because a
            # shell forgot a variable would break a healthy job. It is a disclosure, so the marker is
            # counted for the VERDICT SENTENCE, never for the exit code.
            echo "  ⚠️ INSTALLED-SKIPPED   $label: INSTALLED, but SKIPPED now (needs$unset_ph, unset on this box — the installer SKIPs this template, so the installed copy is neither refreshed nor removed)"
            return 0
        fi
        echo "  $label: NOT APPLICABLE (needs$unset_ph, unset on this box — the installer SKIPs it)"
        return 0
    fi
    # ⛔ THE INSTALL PATH HAS THREE SKIP ARMS, NOT TWO (#3826 review P2, round 2). The guards above
    # mirror `install_job`'s unresolved-placeholder and empty-`{{PATH}}` arms. `install_job` SKIPs a
    # THIRD class — a unit whose rendered target sits under a macOS TCC root (`verify_targets` → 2,
    # #427) — and returns 0 having DISARMED any installed copy. Without the same arm here that
    # template fell through to `NOT INSTALLED` + rc 1: a PERMANENT red no command can clear, because
    # re-running the installer SKIPs it again. MEASURED on the suite's own TCC fixture:
    #   install   → `SKIP … a macOS TCC root (#427)`   rc 0
    #   --status  → `NOT INSTALLED (template v0.2.0)`  rc 1
    # and `fleet-schedule.py --verify` turns that rc into `SCHEDULE NOT VERIFIED` → `activate-harness
    # … FAILING`. That is the "instrument whose healthy state is red" class this file removes for
    # every OTHER skip arm (rounds 9-11), left standing on the one added for #427 — and the comment
    # above says the guards are "mirrored verbatim … so a template cannot be skipped at install time
    # and demanded by `--status`", which this arm is what makes true.
    # ⛔ IT REPORTS A SKIP, NOT A PASS: the installed-copy variant keeps a counted marker, so a box
    # still holding one is disclosed to the verdict sentence rather than certified clean.
    local _tmp _tcc_vrc _cmux_target="" _cmux_rc=0
    # ⛔ THE RENDERED PLIST IS MATERIALISED IN A REAL TEMP FILE, AND A TEMP-FILE FAILURE IS ITS OWN
    # FAIL-CLOSED ANSWER — never a content verdict (#3826 review P1, round 17).
    # Round 16 took the cmux question out of the `mktemp` guard to stop an unwritable TMPDIR from
    # hiding a gated job, and handed it a PROCESS SUBSTITUTION instead. That reads as a path and is a
    # PIPE: `plist_program_args` → `plist_reader_py` does `plistlib.load(open(sys.argv[1], "rb"))`,
    # `plistlib` requires a SEEKABLE stream, and `/dev/fd/N` raises
    # `UnsupportedOperation: File or stream is not seekable` → the reader exits 3, the PlistBuddy
    # fallback does not exist off macOS, so `_cmux_target` came back EMPTY for a GATED job, this arm
    # was skipped, and the row fell through to the content comparison below. MEASURED at `8aade2a1c`
    # on a byte-identical install of a template naming `scripts/heartbeat-loop.sh` (both readers
    # isolated on a real file vs a process substitution): `installed=loaded version=v0.0.1 (in sync)`,
    # rc **0** — the certify-the-blind-job fail-open this whole change exists to remove, re-opened by
    # its own fix, with the repo's own §17b red on it (5 assertions).
    # ⛔ SO: ONE real temp file serves BOTH probes (the TCC arm already needed one), and `mktemp`
    # failing is answered as `2 UNKNOWN` — which is what round 16's goal actually required ("a broken
    # TMPDIR must not be able to hide a gated job") without asserting that a pipe is a file.
    # `plist_program_args` writes its READER to a temp file too, so the same broken TMPDIR surfaces
    # one call in as rc=3 ("could not read") rather than as "not gated" — see `plist_cmux_gated_target`.
    # ⛔ ASKED FROM THE MANIFEST AGAIN, DELIBERATELY — NOT DERIVED FROM `verify_targets`'s exit code
    # (#3826 review P2, and the concurrent lane's note on this same block): a shared `1` cannot say
    # whether a target was MISSING (a farm gap, which --status must not turn into a permanent red) or
    # cmux-GATED (the blind job this change exists to refuse).
    if ! _tmp="$(mktemp 2>/dev/null)"; then
        echo "  ⛔ UNKNOWN   $label: cannot create a temp file (TMPDIR/TMP/TEMP unwritable), so neither the cmux launch-path gate nor the TCC target check can be evaluated — a unit that cannot be graded is NOT certified"
        return 2
    fi
    if ! printf '%s' "$rendered" > "$_tmp"; then
        rm -f "$_tmp"
        echo "  ⛔ UNKNOWN   $label: cannot write the rendered plist to a temp file, so neither the cmux launch-path gate nor the TCC target check can be evaluated — a unit that cannot be graded is NOT certified"
        return 2
    fi
    # ⛔ A cmux-GATED TEMPLATE IS NEVER `in sync` (#3826 review P2 — a fail-open on the exact
    # defect this change exists to catch). `verify_targets` returns 1 here, so the arms below
    # graded its CONTENT: a byte-identical template and plist agreed, the row read
    # `installed=loaded version=v… (in sync)`, and `--status` exited 0 — certifying a job that
    # installs, loads, ticks and delivers NOTHING. This is not hypothetical: the blind job in
    # #1867's own body was installed and `--status`-clean for its whole life. It is now a row of
    # its own and a non-zero exit, so the two verbs agree about one file.
    # ⛔ AND "COULD NOT READ" IS NOT "NOT GATED" (round 17): `plist_cmux_gated_target` answers 3 for
    # an unreadable rendered plist, so a reader that could not look is UNKNOWN here instead of being
    # read as a clean classification. Collapsing the two is how the pipe above became invisible.
    _cmux_target="$(plist_cmux_gated_target "$_tmp")" || _cmux_rc=$?
    case "$_cmux_rc" in
        1) : ;;                       # read, and it names no cmux-gated script
        0)
            echo "  ⛔ CMUX-GATED   $label: this job installs, loads and ticks, and is BLIND under launchd ($_cmux_target)"
            echo "        the cmux socket (socketControlMode = cmuxOnly) gates on launch-chain attribution,"
            echo "        which a launchd job never has, so it delivers NOTHING while its log reads as"
            echo "        activity (#1867). This template is listed in templates/launchd/LAUNCHD-INCOMPATIBLE"
            echo "        — remove it from the set; no install step makes it work."
            echo "        Documented launch path: bash scripts/heartbeat-launch.sh start"
            rm -f "$_tmp"
            return 1
            ;;
        *)
            rm -f "$_tmp"
            if [ "$_cmux_rc" -eq 4 ]; then
                echo "  ⛔ UNKNOWN   $label: the cmux launch-path GATE could not be evaluated (no LAUNCHD-INCOMPATIBLE manifest, or one holding no entry), so whether this unit is blind under launchd cannot be answered — a gate that cannot open is not a clean unit"
            else
                echo "  ⛔ UNKNOWN   $label: the rendered plist could not be READ (rc=$_cmux_rc), so whether it names a cmux-gated script cannot be answered — an unreadable unit is never a clean one"
            fi
            return 2
            ;;
    esac
    _tcc_vrc=0
    verify_targets "$_tmp" >/dev/null 2>&1 || _tcc_vrc=$?
    rm -f "$_tmp"
    if [ "$_tcc_vrc" -eq 2 ]; then
        if [ -f "$installed" ]; then
            echo "  ⚠️ INSTALLED-SKIPPED   $label: INSTALLED, but SKIPPED now (launchd cannot READ this unit's target — a macOS TCC root, #427; the installer SKIPs this template and DISARMS the copy, so what runs is not what the template describes)"
        else
            echo "  $label: NOT APPLICABLE (launchd cannot READ this unit's target — a macOS TCC root, #427; no install step changes this box's layout)"
        fi
        return 0
    fi
    if [ ! -f "$installed" ]; then
        # ⛔ AND AN INSTALLABLE TEMPLATE THAT IS NOT THERE IS A FAILURE ROW WITH A FAILURE CODE
        # (#1867 review, round 9). This function used to print the three failure verdicts and return
        # 0 for all of them, so `--status` exited 0 on a box whose declared jobs were absent, unloaded
        # or drifted — while its own header promised "for `--status`: 0 clean". MEASURED pre-fix with a
        # fake `launchctl`: an absent, installable declared job printed `NOT INSTALLED (template
        # v0.1.0)` and rc was 0; a drifted one printed `(DRIFTED (template changed — re-run
        # installer))` and rc was 0. `fleet-schedule.py --verify` was safe only because it ALSO scans
        # the text for markers, i.e. the verb had two answers to "is this box clean?" and the one a
        # shell caller reads was the wrong one.
        echo "  $label: NOT INSTALLED (template v$version)"
        return 1
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
    case "$state/$drift" in
        "loaded/in sync") return 0 ;;
    esac
    return 1
}

# ── THE DECLARED SET — every template this directory describes, at ANY depth (#1867 review P1) ────
# ⛔ RECURSIVE, and the recursion is the fix, not a convenience. Counting only the FLAT `*.plist`
# templates made the four templates this repo ships one directory down — `conflict-rebase/`,
# `harness-apply/`, `reaper/`, `runner-autoscale/`, each installed into `~/Library/LaunchAgents` by
# its own installer — read as UNMANAGED on a box that has the repo's OWN jobs armed. `--status` then
# exited 1 and printed the `launchctl bootout && rm -f` remedy for three owner-armed jobs, so the
# instrument's healthy state on the reference Mac was a hard FAILING row. A job declared one
# directory down IS described by this repo; the question the caller asks is "is this label in the
# declared set?", and the declared set is this directory's templates wherever they sit.
#
# ⛔ AND "WHEREVER THEY SIT" MEANS A WALK (#1867 review P2, round 7). Two fixed globs are "flat, or
# exactly ONE directory down", while this heading, `is_declared`'s comment and
# docs/ops/heartbeat-launch-path.md all said "ANY depth" / "resolved recursively". A template at
# `templates/launchd/<group>/<sub>/x.plist` would therefore be reported UNMANAGED — with
# `launchctl bootout … && rm -f …` printed as its remedy — which is precisely the harm the P1 above
# was raised for, closed for one level while the comment claimed all of them. The claim and the code
# now agree, and §18b pins a template THREE levels down so a future narrowing reds.
declared_labels() {
    local template
    while IFS= read -r template; do
        [ -n "$template" ] || continue
        basename "$template" .plist
    done < <(find "$TEMPLATES_DIR" -type f -name '*.plist' 2>/dev/null | LC_ALL=C sort)
}

is_declared() { # $1 = label → 0 when a template in the declared set (any depth) describes it
    # Capture, then grep a here-string — never `declared_labels | grep -q` (#864's SIGPIPE shape).
    [ -n "$1" ] || return 1
    grep -qxF -- "$1" <<<"$(declared_labels || true)"
}

# ── UNMANAGED INSTALLED PLISTS (#1867) ─────────────────────────────────────────────────────────────
# A plist installed on the box that NO template in the declared set describes is invisible to every
# content comparison this file makes — the loop in `--status` and the install loop both iterate
# TEMPLATES, so a job that was installed by hand (or by a template that has since been deleted)
# simply is not looked at. That was the blind heartbeat's exact shape: installed, loaded, ticking
# on the wrong launch path, and reported by nothing. Behaviour drift is invisible to a drift check
# on content; a job outside the declared set is invisible to BOTH.
#
# Scoped to the labels this repo can plausibly own (`com.eldato.*`, `com.tortoise.*`) so a box's
# own unrelated LaunchAgents are not this installer's business — the same boundary the rest of the
# file uses when it probes for an eldato domain.
#
# ⛔ TWO DECLARED EXCLUSIONS, both load-bearing and both about NOT crying wolf:
#   · a label in `RETIRED` is deliberately template-less — it is DECLARED and `retire_pass` removes
#     it, so it is pending retirement, not unmanaged;
#   · a label in `OWNED-BY-OTHER-INSTALLERS` is DECLARED by ANOTHER surface of this repo — an
#     installer in `scripts/install-*.sh`, the harness installer, or (the one shape that is not an
#     installer at all) the controller job a box already carries and `scripts/orchestrator-bringup.sh`
#     ADOPTS. None of them is this installer's set to describe.
# Without the second, the reference Mac layout is red forever (#1867 review P1) — and the remedy
# this command prints for a stray is a DELETION, so a missing declaration is not a cosmetic false
# alarm: it aims `launchctl bootout … && rm -f …` at a live job of this repo's own.
# Returns 0 when the installed set was enumerated (rows on stdout, possibly none), 2 when it could
# NOT be — "I could not look" is a different answer from "nothing to report", and the caller must be
# able to tell them apart (see the UNKNOWN arm in --status, #1867 review P2).
unmanaged_plists() {
    local installed label
    # No install dir at all is a known, benign state (nothing was ever installed here).
    [ -e "$AGENTS_DIR" ] || return 0
    # ⛔ EXISTS BUT CANNOT BE ENUMERATED IS NOT "NOTHING UNMANAGED" (#1867 review P2). An unreadable
    # or non-directory AGENTS_DIR produces no rows, empty rows read as a clean box, and `--status`
    # then exits 0 from an instrument that looked at nothing — the exact fail-open this file guards
    # three functions away in `cmux_gate_required` ("must not install on the assumption that none
    # are"). Refuse instead: 2 = UNKNOWN, never a pass.
    if [ ! -d "$AGENTS_DIR" ] || [ ! -r "$AGENTS_DIR" ] || [ ! -x "$AGENTS_DIR" ]; then
        return 2
    fi
    # ⛔ AND THE DECLARED SET NEEDS THE SAME GUARD (#1867 review, round 9). `is_declared` asks "is this
    # label in the declared set?", and with an EMPTY declared set the answer for EVERY label is no — so
    # an unreadable or empty TEMPLATES_DIR turns this function's own output into the delete advice
    # above, aimed at the repo's armed jobs. MEASURED with a fixture where `com.eldato.ai-drainer` was
    # installed AND its template was present: declared set intact → `installed=loaded … (DRIFTED)` and
    # no bootout; TEMPLATES_DIR empty → `⛔ UNMANAGED …` plus `launchctl bootout … && rm -f …`;
    # TEMPLATES_DIR chmod 000 → the identical row and the identical delete command. `cmux_gate_required`
    # already refuses an EMPTY gate on the install path ("an EMPTY gate is the same no-op as a missing
    # one"); this is that rule on the status path. rc 3 = "the declared set could not answer".
    if [ -z "$(declared_labels 2>/dev/null)" ]; then
        return 3
    fi
    # ⛔ AND THE EXEMPTION LISTS ARE THE SAME KIND OF INPUT (#1867 review, round 12). `is_retired` and
    # `is_foreign` are asked for EVERY installed label, and both answer "no" when their manifest could
    # not be read — so the same fail-open the guard above closes for the template walk is still open
    # one call away, on the two lists whose whole job is to KEEP a live job out of the `bootout && rm -f`
    # advice. A tree that ships templates but no readable RETIRED is mutilated, not clean; refuse to
    # classify rather than hand an operator a deletion command on the strength of a list it never read.
    # ⛔ AND AN EMPTY EXEMPTION LIST IS THE SAME NO-OP AS A MISSING ONE (#3826 review P2, round 17).
    # The guard below tested a manifest's PATH only (`-r` / `-f`), so a manifest that EXISTS and is
    # EMPTY — a truncated file, a mangled merge, a copy whose entries were lost — passed it;
    # `is_retired` and `is_foreign` then answered "no" for EVERY label, and the loop handed an
    # operator `launchctl bootout … && rm -f …` for a live job another installer of THIS repo owns.
    # That is the identical sentence `cmux_gate_required` already refuses on the install path ("an
    # EMPTY gate is the same no-op as a missing one"), one file over. MEASURED at `8aade2a1c` with
    # `com.eldato.orchestrator-loop` installed and `OWNED-BY-OTHER-INSTALLERS` truncated to 0 bytes:
    # `⛔ UNMANAGED com.eldato.orchestrator-loop` PLUS the bootout+rm remedy, rc 1; with the manifest's
    # entries restored the same box printed 0 UNMANAGED rows. rc 3 = the declared set could not
    # answer, which the caller reports as UNKNOWN — never as a deletion instruction.
    # The third clause keeps the fixture carve-out: a TEMPLATES_DIR override that ships no manifest of
    # its own falls back to the checkout's copy, and only a box with NO declarations anywhere (no
    # manifest AND no repo template tree) is allowed an empty foreign list.
    # ⛔ AN EMPTY *FOREIGN* LIST IS A REFUSAL, AN EMPTY *RETIRED* LIST IS NOT, AND AN UNREADABLE RETIRED
    # STILL IS (#3826 review P2 round 18 / P3 round 19). `RETIRED` is a RECORD OF REMOVALS, so "holds no
    # entry" is its legitimate terminal state — refusing it made a clean in-sync box a PERMANENT red with
    # a false diagnosis (MEASURED: `in sync` for the job, then `⛔ UNKNOWN … could NOT be read`, rc 2).
    # `OWNED-BY-OTHER-INSTALLERS` is the opposite: an empty one re-classifies live jobs another installer
    # owns as strays and prints the command that DELETES them, so emptiness there is refused.
    # ⛔ BUT NARROWING THAT CLAUSE ALSO DROPPED THE RETIRED *PRESENCE* GUARD, AND THIS COMMENT CLAIMED IT
    # SURVIVED (#3826 review P3, round 19). `retired_manifest` prints nothing when neither copy is
    # readable, so `is_retired` answered "no" for every label and a retired-but-installed job was
    # reported `⛔ UNMANAGED` **with** `launchctl bootout … && rm -f …` — the row class the doc says
    # cannot be produced. Restored below as its own term, which is what the doc's sentence ("if neither
    # is readable `--status` answers 2 UNKNOWN") actually describes. The EMPTY case stays permitted, and
    # that has a declared consequence: `RETIRED`'s entries ARE the declaration, so a manifest emptied by
    # hand re-classifies what it used to name — `fleet-schedule.py --check` is the authoring gate for a
    # retirement, not this one.
    _fl="$(foreign_labels || true)"
    if [ -z "$(retired_manifest)" ]; then
        return 3
    fi
    if [ -z "$_fl" ] && { [ -n "$(foreign_manifest)" ] || [ -d "$INFRA_ROOT/templates/launchd" ]; }; then
        return 3
    fi
    for installed in "$AGENTS_DIR"/com.eldato.*.plist "$AGENTS_DIR"/com.tortoise.*.plist; do
        [ -f "$installed" ] || continue
        label="$(basename "$installed" .plist)"
        # Declared anywhere in the template tree — at ANY depth, which `declared_labels` walks — is
        # declared. (This said "flat, or one directory down" while the walk was two fixed globs; both
        # the walk and this sentence are the same question, so they move together.)
        is_declared "$label" && continue
        # A RETIRED label is deliberately template-less: it is DECLARED and it is removed by
        # retire_pass on the next install, so it is not "unmanaged" — it is pending retirement.
        is_retired "$label" && continue
        # Declared and owned by another installer of THIS repo — not this directory's set, and a
        # red here would be a permanent false alarm on the reference layout.
        is_foreign "$label" && continue
        printf '%s\n' "$label"
    done
}

# ── A RETIRED LABEL THAT IS STILL INSTALLED (round 8) ───────────────────────────────────────────
# ⛔ THE FALSE PASS THIS INSTRUMENT ITSELF WAS HOLDING. `unmanaged_plists` exempts RETIRED labels
# (they are DECLARED, so "no template" is not "undescribed"), and `retire_pass` — the ONLY remover —
# runs on an INSTALL, never on `--status`. Exempting the class from the ROW was right; exempting it
# from the EXIT CODE was not: on a box still carrying `com.tortoise.heartbeat-loop.plist`, `--status`
# printed the retired list as prose, produced no row, and exited 0 — so `scripts/fleet-schedule.py
# --verify` printed `SCHEDULE VERIFIED` over the exact blind job this change exists to remove, while
# that job ticked, logged `Access denied`, and delivered nothing. MEASURED on round 7's code with a
# fixture holding only that plist: rc=0, zero `UNMANAGED` rows, plist still on disk; with the RETIRED
# line removed from a copy of the templates, rc=1 and the `bootout && rm -f` remedy.
# So it gets its OWN row class and its own exit contribution — and NOT the delete remedy, which would
# be wrong twice over (the label IS declared, and `retire_pass` does the bootout AND the removal, on
# the next install). The state is transient by construction: any install clears it.
installed_retired_plists() {
    local installed label
    # No install dir at all is a known, benign state (nothing was ever installed here).
    [ -e "$AGENTS_DIR" ] || return 0
    for installed in "$AGENTS_DIR"/com.eldato.*.plist "$AGENTS_DIR"/com.tortoise.*.plist; do
        [ -f "$installed" ] || continue
        label="$(basename "$installed" .plist)"
        is_retired "$label" || continue
        printf '%s\n' "$label"
    done
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

# Retired launchd jobs (#432 — Option C): labels listed in templates/launchd/RETIRED. TWO of them
# (#427/#431) moved to extensions/session-checks.ts (session_start, age-gated) because macOS TCC blocks
# launchd-spawned processes from ~/Documents regardless of interpreter — and the others were retired
# for their own reasons, spelled in the manifest beside each label (the #2303 watchdog → the SHIPPED
# controller-watchdog template; #1867's blind heartbeat → scripts/heartbeat-launch.sh). ⛔ Do NOT state
# one destination for the CLASS: that sentence was printed to operators and was false for two of the
# four labels (round 8). The installer unloads + removes retired jobs on machines that installed them
# pre-retirement (the template loop only manages PRESENT templates, so a removed template would
# otherwise strand installed jobs forever), and `--status` reports one that is still installed as
# RETIRED-INSTALLED and exits 1 until that install runs.
#
# ⛔ A LABEL HERE RETIRES THE JOB EVEN WHEN ITS TEMPLATE IS STILL PRESENT, AND
# THAT IS DELIBERATE (#2908). The installer used to ERROR and exit 1 on the
# conflict, which on a cell meant one stale manifest line disarmed the WHOLE
# scheduled layer — no reaping, no liveness detection, no canary (measured
# 2026-10-27: `FATAL: the scheduled layer would not start (rc=1)` on cells 3
# and 4). Retirement is the operator's stated intent and the only statement a
# MACHINE can honour, so it wins: the job is skipped and any installed copy is
# unloaded + removed. The contradiction is a REPO authoring error and is refused
# where it is authored instead — `scripts/fleet-schedule.py --check`, which
# exits 1 for every label listed here that still has a template. Both backends
# follow that split: the declaration gate refuses, the machine honours.
# ⛔ FAIL-CLOSED RESOLUTION, and the fallback is the point (#1867 review, round 12). `TEMPLATES_DIR` is
# an env override (the test suite isolates through it), so reading the manifest ONLY from there made the
# exemption a no-op on any box where the override points at a directory without it — and the observable
# of "I could not read the retirement list" is identical to "nothing is retired", which turns every
# retired label into an UNMANAGED row carrying `launchctl bootout … && rm -f …` aimed at a live job.
# That is verbatim the harm `OWNED-BY-OTHER-INSTALLERS` exists to prevent (its header, `:28-31`:
# "A missing entry therefore does not merely print a false alarm — it hands the operator the command
# that DELETES a live job"). `cmux_manifest` and `foreign_manifest` already resolve this way; RETIRED
# is the third manifest in the same directory and must not be the one that reads differently.
retired_manifest() {
    if [ -r "$TEMPLATES_DIR/RETIRED" ]; then
        printf '%s\n' "$TEMPLATES_DIR/RETIRED"
    elif [ -r "$INFRA_ROOT/templates/launchd/RETIRED" ]; then
        printf '%s\n' "$INFRA_ROOT/templates/launchd/RETIRED"
    fi
}

retired_labels() {
    local manifest label
    manifest="$(retired_manifest)"
    [ -n "$manifest" ] || return 0
    while IFS= read -r label; do
        case "$label" in
            ""|"#"*) continue ;;
        esac
        printf '%s\n' "$label"
    done < "$manifest"
}

# ── LABELS ANOTHER INSTALLER IN THIS REPO OWNS (#1867 review P1) ────────────────────────────────
# `unmanaged_plists` asks "is this job described by the declared set?", and the declared set is
# THIS directory. But this repo installs launchd jobs from a SECOND surface: the harness controller
# `com.eldato.orchestrator-loop` is rendered by `scripts/orchestrator-harness/install.sh` from its
# OWN template, outside `templates/launchd/` — deliberately, because that installer owns its
# lifecycle through `launchd-cycle.sh`. Flagging it made the honest answer on the reference Mac a
# PERMANENT red: `--status` rc=1 → `scripts/fleet-schedule.py` prints `SCHEDULE NOT VERIFIED` →
# `activate-harness.sh` reports `fleet-schedule … FAILING`. An instrument whose healthy state is red
# is one an operator learns to ignore, or "fixes" by deleting a plist the controller needs.
#
# ⛔ THE LIST IS DECLARED, NOT GUESSED, and it is drift-gated IN BOTH DIRECTIONS: §18 of
# `install-launchd.test.sh` asserts (1) that every entry still has a declaring surface in this repo —
# matched against ALL the spellings those surfaces use, because one of them spells its label ONLY as an
# inline `<string>com.…</string>` plist body plus a literal `Library/LaunchAgents/<label>.plist` path
# (`scripts/install-lane-arm-timer.sh`: its `LABEL=eldato-lane-arm` is the systemd unit name) — and (2)
# the REVERSE, that every label an installer here writes into `LaunchAgents` is a template, RETIRED, or
# declared here. A gate that can only catch a STALE entry cannot catch the direction that does harm: a
# MISSING one, which prints a deletion command for a live job.
# Resolution mirrors `cmux_manifest` (TEMPLATES_DIR first, then the checkout's own copy) so an
# env-overridden template dir — the test fixture — still finds it, and a farmed run still falls back to
# the tree it came from.
foreign_manifest() {
    if [ -f "$TEMPLATES_DIR/OWNED-BY-OTHER-INSTALLERS" ]; then
        printf '%s\n' "$TEMPLATES_DIR/OWNED-BY-OTHER-INSTALLERS"
    elif [ -f "$INFRA_ROOT/templates/launchd/OWNED-BY-OTHER-INSTALLERS" ]; then
        printf '%s\n' "$INFRA_ROOT/templates/launchd/OWNED-BY-OTHER-INSTALLERS"
    fi
}

foreign_labels() {
    local manifest label
    manifest="$(foreign_manifest)"
    [ -n "$manifest" ] || return 0
    while IFS= read -r label; do
        case "$label" in
            ""|"#"*) continue ;;
        esac
        printf '%s\n' "$label"
    done < "$manifest"
}

is_foreign() { # $1 = label → 0 when another installer in this repo owns it
    # Capture, then grep a here-string — never `foreign_labels | grep -q` (#864's SIGPIPE shape).
    [ -n "$1" ] || return 1
    grep -qxF -- "$1" <<<"$(foreign_labels || true)"
}

# ── THE cmux LAUNCH-PATH GATE (#1867) ────────────────────────────────────────────────────────────
# Templates/launchd/LAUNCHD-INCOMPATIBLE declares, once and in the repo, the scripts that a
# launchd job must never run because their whole job is to touch the cmux socket — which refuses a
# launchd-spawned caller. The check lives HERE, at the renderer, because that is where the wrong
# launch path was being produced (the installer had NO knowledge of the gate: grep for `cmux` /
# `socketControlMode` returned nothing, so it installed blindness by design and silently).
cmux_gated_scripts() {
    local manifest entry
    manifest="$(cmux_manifest)"
    [ -n "$manifest" ] || return 0
    while IFS= read -r entry; do
        case "$entry" in
            ""|\#*) continue ;;
        esac
        printf '%s\n' "$entry"
    done < "$manifest"
}

# cmux_manifest — the manifest this run will use, or EMPTY when the checkout does not carry one.
#
# ⛔ FAIL-CLOSED RESOLUTION, and the fallback is the point. `TEMPLATES_DIR` is an env override (the
# test suite isolates through it), so reading the manifest ONLY from there made the gate a no-op on
# any box where the override points at a directory without it — the "a gate that silently does
# nothing" class this whole change is about. The REPO's own copy is therefore the fallback, and a
# run where NEITHER exists is refused outright by `cmux_gate_required` below rather than proceeding
# ungated.
cmux_manifest() {
    if [ -f "$TEMPLATES_DIR/LAUNCHD-INCOMPATIBLE" ]; then
        printf '%s\n' "$TEMPLATES_DIR/LAUNCHD-INCOMPATIBLE"
    elif [ -f "$INFRA_ROOT/templates/launchd/LAUNCHD-INCOMPATIBLE" ]; then
        printf '%s\n' "$INFRA_ROOT/templates/launchd/LAUNCHD-INCOMPATIBLE"
    fi
}

# cmux_gate_required — refuse to install ANYTHING when the gate has no manifest to evaluate.
# An installer that cannot tell whether a template is cmux-gated must not install on the assumption
# that none are: that is precisely how the blind heartbeat was installed and reported as success.
cmux_gate_required() {
    local manifest listing
    manifest="$(cmux_manifest)"
    if [ -z "$manifest" ]; then
        echo "ERROR: the cmux launch-path gate cannot be evaluated — no LAUNCHD-INCOMPATIBLE manifest" >&2
        echo "       looked in: $TEMPLATES_DIR/ and $INFRA_ROOT/templates/launchd/" >&2
        echo "       Without it this installer cannot tell whether a template would install a job that" >&2
        echo "       is blind under launchd (#1867), so it installs NOTHING." >&2
        return 1
    fi
    listing="$(cmux_gated_scripts || true)"
    if [ -z "$listing" ]; then
        echo "ERROR: $manifest lists no scripts — an EMPTY gate is the same no-op as a missing one" >&2
        return 1
    fi
    return 0
}

# is_cmux_gated <absolute argv path> → 0 when it is a declared cmux-gated script.
#
# ⛔ SUFFIX MATCH, NOT PREFIX. The gate is a property of the SCRIPT, not of the directory it was
# checked out into: `$HOME/.pi/agent/scripts/heartbeat-loop.sh` (the farmed deployment copy that a
# plist actually names) and `<worktree>/scripts/heartbeat-loop.sh` are the same script and must
# both refuse. Resolving both sides and comparing the repo-relative tail is what makes the refusal
# predictable from the manifest alone; the matching rule is stated in the manifest's own header.
# Capture-then-herestring, never a pipe into `grep -q` — under `pipefail` the producer takes
# SIGPIPE at grep's first match and the verdict inverts (#864's shape).
is_cmux_gated() {
    local arg="$1" entry gated
    [ -n "$arg" ] || return 1
    gated="$(cmux_gated_scripts || true)"
    [ -n "$gated" ] || return 1
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        case "$arg" in
            "$entry"|*/"$entry") return 0 ;;
        esac
    done <<<"$gated"
    return 1
}

# plist_cmux_gated_target <plist> → prints the FIRST cmux-gated program argument;
#   0 when there is one · 1 when the plist was READ and names none · 3 when it could NOT be read ·
#   4 when the GATE could not be evaluated (no manifest, or an empty one). The answers are distinct on
#   purpose — collapsing "could not read" or "could not evaluate" into "not gated" is exactly how a pipe
#   handed to plistlib, and then a missing manifest, each certified a blind job `in sync` (#3826 P1).
#
# ⛔ THE ONE PREDICATE `install` AND `--status` BOTH CONSULT (#3826 review P2). They used to disagree
# about the same file by construction: `verify_targets` answers `1` for BOTH "a target is missing" and
# "a target is cmux-gated", so `status_job` could not act on the cmux case without also refusing every
# box whose farm is incomplete — and it acted on `2` ONLY, which let the gated template fall through to
# the content comparison and be reported `installed=loaded version=v… (in sync)` with rc 0. MEASURED on
# the round-13 code: the rendered template naming `<repo>/scripts/heartbeat-loop.sh`, installed
# byte-identically, printed `in sync` and STATUS_RC=0, while `install-launchd.sh` refused the SAME file
# loudly. A shared integer cannot carry "why"; asking the manifest again can.
plist_cmux_gated_target() {
    local args_out kind arg _rc=0
    # ⛔ "COULD NOT READ" MUST NOT ARRIVE AS "NOT GATED" (#3826 review P1, round 17). Both used to be
    # `return 1`, so a reader that failed — an unreadable plist, a temp file it could not create, or
    # (the measured regression) a PROCESS SUBSTITUTION, which plistlib cannot read because it needs a
    # seekable stream — was indistinguishable from "read it, nothing gated", and `status_job` graded
    # the CONTENT of a blind job and certified it `in sync` rc 0. Two codes, not one:
    #   0 = GATED (the target is printed) · 1 = READ, and it names no gated script
    #   3 = the rendered plist could not be READ (the same code `plist_reader_py` uses)
    #   4 = the GATE could not be EVALUATED — no LAUNCHD-INCOMPATIBLE manifest, or an EMPTY one
    # ⛔ AND 4 IS A SEPARATE ANSWER FROM 1 (#3826 review P1, round 18). `is_cmux_gated` answers "not
    # gated" when the manifest is missing or holds no entry (`[ -n "$gated" ] || return 1`), and on the
    # INSTALL path that is safe because `cmux_gate_required` refuses the whole run first — but the
    # `--status` block ENDS before that call, so `--status` inherited the answer without the gate.
    # MEASURED at `f17785035` on a scratch INFRA_ROOT whose templates/launchd carried a GATED template
    # and NO manifest (and again with a comments-only one), byte-identical install:
    #   --status → `com.eldato.tccprobe: installed=loaded version=v0.0.1 (in sync)`   STATUS_RC=0
    #   install  → `ERROR: the cmux launch-path gate cannot be evaluated`               INSTALL_RC=1
    # — the two verbs disagreeing about one file, which is the invariant this function exists to keep.
    # With the real manifest present the same fixture reds `⛔ CMUX-GATED` rc 1, so 4 is the missing arm,
    # not a new behaviour. "I could not evaluate the gate" is never "this job is clean".
    if [ -z "$(cmux_gated_scripts || true)" ]; then
        return 4
    fi
    args_out="$(plist_program_args "$1")" || _rc=$?
    [ "$_rc" -eq 0 ] || return 3
    while IFS=$'\t' read -r kind arg; do
        [ -n "$arg" ] || continue
        if is_cmux_gated "$arg"; then
            printf '%s' "$arg"
            return 0
        fi
    done <<<"$args_out"
    return 1
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
#
# ⛔ A TEMPLATE THAT STILL EXISTS IS A WARNING, NOT A LAYER-WIDE REFUSAL (#2908). This used to
# `rc=1` — and every caller propagates that, so a single contradictory line in RETIRED took the
# ENTIRE layer down on the machine that needed it (the #2908 cells ran with no reaper, no liveness
# detection and no canary). The manifest is the operator's stated intent, so it is honoured: warn,
# unload + remove, let the template loop skip the job. The authoring error is refused by the
# repo's own declaration gate — `fleet-schedule.py --check` exits 1 for exactly this state — which
# is the same split the Linux runtime makes.
retire_pass() {
    local label
    for label in $(retired_labels); do
        if [ -f "$TEMPLATES_DIR/$label.plist" ]; then
            echo "WARN: $label is in RETIRED but a template still exists — retiring it anyway (the manifest wins); remove the template in the repo to clear this" >&2
        fi
        retire_job "$label"
    done
    return 0
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
    # ⛔ THE PER-JOB ROWS CARRY THE EXIT CODE (round 9). `status_rc` used to start at 0 AFTER the loop
    # and was raised only by the three set-level arms, so a declared job that was absent, unloaded or
    # drifted printed a failure row and still exited 0 — the "caveat with exit 0 is read as green"
    # class this file fixes for UNMANAGED and RETIRED-INSTALLED, left unfixed for the three verdicts
    # that fire on a normal day. A 2 (UNKNOWN) is never downgraded to 1: the higher answer wins.
    status_rc=0
    for template in "$TEMPLATES_DIR"/*.plist; do
        [ -f "$template" ] || continue
        # ⛔ A RETIRED LABEL IS A NAMED STATE, NEVER AN ABSENCE (#2908 review, P1). A retired job is
        # DELIBERATELY never installed, so handing it to status_job printed "NOT INSTALLED" — and
        # `fleet-schedule.py --verify` on macOS turns every NOT INSTALLED line into FAIL
        # `SCHEDULE NOT VERIFIED`, rc 1. So the one-line manifest edit this PR advertises
        # (templates/launchd/RETIRED:12-14, "an operator action on ONE file") started the layer and
        # then had its own gate report it broken: the #3029 false-FAIL class, closed on Linux and
        # left standing on the other backend. The comparable (systemd `mask`) names the retirement
        # as a state (`masked`) rather than reporting the unit absent, and so does this.
        # The installed-copy arm stays a FAILURE on purpose: the manifest says retired, so a copy
        # still on disk is DRIFT from the declaration — a false PASS here would be worse than the
        # false FAIL being closed, and `--install` is what clears it (retire_pass unloads + removes).
        # ⛔ AND IT NOW CARRIES THE EXIT CODE (#1867 rounds 8/9): the set-level `RETIRED-INSTALLED`
        # pass below names every retired label still on disk — template or not — and raises status_rc,
        # so this row and that one agree rather than one of them printing a caveat behind an rc=0.
        # ⛔ AND IT DOES NOT CARRY THE WORD `DRIFTED` (round 12). `fleet-schedule.py --verify` counts
        # JOB MARKERS, so a retired label that had BOTH a surviving template and an installed copy
        # produced two marked lines for ONE job (this row's `DRIFTED` and the set-level
        # `⛔ RETIRED-INSTALLED`) and the verdict said "2 launchd job(s)" over one — the same
        # not-a-count-of-jobs lie round 5 fixed in the other direction. The FAILURE row for this state
        # is the set-level one, which owns both the marker and the exit code; this row states the fact
        # without competing to be counted. The template-present, nothing-installed case keeps its
        # wording (#2908: a retired job is deliberately never installed, so that is not a failure).
        label="$(job_label "$template")"
        if is_retired "$label"; then
            if [ -f "$AGENTS_DIR/$label.plist" ]; then
                echo "  $label: RETIRED (manifest wins) — an installed copy ALSO survives; re-run the installer to unload + remove it"
            else
                echo "  $label: RETIRED (manifest wins — template present; remove the template in the repo)"
            fi
            continue
        fi
        # ⛔ THE HIGHER ANSWER WINS (#3826 review P1, round 17). `status_job` can now answer 2
        # (UNKNOWN — a temp file it cannot create, a rendered plist it cannot read), and this arm
        # collapsed every non-zero into 1, so the sentence above ("A 2 (UNKNOWN) is never downgraded
        # to 1") described an intent the code did not implement. Fail-closed either way; the
        # difference is whether the exit status says "this box is wrong" (1) or "nobody could
        # look" (2). NOT `local` — this runs at script top level (round-16 P3).
        _jrc=0
        status_job "$template" || _jrc=$?
        [ "$_jrc" -gt "$status_rc" ] && status_rc="$_jrc"
    done
    # ── DECLARED BUT NOT OWNED HERE: NAMED, NOT SILENT (#3826 review P2) ──────────────────────────
    # ⛔ TWO SETS, ONE NAME. `declared_labels` is a WALK (any depth), and `is_declared` uses it to
    # EXEMPT a template from the UNMANAGED alarm — while this per-job pass (and the install loop, and
    # `--uninstall`) are a FLAT `$TEMPLATES_DIR/*.plist` glob. A template in a SUBDIRECTORY therefore
    # produced NO ROW AT ALL: declared, therefore not reported as a stray, and never inspected. This
    # repo ships four of them — `reaper/`, `conflict-rebase/`, `harness-apply/`, `runner-autoscale/`
    # — each installed and verified by its own `install-*-timer.sh` with a DIFFERENT placeholder set.
    # MEASURED pre-fix on a fixture (one flat template installed in sync + `reaper/<label>.plist`
    # with nothing installed): rc=0, and the nested label appeared NOWHERE in the output — while
    # `scripts/fleet-schedule.py --verify` printed `SCHEDULE VERIFIED — launchd job set matches
    # templates/launchd` over declarations nothing had looked at. Silent, correct-looking and blind is
    # the exact shape this file exists to remove.
    # ⛔ THEY ARE NOT GRADED BY `status_job` — deliberately. Their placeholder set differs on purpose
    # (that is WHY they live in a subdirectory: `install-*-timer.sh`'s own headers say so, 4x), so a
    # content comparison here would invent a DRIFT for a correct install — a new false FAIL traded for
    # the false PASS. The honest row STATES the delegation and NAMES the template, so "declared" and
    # "visible" are the same set in both directions and the verdict sentence below is not a claim
    # about files nothing read.
    delegated=0
    # ⛔ RESOLVED BEFORE COMPARING (#3826 review P2). `dirname` NEVER emits a trailing slash, so a
    # TEXTUAL compare against `$TEMPLATES_DIR` classified this installer's own flat set as "another
    # installer's directory" whenever the spelling differed by a trailing slash — which is exactly what
    # shell tab-completion inserts. MEASURED with `TEMPLATES_DIR="$PWD/templates/launchd/"`: 23
    # `DELEGATED —` rows instead of 4, every graded job appearing TWICE with contradictory verdicts
    # (`NOT INSTALLED (template v0.2.0)` beside `DELEGATED — … installed and graded by another
    # installer`), asserting a false ownership and a false state for an absent job while
    # `fleet-schedule.py --verify` counted the 23 disclosures over 19 jobs it had just graded.
    # ⛔ NOT `local` — THIS RUNS AT SCRIPT TOP LEVEL (#3826 review P3). `local` outside a function
    # prints `local: can only be used in a function` to STDERR on every `--status` run, which is the
    # stream `scripts/fleet-schedule.py --verify` parses (`out.stdout + out.stderr`). Harmless to the
    # exit code, which is why only reading the stderr shows it. Measured: 1 error line before, 0 now.
    _own_dir="$(cd "$TEMPLATES_DIR" 2>/dev/null && pwd -P)" || _own_dir="${TEMPLATES_DIR%/}"
    while IFS= read -r template; do
        [ -n "$template" ] || continue
        # Anything DIRECTLY in TEMPLATES_DIR is this installer's own set — already graded above.
        _tpl_dir="$(cd "$(dirname "$template")" 2>/dev/null && pwd -P)" || _tpl_dir="$(dirname "$template")"
        [ "$_tpl_dir" = "$_own_dir" ] && continue
        label="$(job_label "$template")"
        if is_retired "$label"; then
            echo "  $label: RETIRED (manifest wins — template in a subdirectory; remove the template in the repo)"
        else
            echo "  $label: DELEGATED — declared here, installed and graded by another installer ($template)"
        fi
        delegated=$((delegated + 1))
    done < <(find "$TEMPLATES_DIR" -type f -name '*.plist' 2>/dev/null | LC_ALL=C sort)
    if [ "$delegated" -gt 0 ]; then
        echo "    DELEGATED is a NAMED state, not a failure and not a green: these templates are this"
        echo "    repo's own declarations but another installer renders, loads and verifies them, so this"
        echo "    command does not grade their content (and never aims a bootout at them)."
    fi
    # ⛔ AN INSTALLED JOB WITH NO TEMPLATE IS NOT "NOTHING TO REPORT" (#1867). It is a job on the
    # box the declared set does not describe, so neither this pass nor the content comparison can
    # say anything about it — the blind heartbeat sat in exactly that hole. Named loudly, and the
    # EXIT CODE carries it: a status command that prints a caveat and exits 0 is read by every
    # caller as "green".
    status_rc=${status_rc:-0}
    unmanaged=""
    unr_rc=0
    unmanaged="$(unmanaged_plists)" || unr_rc=$?
    if [ "$unr_rc" -ne 0 ] && [ "$unr_rc" -ne 1 ]; then
        # ⛔ FAIL-CLOSED, like `check`/`cmux_gate_required` above (0 OK · 1 DRIFT · 2 UNKNOWN — never
        # a pass). A hard failure of `unmanaged_plists` used to be erased by `|| true` into the same
        # empty string a clean box produces, so an enumeration that failed read as GREEN.
        echo "" >&2
        if [ "$unr_rc" -eq 3 ]; then
            # ⛔ AND "CANNOT READ THE DECLARED SET" GETS ITS OWN SENTENCE (round 9), because its
            # consequence is worse than a missed alarm: with an empty declared set EVERY installed job
            # reads UNMANAGED, and the remedy those rows carry is `launchctl bootout … && rm -f …`
            # aimed at this repo's own armed jobs. MEASURED pre-fix with `TEMPLATES_DIR` empty (and
            # again with it chmod 000): `com.eldato.ai-drainer` was reported UNMANAGED with the delete
            # command, on a box where its template was present and merely unreadable.
            echo "  ⛔ UNKNOWN — the DECLARED SET (or its exemption lists: RETIRED," >&2
            echo "     OWNED-BY-OTHER-INSTALLERS) under $TEMPLATES_DIR could NOT be evaluated: it could" >&2
            echo "     not be read, or a list that must name entries holds NONE — a truncated or mangled" >&2
            echo "     manifest is not a blank exemption list. Every installed job would then be" >&2
            echo "     classified against an empty set. Nothing was classified: this is an unanswered" >&2
            echo "     question, not a box full of strays. Restore the manifest(s) under" >&2
            echo "     $TEMPLATES_DIR before trusting any green — or any deletion it advises." >&2
        else
            echo "  ⛔ UNKNOWN — $AGENTS_DIR exists but could NOT be enumerated (rc $unr_rc)." >&2
            echo "     The installed-job set was NOT inspected: this is an unanswered question, not a" >&2
            echo "     clean box. Re-run with a readable $AGENTS_DIR before trusting any green." >&2
        fi
        status_rc=2
    fi
    if [ -n "$unmanaged" ]; then
        echo ""
        # ⛔ ONE LINE PER JOB, AND EACH ONE CARRIES THE VERDICT WORD (#1867 review P3, round 5). The
        # intro used to carry `UNMANAGED` and the job lines did not, so a consumer counting occurrences
        # of the word counted ONE however many jobs there were. `scripts/fleet-schedule.py --verify`
        # prints that count in its verdict, so it said "1 launchd job(s) …" over three — the same
        # family of lie as the `0` it replaced, one order of magnitude smaller. The word now appears on
        # the JOB lines and not in the intro, so counting `⛔ UNMANAGED` is counting jobs.
        echo "  ⛔ Installed job(s) with NO template in the declared set — one line per job:" >&2
        while IFS= read -r _lbl; do
            [ -n "$_lbl" ] || continue
            echo "  ⛔ UNMANAGED   $_lbl ($AGENTS_DIR/$_lbl.plist)" >&2
        done <<<"$unmanaged"
        echo "    None of these is described by this repo, so no template change and no content comparison can" >&2
        echo "    reach one. DECIDE before acting — three declarations are not a deletion:" >&2
        echo "      · a job this repo ships        → add a template under templates/launchd/" >&2
        echo "      · another surface here owns it → templates/launchd/OWNED-BY-OTHER-INSTALLERS" >&2
        echo "      · a job that should go away    → templates/launchd/RETIRED, which retire_pass" >&2
        echo "                                       removes on the next install (no hand-deletion)" >&2
        echo "      · a job nobody declares        → remove it, but ONLY after checking nothing of" >&2
        echo "                                       yours supervises the label:" >&2
        while IFS= read -r _lbl; do
            [ -n "$_lbl" ] || continue
            echo "          launchctl bootout gui/$(id -u) \"$AGENTS_DIR/$_lbl.plist\" && rm -f \"$AGENTS_DIR/$_lbl.plist\"" >&2
        done <<<"$unmanaged"
        # ⛔ THE HIGHER ANSWER WINS, HERE TOO (#3826 review P3, round 18). This arm set 1 unconditionally,
        # so a per-job `2 (UNKNOWN)` from the temp-file/read arms above was DOWNGRADED to 1 ("this box
        # is wrong") — indistinguishable from a real DRIFT, and contradicting the invariant stated one
        # loop up ("A 2 (UNKNOWN) is never downgraded to 1: the higher answer wins"). The neighbouring
        # RETIRED-INSTALLED arm already does it this way. Fail-closed either way; the difference is
        # what the exit status claims.
        [ "$status_rc" -eq 0 ] && status_rc=1
    fi
    # ── RETIRED, STILL INSTALLED (round 8) — its own row class, its own exit contribution ────────
    # One line per job, carrying the verdict word, for the same reason `UNMANAGED` does: a consumer
    # counting markers must count JOBS. The remedy is an INSTALL (which runs `retire_pass`), never
    # `rm -f` — the label is declared, so a hand-deletion is the wrong instruction, and it would leave
    # the launchd registration behind.
    _retired_installed="$(installed_retired_plists)" || true
    if [ -n "$_retired_installed" ]; then
        echo "" >&2
        echo "  ⛔ RETIRED in this repo, STILL INSTALLED here — one line per job:" >&2
        while IFS= read -r _lbl; do
            [ -n "$_lbl" ] || continue
            echo "  ⛔ RETIRED-INSTALLED   $_lbl ($AGENTS_DIR/$_lbl.plist)" >&2
        done <<<"$_retired_installed"
        echo "    Each is declared in templates/launchd/RETIRED and removed by retire_pass, which runs on" >&2
        echo "    an INSTALL — never on --status. Nothing needs them; run:" >&2
        # ⛔ THE REMEDY MUST BE A VERB THIS FILE HAS (#1867 review, round 10). It printed
        # `install-launchd.sh --install`, and there is no `--install` arm — it falls to `*)` and exits 2
        # with a usage error, so the removal path for the blind heartbeat could not be executed as
        # instructed: MEASURED, the printed command → rc 2, plist still on disk, RETIRED-INSTALLED still
        # printed; the SAME command with no argument → `RETIRED (unloaded + removed)`, row gone. The
        # install path is the bare invocation; `--install` was invented by the string. §18 now runs the
        # no-argument form and asserts the row clears, so a re-introduced dead verb reds.
        echo "      bash scripts/install-launchd.sh" >&2
        if [ "$status_rc" -eq 0 ]; then
            status_rc=1
        fi
    fi
    unset _retired_installed
    if [ -n "$(retired_labels)" ]; then
        # ⛔ THE SENTENCE WAS FALSE FOR TWO OF THE THREE LABELS IT NAMED (round 8). It said every
        # retired job "moved to session-checks, #432" — true of hub-state-check and skill-lint-oracle,
        # and false of `com.eldato.orchestrator-watchdog` (retired in favour of the SHIPPED
        # controller-watchdog template) and of `com.tortoise.heartbeat-loop` (whose work moved to
        # `scripts/heartbeat-launch.sh`). An operator reading the status of the box's blind heartbeat
        # was told its work lives in session-checks. The list is what matters — which labels are
        # retired — so it is stated as that, and the reason each was retired lives in the manifest.
        echo "Retired in this repo (no template; the next install unloads + removes each): $(retired_labels | tr '\n' ' ')"
    fi
    echo "Env: AGENT_INFRA_PATH=$AGENT_INFRA_PATH"
    echo "     TORTOISE_REPO=${TORTOISE_REPO:-<unset — session-checks will use the sibling tortoise or skip the hub leg>}"
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
    exit "$status_rc"
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
# ⛔ THE GATE IS EVALUATED BEFORE THE FIRST TEMPLATE IS TOUCHED. A cmux-gated job that installs is
# blind for its whole life and reports success; there is nothing to repair afterwards, so this is a
# precondition of the run rather than a verdict on individual jobs.
cmux_gate_required || exit 1
# Retire first (#432): unload jobs whose work moved to session-checks.
retire_pass || fail=1
for template in "$TEMPLATES_DIR"/*.plist; do
    [ -f "$template" ] || continue
    if is_retired "$(basename "$template" .plist)"; then
        # retire_pass has already warned + unloaded above when the two files contradict; either
        # way a retired label is never installed (#2908 — the manifest wins on a machine).
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
