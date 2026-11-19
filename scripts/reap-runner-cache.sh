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
#   <install>/_diag/*.log        files older than REAP_RC_LOG_DAYS (default 7).
#
# plus the SHARED per-box cache root (`XDG_CACHE_HOME` for pool-started runners, see
# `scripts/ci_runner_pool.sh`), which is what stops the multiplication: N installs with a
# `XDG_CACHE_HOME` each hold N copies of the same content, one per-box root holds one.
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
#   * `bin/Runner.Listener` present AND content under `_work` written within REAP_RC_JOB_WINDOW_S
#     (default 900 s) → a job is running or has just started. Skip.
#   * a listener with no worker and nothing fresh under `_work` → the install is BETWEEN jobs. Its
#     cache is not in use; the next job re-downloads what it needs. Reap.
#
# ⛔ AN UNREADABLE PROCESS CENSUS IS NOT "NOBODY IS RUNNING". If `ps` cannot answer, every install's
# liveness is UNKNOWN, so NOTHING is removed and the pass exits 3 (`census=unreadable`) — the same
# fail-closed answer `reap-lane-venvs.sh` gives when its probe is missing. An absent census read as
# "idle" is the one shape that turns this class into a job-killer.
# ⛔ AND THE PROBE IS RE-ASKED IMMEDIATELY BEFORE EVERY REMOVAL (`toctou`), because classification can
# be minutes old on a box whose `du` is slow: a job that started in that window must not lose its
# cache. A re-probe that cannot answer KEEPS the candidate.
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
#
# ── EXIT CODES ───────────────────────────────────────────────────────────────────────────────────
#   0  the sweep ran; nothing is wrong (this INCLUDES a sweep that found nothing to do)
#   2  usage
#   3  FAIL-CLOSED — the process census could not be read, a glob list an operator SET matched no
#      install, or a matched root was refused because it is not an install. Nothing was removed.
#   4  a removal FAILED (the path is still there after `rm`)
#   5  DRY RUN with work present (the dry run's whole job is to say so)
#
# Env seams (each validated at startup; a garbage value is a refusal, never a default):
#   REAP_RC_GLOBS          space-separated globs naming the runner INSTALL dirs
#                          (default: /opt/gh-runner* $HOME/actions-runner* $HOME/actions-runner/*
#                          /tmp/actions-runner* /tmp/actions-runner/*). ⛔ SET-BUT-EMPTY IS A REFUSAL:
#                          `${X:-default}` would substitute the WIDEST list for an operator who emptied
#                          the seam to turn the class off, which is the delete direction.
#   REAP_RC_SHARED_GLOBS   space-separated globs naming the ONE per-box cache root
#                          (default: /tmp/actions-runner/_cache $HOME/actions-runner/_cache)
#   REAP_RC_EXPLICIT       1 = REAP_RC_GLOBS was SET by the caller, so matching nothing is a REFUSAL
#                          (an asserted layout that is not there) and not a measured-empty box
#   REAP_RC_MIN_CACHE_MB   the SIZE bound on a `.cache`: a cache smaller than this is KEPT, because
#                          reaping a few MB of a content-addressed cache buys nothing and costs every
#                          later job a re-download (default 256)
#   REAP_RC_SCRATCH_DAYS   age bound for `_work/_temp` entries  (default 7)
#   REAP_RC_LOG_DAYS       age bound for `_diag/*.log` files    (default 7)
#   REAP_RC_JOB_WINDOW_S   "a job is running" freshness window  (default 900)
#   REAP_RC_MAX_MB         per-pass cap, 0 = uncapped           (default 0; the entry point passes one)
#   REAP_RC_PS_BIN         the process census binary            (default /bin/ps)
#   REAP_RC_DU_BIN         (default du)  REAP_RC_STAT_BIN (default stat)
#   REAP_RC_STATE_DIR      where the bounded log lives          (default $DISK_REAPER_STATE_DIR)
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
    SHARED_GLOBS="/tmp/actions-runner/_cache $HOME/actions-runner/_cache"
