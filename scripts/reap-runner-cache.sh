#!/usr/bin/env bash
# reap-runner-cache.sh — reclaim the CI runners' per-install PACKAGE CACHE and aged scratch
# (class=runner-cache, agent-infra#4168).
#
# THE MEASURED DEFECT (2026-11-19, five cells). Every runner install keeps its own `.cache` under the
# install root (`/opt/gh-runner-*/.cache`), it is never bounded by anything, and nothing reaps it:
#
#   cell-4  /opt/gh-runner-x64/.cache        40.7 GB   ·  /opt/gh-runner-cell4/.cache    38.1 GB
#           /opt/gh-runner-x64-4/.cache      23.5 GB
#   cell-2  /opt/gh-runner-x64-4/.cache      50.1 GB   ← single largest
#   cell-1  five installs, 17.3 / 27.1 / 21.6 / 19.8 / 13.4 GB
#   cell-3  one install, 42.7 GB
#   cell-5  four installs, 17.9–36.3 GB
#
# A one-pass `rm -rf /opt/gh-runner-*/.cache` reclaimed **≈445 GB across five boxes** (cell-4 went
# 2.3 GB → 116 GB free) and no work was lost: a package cache is content-addressed and regenerates.
#
# ⛔ WHY THIS IS A PIPELINE DEFECT AND NOT TIDINESS. The runner ceiling on a cell is DISK-BOUND:
# `per_runner_disk_mb ≈ 8409` and `DISK_RESERVE_MB = 20480` in `runner_autoscale.py`, so a box needs
# ~20 GB reserve plus ~8.4 GB per runner and at 2–8 GB free `by_disk` pins the ceiling to **1** — the
# box cannot add capacity while its own cache fills the disk (#4004 is the same symptom from the other
# side). None of the entry point's five classes matched this sink: `uv` bounds the MACHINE-GLOBAL
# caches (`~/.cache/uv`), `venv` the lane envs, `worktree` the checkouts, `duplicate-install` surplus
# install COPIES, and `runner-work` the `_work` checkouts. So 445 GB sat in none of the traffic
# classes while the hourly pass reported `ignored-artifact:89 … dirty:10 live-process:2` and reclaimed
# **187 MB** — correct by its own rules and irrelevant to a 40 GB cache.
#
# ── WHAT THIS CLASS RECLAIMS, AND WHAT IT NEVER TOUCHES ───────────────────────────────────────────
# Per install (a directory carrying the install marker `bin/Runner.Listener`, the same marker
# `reap-duplicate-installs.sh` uses — ⛔ NOT "whatever the glob matched": a seam ONE COMPONENT SHORT
# already matched the runner INSTALL tree once and `rm -rf`'d `bin/`, `config/` and `externals/` in a
# sibling class, so the candidate set is decided by a MARKER and not by a glob):
#
#   <install>/.cache/            the whole package cache. Regenerates; the measured 445 GB.
#   <install>/_work/_temp/*      entries older than REAP_RC_SCRATCH_DAYS (default 7).
#   <install>/_diag/*.log        files older than REAP_RC_LOG_DAYS (default 7) — ⛔ EXCEPT THE NEWEST
#                                one per install: a listener holds its CURRENT log OPEN, so unlinking
#                                it reclaims no bytes while crediting the `du` figure to the ledger and
#                                costing the next failure its diagnostics (#4169 review).
#                                ⛔ BOTH AGE GATES SHIP A MUTANT, and the log one needs a fixture that
#                                can SEE it: with a single young log the unconditional newest-log keep
#                                answers for the age gate, so the row passed on a tree where the gate
#                                was deleted (#4169 review, P2 — a dead-weight assertion). The suite's
#                                `case_b` now asserts an OLDER young log beside a newer one, which only
#                                the age gate can keep.
#
# plus the SHARED per-box cache root (`XDG_CACHE_HOME` for pool-started runners, see
# `scripts/ci_runner_pool.sh`), which is what stops the multiplication: N installs with a
# `XDG_CACHE_HOME` each hold N copies of the same content, one per-box root holds one. ⛔ THAT ROOT IS
# GLOB-DECIDED, SO IT IS SCOPE-CHECKED BEFORE ANY DELETE: it must not BE an install and must not
# CONTAIN one (`REFUSED … reason=shared-root-contains-an-install`), because the one-token error this
# seam invites is naming the installs' PARENT — and the liveness gate cannot save it, since a runner
# between jobs is idle BY DESIGN. A refused root ends the pass at `census=refused`/rc 3.
#
# `cache_mb=` IS THE CLASS'S TOTAL, SO IT INCLUDES THE SHARED ROOT. It used to sum only the installs'
# `.cache` dirs, so on exactly the layout the durable half creates (writes go to `XDG_CACHE_HOME`, the
# per-install caches stay empty) the record read `cache_mb=0` beside a non-zero `freed_mb` — a
# self-contradicting number in a class whose rule is "the numbers are printed, not implied" (#4169).
# ⛔ AND A CACHE THE PRESSURE GATE KEEPS IS NOT `du`'d (#4169 review, P3): `df` is one syscall, `du` on
# a 50 GB cache is minutes, and the gate that KEEPS an entry does not need its size. So the size is
# taken only when this pass might act on the entry, and every entry whose size was NOT read is counted
# in `cache_mb_unmeasured=` and printed as `cache_mb=not-measured(<why>)` — a lower bound that SAYS it
# is one, rather than a `du` per install on a pass that fires 144×/day.
# ⛔ THE SYMLINKED-CACHE ARM IS A POLICY KEEP, NOT AN ABSTENTION. A `.cache` that is a symlink (the
# ordinary operator remedy for a small root volume) used to be counted `unmeasurable`, and any
# unmeasurable forces rc 3 — so the class failed closed FOREVER on a healthy box. Nothing is unknown
# here: this class does not follow a symlink in a delete path, the link and its target belong to the
# operator, and the journal names the entry. So it is `KEPT reason=symlinked-cache` like the other
# policy keeps (`below-min-cache`, `*-free-above-trigger`), and the bytes under the target are outside
# this class's scope BY DESIGN — which the line says.
#
# ⛔ THE INSTALL TREE ITSELF IS NEVER A CANDIDATE — not `bin/`, not `config/`, not `externals/`, not
# `_work/<checkout>` (that is `reap-runner-work.sh`'s sink with its own mtime floor), not `_tool`,
# `_actions` or `_update` (the runner's cross-job caches: reaping those makes every later CI run
# re-download, which is a different trade and not this class's to make). `_work/_temp` is touched ONLY
# under the aged-AND-idle gate below, which is exactly the window `reap-runner-work.sh` refuses to
# touch it in — see the note there.
#
# ── THE ONE CORRECTNESS PROPERTY: NEVER DELETE A CACHE A LIVE JOB IS USING ───────────────────────
# A cache deleted mid-job fails the job (a half-written archive, a missing toolchain), so an install
# with a job in flight is SKIPPED WHOLE and REPORTED (`skipped-live`), never partially reaped. The
# verdict comes from the process table, which is the only witness that can answer it:
#
#   * `bin/Runner.Worker` in an install's process list  → a JOB IS RUNNING. Skip.
#   * CONTENT UNDER `_work` WRITTEN WITHIN REAP_RC_JOB_WINDOW_S (default 900 s) → a job is running or
#     has just started. Skip. ⛔ THIS WITNESS IS ASKED FIRST AND IS ARGV-INDEPENDENT: it used to be
#     gated BEHIND a literal `$d/bin/Runner.Listener` / `$d/run.sh` argv match, so an install whose
#     listener argv is not that exact string (`./run.sh` from the install's own cwd, a canonicalised
#     path reached through a symlinked parent, a renamed run.sh) took the `no-listener` arm and lost its
#     cache WITHOUT the one witness that does not depend on argv ever being consulted (#4169 review).
#   * a listener with no worker and nothing fresh under `_work` → the install is BETWEEN jobs. Its
#     cache is not in use; the next job re-downloads what it needs. Reap.
#
# ⛔ AN UNREADABLE PROCESS CENSUS IS NOT "NOBODY IS RUNNING". If `ps` cannot answer, every install's
# liveness is UNKNOWN, so NOTHING is removed and the pass exits 3 (`census=unreadable`) — the same
# fail-closed answer `reap-lane-venvs.sh` gives when its probe is missing. An absent census read as
# "idle" is the one shape that turns this class into a job-killer.
# ⛔ AND THE PROBE IS RE-ASKED IMMEDIATELY BEFORE EVERY REMOVAL (`toctou`), because classification can
# be minutes old on a box whose `du` is slow: a job that started in that window must not lose its
# cache. A re-probe that cannot answer KEEPS the candidate. "Re-asked" means a FRESH process table —
# one `ps` per removal — not a second look at the frozen one: a census read once at pass start cannot
# observe a job that started after it, so a re-probe that reuses it is not a probe at all (the shape
# #4169's review found: the `toctou` arm existed, was documented, and could not fire). The SHARED
# root re-asks the POPULATION question ("does ANY install have a job in flight NOW?"), because that
# root is what every install's listener reads.
#
# ⛔ AND THE PROBE IS ONLY HALF OF IT: THE REMOVAL IS A RENAME, THEN A DELETE. A probe followed by a
# 21–50 GB `rm -rf` is a check-then-act whose window is the WHOLE recursive delete — minutes, at the
# sizes this file's header measures, and `REAP_RC_DU_TIMEOUT=120` already concedes them. A listener
# that picked up a job one second after the probe would read a half-deleted `.cache` for the rest of
# the free, which is exactly the failing job this class exists to prevent. So `reap_one` first
# `mv`s the candidate to `<path>.reaping.<pid>` and only then frees the renamed tree: the rename is
# ONE syscall, so the probe has to be correct only up to it. A job that starts AFTER the rename finds
# no path and re-creates a fresh directory; a job that started BEFORE it keeps its open inodes, since
# unlinking a file another process holds open reclaims the name, not the content. The path is what a
# job's toolchain resolves, and it stops existing at the rename.
#   ⛔ A RENAME THAT CANNOT HAPPEN IS NOT A DELETE PERMISSION: the entry is reported
#   `ERR … reason=quarantine-failed` and counted `failed` (rc 4). A delete that cannot first be made
#   atomic is not attempted, and a failed FREE of the quarantined tree names the leftover
#   (`reason=remove-failed-quarantined path=<q>`), so the bytes are never silently orphaned.
#
# ── CADENCE (agent-infra#4168 point 3) ───────────────────────────────────────────────────────────
# This file is the POLICY OWNER; it holds no clock. `disk-reaper.sh` runs it on TWO cadences and its
# header states why both exist: the hourly full pass (cheap to add here — this class is a `du` per
# install plus a `ps`), and a SIZE-TRIGGERED pass (`--size-trigger`) that fires when free space on the
# installs' filesystem drops below `DISK_REAPER_RUNNER_CACHE_TRIGGER_FREE_MB` (default 40960 MB = 40
# GB). Hourly alone cannot hold a reserve: a busy box writes tens of GB of cache per hour, and the
# measurement that motivated this issue is precisely a pass that ran on a clock while the box fell to
# 2.3 GB free. The per-pass cap (`--max-mb`, and `DISK_REAPER_RUNNER_CACHE_PASS_CAP_MB`, default
# 20480 MB) exists so the frequent pass cannot itself become the load problem: it stops after the cap
# and reports `capped=1 remaining=<n>` so the next tick continues where it stopped.
# ⛔ A CANDIDATE THAT ALONE EXCEEDS THE WHOLE CAP IS STILL TAKEN, while the pass has not yet reached
# its cap. Without that, the cap is an INERT ENFORCER on exactly the population this class exists to
# free: the measured installs are 50.1 / 40.7 / 42.7 / 38.1 / 36.3 / 27.1 / 23.5 / 21.6 GB against a
# 20 GB default, so every one of them is `FREED_MB(0) + pending > MAX_MB` on EVERY tick, forever —
# while the log line promises the next tick continues and the record says `capped=1 remaining=<n>`.
# Admitting one such candidate drops the box by that much and leaves the rest for the next tick, so
# the cap still bounds the pass's work per tick and the backlog still converges.
#
# ⛔ AN UNSIZED CANDIDATE CLAIMS THE WHOLE CAP (agent-infra#4169 review, P3). A `du` that times out —
# the 21–50 GB trees this class exists for — yields `?`, and `${size%%[!0-9]*}` turned that into
# `pending=0`, so such a pass was effectively UNCAPPED while its record still printed `max_mb=` and
# the docs promised the cap stops a pass that fires 144×/day. `?` is now treated as at least `MAX_MB`:
# the first one is still admitted (the oversized-candidate rule), and from then on the pass is capped.
# `freed_mb` stays an honest MEASURED number — the claim is tracked separately (`UNSIZED_MB`), because
# crediting megabytes nobody measured to `freed_mb` would be the same false number in the other
# direction.
#
# ── EXIT CODES ───────────────────────────────────────────────────────────────────────────────────
#   0  the sweep ran; nothing is wrong (this INCLUDES a sweep that found nothing to do)
#   2  usage
#   3  FAIL-CLOSED — the process census could not be read, a glob list an operator SET matched no
#      install (no directory at all, or directories of which none carries the install marker), or a
#      matched SHARED root was REFUSED because it is — or contains — an install. Nothing was removed.
#      ⛔ EACH OF THOSE PUBLISHES ITS OWN CENSUS STATE (`census=no-roots` / `census=refused`) because the
#      REMEDY differs; folding a refusal into a measured zero is how an operator widens a glob that was
#      already matching instead of fixing the one token that is wrong.
#   4  a removal FAILED (the path is still there after `rm`, or it could not be renamed out of the
#      way in the first place)
#   5  DRY RUN with work present (the dry run's whole job is to say so)
#
# Env seams (each validated at startup; a garbage value is a refusal, never a default):
#   REAP_RC_GLOBS          space-separated globs naming the runner INSTALL dirs
#                          (default: /opt/gh-runner* $HOME/actions-runner* $HOME/actions-runner/*
#                          /tmp/actions-runner* /tmp/actions-runner/*). ⛔ SET-BUT-EMPTY IS A REFUSAL:
#                          `${X:-default}` would substitute the WIDEST list for an operator who emptied
#                          the seam to turn the class off, which is the delete direction.
#   REAP_RC_SHARED_GLOBS   space-separated globs naming the ONE per-box cache root
#                          (default: /tmp/actions-runner/_cache $HOME/actions-runner/_cache
#                          ${RUNNER_ROOT:-/tmp/actions-runner}/_cache). ⛔ THE GLOBS ARE NOT THE ONLY
#                          SOURCE AND THEY ARE NOT THE AUTHORITATIVE ONE: every discovered install's
#                          PARENT is also asked for `_cache` (see `add_shared_dir`), because that is the
#                          pool's own default (`CACHE_ROOT=${RUNNER_CACHE_ROOT-$RUNNER_ROOT/_cache}`, with
#                          the installs at `$RUNNER_ROOT/gh-runner-*`) read off the layout instead of off
#                          this process' environment — a scheduled unit that renders no `RUNNER_ROOT`
#                          cannot falsify it (#4169 review, BLOCKING).
#   REAP_RC_SHARED_TRIGGER_FREE_MB
#                          the free-space gate on the SHARED root: it is emptied only when the filesystem
#                          holding it has LESS than this many MiB free (default 40960 = the size-triggered
#                          pass's own trigger; 0 disables the gate). A shared cache is a WARM cache, not a
#                          leak: sweeping it on an hourly pass over a box with 200 GB free makes every
#                          job re-download the same packages (#4169 review, P3).
#   REAP_RC_INSTALL_TRIGGER_FREE_MB
#                          the SAME gate for a per-install `.cache`, measured on the filesystem that
#                          holds THAT install (default 40960; 0 disables). ⛔ IT EXISTS BECAUSE THE
#                          ENTRY POINT'S TRIGGER CANNOT SEE THIS CLASS'S SINKS: the `--size-trigger`
#                          pass fires when ANY filesystem its glob prefixes resolve to is low, and those
#                          prefixes include `/tmp` and `$HOME` — so a box whose `/tmp` is a small tmpfs
#                          fired the pass every 10 minutes while the RUNNERS' filesystem held hundreds
#                          of GB free, and the pass would have flushed every idle install's warm cache
#                          with no free-space condition at all (#4169 review, P2). The trigger's job is
#                          to decide whether the PASS runs; this gate decides whether THIS cache's own
#                          filesystem needs the space. Both are forwarded from the same operator dial
#                          (`DISK_REAPER_RUNNER_CACHE_TRIGGER_FREE_MB`) by `disk-reaper.sh`.
#   REAP_RC_DF_BIN         the free-space probe             (default df, called as `df -Pk <path>`)
#   REAP_RC_EXPLICIT       1 = REAP_RC_GLOBS was SET by the caller, so matching NO INSTALL is a REFUSAL
#                          (an asserted layout that is not there, or a seam one component short) and not
#                          a measured-empty box. `disk-reaper.sh` sets it from the operator seam.
#   REAP_RC_MIN_CACHE_MB   the SIZE bound on a `.cache`: a cache smaller than this is KEPT, because
#                          reaping a few MB of a content-addressed cache buys nothing and costs every
#                          later job a re-download (default 256)
#   REAP_RC_SCRATCH_DAYS   age bound for `_work/_temp` entries  (default 7)
#   REAP_RC_LOG_DAYS       age bound for `_diag/*.log` files    (default 7)
#   REAP_RC_JOB_WINDOW_S   "a job is running" freshness window  (default 900)
#   REAP_RC_MAX_MB         per-pass cap, 0 = uncapped           (default 0; the entry point passes one)
#   REAP_RC_PS_BIN         the process census binary            (default /bin/ps)
#   REAP_RC_DU_BIN         (default du)  REAP_RC_STAT_BIN (default stat)
#   REAP_RC_STATE_DIR      the state dir (also the log's default location)
#                          (default $DISK_REAPER_STATE_DIR)
#   REAP_RC_LOG            the pass log's path                 (default <state>/runner-cache-reap.log)
#                          ⛔ HONOURED, like REAP_RW_LOG/REAP_AW_LOG: the entry point exports it on the
#                          state-dir-fallback path, and an exported seam the owner ignores reads as a
#                          seam that does not exist (#4169 review) — the log then lands in $HOME on
#                          exactly the full-disk pass the fallback exists for.
#   REAP_RC_DRY_RUN        0 supplies the default mode only (an explicit flag always wins)
#
# ⛔ THIS FILE IS THE CLASS'S ONLY DELETE RULE. `disk-reaper.sh` runs it and accounts for it; it
# contains no `rm` of a filesystem path (its suite pins that), exactly as it does for the other five
# owners. A second copy of this policy is how a live job loses its cache to a sweep whose author only
# read one of them.
set -uo pipefail

