#!/usr/bin/env bash
# reap-runner-work.sh — reclaim the CI runners' `_work` checkouts (class=runner-work).
#
# THE MEASURED DEFECT (2026-10-28, cell c1 `vm-efa6cc8fdb974e61b5c054acf41d8846`, 8 cores, 12
# GitHub Actions runners): `/` reached **98% used, 3.5 G free**, and `/opt/gh-runner-x64-{2,4,5,6,7,8}/_work`
# held **19 G** of checkout left behind by jobs that had finished or been killed. A runner cleans its
# own `_work/<entry>` only on a NORMAL job end, so a cancelled, crashed or OOM-killed job's tree stays
# for ever. Sizes per runner measured 2.6–4.7 G. The hand reap of exactly this sink took the box from
# 98% → 90% without disturbing a single running job — that hand reap is this policy.
#
# ⛔ NEITHER `uv`, `venv`, `worktree` NOR `duplicate-install` MATCHES IT. Runner `_work` is not a
# package cache, not a lane env, not a checkout of a repo we track, and not a duplicate install — so
# 19 G of one cell's disk sat in NONE of the traffic classes while the hourly timer reported healthy.
# A sink with no class is a sink nothing measures. This file is that class's POLICY OWNER: it holds the
# one delete rule and `disk-reaper.sh` runs it and accounts for it, exactly as the other four classes
# work (that entry point contains no `rm` on a filesystem path, and its suite pins that).
#
# ── THE SAFETY GATE, AND IT IS THE WHOLE POLICY ────────────────────────────────────────────────
# A `_work` entry is reapable ONLY when its **newest content is older than the floor**
# (`--min-age`, default 3600 s). The IN-ENTRY witness is the checkout's OWN writes — the outputs, build
# artefacts, `.venv`/`node_modules` and any file a step creates under the checkout — so "nothing under
# this entry has been written for N seconds" is a positive fact about a dead entry. ⛔ `_work/_temp`
# (the step scripts and the command logs) is a SIBLING of `_work/<repo>`, not a child of it — the vendor
# creates `_temp`/`_tool`/`_actions`/`_work` at the runner root (`actions/runner`
# `src/Runner.Common/Constants.cs` `WellKnownDirectory`, and the checkout is
# `Path.Combine(_workDirectory, trackingConfig.PipelineDirectory)` in `JobExecution`), so a write there
# does NOT refresh the checkout's floor and it is NOT an in-entry witness. The comparison set is everything under the
# entry INCLUDING the entry's own top directory (a `find -newer` walk naturally covers it), which is
# the CONSERVATIVE direction: a stray `touch`/`cp` over a dead entry's top dir restores its floor
# rather than leaving it removable. What the gate deliberately does NOT use is the top directory's
# mtime ALONE — a killed job leaves that directory stamped at the moment of the kill while its
# CONTENTS can be hours older, so "the dir is old" is not on its own the proof.
#
# ⛔ DO NOT "IMPROVE" THIS INTO A `pgrep Runner.Listener` BUSY-CHECK. A busy-check is NOT AVAILABLE
# LOCALLY in a form that can be trusted: the listener is a child of the runner service, the job worker's
# state lives inside the runner process, and `_work/<entry>` carries no owner pid, no lock file and no
# name-to-process mapping. A `pgrep`-shaped guess ("a listener exists somewhere on this box") is both
# over-broad — it would keep every dead entry while ANY runner is idle, which on a 12-runner box is
# always — and under-broad (a `--ephemeral` runner started by hand is neither a service nor a child of
# one). The result would be a class that reaps nothing and reports healthy: the inert-enforcer shape
# this whole reaper exists to remove. mtime is the proof because the runner's own I/O is the evidence;
# the FLOOR is the dial, and it is the operator's (`REAP_RW_MIN_AGE` / `--min-age`).
# Measured: a 120-minute hand reap on a box with 12 live runners lost no job. The default here is the
# briefer 60 minutes — and because the floor is what prices this trade, a box whose jobs write only
# OUTSIDE the checkout should use the validated 7200 s (`DISK_REAPER_RUNNER_MIN_AGE=7200`), not the
# shipped 3600 s. ⚠️ RESIDUAL, stated so it is not discovered: a job that writes NOTHING **INSIDE ITS
# CHECKOUT** for longer than the floor is indistinguishable from a dead entry by this test. That is a
# whole-job exposure for any job whose artefacts land in `$TMPDIR`, `~/.cache` or `_work/_temp` (every
# step after checkout), not merely "one long quiet step". If a box runs such jobs, raise the floor —
# that is the intended response, not a busy-check.
#
# ⛔ DELIBERATELY RETAINED: `_work/_tool` AND `_work/_actions`. They are the runner's CROSS-JOB caches —
# every downloaded action (`_actions`) and every toolchain it fetched (`_tool`) — so removing them does
# not free dead checkout, it forces a re-download on the NEXT job and makes every subsequent CI run
# slower. That is a different trade from the one this class is for, and it is not this class's to make.
# They are excluded from the candidate set BEFORE anything is measured, and the exclusion is counted
# (`retained=<n>`) so "why is this directory still here" has an answer on the class line. A test proves
# they survive even when they are the oldest thing in the tree.
#
# Usage:
#   reap-runner-work.sh [--dry-run|--apply] [--glob PATTERN]... [--min-age S]
#                       [--print-config] [--help]
#
#   (no mode flag)  dry-run: report what WOULD be removed, with byte counts; remove NOTHING
#   --apply         armed pass
#   --glob PATTERN  a shell glob naming runner `_work` roots (repeatable; replaces the default list)
#   --min-age S     seconds a `_work` entry must have gone unwritten before it is a candidate
#                   (default 3600)
#   --print-config  `globs=…` / `min_age=…` / `retained=…` / `mode=…` for the caller
#   --help          this text (exit 0)
#
# Env seams:
#   REAP_RW_GLOBS       space-separated globs of `_work` roots (same as --glob; `disk-reaper.sh` passes
#                       its own DISK_REAPER_RUNNER_GLOBS down here). Default:
#                           /opt/gh-runner*/_work $HOME/actions-runner*/_work /tmp/actions-runner*/_work
#                       ⚠️ Globs are expanded ONE level, as written. A layout that nests the install one
#                       directory deeper (`/tmp/actions-runner/<name>/_work`) needs `*/*` in the pattern.
#                       A SET-but-EMPTY value is a REFUSAL (an empty list would scan nothing for ever
#                       while the class reported a measured zero).
#   REAP_RW_MIN_AGE     the mtime floor in seconds (default 3600)
#   REAP_RW_DRY_RUN     0 supplies the default mode only (an explicit flag always wins)
#   REAP_RW_STATE_DIR   lock + log dir (default $HOME/.pi/agent/state)
#   REAP_RW_LOG         pass log (default $REAP_RW_STATE_DIR/reap-runner-work.log)
#   REAP_RW_LOCK_STALE_SECONDS  stale lock reclaim bound (default 1800)
#   REAP_RW_BUDGET_SECONDS      wall-clock budget for the `--apply` sweep (default 300). ⛔ IT DOES NOT
#                       BOUND `--dry-run`, and that asymmetry is deliberate: in `--apply` a spent budget has
#                       a defined, safe meaning — every entry still unprocessed is KEPT and PRESERVED
#                       (`reason=budget`) — whereas truncating a dry pass would emit a SUMMARY
#                       `candidates=N` for a population LARGER than N, i.e. a partial count presented as a
#                       total, which is the false-measurement shape this class's own `census=` refusal
#                       exists to prevent. A dry pass therefore measures the WHOLE population it matched.
#                       It is still bounded, one call at a time, by the watchdogs below; its aggregate cost
#                       is candidates x those bounds, not this knob. A malformed value IS refused in both
#                       modes (`num` at startup), so the seam is validated everywhere and only its
#                       bounding effect is apply-only.
#   REAP_RW_DU_TIMEOUT / REAP_RW_FIND_TIMEOUT  per-call watchdogs, secs (default 120 each)
#   REAP_RW_EXPLICIT    1 when the caller's glob list came from an EXPLICIT operator seam rather than
#                       the defaults. It changes ONE outcome: a sweep that matches no root at all is then
#                       a REFUSAL (the operator asserted a layout that is not there) instead of a
#                       measured empty population. `disk-reaper.sh` sets it, and so does `--glob` — an
#                       operator who names the layout with this script's own flag is making exactly the
#                       same assertion, so the flag must not be the one spelling that fails open.
#   BOUNDED_LIB         the bounded-execution helper (default: lib/bounded.sh beside this script, then
#                       $HOME/.pi/agent/scripts/lib/). A SET-but-missing value, or none at all, is a
#                       REFUSAL at startup — the rule `disk-reaper.sh` already applies (#2046): without
#                       it every `find` here runs unbounded or fails, and a reaper that hangs the cell is
#                       worse than the disk it was reclaiming.
#   TB_TIMEOUT_BIN / TB_TIMEOUT_FORCE_INTERNAL  passed through to the library unchanged.
#
# Exit codes (the family's vocabulary, so `disk-reaper.sh` maps it through its own `delegate_rc`):
#   0  ran; every action succeeded (including "no runner `_work` root exists here" — a measured empty
#      population, `roots=0`, when the globs are the DEFAULTS; see REAP_RW_EXPLICIT)
#   2  usage
#   3  FAIL-CLOSED — the bounded library is missing, the lock is held, the floor reference cannot be
#      written, there is no writable scratch, or an EXPLICIT glob list matched no root at all.
#   4  a removal FAILED (named on its own line; the entry is still there)
#
set -uo pipefail