fi
MIN_CACHE_MB="${REAP_RC_MIN_CACHE_MB:-256}"
SCRATCH_DAYS="${REAP_RC_SCRATCH_DAYS:-7}"
LOG_DAYS="${REAP_RC_LOG_DAYS:-7}"
JOB_WINDOW_S="${REAP_RC_JOB_WINDOW_S:-900}"
MAX_MB="${REAP_RC_MAX_MB:-0}"
PS_BIN="${REAP_RC_PS_BIN:-/bin/ps}"
DU_BIN="${REAP_RC_DU_BIN:-du}"
STAT_BIN="${REAP_RC_STAT_BIN:-stat}"
DRY_RUN="${REAP_RC_DRY_RUN:-1}"
STATE_DIR="${REAP_RC_STATE_DIR:-${DISK_REAPER_STATE_DIR:-${HOME:-}/.pi/agent/state}}"
PS_TIMEOUT="${REAP_RC_PS_TIMEOUT:-60}"
DU_TIMEOUT="${REAP_RC_DU_TIMEOUT:-120}"
FIND_TIMEOUT="${REAP_RC_FIND_TIMEOUT:-120}"

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
CENSUS="ok"
CAND_NAMES=""
# Per-install readings, printed on their own lines so an operator can see WHICH install holds the
# bytes (agent-infra#2344: a gate that acts without printing the number it read is a wish).
READINGS=""

is_dry() { [ "$DRY_RUN" = "1" ]; }

rm_path() { rm -rf -- "$1"; }