SCRIPT_NAME="reap-runner-cache.sh"
CLASS_NAME="runner-cache"

# ── bounded execution (#2046): the same ONE resolver every owner uses ────────────────────────────
# macOS ships no `timeout`, and a class that fails closed on every pass there is the inert-enforcer
# shape this feature exists to remove. `TB_TIMEOUT_BIN` pinned-but-unusable is a REFUSAL at startup.
SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)"
fi
BOUNDED_LIB="${BOUNDED_LIB:-}"
if [ -z "$BOUNDED_LIB" ]; then
    for _cand in "$SELF_DIR/lib/bounded.sh" "${HOME:-}/.pi/agent/scripts/lib/bounded.sh"; do
        [ -n "$_cand" ] || continue
        [ -f "$_cand" ] && { BOUNDED_LIB="$_cand"; break; }
    done
fi
if [ ! -f "$BOUNDED_LIB" ]; then
    printf '%s: FAIL-CLOSED at startup — the bounded-execution library is missing (%s); refusing to sweep without a wall-clock bound\n' \
        "$SCRIPT_NAME" "${BOUNDED_LIB:-not beside this script and not in ${HOME:-}/.pi/agent/scripts/lib/}" >&2
    exit 3
fi
# shellcheck source=lib/bounded.sh
. "$BOUNDED_LIB"
if [ "${TB_TIMEOUT_KIND:-}" = "invalid" ]; then
    printf '%s: FAIL-CLOSED at startup — TB_TIMEOUT_BIN=%s cannot be executed; refusing rather than sweeping with an unbounded probe\n' \
        "$SCRIPT_NAME" "${TB_TIMEOUT_BIN:-}" >&2
    exit 3
fi

# ── operands ────────────────────────────────────────────────────────────────────────────────────
# ⛔ `-` NOT `:-` for the two glob lists: a SET-but-EMPTY value is a refusal below, never the default.
RC_GLOBS="${REAP_RC_GLOBS-}"
RC_GLOBS_SET=0
[ -n "${REAP_RC_GLOBS+set}" ] && RC_GLOBS_SET=1
if [ "$RC_GLOBS_SET" = 0 ]; then
    RC_GLOBS="/opt/gh-runner* $HOME/actions-runner* $HOME/actions-runner/* /tmp/actions-runner* /tmp/actions-runner/*"