SCRIPT_NAME="reap-runner-work.sh"
SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)"
fi
STATE_DIR="${REAP_RW_STATE_DIR:-${HOME:-}/.pi/agent/state}"
LOG="${REAP_RW_LOG:-$STATE_DIR/reap-runner-work.log}"
LOCK_DIR="$STATE_DIR/reap-runner-work.lock"
LOCK_STALE_SECONDS="${REAP_RW_LOCK_STALE_SECONDS:-1800}"
# `-` (not `:-`): an EMPTY value is not an assertion, and that distinction is a whole verdict below.
EXPLICIT="${REAP_RW_EXPLICIT-0}"
# `/opt` first because that is where the measured cell's 19 G was; `$HOME` and `/tmp` because that is
# where the farm puts runners elsewhere (cell 3 keeps installs under `/tmp/actions-runner`, cell 4's
# are in `/opt`).
GLOBS="${REAP_RW_GLOBS-/opt/gh-runner*/_work $HOME/actions-runner*/_work /tmp/actions-runner*/_work}"
MIN_AGE="${REAP_RW_MIN_AGE:-3600}"
DU_TIMEOUT="${REAP_RW_DU_TIMEOUT:-120}"
FIND_TIMEOUT="${REAP_RW_FIND_TIMEOUT:-120}"
DRY_RUN="${REAP_RW_DRY_RUN:-1}"
BUDGET="${REAP_RW_BUDGET_SECONDS:-300}"
PRINT_CONFIG=0
GLOB_ARGS_GIVEN=0