du_mb() { # <path> — blocks occupied in MiB, or empty when the probe could not answer
    local kb
    kb="$(tb_timeout "$DU_TIMEOUT" "$DU_BIN" -sk "$1" 2>/dev/null)" || return 1
    kb="${kb%%[[:space:]]*}"
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

# ── the process census: ONE read, used for every install ─────────────────────────────────────────
# A per-install `ps` would be N walks of the same table on a 12-runner box; and a census that cannot
# answer is not "idle" (see the header), so it is captured once and its failure is sticky.
CENSUS_TEXT=""
census_read() {
    # ⛔ `-axo` (not `-eo`): the runner's argv is what identifies the install, and a BSD `ps` without
    # `-x` omits every process not owned by this session — the listeners on a system unit included.
    CENSUS_TEXT="$(tb_timeout "$PS_TIMEOUT" "$PS_BIN" -axo pid=,command= 2>/dev/null)"; local rc=$?
    if [ "$rc" != 0 ] || [ -z "$CENSUS_TEXT" ]; then CENSUS="unreadable"; return 1; fi
    return 0
}

# proc_has <token> — 0 when some process's command line mentions <token>.
# The table is one process per line, so a plain fixed-string search per token is exact enough: an
# install path is unique on the box, and a false POSITIVE here only KEEPS a cache (the safe direction).
# ⛔ NOT `printf … | grep -q` (#841/#861). This file runs under `pipefail`, so a builtin writer that
# takes SIGPIPE when `grep -q` exits early makes the PIPELINE non-zero — and the direction that matters
# here is the FALSE NEGATIVE: "no Runner.Worker found" is what authorises deleting a live job's cache.
# A here-string is a temp file, so there is no second process to signal.
proc_has() { grep -F -q -- "$1" <<<"$CENSUS_TEXT"; }

# newest_mtime_under <dir> — the newest mtime of any entry directly under <dir> (0 = "no answer").
# Deliberately ONE level and bounded: this is a freshness witness, not an inventory, and walking a
# 4 GB checkout to answer it is the cost this class exists to avoid.
newest_mtime_under() {
    local d="$1" f m best=0
    [ -d "$d" ] || { printf '0'; return 0; }
    for f in "$d"/*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        m="$(mtime_of "$f")" || continue
        [ "$m" -gt "$best" ] && best="$m"
    done
    printf '%s' "$best"
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
    if proc_has "$d/bin/Runner.Listener" || proc_has "$d/run.sh"; then
        newest="$(newest_mtime_under "$d/_work")"
        if [ "${newest:-0}" -gt 0 ] && [ "$(( $(now) - newest ))" -le "$JOB_WINDOW_S" ]; then
            LIVE_REASON="listener+busy-work"; return 0
        fi
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
    [ "$(( FREED_MB + pending ))" -gt "$MAX_MB" ]
}

# reap_one <path> <size-mb|?-> <kind> <install> — the ONE destructive call, gated three ways.
#   1. the cap (a pass may not become the load problem it exists to fix)
#   2. a RE-PROBE of the install's liveness, immediately before removal
#   3. `rm -rf` is not evidence: the path must be GONE afterwards or the removal FAILED
reap_one() {
    local path="$1" size="$2" kind="$3" install="$4" _live
    if cap_reached "${size%%[!0-9]*}"; then
        CAPPED=1; REMAINING=$((REMAINING + 1))
        log_line "KEPT   $path reason=pass-cap (per-pass cap ${MAX_MB}MB reached; the next tick continues)"
        return 0
    fi
    CANDIDATES=$((CANDIDATES + 1))
    if is_dry; then
        CAND_NAMES="${CAND_NAMES}${CAND_NAMES:+
}REAP ${size}MB ${path} kind=${kind}"
        case "$size" in ''|*[!0-9]*) ;; *) FREED_MB=$((FREED_MB + size)) ;; esac
        return 0
    fi
    # ⛔ RE-PROBE IMMEDIATELY BEFORE THE DESTRUCTIVE CALL. The classification above can be minutes old
    # on a box whose `du` is slow, and a job that started in that window must not lose its cache.
    if [ -n "$install" ]; then
        install_live "$install"; _live=$?
        case "$_live" in
            0) SKIPPED_LIVE=$((SKIPPED_LIVE + 1))
               log_line "SKIPPED-LIVE $path reason=toctou:${LIVE_REASON} (a job started during the pass; re-probed immediately before removal, NOT removed)"
               return 0 ;;
            2) UNMEASURABLE=$((UNMEASURABLE + 1))
               log_line "KEPT   $path reason=toctou-census-unreadable (the re-probe could not answer; NOT removed)"
               return 0 ;;
        esac
    fi
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        GONE=$((GONE + 1))
        log_line "GONE   $path reason=vanished-at-removal (nothing removed by this class, and not an abstention)"
        return 0
    fi
    if rm_path "$path" 2>/dev/null && [ ! -e "$path" ] && [ ! -L "$path" ]; then
        REAPED=$((REAPED + 1))
        case "$size" in ''|*[!0-9]*) ;; *) FREED_MB=$((FREED_MB + size)) ;; esac
        log_line "REAPED $path how=rm kind=${kind} mb=${size}"
        log "reaped $path kind=$kind mb=$size"
    else
        FAILED=$((FAILED + 1))
        log_line "ERR    $path reason=remove-failed"
        log "REMOVAL FAILED $path"
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
    local d="$1" cache="$1/.cache" sz reading cutoff_s cutoff_l f fm
    INSTALLS=$((INSTALLS + 1))
    # ── the reading FIRST, so the line exists even for an install that is skipped ────────────────
    if [ -e "$cache" ] || [ -L "$cache" ]; then sz="$(du_mb "$cache")" || sz=""; else sz="0"; fi
    install_live "$d"; local live=$?
    # ⛔ `ANY_LIVE` IS ACCUMULATED HERE, in the ONE place every install is read, and not by a second
    # pass over the population: two reads of the same answer is how the shared root's gate and the
    # per-install verdict drift apart.
    [ "$live" = 0 ] && ANY_LIVE=1
    reading="INSTALL ${d} cache_mb=${sz:-?} live=$( [ "$live" = 0 ] && printf yes || { [ "$live" = 2 ] && printf unknown || printf no; } ) reason=${LIVE_REASON}"
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
        # ⛔ A SYMLINKED CACHE IS NEVER FOLLOWED. `rm -rf` on a symlink removes the LINK (harmless),
        # but `du` and every later reading would then describe a tree this class does not own — and a
        # dangling link is a box whose big disk was unmounted, which is not a state to guess at.
        if [ -L "$cache" ]; then
            UNMEASURABLE=$((UNMEASURABLE + 1))
            log_line "KEPT   $cache reason=symlinked-cache (this class never follows one in a delete path)"
        elif [ -n "$sz" ] && [ "$sz" -lt "$MIN_CACHE_MB" ]; then
            # ⛔ THE SIZE BOUND, AND IT IS THE "NO CHURN" HALF OF THE POLICY. A cache is
            # content-addressed: reaping 40 GB costs every later job a re-download of what it needs,
            # and reaping 4 MB costs exactly the same trade for nothing. Below the bound the entry is
            # KEPT and NAMED, so "the cache is still there" has an answer other than "the reaper broke".
            KEPT=$((KEPT + 1))
            log_line "KEPT   $cache reason=below-min-cache (${sz}MB < ${MIN_CACHE_MB}MB — reaping it would cost the next job a re-download for no meaningful space)"
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
    local root="$1" sz
    [ -d "$root" ] || return 0
    # ⛔ NO SECOND CENSUS HERE. `ANY_LIVE` was established by `sweep_install`, the one place every
    # install's liveness is read; re-probing the population here would be a second answer to the same
    # question, and the two can disagree while a job starts between them.
    if [ "$CENSUS" != ok ]; then
        UNMEASURABLE=$((UNMEASURABLE + 1))
        log_line "KEPT   $root reason=census-unreadable (the SHARED root is used by every install; liveness is UNKNOWN)"
        return 0
    fi
    if [ "$ANY_LIVE" = 1 ]; then
        sz="$(du_mb "$root")" || sz=""
        SKIPPED_LIVE=$((SKIPPED_LIVE + 1))
        log_line "SKIPPED-LIVE $root reason=skipped-live:an-install-has-a-job-running cache_mb=${sz:-?} (the SHARED cache is used by every install on this box)"
        READINGS="${READINGS}${READINGS:+
}INSTALL ${root} cache_mb=${sz:-?} live=yes reason=shared-with-a-live-install"
        return 0
    fi
    if [ -L "$root" ]; then
        UNMEASURABLE=$((UNMEASURABLE + 1))
        log_line "KEPT   $root reason=symlinked-cache (never followed in a delete path)"
        return 0
    fi
    sz="$(du_mb "$root")" || sz=""
    READINGS="${READINGS}${READINGS:+
}INSTALL ${root} cache_mb=${sz:-?} live=no reason=shared-root-no-job-running"
    # ⛔ THE SHARED ROOT IS RECLAIMED IN PLACE, NOT DELETED. It is the `XDG_CACHE_HOME` a running
    # listener was started with: removing the DIRECTORY itself is fine for an idle box, but keeping it
    # (and emptying it) means a listener that starts between this pass and its re-probe cannot land in
    # a missing directory. Its CONTENTS are the cache.
    local e sz2
    for e in "$root"/*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        [ -L "$e" ] && { KEPT=$((KEPT + 1)); log_line "KEPT   $e reason=symlink (never followed in a delete path)"; continue; }
        sz2="$(du_mb "$e")" || sz2=""
        reap_one "$e" "${sz2:-?}" shared-cache ""
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

# glob_matches_any <list> — 0 when at least one pattern matches at least one existing directory.
# Used to tell "this box has no runners" (a measured empty population, exit 0) from "the operator
# asserted a layout that is not there" (a refusal), exactly as the runner-work owner does.
glob_matches_any() {
    local g p _had_f=0
    case $- in *f*) _had_f=1 ;; esac
    set -f
    for g in $1; do
        # shellcheck disable=SC2086
        for p in $(compgen -G "$g" 2>/dev/null); do
            [ -d "$p" ] && { [ "$_had_f" = 1 ] || set +f; return 0; }
        done
    done
    [ "$_had_f" = 1 ] || set +f
    return 1
}

mkdir -p "$STATE_DIR" 2>/dev/null || true
LOG_FILE="$STATE_DIR/runner-cache-reap.log"
: >"$LOG_FILE" 2>/dev/null || LOG_FILE=""

log_line "reap-runner-cache: mode=$( is_dry && printf dry-run || printf apply ) install_globs='$RC_GLOBS' shared_globs='$SHARED_GLOBS' min_cache_mb=${MIN_CACHE_MB} scratch_days=${SCRATCH_DAYS} log_days=${LOG_DAYS} job_window=${JOB_WINDOW_S}s max_mb=${MAX_MB}"

census_read || log_line "reap-runner-cache: ⛔ CENSUS UNREADABLE — '$PS_BIN -axo pid=,command=' did not answer, so no install's liveness can be proved. NOTHING will be removed and this pass is FAIL-CLOSED (a cache deleted under a live job fails the job)."

discover
if [ -z "$INSTALL_DIRS" ]; then
    if [ "$RC_EXPLICIT" = 1 ] && ! glob_matches_any "$RC_GLOBS"; then
        printf '%s: FAIL-CLOSED — REAP_RC_GLOBS ('%s') matched NO directory, and it was set EXPLICITLY; a class that scans nothing is NOT a pass\n' "$SCRIPT_NAME" "$RC_GLOBS" >&2
        log_line "reap-runner-cache: SUMMARY class=${CLASS_NAME} census=no-roots installs=0 candidates=0 reaped=0 skipped_live=0 kept=0 unmeasurable=0 failed=0 freed_mb=0 cache_mb=0 capped=0 remaining=0"
        exit 3
    fi
    log_line "reap-runner-cache: no runner install matched $RC_GLOBS — a MEASURED empty population (this box runs no CI runner in those layouts)"
fi

for d in $INSTALL_DIRS; do
    sweep_install "$d"
done

# The shared roots last: they need every install's liveness, which the loop above just established.
SEEN_SHARED=" "
if [ -n "$SHARED_GLOBS" ]; then
    _had_f=0
    case $- in *f*) _had_f=1 ;; esac
    set -f
    for g in $SHARED_GLOBS; do
        # shellcheck disable=SC2086
        for p in $(compgen -G "$g" 2>/dev/null); do
            [ -d "$p" ] || continue
            case "$SEEN_SHARED" in *" $p "*) continue ;; esac
            SEEN_SHARED="$SEEN_SHARED$p "
            sweep_shared "$p"
        done
    done
    [ "$_had_f" = 1 ] || set +f
fi

# ── the report ─────────────────────────────────────────────────────────────────────────────────
# ⛔ EVERY READING IS PRINTED (agent-infra#2344). "the class did nothing" and "the class could not see
# anything" are different states, and only the numbers tell them apart.
[ -n "$READINGS" ] && log_line "$READINGS"
[ -n "$CAND_NAMES" ] && log_line "$CAND_NAMES"

rc=0
[ "$FAILED" -gt 0 ] && rc=4
if [ "$CENSUS" != ok ] || [ "$UNMEASURABLE" -gt 0 ]; then
    # ⛔ AN UNMEASURABLE CANDIDATE IS NOT A SUCCESS. It was KEPT because the gate could not answer, and
    # a pass that cannot answer is fail-closed (rc 3) — the same rule every other owner applies. A
    # `census=unreadable` with nothing matched at all is still 3.
    [ "$rc" = 0 ] && rc=3
fi
if [ "$rc" = 0 ] && is_dry && [ "$CANDIDATES" -gt 0 ]; then rc=5; fi

log_line "reap-runner-cache: SUMMARY class=${CLASS_NAME} census=$CENSUS installs=${INSTALLS} cache_mb=${CACHE_TOTAL_MB} candidates=${CANDIDATES} reaped=${REAPED} skipped_live=${SKIPPED_LIVE} kept=${KEPT} unmeasurable=${UNMEASURABLE} gone=${GONE} failed=${FAILED} freed_mb=${FREED_MB} capped=${CAPPED} remaining=${REMAINING} scratch_days=${SCRATCH_DAYS} log_days=${LOG_DAYS} job_window=${JOB_WINDOW_S}s max_mb=${MAX_MB}"
[ -n "$LOG_FILE" ] && log "SUMMARY census=$CENSUS installs=$INSTALLS cache_mb=$CACHE_TOTAL_MB candidates=$CANDIDATES reaped=$REAPED skipped_live=$SKIPPED_LIVE freed_mb=$FREED_MB"
command -v tb_bound_cleanup >/dev/null 2>&1 && tb_bound_cleanup
exit "$rc"