fi
RC_EXPLICIT="${REAP_RC_EXPLICIT:-$RC_GLOBS_SET}"
SHARED_GLOBS="${REAP_RC_SHARED_GLOBS-}"
SHARED_GLOBS_SET=0
[ -n "${REAP_RC_SHARED_GLOBS+set}" ] && SHARED_GLOBS_SET=1
if [ "$SHARED_GLOBS_SET" = 0 ]; then
    # ⛔ THE LIST BELOW IS A LEGACY-COMPATIBILITY NET, NOT THE COUPLING (#4169 review, BLOCKING).
    # `ci_runner_pool.sh` exports `XDG_CACHE_HOME=${RUNNER_CACHE_ROOT-$RUNNER_ROOT/_cache}` (its own
    # `RUNNER_ROOT` default is `/tmp/actions-runner`), and on the layout this repo documents as LIVE —
    # `RUNNER_ROOT=/opt`, where all four installs on `pi-cell-4` sit (`ci_runner_pool.sh` records the
    # measurement) — a hardcoded `/tmp/... $HOME/...` list matches NOTHING while the pool writes tens of
    # GB into `/opt/_cache`. The derived `${RUNNER_ROOT:-…}/_cache` entry below agreed only when THIS
    # process' environment carried the same `RUNNER_ROOT`, and neither scheduled artifact renders it, so
    # it was the review's falsified "one source". THE REAL COUPLING IS THE LAYOUT: every discovered
    # install's parent is asked for `_cache` (see the derivation at the shared-dir collection), which
    # cannot disagree with the pool whatever an environment says.
    SHARED_GLOBS="/tmp/actions-runner/_cache $HOME/actions-runner/_cache ${RUNNER_ROOT:-/tmp/actions-runner}/_cache"
fi
MIN_CACHE_MB="${REAP_RC_MIN_CACHE_MB:-256}"
SCRATCH_DAYS="${REAP_RC_SCRATCH_DAYS:-7}"
LOG_DAYS="${REAP_RC_LOG_DAYS:-7}"
JOB_WINDOW_S="${REAP_RC_JOB_WINDOW_S:-900}"
MAX_MB="${REAP_RC_MAX_MB:-0}"
PS_BIN="${REAP_RC_PS_BIN:-/bin/ps}"
DU_BIN="${REAP_RC_DU_BIN:-du}"
DF_BIN="${REAP_RC_DF_BIN:-df}"
SHARED_TRIGGER_FREE_MB="${REAP_RC_SHARED_TRIGGER_FREE_MB:-40960}"
case "$SHARED_TRIGGER_FREE_MB" in
    ''|*[!0-9]*) printf '%s: FAIL-CLOSED — REAP_RC_SHARED_TRIGGER_FREE_MB=%s is not a whole number of MiB; a garbage gate value must not silently disable (or widen) a delete gate\n' \
        "$SCRIPT_NAME" "$SHARED_TRIGGER_FREE_MB" >&2
        exit 2 ;;
esac
INSTALL_TRIGGER_FREE_MB="${REAP_RC_INSTALL_TRIGGER_FREE_MB:-40960}"
case "$INSTALL_TRIGGER_FREE_MB" in
    ''|*[!0-9]*) printf '%s: FAIL-CLOSED — REAP_RC_INSTALL_TRIGGER_FREE_MB=%s is not a whole number of MiB; a garbage gate value must not silently disable (or widen) a delete gate\n' \
        "$SCRIPT_NAME" "$INSTALL_TRIGGER_FREE_MB" >&2
        exit 2 ;;
esac
STAT_BIN="${REAP_RC_STAT_BIN:-stat}"
DRY_RUN="${REAP_RC_DRY_RUN:-1}"
STATE_DIR="${REAP_RC_STATE_DIR:-${DISK_REAPER_STATE_DIR:-${HOME:-}/.pi/agent/state}}"
LOG_FILE="${REAP_RC_LOG:-$STATE_DIR/runner-cache-reap.log}"
PS_TIMEOUT="${REAP_RC_PS_TIMEOUT:-60}"
DU_TIMEOUT="${REAP_RC_DU_TIMEOUT:-120}"

usage() {
    sed -n '2,200p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed -n '1,120p'
    printf '\nusage: %s [--dry-run|--apply] [--max-mb N] [--min-cache-mb N] [--scratch-days N] [--log-days N]\n' "$SCRIPT_NAME"
    printf '       %*s [--job-window S] [--help]\n' "${#SCRIPT_NAME}" ''
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --apply)   DRY_RUN=0; shift ;;
        --max-mb)  [ $# -ge 2 ] || { printf '%s: --max-mb needs a number\n' "$SCRIPT_NAME" >&2; exit 2; }
                   MAX_MB="$2"; shift 2 ;;
        --min-cache-mb) [ $# -ge 2 ] || { printf '%s: --min-cache-mb needs a number\n' "$SCRIPT_NAME" >&2; exit 2; }
                   MIN_CACHE_MB="$2"; shift 2 ;;
        --scratch-days) [ $# -ge 2 ] || { printf '%s: --scratch-days needs a number\n' "$SCRIPT_NAME" >&2; exit 2; }
                   SCRATCH_DAYS="$2"; shift 2 ;;
        --log-days) [ $# -ge 2 ] || { printf '%s: --log-days needs a number\n' "$SCRIPT_NAME" >&2; exit 2; }
                   LOG_DAYS="$2"; shift 2 ;;
        --job-window) [ $# -ge 2 ] || { printf '%s: --job-window needs a number\n' "$SCRIPT_NAME" >&2; exit 2; }
                   JOB_WINDOW_S="$2"; shift 2 ;;
        --help|-h) usage ;;
        *) printf '%s: unknown argument: %s (see --help)\n' "$SCRIPT_NAME" "$1" >&2; exit 2 ;;
    esac
done

# ⛔ EVERY NUMERIC OPERAND HERE REACHES AN ARITHMETIC COMPARISON. A non-numeric value makes `[ -gt ]`
# ERROR, and under `set -u` without `-e` the error status takes the `else` arm — which on this class
# means "IDLE, reap it". So a typo in the age bound would turn a fail-closed gate into a delete
# licence. Refuse at startup instead, and bound the magnitude too (a value above intmax_t makes the
# comparison itself error, the same fail-open one size class up).
_seam_ok() { # <name> <value> — refuse a value that is not 1..9 digits
    case "${2:-}" in
        ''|*[!0-9]*)
            printf '%s: FAIL-CLOSED — %s must be a whole number (got %s)\n' "$SCRIPT_NAME" "$1" "'${2:-}'" >&2
            return 1 ;;
    esac
    local _n="${2#"${2%%[!0]*}"}"; [ -n "$_n" ] || _n=0
    if [ "${#_n}" -gt 9 ]; then
        printf '%s: FAIL-CLOSED — %s=%s is out of range (at most 9 digits can be compared)\n' "$SCRIPT_NAME" "$1" "$2" >&2
        return 1
    fi
    return 0
}
_seam_ok REAP_RC_MIN_CACHE_MB "$MIN_CACHE_MB" || exit 3
_seam_ok REAP_RC_SCRATCH_DAYS "$SCRATCH_DAYS" || exit 3
_seam_ok REAP_RC_LOG_DAYS "$LOG_DAYS" || exit 3
_seam_ok REAP_RC_JOB_WINDOW_S "$JOB_WINDOW_S" || exit 3
_seam_ok REAP_RC_MAX_MB "$MAX_MB" || exit 3
# ⛔ A SET-BUT-EMPTY GLOB LIST IS A REFUSAL. An emptied seam would otherwise "scan nothing" and print a
# MEASURED ZERO — an inert class reading healthy on the box it exists to free.
if [ "$RC_GLOBS_SET" = 1 ] && [ -z "$RC_GLOBS" ]; then
    printf '%s: FAIL-CLOSED — REAP_RC_GLOBS is SET but EMPTY. An empty list scans nothing and reports a measured zero; to disable the class, drop it from the pass (--only) instead\n' "$SCRIPT_NAME" >&2
    exit 3
fi
if [ "$SHARED_GLOBS_SET" = 1 ] && [ -z "$SHARED_GLOBS" ]; then
    printf '%s: FAIL-CLOSED — REAP_RC_SHARED_GLOBS is SET but EMPTY (same rule as REAP_RC_GLOBS)\n' "$SCRIPT_NAME" >&2
    exit 3
fi

log_line() { printf '%s\n' "$*"; }
log() { [ -n "${LOG_FILE:-}" ] && printf '%s\n' "$*" >>"$LOG_FILE" 2>/dev/null; return 0; }
now() { date +%s; }

# ── counters (one per outcome; every one is printed, so none can be inferred from another) ───────
INSTALLS=0
CANDIDATES=0
REAPED=0
KEPT=0
SKIPPED_LIVE=0
UNMEASURABLE=0
GONE=0
FAILED=0
CAPPED=0
REMAINING=0
FREED_MB=0
CACHE_TOTAL_MB=0
# ⛔ WHAT AN UNSIZED CANDIDATE CLAIMS OF THE PER-PASS CAP, kept apart from `FREED_MB` on purpose: the
# claim must BOUND the pass, while `freed_mb` must stay a measured number (#4169 review, P3).
UNSIZED_MB=0
# Entries whose size this pass did NOT read because a gate kept them without needing it.
CACHE_NOT_MEASURED=0
# A REFUSED SCOPE IS ITS OWN OUTCOME (see the exit-code table): it is not an abstention (a gate that
# could not ANSWER) and it is emphatically not a measured zero.
REFUSED=0
CENSUS="ok"
CAND_NAMES=""
# Per-install readings, printed on their own lines so an operator can see WHICH install holds the
# bytes (agent-infra#2344: a gate that acts without printing the number it read is a wish).
READINGS=""

is_dry() { [ "$DRY_RUN" = "1" ]; }

rm_path() { rm -rf -- "$1"; }
# mv_path <from> <to> — the ATOMIC half of a removal. One rename is the whole of the window in which a
# job could observe a disappearing cache; the recursive free happens afterwards, on a name no job's
# toolchain resolves (#4169 review, P2). Silent on failure on purpose: the caller VERIFIES the move
# (`[ ! -e "$path" ]`) and reports the refusal, so a `mv` that cannot run is never mistaken for one
# that did.
mv_path() { mv -- "$1" "$2" 2>/dev/null; }

du_mb() { # <path> — blocks occupied in MiB, or empty when the probe could not answer
    local kb
    kb="$(tb_timeout "$DU_TIMEOUT" "$DU_BIN" -sk "$1" 2>/dev/null)" || return 1
    kb="${kb%%[[:space:]]*}"
    case "$kb" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$(( kb / 1024 ))"
}