# The cross-job caches this class deliberately does NOT touch (see the header). One name per line, so a
# future runner layout is one entry and no loop change.
RETAINED_NAMES="_tool
_actions"

log_line() { printf '%s\n' "$*"; }
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true; }
die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 2; }
num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
now() { date +%s; }

usage() {
    if [ -r "${BASH_SOURCE[0]:-}" ]; then
        awk 'NR==1{next} /^set -uo pipefail$/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
    else
        printf 'usage: %s [--dry-run|--apply] [--glob PATTERN]... [--min-age S] [--print-config]\n' "$SCRIPT_NAME"
    fi
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --apply)   DRY_RUN=0; shift ;;
        --glob)    [ $# -ge 2 ] || die "--glob needs a pattern"
                   [ -n "$2" ] || die "--glob was given an empty pattern"
                   # ⛔ `--glob` IS an explicit assertion, so it MUST set the flag the census reads.
                   # Without this the seam's two spellings disagreed: `REAP_RW_GLOBS=<no-match>` was a
                   # refusal (rc 3, `census=no-roots`) while `--glob <no-match>` was a measured empty
                   # population (rc 0, `census=ok`) — a false PASS, through the spelling `--help`
                   # recommends. Not reachable from `disk-reaper.sh`, which hands the seams down as env
                   # and never passes `--glob`; the exposure is a hand-run or a future caller.
                   EXPLICIT=1
                   if [ "$GLOB_ARGS_GIVEN" = 1 ]; then GLOBS="$GLOBS $2"; else GLOBS="$2"; GLOB_ARGS_GIVEN=1; fi
                   shift 2 ;;
        --min-age) [ $# -ge 2 ] || die "--min-age needs a number"
                   num "$2" || die "--min-age must be a whole number of seconds (got '$2')"
                   MIN_AGE="$2"; shift 2 ;;
        --print-config) PRINT_CONFIG=1; shift ;;
        --help|-h) usage ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

# ⛔ A SET-BUT-EMPTY GLOB LIST IS A REFUSAL, and it is the seam most likely to be emptied by a
# template: `${REAP_RW_GLOBS:-default}` would SILENTLY substitute the defaults for an empty value, so an
# operator (or a rendered unit) that emptied the seam to "turn the class off" would instead get the
# widest possible sweep. `disk-reaper.sh` applies the same rule to DISK_REAPER_RUNNER_GLOBS.
case "$GLOBS" in *[![:space:]]*) : ;; *)
    printf '%s: ⛔ FAIL-CLOSED — the glob list is EMPTY; an empty list would scan nothing for ever while the class reported a measured zero\n' "$SCRIPT_NAME" >&2
    printf '%s: set REAP_RW_GLOBS (or pass --glob), or leave it UNSET to take the defaults\n' "$SCRIPT_NAME" >&2
    exit 3 ;;
esac
num "$MIN_AGE"            || die "REAP_RW_MIN_AGE must be a whole number of seconds (got '$MIN_AGE')"
num "$BUDGET"             || die "REAP_RW_BUDGET_SECONDS must be a whole number"
num "$LOCK_STALE_SECONDS" || die "REAP_RW_LOCK_STALE_SECONDS must be a whole number"
num "$DU_TIMEOUT"         || die "REAP_RW_DU_TIMEOUT must be a whole number"
num "$FIND_TIMEOUT"       || die "REAP_RW_FIND_TIMEOUT must be a whole number"
case "$DRY_RUN" in 0|1) ;; *) die "REAP_RW_DRY_RUN must be 0 or 1 (got '$DRY_RUN')" ;; esac

if [ "$PRINT_CONFIG" = 1 ]; then
    printf 'globs=%s\n' "$GLOBS"
    printf 'min_age=%s\n' "$MIN_AGE"
    printf 'retained=%s\n' "$(printf '%s' "$RETAINED_NAMES" | tr '\n' ',' | sed 's/,$//')"
    printf 'mode=%s\n' "$([ "$DRY_RUN" = 1 ] && printf dry-run || printf apply)"
    exit 0
fi

# ── the bounded-execution library (#2046), resolved the way the entry point resolves it ──────────
# ⛔ ONE IMPLEMENTATION, SHARED. `timeout` is GNU coreutils and macOS ships it nowhere; the library
# resolves `timeout` -> `gtimeout` -> an internal background watchdog with 124 == timeout. A second
# resolver here is how the two drift, so this file has none: a missing library is a REFUSAL, never a
# sweep that quietly ran unbounded.
BOUNDED_LIB="${BOUNDED_LIB:-}"
if [ -z "$BOUNDED_LIB" ]; then
    for cand in "$SELF_DIR/lib/bounded.sh" "${HOME:-}/.pi/agent/scripts/lib/bounded.sh"; do
        [ -n "$cand" ] || continue
        [ -f "$cand" ] && { BOUNDED_LIB="$cand"; break; }
    done
fi
if [ ! -f "$BOUNDED_LIB" ]; then
    printf '%s: ⛔ FAIL-CLOSED — the bounded-execution library is missing (%s)\n' \
        "$SCRIPT_NAME" "${BOUNDED_LIB:-not beside this script ($SELF_DIR/lib/) and not in ${HOME:-}/.pi/agent/scripts/lib/}" >&2
    printf '%s: refusing to start rather than run unbounded filesystem sweeps (#2046)\n' "$SCRIPT_NAME" >&2
    printf 'SKIP reason=library-missing\n'
    printf 'SUMMARY class=runner-work mode=%s globs=0 roots=0 candidates=0 reaped=0 kept=0 retained=0 failed=0 census=library-missing\n' \
        "$([ "$DRY_RUN" = 1 ] && printf dry-run || printf apply)"
    exit 3
fi
# shellcheck source=lib/bounded.sh
. "$BOUNDED_LIB"
if [ "${TB_TIMEOUT_KIND:-}" = "invalid" ]; then
    printf '%s: ⛔ FAIL-CLOSED — TB_TIMEOUT_BIN=%s cannot be executed\n' "$SCRIPT_NAME" "${TB_TIMEOUT_BIN:-}" >&2
    printf 'SUMMARY class=runner-work mode=%s globs=0 roots=0 candidates=0 reaped=0 kept=0 retained=0 failed=0 census=watchdog-invalid\n' \
        "$([ "$DRY_RUN" = 1 ] && printf dry-run || printf apply)"
    exit 3