# free_mb_for_path <path> — MiB free on the filesystem holding <path>, or empty when it cannot answer.
# `df -Pk` is the POSIX spelling on Linux and on BSD/macOS alike ("-P" = one record per line), the same
# reason `du -sk` is used above; its 4th column is 1KiB blocks, so the reading is divided, not rounded.
free_mb_for_path() {
    local out kb
    out="$(tb_timeout "$DU_TIMEOUT" "$DF_BIN" -Pk "$1" 2>/dev/null)" || return 1
    kb="$(printf '%s\n' "$out" | awk 'NR==2 && $4 ~ /^[0-9]+$/ { printf "%d", $4 }') "
    kb="${kb%% *}"
    case "$kb" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$(( kb / 1024 ))"
}

mtime_of() { # <path> — epoch mtime, portable across GNU and BSD stat; empty when unstatable
    local m
    m="$(tb_timeout 60 "$STAT_BIN" -f '%m' "$1" 2>/dev/null)"
    case "$m" in ''|*[!0-9]*) ;; *) printf '%s' "$m"; return 0 ;; esac
    m="$(tb_timeout 60 "$STAT_BIN" -c '%Y' "$1" 2>/dev/null)"
    case "$m" in ''|*[!0-9]*) return 1 ;; *) printf '%s' "$m" ;; esac
}

# ── the process census: ONE read for the pass, and a FRESH one before every removal ─────────────
# A per-install `ps` would be N walks of the same table on a 12-runner box; and a census that cannot
# answer is not "idle" (see the header), so it is captured once and its failure is sticky.
# ⛔ `census_read` ASSIGNS NOTHING UNLESS IT SUCCEEDS. A failed read that blanked `CENSUS_TEXT` would
# leave `proc_has` searching "" — answering "no Runner.Worker found" — which is the DELETE direction,
# the same fail-open the numeric seams above refuse. The caller decides what a failure MEANS:
# pass-start sets `CENSUS=unreadable` (the sticky, fail-closed verdict), a re-probe KEEPS the candidate.
CENSUS_TEXT=""
census_read() {
    # ⛔ `-axo` (not `-eo`): the runner's argv is what identifies the install, and a BSD `ps` without
    # `-x` omits every process not owned by this session — the listeners on a system unit included.
    local _t
    _t="$(tb_timeout "$PS_TIMEOUT" "$PS_BIN" -axo pid=,command= 2>/dev/null)" || return 1
    [ -n "$_t" ] || return 1
    CENSUS_TEXT="$_t"
    return 0
}

# census_refresh — the TOCTOU probe: RE-READ the table, immediately before a removal.
# ⛔ This is what makes the header's promise true. Classification runs, then `du` on a 50 GB cache can
# take minutes; a census read ONCE cannot see a job that started in that window, so a "re-probe" that
# consults the frozen text (or only the `_work` mtime witness) proves nothing about the process table.
# One `ps` per removal is the cost, and it is deliberately paid: a `ps` is milliseconds against a `du`
# that already takes seconds, and the alternative is deleting a live job's cache.
census_refresh() { census_read; }

# any_live_now — the SHARED root's re-probe question, against the CURRENT (just refreshed) census:
# is ANY install running a job right now? The shared root is every install's `XDG_CACHE_HOME`, so a
# single live install anywhere on the box makes it unsafe.
# ⛔ AND AN EMPTY POPULATION IS NOT AN ANSWER (#4169 review, P3). `for d in $INSTALL_DIRS` with no
# disclosed install iterates ZERO times and the function then answers "not live" — having read
# NOTHING — while the caller has just paid for a fresh `census_refresh`. The pass-start Q gate refuses
# that shape at the PRE-loop position (an unattributed runner process keeps the root), but the
# per-entry re-probe in `reap_one` reaches this function minutes later, so the same question has to be
# asked of the SAME fresh census here: with no population, a runner process the pass cannot attribute
# to any discovered install means liveness is UNKNOWN and the entry is KEPT. A zero-install pass over
# a box with no runner process at all still answers IDLE — that is a census result, not an absence.
any_live_now() {
    local d rc
    if [ -n "$INSTALL_DIRS" ]; then
        for d in $INSTALL_DIRS; do
            install_live "$d"; rc=$?
            if [ "$rc" = 0 ]; then return 0; fi
        done
        return 1
    fi
    if proc_has "Runner.Listener" || proc_has "Runner.Worker"; then
        LIVE_REASON="unattributed-runner-process"
        return 0
    fi
    return 1
}

# proc_has <token> — 0 when some process's command line mentions <token>.
# The table is one process per line, so a plain fixed-string search per token is exact enough: an
# install path is unique on the box, and a false POSITIVE here only KEEPS a cache (the safe direction).
# ⛔ NOT `printf … | grep -q` (#841/#861). This file runs under `pipefail`, so a builtin writer that
# takes SIGPIPE when `grep -q` exits early makes the PIPELINE non-zero — and the direction that matters
# here is the FALSE NEGATIVE: "no Runner.Worker found" is what authorises deleting a live job's cache.
# A here-string is a temp file, so there is no second process to signal.
# newest_mtime_under — DELETED by the #4169 review's P1 fix. It read the mtime of `_work/_temp` itself,
# i.e. of a directory this class deletes into, so `rm` of one scratch entry made the next one look like a
# running job. The witness is `work_witness_newest` below, which asks what a JOB WROTE.
proc_has() { grep -F -q -- "$1" <<<"$CENSUS_TEXT"; }