fi
tb_bound_tmp || printf '%s: warn: no writable TMPDIR — bounded probes will run without a scratch dir\n' "$SCRIPT_NAME" >&2

file_mtime() {
    local m
    m="$(tb_timeout 60 stat -c '%Y' "$1" 2>/dev/null)"
    case "$m" in ''|*[!0-9]*) ;; *) printf '%s' "$m"; return 0 ;; esac
    m="$(tb_timeout 60 stat -f '%m' "$1" 2>/dev/null)"
    case "$m" in ''|*[!0-9]*) return 1 ;; *) printf '%s' "$m" ;; esac
}

du_mb() { # <path> — MiB by du, or `?` when it cannot be measured (never 0)
    local kb
    kb="$(tb_timeout "$DU_TIMEOUT" du -sk "$1" 2>/dev/null)" || { printf '?'; return 0; }
    kb="${kb%%[[:space:]]*}"
    case "$kb" in ''|*[!0-9]*) printf '?' ;; *) printf '%s' "$(( kb / 1024 ))" ;; esac
}

# ── lock (the same model as every owner in this family) ─────────────────────────────────────────
LOCK_HELD=0
acquire_lock() {
    local owner started _lmt _lage
    mkdir -p "$STATE_DIR" 2>/dev/null
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf 'pid=%s started=%s\n' "$$" "$(now)" >"$LOCK_DIR/token" 2>/dev/null || true
        LOCK_HELD=1; return 0
    fi
    # ⛔ PARSE THE FIELDS, NEVER `s/^pid=//` — that captures the whole tail (`"1234 started=5678"`),
    # `num` rejects it, the live-owner check never runs, and every existing lock is then declared stale
    # and removed while its owner is LIVE (the defect `reap-duplicate-installs.sh` records verbatim).
    owner="$(sed -n 's/^.*pid=\([0-9][0-9]*\).*/\1/p' "$LOCK_DIR/token" 2>/dev/null | head -1)"
    started="$(sed -n 's/.*started=\([0-9][0-9]*\).*/\1/p' "$LOCK_DIR/token" 2>/dev/null | head -1)"
    if num "$owner" && kill -0 "$owner" 2>/dev/null; then
        log_line "SKIP reason=lock-held pid=$owner"
        return 3
    fi
    # An UNATTRIBUTABLE lock is honoured while it is young (a live owner whose token write failed is the
    # routine full-disk shape), and reclaimed once it passes the stale bound.
    if ! num "$owner"; then
        if [ -f "$LOCK_DIR/token" ]; then _lmt="$(file_mtime "$LOCK_DIR/token")"; else _lmt="$(file_mtime "$LOCK_DIR")"; fi
        if num "$_lmt"; then
            _lage=$(( $(now) - _lmt ))
            if [ "$_lage" -ge 0 ] && [ "$_lage" -le "$LOCK_STALE_SECONDS" ]; then
                log_line "SKIP reason=lock-tokenless age=${_lage}s"
                return 3
            fi
        fi
    fi
    log_line "note: reclaiming a STALE lock ($LOCK_DIR, pid ${owner:-?} started ${started:-?} is gone)"
    rm -rf "$LOCK_DIR" 2>/dev/null
    mkdir "$LOCK_DIR" 2>/dev/null || { log_line "SKIP reason=lock-uncreatable path=$LOCK_DIR"; return 3; }
    printf 'pid=%s started=%s\n' "$$" "$(now)" >"$LOCK_DIR/token" 2>/dev/null || true
    LOCK_HELD=1; return 0
}
release_lock() { [ "${LOCK_HELD:-0}" = 1 ] && { rm -rf "$LOCK_DIR" 2>/dev/null; LOCK_HELD=0; }; return 0; }

# ── the mtime floor: one reference FILE, portable across GNU and BSD ────────────────────────────
# `find -newermt` is GNU-only and `date -d` is GNU-only; `find -newer <file>` and `touch -t` exist on
# both, so the floor is a file whose mtime is `now - MIN_AGE`: everything newer than it was written
# since the floor. `date -r` is the BSD spelling and `date -d @` the GNU one — the same pair the class
# fixtures use, so a host that can age a fixture can age this file.
make_floor_ref() { # <path> — 0 written, 1 cannot be written (a REFUSAL, never a silent 0 floor)
    local p="$1" when stamp
    when=$(( $(now) - MIN_AGE ))
    stamp="$(date -r "$when" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$when" +%Y%m%d%H%M.%S 2>/dev/null)"
    [ -n "$stamp" ] || return 1
    : >"$p" 2>/dev/null || return 1
    touch -t "$stamp" "$p" 2>/dev/null || return 1
    return 0
}

# entry_written_since <entry> <floor-ref> — is ANY content under the entry newer than the floor?
#   0 = yes (KEEP: a writer inside the floor)   1 = no (reapable)   2 = could not answer (KEEP)
# ⛔ `-type d` IS IN THE SET. A job that has just created a top-level directory of its checkout is ALIVE,
# and in that instant the directory's mtime is the only evidence that exists.
# ⛔ AN UNANSWERABLE WALK IS NEVER "DEAD". `find` exits 1 on any error (a permission denied, a vanished
# mount) and the watchdog gives 124 on a timeout; both must be KEEP. That is why the verdict is not read
# off a pipeline (whose status is `head`'s) — an empty answer is re-asked without the pipe, and only a
# clean, empty walk is proof of a dead entry.
entry_written_since() { # <entry> <floor-ref>
    local entry="$1" ref="$2" out probe="$SCRATCH/probe.$$"
    out="$(tb_timeout "$FIND_TIMEOUT" find "$entry" \( -type f -o -type d \) -newer "$ref" -print 2>/dev/null | head -1)"
    [ -n "$out" ] && return 0
    # The FIRST hit is enough, so a live entry costs one stat instead of a walk of a 4 GB tree; only an
    # EMPTY answer pays for the second walk, and it is about to be deleted anyway.
    tb_timeout "$FIND_TIMEOUT" find "$entry" \( -type f -o -type d \) -newer "$ref" -print 2>/dev/null >"$probe" || { rm -f "$probe" 2>/dev/null; return 2; }
    if [ -s "$probe" ]; then rm -f "$probe" 2>/dev/null; return 0; fi
    rm -f "$probe" 2>/dev/null
    return 1
}

# ── the sweep ───────────────────────────────────────────────────────────────────────────────────
ROOTS=0; GLOBS_N=0; CAND=0; REAPED=0; KEPT=0; RETAINED=0; FAILED=0; UNMEASURABLE=0
DEADLINE=0; MODE_TEXT=dry-run; SCRATCH=""; FLOOR_REF=""

is_retained() { # <entry name> — 0 when this name is a cross-job cache (never a candidate)
    local n="$1" rn
    while IFS= read -r rn; do
        [ -n "$rn" ] || continue
        [ "$n" = "$rn" ] && return 0
    done <<<"$RETAINED_NAMES"
    return 1
}