# work_witness_newest <work-dir> — the newest mtime a JOB WROTE under `_work`, never the mtime of the
# directory this class deletes into (#4169 review, P1). ⛔ IT REPLACES `newest_mtime_under "$d/_work"`
# ENTIRELY (that helper is deleted, not merely unused: a second, weaker witness left beside this one is
# how the next reader re-introduces the bug). It IS re-read on every call, on purpose — the witness that
# must be fresh per removal is the PROCESS CENSUS (`census_refresh`); this one only has to avoid being
# a value the pass itself perturbed.
#
# ⛔ THE SELF-POISONING THIS CLOSES, stated as the mechanism because it is not obvious from a diff:
# `_work/_temp` is a DIRECT CHILD of `_work`, and `rm` of an entry inside it sets `_temp`'s OWN mtime to
# now. Taking `newest_mtime_under "$d/_work"` therefore read this class's own last delete as "a job is
# running": entry #2 of the same pass was skipped `toctou:busy-work`, the whole `_diag` arm after it was
# skipped too, and — because the poisoned mtime persists after the pass — the NEXT tick (10 min against
# a 900 s window) classified a box with no job on it as LIVE and skipped that install's `.cache` whole.
# So at most one aged scratch entry per install was ever reclaimable per pass, and the class halved its
# own duty cycle exactly while the backlog it exists to bound was still there.
#
# ⛔ THE WITNESS IS NOT WEAKENED, IT IS RE-AIMED AT THE WRITER: a live job's own writes still show up —
# files it creates inside `_temp` have fresh mtimes (so one bounded level DOWN `_temp` is asked), and
# its checkout under `_work/<repo>` is untouched by this class. What is dropped is only the mtime of a
# directory this class bumps itself. A job that merely EMPTIES `_temp` at a job boundary is no longer a
# freshness reading — that is the disclosed cost of not poisoning the witness, and it points in the
# keep-less direction only for a cache that the install-arm pressure gate (and the shared root's own
# gate) already protects on a healthy box.
work_witness_newest() {
    local d="$1" f c m best=0
    [ -d "$d" ] || { printf '0'; return 0; }
    for f in "$d"/*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        if [ "$f" = "$d/_temp" ]; then
            for c in "$f"/*; do
                [ -e "$c" ] || [ -L "$c" ] || continue
                m="$(mtime_of "$c")" || continue
                [ "$m" -gt "$best" ] && best="$m"
            done
            continue
        fi
        m="$(mtime_of "$f")" || continue
        [ "$m" -gt "$best" ] && best="$m"
    done
    printf '%s' "$best"
}

# work_witness <install> — the `_work` freshness witness for one install.
work_witness() {
    work_witness_newest "${1%/}/_work"
}

# install_live <install-dir> — 0 LIVE (skip), 1 IDLE (safe to reap), 2 CANNOT ANSWER (skip).
# Sets LIVE_REASON for the report; the report is the whole point, so the reason is never inferred by
# the caller from the return code.
LIVE_REASON=""
install_live() {
    local d="$1" newest
    LIVE_REASON=""
    if [ "$CENSUS" != "ok" ]; then LIVE_REASON="census-unreadable"; return 2; fi
    # A JOB IN FLIGHT is the decisive witness: Actions spawns one `Runner.Worker` per job, so its
    # presence means the install's cache is being read right now.
    if proc_has "$d/bin/Runner.Worker" || proc_has "$d/bin/Runner.Worker.dll"; then
        LIVE_REASON="worker-running"; return 0
    fi
    # ⛔ THE `_work` WITNESS IS ARGV-INDEPENDENT AND IS ASKED FIRST (#4169 review). It was gated BEHIND
    # the literal listener-argv match below, so an install whose listener argv is not that exact string
    # — `./run.sh` from the install's own cwd, a canonicalised path reached through a symlinked parent,
    # a renamed `run.sh` — fell to the `no-listener` arm and its cache was reaped WITHOUT asking the one
    # witness that does not depend on argv. Content under `_work` written inside the job window is a job
    # running or just started whatever the process table spells; the conservative direction costs one
    # pass, the other costs a job. The cost is one bounded listing per install (one level, never a walk).
    # ⛔ AND IT ASKS A WITNESS THIS CLASS CANNOT PERTURB (`work_witness`): this very function is the
    # pre-removal re-probe, and re-deriving the freshness of the SINK'S OWN directory between two
    # removals made the class skip its own remaining candidates (#4169 review, P1).
    newest="$(work_witness "$d")"
    if [ "${newest:-0}" -gt 0 ] && [ "$(( $(now) - newest ))" -le "$JOB_WINDOW_S" ]; then
        LIVE_REASON="busy-work"; return 0
    fi
    if proc_has "$d/bin/Runner.Listener" || proc_has "$d/run.sh"; then
        # A listener with nothing fresh under `_work` is BETWEEN jobs: the cache is idle, and the next
        # job re-downloads what it needs. Reap.
        LIVE_REASON="idle-listener"; return 1
    fi
    LIVE_REASON="no-listener"; return 1
}

# cap_reached <pending-mb> — 0 when adding <pending-mb> would exceed the per-pass cap.
# ⛔ THE CAP IS ENFORCED ON THE CANDIDATE SET IN BOTH MODES. A dry run that reported every candidate
# on a box where the armed pass would stop at the cap describes a pass that cannot happen; the two
# modes must select the SAME candidates or the dry run is not a preview of anything.
cap_reached() {
    local pending="${1:-0}"
    [ "$MAX_MB" -gt 0 ] || return 1
    # ⛔ A CANDIDATE BIGGER THAN THE WHOLE CAP IS NOT REFUSED FOREVER (see the header). The measured
    # population is 21–50 GB against a 20 GB default, so testing `FREED_MB + pending > MAX_MB` from a
    # `FREED_MB` that starts at 0 refuses the headline case on EVERY tick and the box never frees it.
    # Admit exactly one such candidate per pass, while the pass has not reached its cap yet (so a
    # small candidate earlier in the pass cannot lock the big one out), and let the cap bound
    # everything after it: FREED_MB then exceeds MAX_MB and every later candidate is deferred.
    # ⛔ THE CLAIM IS `FREED_MB + UNSIZED_MB`, NOT `FREED_MB`: an unsized (`?`) candidate claims the
    # whole cap, so one admitted `du`-timeout tree caps the pass instead of leaving it uncapped
    # (#4169 review, P3). With every size measured, `UNSIZED_MB` is 0 and this is the arithmetic it
    # always was.
    if [ "$pending" -gt "$MAX_MB" ] && [ "$(( FREED_MB + UNSIZED_MB ))" -lt "$MAX_MB" ]; then
        return 1
    fi
    [ "$(( FREED_MB + UNSIZED_MB + pending ))" -gt "$MAX_MB" ]
}

# reap_one <path> <size-mb|?-> <kind> <install|-> — the ONE destructive call, gated three ways.
#   1. the cap (a pass may not become the load problem it exists to fix)
#   2. a RE-PROBE against a FRESH process census, immediately before removal
#   3. `rm -rf` is not evidence: the path must be GONE afterwards or the removal FAILED
# `<install>` names the install whose liveness the re-probe re-asks; `-` is the SHARED cache root,
# whose question is the population's (any install live), because that root is not one install's.
reap_one() {
    local path="$1" size="$2" kind="$3" install="$4" _live _pending _q
    # ⛔ AN UNSIZED CANDIDATE CLAIMS THE WHOLE CAP (#4169 review, P3). `${size%%[!0-9]*}` collapsed
    # every `?` (a `du` that timed out on a 40–50 GB tree) to 0, so such a pass was uncapped: the cap
    # promised in the docs bounded nothing on exactly the population it was written for.
    _pending="${size%%[!0-9]*}"
    case "$size" in ''|*[!0-9]*) _pending="$MAX_MB" ;; esac
    if cap_reached "$_pending"; then
        CAPPED=1; REMAINING=$((REMAINING + 1))
        log_line "KEPT   $path reason=pass-cap (per-pass cap ${MAX_MB}MB reached; the next tick continues)"
        return 0
    fi
    CANDIDATES=$((CANDIDATES + 1))
    if is_dry; then
        CAND_NAMES="${CAND_NAMES}${CAND_NAMES:+
}REAP ${size}MB ${path} kind=${kind}"
        case "$size" in
            ''|*[!0-9]*) UNSIZED_MB=$((UNSIZED_MB + MAX_MB)) ;;
            *)           FREED_MB=$((FREED_MB + size)) ;;
        esac
        return 0
    fi
    # ⛔ RE-PROBE IMMEDIATELY BEFORE THE DESTRUCTIVE CALL, AGAINST A FRESH CENSUS. The classification
    # above can be minutes old on a box whose `du` is slow, and a job that started in that window must
    # not lose its cache. ⛔ THE REFRESH COMES FIRST AND ITS FAILURE IS FATAL TO THE REMOVAL: without
    # it `install_live` would answer from the pass-start text and the `toctou` arm could never fire
    # (#4169 review) — a documented gate that cannot act is worse than no gate.
    if ! census_refresh; then
        UNMEASURABLE=$((UNMEASURABLE + 1))
        log_line "KEPT   $path reason=toctou-census-unreadable (the re-probe could not RE-READ the process table; NOT removed)"
        return 0
    fi
    if [ "$install" = "-" ]; then
        # The SHARED root: the question is the POPULATION's, not one install's.
        if any_live_now; then
            SKIPPED_LIVE=$((SKIPPED_LIVE + 1))
            log_line "SKIPPED-LIVE $path reason=toctou:${LIVE_REASON:-an-install-has-a-job-running} (an install started a job during the pass; re-probed immediately before removal, NOT removed)"
            return 0
        fi
    elif [ -n "$install" ]; then
        install_live "$install"; _live=$?
        case "$_live" in
            0) SKIPPED_LIVE=$((SKIPPED_LIVE + 1))
               log_line "SKIPPED-LIVE $path reason=toctou:${LIVE_REASON} (a job started during the pass; re-probed immediately before removal, NOT removed)"
               return 0 ;;
            # ⛔ NO `2` ARM HERE ON PURPOSE. `install_live` answers 2 only for an unreadable census, and
            # that case was just refused by the refresh above (and, at pass start, by `sweep_install`
            # before it ever reaches this call) — so a `2` arm here is unreachable dead code that reads
            # as a gate. The live arm and the refresh-failure arm are the two that can happen.
        esac
    fi
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        GONE=$((GONE + 1))
        log_line "GONE   $path reason=vanished-at-removal (nothing removed by this class, and not an abstention)"
        return 0
    fi
    # ⛔ RENAME FIRST, THEN FREE (#4169 review, P2). The probe above is only correct up to this
    # syscall: without it the window was the whole recursive delete — minutes on a 21–50 GB tree —
    # and a job that started inside it read a half-deleted cache, which is the failing job this class
    # exists to prevent. After the rename the PATH a job resolves no longer exists (a job that starts
    # now gets a fresh directory), while a job that started before it keeps its open inodes.
    _q="${path}.reaping.$$"
    if ! mv_path "$path" "$_q" || [ -e "$path" ] || [ -L "$path" ]; then
        FAILED=$((FAILED + 1))
        log_line "ERR    $path reason=quarantine-failed (the candidate could not be RENAMED out of the way, so it was NOT deleted: a removal that cannot first be made atomic is not attempted — a live job must never observe a half-deleted tree)"
        log "REMOVAL REFUSED (quarantine) $path"
        return 0
    fi
    if rm_path "$_q" 2>/dev/null && [ ! -e "$_q" ] && [ ! -L "$_q" ]; then
        REAPED=$((REAPED + 1))
        case "$size" in
            ''|*[!0-9]*) UNSIZED_MB=$((UNSIZED_MB + MAX_MB)) ;;
            *)           FREED_MB=$((FREED_MB + size)) ;;
        esac
        log_line "REAPED $path how=rm-quarantined kind=${kind} mb=${size}"
        log "reaped $path kind=$kind mb=$size how=rm-quarantined"
    else
        FAILED=$((FAILED + 1))
        log_line "ERR    $path reason=remove-failed-quarantined path=$_q (the tree was renamed out of a live job's reach but could not be freed; the bytes are still on disk under that name and nothing else in this class matches it)"
        log "REMOVAL FAILED (quarantined) $path -> $_q"
    fi
    return 0
}

# ── the installs ─────────────────────────────────────────────────────────────────────────────────
# ⛔ THE MARKER DECIDES, NOT THE GLOB. A glob one component short already swept a runner INSTALL tree
# in a sibling class (`REAPED …/gh-runner-x//bin`), so a directory is an install only when it carries
# the listener binary. That also makes the wide defaults above safe.
is_install() { [ -f "$1/bin/Runner.Listener" ] || [ -L "$1/bin/Runner.Listener" ]; }

SEEN_INSTALLS=" "
sweep_install() { # <install-dir>
    local d="$1" cache="$1/.cache" sz="" reading cutoff_s cutoff_l f fm newest_log newest_lm _lm
    local _press="" _press_state="none" _defer=""
    INSTALLS=$((INSTALLS + 1))
    # ── THE CHEAP GATE FIRST, THE READING AFTER (#4169 review, P3) ───────────────────────────────
    # `df` is ONE syscall on the install's own filesystem; `du -sk` of a measured cache is MINUTES
    # (21–50 GB, and `REAP_RC_DU_TIMEOUT=120` already concedes it). The free-space gate is the only
    # gate that can KEEP an entry WITHOUT knowing its size, so it is asked first and the size is read
    # only when this pass might act. Without this, a `--size-trigger` pass that fired on an unrelated
    # small filesystem (a tmpfs `/tmp`, `$HOME` on a small root) paid a `du` per install to decide
    # nothing — the cost the docs claimed was "one `df`".
    # ⛔ AND A SYMLINKED `.cache` IS NEVER `du`'d AT ALL: `du -sk <link>` dereferences its operand, so
    # the old unconditional reading described a tree this class does not own and then threw the
    # number away.
    if [ -e "$cache" ] || [ -L "$cache" ]; then
        if [ -L "$cache" ]; then
            _press_state="symlinked"
        elif [ "$INSTALL_TRIGGER_FREE_MB" -gt 0 ]; then
            _press="$(free_mb_for_path "$d")" || _press=""
            case "$_press" in ''|*[!0-9]*) _press="" ;; esac
            if [ -z "$_press" ]; then _press_state="unanswerable"
            elif [ "$_press" -ge "$INSTALL_TRIGGER_FREE_MB" ]; then _press_state="warm"
            else _press_state="pressure"; fi
        else
            _press_state="gate-off"
        fi
        case "$_press_state" in
            symlinked)    _defer="symlink" ;;
            unanswerable) _defer="free-unmeasurable" ;;
            warm)         _defer="free-above-trigger" ;;
            *)            sz="$(du_mb "$cache")" || sz="" ;;
        esac
    else
        sz="0"
    fi
    # ⛔ A DEFERRED SIZE IS SAID SO, NEVER PRINTED AS `?`-MEANS-UNMEASURABLE: `?` is "a probe could
    # not answer"; this is "the pass did not need the number", and the two must not read alike. The
    # count goes into the SUMMARY as `cache_mb_unmeasured=`, because `cache_mb=` is then a LOWER BOUND
    # and a reader comparing it with `df` must be told why (#2344: print the reading, do not imply it).
    [ -n "$_defer" ] && CACHE_NOT_MEASURED=$((CACHE_NOT_MEASURED + 1))
    install_live "$d"; local live=$?
    # ⛔ `ANY_LIVE` IS ACCUMULATED HERE, in the ONE place every install is read, and not by a second
    # pass over the population: two reads of the same answer is how the shared root's gate and the
    # per-install verdict drift apart.
    [ "$live" = 0 ] && ANY_LIVE=1
    reading="INSTALL ${d} cache_mb=$( [ -n "$_defer" ] && printf 'not-measured(%s)' "$_defer" || printf '%s' "${sz:-?}" ) live=$( [ "$live" = 0 ] && printf yes || { [ "$live" = 2 ] && printf unknown || printf no; } ) reason=${LIVE_REASON}"
    READINGS="${READINGS}${READINGS:+
}${reading}"
    case "$sz" in ''|*[!0-9]*) ;; *) CACHE_TOTAL_MB=$((CACHE_TOTAL_MB + sz)) ;; esac

    # ── the ONE correctness property: a live install is skipped WHOLE, and reported ──────────────
    if [ "$live" = 0 ]; then
        SKIPPED_LIVE=$((SKIPPED_LIVE + 1))
        log_line "SKIPPED-LIVE $d reason=skipped-live:${LIVE_REASON} cache_mb=${sz:-?} (a job is running in this install; its cache and scratch are NOT touched)"
        return 0
    fi
    if [ "$live" = 2 ]; then
        # The census could not answer. Nothing under this install may be removed, and the pass is not
        # allowed to call that "nothing to do" — `CENSUS` is already `unreadable` and the exit is 3.
        UNMEASURABLE=$((UNMEASURABLE + 1))
        log_line "KEPT   $d reason=census-unreadable (liveness UNKNOWN, so neither its cache nor its scratch may be removed)"
        return 0
    fi

    # ── .cache: the whole directory, and the measured 445 GB ────────────────────────────────────
    if [ -e "$cache" ] || [ -L "$cache" ]; then
        # ⛔ A SYMLINKED CACHE IS NEVER FOLLOWED, AND IT IS A POLICY KEEP — NOT AN ABSTENTION
        # (#4169 review, P3). `rm -rf` on a symlink removes the LINK (harmless), but `du` and every
        # later reading would then describe a tree this class does not own — and a dangling link is a
        # box whose big disk was unmounted, which is not a state to guess at. It used to be counted
        # `unmeasurable`, and ANY unmeasurable forces rc 3 — so the ordinary operator remedy for a
        # small root volume (symlink the per-install cache onto a big disk) reddened the hourly
        # reaper FOREVER, with no seam to accept the layout. Nothing is unknown here: the line names
        # the entry, and the bytes under the target are outside this class by design.
        if [ -L "$cache" ]; then
            KEPT=$((KEPT + 1))
            log_line "KEPT   $cache reason=symlinked-cache (a POLICY keep, not an abstention: this class never follows a symlink in a delete path, so the link and its target stay the operator's; the bytes under the target are outside this class's scope and the pass does not fail closed over them)"
        elif [ -n "$sz" ] && [ "$sz" -lt "$MIN_CACHE_MB" ]; then
            # ⛔ THE SIZE BOUND, AND IT IS THE "NO CHURN" HALF OF THE POLICY. A cache is
            # content-addressed: reaping 40 GB costs every later job a re-download of what it needs,
            # and reaping 4 MB costs exactly the same trade for nothing. Below the bound the entry is
            # KEPT and NAMED, so "the cache is still there" has an answer other than "the reaper broke".
            KEPT=$((KEPT + 1))
            log_line "KEPT   $cache reason=below-min-cache (${sz}MB < ${MIN_CACHE_MB}MB — reaping it would cost the next job a re-download for no meaningful space)"
        elif [ "$INSTALL_TRIGGER_FREE_MB" -gt 0 ] && [ -z "$_press" ]; then
            # ⛔ AN UNANSWERABLE PROBE KEEPS THE CACHE. `df` failing is not evidence of pressure, and
            # reading it as "reap" is the fail-open shape the numeric seams above already refuse. It is
            # reported as UNMEASURABLE, so the pass's own verdict does not claim a clean run.
            UNMEASURABLE=$((UNMEASURABLE + 1))
            log_line "KEPT   $cache reason=install-free-unmeasurable ('$DF_BIN -Pk' could not answer for this install, so the free-space gate cannot say whether ITS filesystem is under pressure; NOT removed, and not measured)"
        elif [ "$INSTALL_TRIGGER_FREE_MB" -gt 0 ] && [ "$_press" -ge "$INSTALL_TRIGGER_FREE_MB" ]; then
            # ⛔ PRESSURE-GATED, NOT AGE-GATED — THE SAME POLICY THE SHARED ROOT ALREADY HAD (#4169
            # review, P2). Without this, EVERY pass reaped EVERY idle install's whole warm cache no
            # matter how much space the box had: the frequent pass is what made that visible (a tmpfs
            # `/tmp` in the trigger's prefix set fired it 144×/day over a healthy cache volume), but the
            # HOURLY pass did the same thing. A cache is a WARM cache, not a leak.
            KEPT=$((KEPT + 1))
            log_line "KEPT   $cache reason=install-free-above-trigger free_mb=${_press} trigger_mb=${INSTALL_TRIGGER_FREE_MB} cache_mb=not-measured (a WARM cache on a filesystem with space: this filesystem does not need the bytes, the next job would re-download them, and its size was NOT read — one `df` instead of a `du` of the whole tree)"
        else
            # ⛔ RE-MEASURE AT THE MOMENT OF ACTION for the cap: the `sz` above is a reading, the
            # number that must respect the cap is the one taken immediately before the delete.
            local sz2; sz2="$(du_mb "$cache")" || sz2=""
            reap_one "$cache" "${sz2:-?}" cache "$d"
        fi
    else
        log_line "KEPT   $cache reason=absent (this install keeps no cache here — nothing to reclaim)"
    fi

    # ── _work/_temp and _diag/*.log: the install's own scratch, age-bounded ─────────────────────
    # ⛔ THE IDLE GATE ABOVE IS WHAT MAKES `_work/_temp` SAFE HERE, and it is the whole difference from
    # `reap-runner-work.sh`, which RETAINS `_temp` because a LIVE job's step script can look stale
    # while its checkout is fresh (a long step writes once). That reasoning holds for a class whose
    # only gate is an mtime floor. This class has a second gate — the install has no job in flight —
    # so an aged entry here belongs to a job that is over, which is precisely the state
    # `reap-runner-work.sh` refuses to reason about at all. `_diag` is the same trade with the runner's
    # own listener logs (they are diagnostics, never inputs of a job).
    cutoff_s=$(( $(now) - SCRATCH_DAYS * 86400 ))
    for f in "$d/_work/_temp"/*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        [ -L "$f" ] && { KEPT=$((KEPT + 1)); log_line "KEPT   $f reason=symlink (never followed in a delete path)"; continue; }
        fm="$(mtime_of "$f")" || { UNMEASURABLE=$((UNMEASURABLE + 1))
            log_line "KEPT   $f reason=unmeasurable-mtime (the age gate could not answer; NOT removed)"; continue; }
        if [ "$fm" -gt "$cutoff_s" ]; then
            KEPT=$((KEPT + 1))
            log_line "KEPT   $f reason=too-young (newer than ${SCRATCH_DAYS}d)"
            continue
        fi
        sz="$(du_mb "$f")" || sz=""
        reap_one "$f" "${sz:-?}" scratch "$d"
    done
    cutoff_l=$(( $(now) - LOG_DAYS * 86400 ))
    # ⛔ THE NEWEST LOG IS THE LISTENER'S *CURRENT* ONE, AND UNLINKING IT RECLAIMS NOTHING and credits
    # bytes that do not exist (#4169 review, P3). `_diag/Runner_<ts>-utc.log` is held OPEN by the
    # listener for its whole lifetime: with no jobs its mtime ages past `REAP_RC_LOG_DAYS`, the age gate
    # admits it, `rm` succeeds — and the inode survives through the open descriptor, so the `du -sk`
    # taken before the delete went into `FREED_MB`/`REAPED` for bytes no `df` pair will ever show, while
    # the box lost the diagnostics an operator needs for the NEXT failure. Exactly one file per install
    # is kept — the newest, which is the one a live listener holds — and the older, closed logs under
    # here are still reaped on the same age bound.
    newest_log=""; newest_lm=-1
    for f in "$d/_diag"/*.log; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        _lm="$(mtime_of "$f")" || continue
        [ "$_lm" -gt "$newest_lm" ] && { newest_lm="$_lm"; newest_log="$f"; }
    done
    for f in "$d/_diag"/*.log; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        [ -L "$f" ] && { KEPT=$((KEPT + 1)); log_line "KEPT   $f reason=symlink (never followed in a delete path)"; continue; }
        fm="$(mtime_of "$f")" || { UNMEASURABLE=$((UNMEASURABLE + 1))
            log_line "KEPT   $f reason=unmeasurable-mtime (the age gate could not answer; NOT removed)"; continue; }
        if [ "$fm" -gt "$cutoff_l" ]; then
            KEPT=$((KEPT + 1))
            log_line "KEPT   $f reason=too-young (newer than ${LOG_DAYS}d)"
            continue
        fi
        if [ -n "$newest_log" ] && [ "$f" = "$newest_log" ]; then
            KEPT=$((KEPT + 1))
            log_line "KEPT   $f reason=newest-log (the listener's CURRENT log: held open, so unlinking it reclaims no bytes and costs the next failure its diagnostics; the aged-and-closed logs beside it are still reaped)"
            continue
        fi
        sz="$(du_mb "$f")" || sz=""
        reap_one "$f" "${sz:-?}" diag "$d"
    done
    return 0
}

# ── the shared per-box cache root (what stops N installs holding N copies) ──────────────────────
# ⛔ ITS GATE IS STRICTER THAN A PER-INSTALL ONE: the root is used by EVERY install on the box, so it
# may only be reaped when NO install has a job in flight. Reaped only after the install sweep, so the
# answer it needs (`ANY_LIVE`) is already known.
ANY_LIVE=0
sweep_shared() {
    local root="$1" sz e sz2 is_inst free_mb
    [ -d "$root" ] || return 0
    # ⛔ `ANY_LIVE` IS THE CLASSIFICATION, NOT THE GATE. It was established by `sweep_install`, the one
    # place every install's liveness is read, and it is what reports the skip (and what makes cleanup
    # of a huge root cheap when a job is already known to be running). The GATE is the per-entry
    # re-probe in `reap_one` (`-` = the population question), against a FRESH census: the entries are
    # removed minutes after this classification on a box whose `du` is slow, and a job that started in
    # that window must not lose the cache it is reading.
    if [ "$CENSUS" != ok ]; then
        UNMEASURABLE=$((UNMEASURABLE + 1))
        log_line "KEPT   $root reason=census-unreadable (the SHARED root is used by every install; liveness is UNKNOWN)"
        return 0
    fi
    if [ -L "$root" ]; then
        KEPT=$((KEPT + 1))
        log_line "KEPT   $root reason=symlinked-cache (a POLICY keep, not an abstention: this class never follows a symlink in a delete path — a symlinked shared root is the operator's own layout, named here so the pass does not fail closed on it forever)"
        return 0
    fi
    # ⛔ SCOPE, BEFORE ANY DELETE AND BEFORE ANY `du` (#4169 review, P2). The install arm is
    # marker-gated (`is_install`) for the reason the header argues at length; this arm had NO equivalent,
    # so the ONE-TONK error this seam invites — naming `$RUNNER_ROOT` instead of `$RUNNER_ROOT/_cache` —
    # turned a delete surface over the runner INSTALL tree (`bin/`, `config.sh`, `.runner`, `_work/`).
    # The liveness gate does not save it: a runner between jobs is `idle-listener` BY DESIGN, so every
    # idle install under a mis-typed root is deletable. Two `stat`s close it — the root must not BE an
    # install, and must not CONTAIN one — and a refusal is the whole pass's, so nothing is deleted
    # before it (the shape `reap-runner-work.sh` already uses for a refused root).
    if is_install "$root"; then
        REFUSED=$((REFUSED + 1))
        log_line "REFUSED $root reason=shared-root-is-an-install (a shared CACHE root must not be a runner INSTALL: the seam is one component short, e.g. '\$RUNNER_ROOT' for '\$RUNNER_ROOT/_cache'; sweeping it would delete bin/, config.sh and _work/ of a live install)"
        return 0
    fi
    is_inst=""
    for e in "$root"/*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        is_install "$e" && { is_inst="$e"; break; }
    done
    if [ -n "$is_inst" ]; then
        REFUSED=$((REFUSED + 1))
        log_line "REFUSED $root reason=shared-root-contains-an-install first=$is_inst (the glob named the installs' PARENT — the seam is one component short, e.g. '\$RUNNER_ROOT' for '\$RUNNER_ROOT/_cache'; nothing under it was touched)"
        return 0
    fi
    # ⛔ THE ROOT'S READING IS TAKEN ONCE AND IS PART OF THE CLASS'S TOTAL (#4169 review, P2).
    # `cache_mb_runner_cache=` is documented as "the total bytes held by the class's caches", and this
    # root — the one the durable half creates, where every pooled install's writes land — was never
    # summed: on a pool box the record read `cache_mb_runner_cache=0 … freed_mb_runner_cache=20480`, a
    # number contradicting itself in a PR whose heading is "the numbers are printed, not implied".
    sz="$(du_mb "$root")" || sz=""
    case "$sz" in ''|*[!0-9]*) ;; *) CACHE_TOTAL_MB=$((CACHE_TOTAL_MB + sz)) ;; esac   # shared-root reading joins the class total
    # ⛔ THE LIVENESS GATE MUST NOT BE VACUOUS (#4169 review, BLOCKING). `any_live_now` walks
    # `$INSTALL_DIRS`, so with NO install discovered it answers "not live" WITHOUT READING ANYTHING —
    # and this arm then emptied the root every install on the box shares, on the word of a question it
    # never asked. When the population is empty the witness is the CENSUS instead: a runner process the
    # pass cannot attribute to any discovered install means an install lives OUTSIDE the globs and may be
    # reading this root right now, so liveness is UNKNOWN and nothing is removed. A census carrying no
    # runner process at all is a real proof (not an absence of evidence) that nothing can be using it.
    if [ "$INSTALLS" -eq 0 ]; then
        if proc_has "Runner.Listener" || proc_has "Runner.Worker"; then
            UNMEASURABLE=$((UNMEASURABLE + 1))
            log_line "KEPT   $root reason=unattributed-runner-process (no install matched this pass's globs, but the process census carries a Runner.Listener/Runner.Worker that no discovered install accounts for — an install OUTSIDE those globs may be using this SHARED root, so its liveness is UNKNOWN and nothing under it was touched)"
            return 0
        fi
    fi
    # ⛔ PRESSURE-GATED, NOT AGE-GATED (#4169 review, P3). This root has no size bound of its own, so an
    # unconditional sweep on the HOURLY pass empties a warm machine-wide cache on a box with hundreds of
    # GB free — every job then re-downloads the same packages, and the class becomes a tax on a healthy
    # machine. It is reaped only below `REAP_RC_SHARED_TRIGGER_FREE_MB` (the same 40 GB the size-triggered
    # pass uses), so the frequent pass owns it under pressure and the hourly pass leaves it warm. ⛔ THE
    # GATE SITS AFTER THE LIVENESS SKIP, so a root a job is actually using is always reported as
    # `skipped-live` — the safety verdict outranks the policy one.

    if [ "$ANY_LIVE" = 1 ]; then
        SKIPPED_LIVE=$((SKIPPED_LIVE + 1))
        log_line "SKIPPED-LIVE $root reason=skipped-live:an-install-has-a-job-running cache_mb=${sz:-?} (the SHARED cache is used by every install on this box)"
        READINGS="${READINGS}${READINGS:+
}INSTALL ${root} cache_mb=${sz:-?} live=yes reason=shared-with-a-live-install"
        return 0
    fi
    if [ "$SHARED_TRIGGER_FREE_MB" -gt 0 ]; then
        free_mb="$(free_mb_for_path "$root")"
        case "${free_mb:-}" in
            ''|*[!0-9]*)
                UNMEASURABLE=$((UNMEASURABLE + 1))
                log_line "KEPT   $root reason=free-unmeasurable ('$DF_BIN -Pk' could not answer for this root, so the free-space gate cannot say whether the box is under pressure; NOTHING under it was removed)"
                READINGS="${READINGS}${READINGS:+
}INSTALL ${root} cache_mb=${sz:-?} live=no reason=shared-free-unmeasurable"
                return 0 ;;
        esac
        if [ "$free_mb" -ge "$SHARED_TRIGGER_FREE_MB" ]; then
            KEPT=$((KEPT + 1))
            log_line "KEPT   $root reason=shared-free-above-trigger free_mb=${free_mb} trigger_mb=${SHARED_TRIGGER_FREE_MB} (a WARM shared cache on a box with space: the gate keeps it, and the size-triggered pass reaps it once free space falls below the trigger)"
            READINGS="${READINGS}${READINGS:+
}INSTALL ${root} cache_mb=${sz:-?} live=no reason=shared-kept-warm-above-trigger"
            return 0
        fi
    fi
    READINGS="${READINGS}${READINGS:+
}INSTALL ${root} cache_mb=${sz:-?} live=no reason=shared-root-no-job-running"
    # ⛔ THE SHARED ROOT IS RECLAIMED IN PLACE, NOT DELETED. It is the `XDG_CACHE_HOME` a running
    # listener was started with: removing the DIRECTORY itself is fine for an idle box, but keeping it
    # (and emptying it) means a listener that starts between this pass and its re-probe cannot land in
    # a missing directory. Its CONTENTS are the cache.
    for e in "$root"/*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        [ -L "$e" ] && { KEPT=$((KEPT + 1)); log_line "KEPT   $e reason=symlink (never followed in a delete path)"; continue; }
        sz2="$(du_mb "$e")" || sz2=""
        reap_one "$e" "${sz2:-?}" shared-cache "-"
    done
    return 0
}

# ── discovery ───────────────────────────────────────────────────────────────────────────────────
# ⛔ NO PATHNAME EXPANSION IN THE LIST SPLIT. An unquoted `for g in $RC_GLOBS` ALSO performs globbing,
# so on a box where `/opt/gh-runner*` matches twelve installs the loop receives twelve WORDS and the
# metacharacter strip never sees a pattern — the exact defect the entry point's `rw_df_targets`
# records. `set -f` around the split gives one word per PATTERN.
INSTALL_DIRS=""
discover() {
    local g p _had_f=0
    case $- in *f*) _had_f=1 ;; esac
    set -f
    for g in $RC_GLOBS; do
        # The expansion is done EXPLICITLY (`compgen -G`) and never by the shell, so each element of
        # `$RC_GLOBS` is one PATTERN: with `set -f` above, a pattern that matches twelve installs
        # cannot arrive here as twelve words.
        # shellcheck disable=SC2086
        for p in $(compgen -G "$g" 2>/dev/null); do
            [ -d "$p" ] || continue
            is_install "$p" || continue
            case "$SEEN_INSTALLS" in *" $p "*) continue ;; esac
            SEEN_INSTALLS="$SEEN_INSTALLS$p "
            INSTALL_DIRS="${INSTALL_DIRS}${INSTALL_DIRS:+
}$p"
        done
    done
    [ "$_had_f" = 1 ] || set +f
    return 0
}

# glob_matched_dirs <list> — the directories a glob list matches, one per line (empty when none).
# ⛔ "MATCHED A DIRECTORY" IS NOT "MATCHED AN INSTALL", AND CONFLATING THEM WAS THE FAIL-OPEN (#4169
# review, BLOCKING). This helper used to be a yes/no directory test, so an operator-set seam that
# matched a tree holding no `bin/Runner.Listener` passed the refusal gate, fell through to the
# "measured empty population" line, and exited 0 with `census=ok installs=0` — an inert class whose
# record read `verdict_runner_cache=ok` over the sink it exists to free. Returning the MATCHES lets the
# refusal name them, so the operator sees a broken install / a seam one component short instead of
# having to re-derive why a matching glob produced no install.
glob_matched_dirs() {
    local g p _had_f=0
    case $- in *f*) _had_f=1 ;; esac
    set -f
    for g in $1; do
        # shellcheck disable=SC2086
        for p in $(compgen -G "$g" 2>/dev/null); do
            [ -d "$p" ] && printf '%s\n' "$p"
        done
    done
    [ "$_had_f" = 1 ] || set +f
    return 0
}

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null || true
: >"$LOG_FILE" 2>/dev/null || LOG_FILE=""

log_line "reap-runner-cache: mode=$( is_dry && printf dry-run || printf apply ) install_globs='$RC_GLOBS' shared_globs='$SHARED_GLOBS' min_cache_mb=${MIN_CACHE_MB} scratch_days=${SCRATCH_DAYS} log_days=${LOG_DAYS} job_window=${JOB_WINDOW_S}s max_mb=${MAX_MB} install_trigger_free_mb=${INSTALL_TRIGGER_FREE_MB} shared_trigger_free_mb=${SHARED_TRIGGER_FREE_MB}"

census_read || { CENSUS="unreadable"; log_line "reap-runner-cache: ⛔ CENSUS UNREADABLE — '$PS_BIN -axo pid=,command=' did not answer, so no install's liveness can be proved. NOTHING will be removed and this pass is FAIL-CLOSED (a cache deleted under a live job fails the job)."; }

discover
if [ -z "$INSTALL_DIRS" ]; then
    if [ "$RC_EXPLICIT" = 1 ]; then
        # ⛔ "MATCHED NO INSTALL" IS THE REFUSAL, NOT "MATCHED NO DIRECTORY" (#4169 review, BLOCKING).
        # The operator asserted a layout and the class found no install in it. Whether the globs matched
        # nothing at all or matched directories carrying no install marker, the class would scan
        # NOTHING — and a class that scans nothing is not a pass. Both refuse (exit 3) and both publish
        # `census=no-roots`, which `disk-reaper.sh` maps to `misconfigured` + `?`, never to a measured 0.
        _mdirs="$(glob_matched_dirs "$RC_GLOBS" | tr '\n' ' ')"
        if [ -n "${_mdirs// /}" ]; then
            _n="$(printf '%s' "$_mdirs" | wc -w | tr -d ' ')"
            printf '%s: FAIL-CLOSED — REAP_RC_GLOBS (%s) matched %s director%s [%s], but NONE carries the install marker bin/Runner.Listener; a class that scans NO INSTALL is not a pass. A directory is an install by its MARKER, never by the glob — fix the seam (or the install), do not widen it\n' \
                "$SCRIPT_NAME" "$RC_GLOBS" "$_n" "$( [ "$_n" = 1 ] && printf 'y' || printf 'ies')" "$_mdirs" >&2
        else
            printf '%s: FAIL-CLOSED — REAP_RC_GLOBS (%s) matched NO directory, and it was set EXPLICITLY; a class that scans nothing is NOT a pass\n' "$SCRIPT_NAME" "$RC_GLOBS" >&2
        fi
        log_line "reap-runner-cache: SUMMARY class=${CLASS_NAME} census=no-roots installs=0 candidates=0 reaped=0 skipped_live=0 kept=0 unmeasurable=0 refused=0 failed=0 freed_mb=0 cache_mb=0 capped=0 remaining=0"
        exit 3
    fi
    log_line "reap-runner-cache: no runner install matched $RC_GLOBS — a MEASURED empty population (this box runs no CI runner in those layouts)"
fi

for d in $INSTALL_DIRS; do
    sweep_install "$d"
done

# The shared roots last: they need every install's liveness, which the loop above just established.
# ⛔ THE MATCHED PATHS ARE COLLECTED UNDER `set -f` AND SWEPT AFTER IT IS RESTORED. `set -f` exists to
# split the GLOB LIST into patterns; leaving it on while the sweep runs disabled GLOBBING INSIDE
# `sweep_shared`, so its `for e in "$root"/*` iterated the literal string `$root/*`, matched nothing,
# and the shared per-box cache root — the durable half of this class — was NEVER emptied. `candidates=`
# stayed 0 and the class read as a measured "nothing to do" (#4169 review: no row covered this root;
# the row it does cover is why it was found). `discover`/`INSTALL_DIRS` is the same shape: collect
# under the flag, consume after it.
SEEN_SHARED=" "
SHARED_DIRS=""
SHARED_DERIVED=""
# add_shared_dir <path> [derived] — one place that decides "is this a candidate at all", so the two
# sources below cannot disagree about existence or about the de-duplication.
add_shared_dir() {
    local p="${1%/}" _derived="${2:-}"
    [ -n "$p" ] || p="/"
    case "$SEEN_SHARED" in *" $p "*) return 0 ;; esac
    [ -d "$p" ] || return 0
    SEEN_SHARED="$SEEN_SHARED$p "
    SHARED_DIRS="${SHARED_DIRS}${SHARED_DIRS:+
}$p"
    [ "$_derived" = derived ] && SHARED_DERIVED="${SHARED_DERIVED}${SHARED_DERIVED:+ }$p"
    return 0
}
if [ -n "$SHARED_GLOBS" ]; then
    _had_f=0
    case $- in *f*) _had_f=1 ;; esac
    set -f
    for g in $SHARED_GLOBS; do
        # shellcheck disable=SC2086
        for p in $(compgen -G "$g" 2>/dev/null); do
            add_shared_dir "$p"
        done
    done
    [ "$_had_f" = 1 ] || set +f
fi
# ⛔ THE DEFAULT HAS ONE SOURCE AND IT IS THE LAYOUT, NOT AN ENVIRONMENT VARIABLE (#4169 review,
# BLOCKING). The pool writes to `${RUNNER_CACHE_ROOT-$RUNNER_ROOT/_cache}` and puts every install at
# `$RUNNER_ROOT/gh-runner-*`, so a discovered install's PARENT IS `$RUNNER_ROOT` and its `_cache` is the
# pool's default — on any box, whatever a scheduled unit happens to render into its `Environment=`.
# ⛔ DERIVING FROM `${RUNNER_ROOT:-…}` IN THIS PROCESS' ENV WAS NOT ONE SOURCE: the two units render only
# `TRIGGER_FREE_MB`/`PASS_CAP_MB`, so on `RUNNER_ROOT=/opt` (the layout `docs/ops/fleet-capacity.md`
# tells operators to use) this process saw no `RUNNER_ROOT`, derived `/tmp/actions-runner/_cache`, and
# the pool's real `/opt/_cache` sat one component away from every glob with nothing reaping it — the
# unbounded sink #4168 exists to remove, reported healthy. The derivation below cannot disagree with the
# pool, because it is read off the installs the pool itself created.
for d in $INSTALL_DIRS; do
    _p="${d%/*}"; [ -n "$_p" ] || _p="/"
    add_shared_dir "$_p/_cache" derived
done
[ -n "$SHARED_DERIVED" ] && log_line "reap-runner-cache: shared_root=derived ($SHARED_DERIVED) — a discovered install's parent is \$RUNNER_ROOT and the pool's cache root is \$RUNNER_ROOT/_cache, so this candidate cannot disagree with the pool about the default"
for p in $SHARED_DIRS; do
    sweep_shared "$p"
done
# ⛔ A SHARED ROOT THAT MATCHED NOTHING IS PRINTED, NOT ASSUMED AWAY (#4169 review, P1). The class's
# durable half moves every pooled install's writes into ONE root the pool derives
# (`$RUNNER_ROOT/_cache`), so a box whose pool root lands outside this seam's globs has its bytes one
# directory up from every candidate: the class reads `candidates=0 verdict=ok` and the sink grows
# unread. The default now derives from the same `RUNNER_ROOT`, and this line makes the remaining case —
# an operator override on ONE of the two tools — findable in the pass record instead of silent.
if [ -n "$SHARED_GLOBS" ] && [ -z "$SHARED_DIRS" ]; then
    log_line "reap-runner-cache: shared_root=absent (shared_globs='$SHARED_GLOBS' matched no directory, and no discovered install's parent holds a _cache — a pool started with a different RUNNER_CACHE_ROOT exports its XDG_CACHE_HOME elsewhere, and NOTHING in this pass covers it: name that path in REAP_RC_SHARED_GLOBS / DISK_REAPER_RUNNER_CACHE_SHARED_GLOBS)"
fi

# ── the report ─────────────────────────────────────────────────────────────────────────────────
# ⛔ EVERY READING IS PRINTED (agent-infra#2344). "the class did nothing" and "the class could not see
# anything" are different states, and only the numbers tell them apart.
[ -n "$READINGS" ] && log_line "$READINGS"
[ -n "$CAND_NAMES" ] && log_line "$CAND_NAMES"

# ⛔ A REFUSED SCOPE IS ITS OWN CENSUS STATE, AND IT IS DECIDED HERE — AFTER every sweep, so no later
# root's liveness question is answered from a census state that is about a SCOPE problem. `refused` is
# not `unmeasurable` (an abstention is a gate that could not ANSWER; a refusal is an input that was
# WRONG) and it is emphatically not `ok`: the documented refusal had no implementation at all, which
# left the class inert while its record read `verdict_runner_cache=ok` (#4169 review, BLOCKING).
if [ "$CENSUS" = ok ] && [ "$REFUSED" -gt 0 ]; then CENSUS="refused"; fi
rc=0
[ "$FAILED" -gt 0 ] && rc=4
if [ "$CENSUS" != ok ] || [ "$UNMEASURABLE" -gt 0 ] || [ "$REFUSED" -gt 0 ]; then
    # ⛔ AN UNMEASURABLE CANDIDATE IS NOT A SUCCESS. It was KEPT because the gate could not answer, and
    # a pass that cannot answer is fail-closed (rc 3) — the same rule every other owner applies. A
    # `census=unreadable` with nothing matched at all is still 3, and a `census=refused` pass removed
    # nothing by construction (the refusal precedes every delete in `sweep_shared`).
    [ "$rc" = 0 ] && rc=3
fi
if [ "$rc" = 0 ] && is_dry && [ "$CANDIDATES" -gt 0 ]; then rc=5; fi

log_line "reap-runner-cache: SUMMARY class=${CLASS_NAME} census=$CENSUS installs=${INSTALLS} cache_mb=${CACHE_TOTAL_MB} cache_mb_unmeasured=${CACHE_NOT_MEASURED} candidates=${CANDIDATES} reaped=${REAPED} skipped_live=${SKIPPED_LIVE} kept=${KEPT} unmeasurable=${UNMEASURABLE} refused=${REFUSED} gone=${GONE} failed=${FAILED} freed_mb=${FREED_MB} capped=${CAPPED} remaining=${REMAINING} scratch_days=${SCRATCH_DAYS} log_days=${LOG_DAYS} job_window=${JOB_WINDOW_S}s max_mb=${MAX_MB}"
# ⛔ THE LOG LINE CARRIES THE POPULATION IT SCANNED (`install_globs=` / `shared_globs=`). The stdout
# header already prints them, but the LOG is the durable artifact an operator reads after the fact, and
# it is the only way a test can prove WHICH population a pass was pinned to — which is the whole point
# of `disk-reaper.test.sh` pinning this class to its fixtures (agent-infra#4169): an unpinned suite ran
# the destructive pass against the box's real `/opt/gh-runner*` installs while claiming to be hermetic.
[ -n "$LOG_FILE" ] && log "SUMMARY census=$CENSUS installs=$INSTALLS cache_mb=$CACHE_TOTAL_MB cache_mb_unmeasured=$CACHE_NOT_MEASURED candidates=$CANDIDATES reaped=$REAPED skipped_live=$SKIPPED_LIVE refused=$REFUSED freed_mb=$FREED_MB install_globs=$RC_GLOBS shared_globs=$SHARED_GLOBS"
command -v tb_bound_cleanup >/dev/null 2>&1 && tb_bound_cleanup
exit "$rc"