prune_entry() { # <entry> <root>
    local entry="$1" root="$2" verdict
    local name="${entry##*/}"
    # ── the deliberate carve-out, applied BEFORE anything is measured ────────────────────────────
    if is_retained "$name"; then
        RETAINED=$((RETAINED + 1))
        log_line "RETAINED $entry reason=cross-job-cache (the runner's downloaded actions and toolchains: reaping them forces a re-download on the NEXT job, so it buys slower CI, not disk)"
        return 0
    fi
    entry_written_since "$entry" "$FLOOR_REF"; verdict=$?
    case "$verdict" in
        0)  KEPT=$((KEPT + 1))
            log_line "KEPT   $entry reason=written-within-floor (the entry or its content was written within ${MIN_AGE}s — a running job writes continuously, so this is the proof it is alive)" ;;
        2)  UNMEASURABLE=$((UNMEASURABLE + 1))
            log_line "KEPT   $entry reason=unreadable (the bounded walk could not answer, so there is no proof the entry is dead; NOT removed)" ;;
        1)  CAND=$((CAND + 1))
            if [ "$DRY_RUN" = 1 ]; then
                # ⛔ THE SIZE IS PRINTED BY THE OWNER, NOT MEASURED AGAIN BY THE CALLER. The row is the
                # family's `REAP <reason> <N>MB <path>` shape (`reap-lane-venvs.sh` uses the same one),
                # because a `du` of a 4 GB dead tree is the expensive part of a dry pass and running it
                # twice — once here and once in `disk-reaper.sh` — doubles the only cost that matters.
                # `?` when du cannot answer: a CANDIDATE whose bytes are unknown is still a candidate, and
                # a caller that dropped the row would report `candidates=0` on a pass with real work.
                #
                # ⛔ AND THE DEADLINE CHECK DELIBERATELY SITS BELOW THIS `return`, NOT ABOVE IT. Moving it
                # up looks like a fix for "the budget is unreachable in dry-run" and is the opposite: the
                # SUMMARY would then print a `candidates=` count TRUNCATED by the budget while reading
                # exactly like a complete measurement — a partial population reported as a total. `--apply`
                # has a safe early-stop (unprocessed entries are PRESERVED, named `reason=budget`); a
                # measurement does not. The trade is documented at `REAP_RW_BUDGET_SECONDS` in the header,
                # and the per-call watchdogs (`REAP_RW_DU_TIMEOUT`/`REAP_RW_FIND_TIMEOUT`) bound each dry
                # step. A reader who wants a bounded dry pass should bound the CANDIDATE COUNT, not move
                # this check.
                log_line "REAP no-write-for-${MIN_AGE}s $(du_mb "$entry")MB $entry"
                return 0
            fi
            if [ "$(now)" -ge "$DEADLINE" ]; then
                KEPT=$((KEPT + 1))
                log_line "KEPT   $entry reason=budget (the ${BUDGET}s budget is spent; unprocessed entries are PRESERVED)"
                return 0
            fi
            # ⛔ RE-PROBE IMMEDIATELY BEFORE THE DESTRUCTIVE CALL. The classification above may be minutes
            # old (a big tree, a slow walk, a long sweep), and a job that started in that window would be
            # killed with its checkout — the one outcome this class must never produce. The re-probe asks
            # the SAME question, so it cannot disagree with the policy it re-asks.
            entry_written_since "$entry" "$FLOOR_REF"; verdict=$?
            case "$verdict" in
                0) KEPT=$((KEPT + 1))
                   log_line "KEPT   $entry reason=toctou (a writer appeared during the pass; re-probed immediately before removal)"
                   return 0 ;;
                2) UNMEASURABLE=$((UNMEASURABLE + 1))
                   log_line "KEPT   $entry reason=toctou-unreadable (the re-probe could not answer; NOT removed)"
                   return 0 ;;
            esac
            if rm -rf "$entry" 2>/dev/null && [ ! -e "$entry" ]; then
                REAPED=$((REAPED + 1))
                log_line "REAPED $entry how=rm (no content written for >= ${MIN_AGE}s)"
                log "reaped $entry root=$root"
            else
                FAILED=$((FAILED + 1))
                log_line "ERR    $entry reason=remove-failed"
                log "REMOVAL FAILED $entry"
            fi ;;
    esac
    return 0
}

sweep_root() { # <_work root>
    local root="$1" e
    ROOTS=$((ROOTS + 1))
    for e in "$root"/*/; do
        e="${e%/}"
        # ⛔ NEVER FOLLOW A SYMLINK OUT OF THE ROOT. `*/` matches a link to a directory and `-d` follows
        # it, so a link planted in `_work` would make this sweep classify — and `rm -rf` — a tree OUTSIDE
        # the population it was told to sweep (the abandoned-worktree owner records the same hazard,
        # measured). A link is not a job's checkout; it is skipped silently, because naming every link in
        # every runner on every pass is noise.
        [ -d "$e" ] && [ ! -L "$e" ] || continue
        prune_entry "$e" "$root"
    done
    return 0
}

# ── main ───────────────────────────────────────────────────────────────────────────────────────
MODE_TEXT=dry-run; [ "$DRY_RUN" = 1 ] || MODE_TEXT=apply
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/reap-rw.XXXXXX" 2>/dev/null)" || SCRATCH=""
if [ -z "$SCRATCH" ]; then
    printf '%s: ⛔ FAIL-CLOSED — no writable scratch dir; refusing to sweep with no floor reference\n' "$SCRIPT_NAME" >&2
    printf 'SKIP reason=scratch-uncreatable\n'
    printf 'SUMMARY class=runner-work mode=%s globs=0 roots=0 candidates=0 reaped=0 kept=0 retained=0 failed=0 census=scratch-uncreatable\n' "$MODE_TEXT"
    exit 3
fi
trap 'release_lock; rm -rf "$SCRATCH" 2>/dev/null; command -v tb_bound_cleanup >/dev/null 2>&1 && tb_bound_cleanup' EXIT

FLOOR_REF="$SCRATCH/floor-ref"
if ! make_floor_ref "$FLOOR_REF"; then
    printf '%s: ⛔ FAIL-CLOSED — cannot write the floor reference file (no portable `touch -t` stamp on this host)\n' "$SCRIPT_NAME" >&2
    printf 'SKIP reason=floor-unprovable\n'
    printf 'SUMMARY class=runner-work mode=%s globs=0 roots=0 candidates=0 reaped=0 kept=0 retained=0 failed=0 census=floor-unprovable\n' "$MODE_TEXT"
    exit 3
fi
if ! acquire_lock; then exit 3; fi

DEADLINE=$(( $(now) + BUDGET ))
log_line "reap-runner-work: pass start mode=$MODE_TEXT min_age=${MIN_AGE}s pid=$$ globs=$(printf '%s' "$GLOBS" | tr ' ' ',')"
log_line "reap-runner-work: retained=$(printf '%s' "$RETAINED_NAMES" | tr '\n' ',' | sed 's/,$//') — cross-job caches, never candidates whatever their age"
log "==== pass start mode=$MODE_TEXT min_age=${MIN_AGE}s explicit=$EXPLICIT ===="

# ⛔ THE GLOBS ARE EXPANDED UNQUOTED ON PURPOSE — that expansion IS the discovery mechanism. A pattern
# that matches nothing expands to ITSELF in bash, which is why every candidate is `-d`-tested rather
# than trusted. A leading `~/` is expanded here because a seam written in a unit file is not expanded by
# the shell that reads it. (A path containing a space cannot be expressed in this list — these layouts
# have none — and `--glob` is repeatable for the rest.)
for _g in $GLOBS; do
    case "$_g" in "~/"*) _g="${HOME:-}/$(printf '%s' "$_g" | sed 's|^~/||')" ;; esac
    GLOBS_N=$((GLOBS_N + 1))
    _matched=0
    for _r in $_g; do
        [ -d "$_r" ] && [ ! -L "$_r" ] || continue
        _matched=1
        log_line "reap-runner-work: root $_r (glob $_g)"
        sweep_root "$_r"
    done
    [ "$_matched" = 1 ] || log_line "reap-runner-work: note: glob $_g matched no runner _work root on this box"
done

# ⛔ THE CENSUS IS DECIDED BEFORE THE SUMMARY IS PRINTED, so the line the entry point lifts and the
# exit status can never disagree about whether this pass measured anything.
CENSUS=ok
if [ "$ROOTS" = 0 ] && [ "$EXPLICIT" = 1 ]; then CENSUS=no-roots; fi

log_line "SUMMARY class=runner-work mode=$MODE_TEXT globs=$GLOBS_N roots=$ROOTS candidates=$CAND reaped=$REAPED kept=$KEPT retained=$RETAINED failed=$FAILED unmeasurable=$UNMEASURABLE min_age=${MIN_AGE}s explicit=$EXPLICIT census=$CENSUS"
log "SUMMARY mode=$MODE_TEXT globs=$GLOBS_N roots=$ROOTS candidates=$CAND reaped=$REAPED kept=$KEPT retained=$RETAINED failed=$FAILED census=$CENSUS"

if [ "$CENSUS" = no-roots ]; then
    # ⛔ AN EXPLICIT LAYOUT THAT MATCHES NOTHING IS A REFUSAL, NOT A ZERO. When the operator (or the
    # rendered unit) SET the glob list, they asserted where this box's runners live; a sweep over a
    # population that is not there must not report `candidates=0` as if it had measured the sink. It is
    # the same rule `disk-reaper.sh` applies to a delegate override it cannot find: an explicit
    # assertion is authoritative, INCLUDING WHEN IT IS WRONG — and being wrong is loud.
    # With the DEFAULT globs the opposite is true: a box with no runners in the documented layouts has
    # an EMPTY POPULATION, which IS a measurement (`roots=0`), not a misconfiguration. Painting that red
    # every hour is the alarm-fatigue shape this family forbids — an alarm nobody reads.
    log_line "SKIP reason=no-roots-matched (the glob list was set EXPLICITLY and matched no directory: '$GLOBS')"
    exit 3
fi

[ "$FAILED" -gt 0 ] && exit 4
exit 0
