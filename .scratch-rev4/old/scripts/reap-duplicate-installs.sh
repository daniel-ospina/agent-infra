#!/usr/bin/env bash
# reap-duplicate-installs.sh — reclaim SURPLUS copies of the same tool install (#2542).
#
# THE MEASURED DEFECT. cell-1 sat at 3.1 GB free with **11.3 GB of `/tmp/actions-runner`** holding
# EIGHT identical runner installs (`ps … | grep -c '[R]unner.Listener'` -> 8) on a box with 8 cores.
# The disk reaper has no class for it: duplicates of the same install are not caches (`uv`), not lane
# envs (`venv`), not checkouts (`worktree`) — so a third of the cell's disk was in none of its
# classes and the guard fired on a 95%-full box and freed 4 MB.
#
# THE RULE, AND IT IS DELIBERATELY THE CONSERVATIVE DIRECTION:
#   * only a copy that is PROVABLY IDLE is removed — no live process's cwd, exe or argv resolves
#     inside it (one census: `scripts/lib/live-paths.sh`), and no service/unit file names it;
#   * the NEWEST copy is always kept — never a candidate, whatever its state;
#   * the LAST copy is never removed: with the newest kept by construction, a family can never be
#     emptied, and that is asserted again before the delete;
#   * a copy whose idleness cannot be proven is KEPT and NAMED;
#   * if the number of copies cannot be established, NOTHING in that family is touched;
#   * if the process list cannot be read at all, the pass FAILS CLOSED and reaps nothing.
#
# ⛔ WHY SO CAREFUL. A runner killed mid-job is a LOST JOB, which is worse than a full disk (#2542:
# `pi-runner-cell3-x64-2` died mid-`packaging-smoke` with ENOSPC and the run went unserved). Deleting
# the install a listener is running from does not just kill the job — the runner never reconnects and
# the pool silently shrinks. So the asymmetry is explicit: a kept duplicate costs disk, a reaped live
# duplicate costs work. Every uncertain case takes the keep arm.
#
# WHAT "DUPLICATE" MEANS, EXACTLY. A family is a directory whose CHILDREN each carry the same
# install MARKER file — by default `bin/Runner.Listener`, which only a GitHub Actions runner install
# has. Markers are a table, not a guess: adding a kind is one entry, and it must be a path that no
# other kind of directory carries. Nothing is inferred from a directory NAME (a copy is not a copy
# because it is called `runner-2`).
#
# Usage:
#   reap-duplicate-installs.sh [--dry-run|--apply] [--root DIR]... [--aged-minutes N]
#                              [--print-config] [--list] [--help]
#
#   (no mode flag) dry-run   report what WOULD be removed; remove NOTHING
#   --apply                  armed pass
#   --root DIR               root to scan at depth 2 (repeatable; default /tmp)
#   --aged-minutes N         a copy younger than this is KEPT (default 180) — a fresh install may be
#                            mid-configuration even with no listener yet
#   --print-config           `roots=…` / `markers=…` for the caller
#   --list                   same as dry-run
#
# Env seams:
#   REAP_DI_ROOTS            colon-separated roots (same as --root)
#   REAP_DI_MARKERS          colon-separated marker paths, relative to a copy (default bin/Runner.Listener)
#   REAP_DI_AGED_MINUTES     the age dial (default 180)
#   REAP_DI_DRY_RUN          0 supplies the default mode only (an explicit flag always wins)
#   REAP_DI_STATE_DIR        lock + log dir (default $HOME/.pi/agent/state)
#   REAP_DI_LOG              pass log (default $REAP_DI_STATE_DIR/reap-duplicate-installs.log)
#   REAP_DI_LOCK_STALE_SECONDS   stale lock reclaim bound (default 1800)
#   REAP_DI_UNIT_DIRS        dirs whose unit/plist files are searched for a copy's path (a copy a
#                            service is configured to start is NOT idle, whatever the process table says)
#   REAP_DI_BUDGET_SECONDS   wall-clock budget for the family loop (default 300)
#   REAP_DI_PROC_ROOT        the process table root (default /proc; a test seam)
#   REAP_DI_LIVE_PATHS       the census library (a SET-but-missing value is a refusal)
#
# Exit codes (the family's vocabulary, so `disk-reaper.sh` maps it unchanged):
#   0  ran; every action succeeded (including "no family found")
#   2  usage
#   3  FAIL-CLOSED — census unreadable, library missing, or the lock is held. Nothing reaped.
#   4  a removal failed (named; the copy is still there)
#
set -uo pipefail

SCRIPT_NAME="reap-duplicate-installs.sh"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
STATE_DIR="${REAP_DI_STATE_DIR:-${HOME:-}/.pi/agent/state}"
LOG="${REAP_DI_LOG:-$STATE_DIR/reap-duplicate-installs.log}"
LOCK_DIR="$STATE_DIR/reap-duplicate-installs.lock"
LOCK_STALE_SECONDS="${REAP_DI_LOCK_STALE_SECONDS:-1800}"
AGED_MINUTES="${REAP_DI_AGED_MINUTES:-180}"
ROOTS="${REAP_DI_ROOTS:-/tmp}"
MARKERS="${REAP_DI_MARKERS:-bin/Runner.Listener}"
UNIT_DIRS="${REAP_DI_UNIT_DIRS:-/etc/systemd/system:${HOME:-}/.config/systemd/user:$([ "$(uname -s 2>/dev/null)" = Darwin ] && printf '/Library/LaunchDaemons:%s/Library/LaunchAgents' "${HOME:-}")}"
DRY_RUN="${REAP_DI_DRY_RUN:-1}"
BUDGET="${REAP_DI_BUDGET_SECONDS:-300}"
LIST_ONLY=0
PRINT_CONFIG=0
ROOTS_GIVEN=0

log_line() { printf '%s\n' "$*"; }
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true; }
die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 2; }
num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
now() { date +%s; }

usage() {
    awk 'NR==1{next} /^set -uo pipefail$/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}" 2>/dev/null \
        || printf 'usage: %s [--dry-run|--apply] [--root DIR]... [--aged-minutes N]\n' "$SCRIPT_NAME"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --apply)   DRY_RUN=0; shift ;;
        --root)    [ $# -ge 2 ] || die "--root needs a path"
                   case "$2" in /*) ;; *) die "--root needs an ABSOLUTE path (got '$2')" ;; esac
                   if [ "$ROOTS_GIVEN" = 1 ]; then ROOTS="$ROOTS:$2"; else ROOTS="$2"; ROOTS_GIVEN=1; fi
                   shift 2 ;;
        --aged-minutes) [ $# -ge 2 ] || die "--aged-minutes needs a number"
                        num "$2" || die "--aged-minutes must be a number (got '$2')"
                        AGED_MINUTES="$2"; shift 2 ;;
        --print-config) PRINT_CONFIG=1; shift ;;
        --list)    LIST_ONLY=1; DRY_RUN=1; shift ;;
        --help|-h) usage ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done
num "$AGED_MINUTES" || die "REAP_DI_AGED_MINUTES must be a number (got '$AGED_MINUTES')"
num "$BUDGET" || die "REAP_DI_BUDGET_SECONDS must be a number"
num "$LOCK_STALE_SECONDS" || die "REAP_DI_LOCK_STALE_SECONDS must be a number"
[ -n "$MARKERS" ] || die "REAP_DI_MARKERS is empty — a family needs a marker to be provable"

if [ "$PRINT_CONFIG" = 1 ]; then
    printf 'roots=%s\n' "$ROOTS"
    printf 'markers=%s\n' "$MARKERS"
    printf 'aged_minutes=%s\n' "$AGED_MINUTES"
    printf 'mode=%s\n' "$([ "$DRY_RUN" = 1 ] && printf dry-run || printf apply)"
    exit 0
fi

# ── the census library (same contract as the abandoned-worktree owner) ──────────────────────────
LIVE_PATHS_LIB=""
if [ -n "${REAP_DI_LIVE_PATHS:-}" ]; then
    [ -f "${REAP_DI_LIVE_PATHS}" ] || {
        printf '%s: ⛔ FAIL-CLOSED — REAP_DI_LIVE_PATHS=%s does not exist\n' "$SCRIPT_NAME" "$REAP_DI_LIVE_PATHS" >&2
        printf 'SKIP reason=library-missing path=%s\n' "$REAP_DI_LIVE_PATHS"
        exit 3
    }
    LIVE_PATHS_LIB="${REAP_DI_LIVE_PATHS}"
else
    for cand in "$SELF_DIR/lib/live-paths.sh" "${HOME:-}/.pi/agent/scripts/lib/live-paths.sh"; do
        [ -n "$cand" ] && [ -f "$cand" ] && { LIVE_PATHS_LIB="$cand"; break; }
    done
fi
if [ -z "$LIVE_PATHS_LIB" ]; then
    printf '%s: ⛔ FAIL-CLOSED — lib/live-paths.sh not found (looked beside this script and in $HOME/.pi/agent/scripts/lib)\n' "$SCRIPT_NAME" >&2
    printf 'SKIP reason=library-missing\n'
    exit 3
fi
# shellcheck source=lib/live-paths.sh
. "$LIVE_PATHS_LIB" || { printf 'SKIP reason=library-unreadable path=%s\n' "$LIVE_PATHS_LIB"; exit 3; }

file_mtime() {
    local m
    m="$(stat -c '%Y' "$1" 2>/dev/null)"
    case "$m" in ''|*[!0-9]*) ;; *) printf '%s' "$m"; return 0 ;; esac
    stat -f '%m' "$1" 2>/dev/null
}

# ── lock (same model as every other owner in this family) ──────────────────────────────────────
LOCK_HELD=0
acquire_lock() {
    local owner started _lmt _lage
    mkdir -p "$STATE_DIR" 2>/dev/null
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf 'pid=%s started=%s\n' "$$" "$(now)" >"$LOCK_DIR/token" 2>/dev/null || true
        LOCK_HELD=1; return 0
    fi
    # ⛔ THE TOKEN IS ONE LINE: `pid=<n> started=<epoch>`. Parsing `s/^pid=//` captures the whole
    # tail (`"1234 started=5678"`), which `num` rejects — so the live-owner check never ran, the
    # tokenless arm (anchored `^started=`) never matched either, and EVERY existing lock was declared
    # stale and DELETED WHILE ITS OWNER WAS LIVE. That removed the only exclusion between two
    # concurrent sweeps of one root: both classify the same directory, both remove it, and the loser
    # reports a removal failure for something already gone. Capture the FIELDS, not the tail.
    owner="$(sed -n 's/^.*pid=\([0-9][0-9]*\).*/\1/p' "$LOCK_DIR/token" 2>/dev/null | head -1)"
    started="$(sed -n 's/.*started=\([0-9][0-9]*\).*/\1/p' "$LOCK_DIR/token" 2>/dev/null | head -1)"
    if num "$owner" && kill -0 "$owner" 2>/dev/null; then log_line "SKIP reason=lock-held pid=$owner"; return 3; fi
    # See the abandoned-worktree owner: only an UNATTRIBUTABLE lock is tokenless, and only while young.
    if ! num "$owner"; then
        if [ -f "$LOCK_DIR/token" ]; then _lmt="$(file_mtime "$LOCK_DIR/token")"; else _lmt="$(file_mtime "$LOCK_DIR")"; fi
        if num "$_lmt"; then
            _lage=$(( $(now) - _lmt ))
            if [ "$_lage" -ge 0 ] && [ "$_lage" -le "$LOCK_STALE_SECONDS" ]; then log_line "SKIP reason=lock-tokenless age=${_lage}s"; return 3; fi
        fi
    fi
    log_line "note: reclaiming a STALE lock ($LOCK_DIR, pid ${owner:-?} is gone)"
    rm -rf "$LOCK_DIR" 2>/dev/null
    mkdir "$LOCK_DIR" 2>/dev/null || { log_line "SKIP reason=lock-uncreatable path=$LOCK_DIR"; return 3; }
    printf 'pid=%s started=%s\n' "$$" "$(now)" >"$LOCK_DIR/token" 2>/dev/null || true
    LOCK_HELD=1; return 0
}
release_lock() { [ "$LOCK_HELD" = 1 ] && { rm -rf "$LOCK_DIR" 2>/dev/null; LOCK_HELD=0; }; return 0; }

# ── is a copy named by a service/unit file? ────────────────────────────────────────────────────
# A configured-but-currently-stopped runner is NOT idle in the operator's intent: the service will
# start it again, and a unit whose ExecStart points at a directory we removed is a broken service on
# the next tick. Cheap and bounded: one fixed-string scan per unit dir, no recursion.
unit_reference() { # <copy-path> -> prints the unit file that names it, rc 0
    local copy="$1" d f
    [ -n "$UNIT_DIRS" ] || return 1
    while IFS= read -r d; do
        [ -n "$d" ] && [ -d "$d" ] || continue
        for f in "$d"/*; do
            [ -f "$f" ] || continue
            if grep -qF -- "$copy" "$f" 2>/dev/null; then printf '%s' "$f"; return 0; fi
        done
    done <<<"$(printf '%s\n' "$UNIT_DIRS" | tr ':' '\n')"
    return 1
}

# ── one family ────────────────────────────────────────────────────────────────────────────────
FAMILIES=0; CAND=0; REAPED=0; KEPT=0; FAILED=0; TOCTOU_WHY=""

# ── the pre-removal RE-PROBE (§ "one family" calls it immediately before `rm -rf`) ────────────
# ⛔ WHY THIS EXISTS AT ALL (#2676 review, cycle 1, P1): every liveness test in `family()` reads the
# census taken ONCE at pass start, and a pass may run for the whole BUDGET. A listener started in that
# interval is not in the snapshot, so the copy it runs from looked idle and was `rm -rf`'d under it.
# The sibling owner (`reap-abandoned-worktrees.sh::toctou_preserve`) re-probes for exactly this window;
# this owner now does the same, and for the same reason. An UNREADABLE fresh census is a PRESERVE.
toctou_preserve() { # <canon> <copy-path> -> 0 = still removable, 1 = PRESERVE (TOCTOU_WHY names it)
    local canon="$1" c="$2" fresh out
    TOCTOU_WHY=""
    fresh="$(mktemp -d "${TMPDIR:-/tmp}/reap-di-reprobe.XXXXXX" 2>/dev/null)" || { TOCTOU_WHY="re-probe-unavailable"; return 1; }
    if ! lp_census "$fresh" >/dev/null 2>&1; then
        rm -rf "$fresh" 2>/dev/null
        TOCTOU_WHY="re-probe-census-unreadable"
        return 1
    fi
    # ⛔ THE FILE, NOT THE DIRECTORY: `lp_census DIR` writes `DIR/live-paths.tsv`, and the witnesses
    # `read` the path they are handed. Handed the DIRECTORY they find no witness and return "clean",
    # which would make this whole re-probe dead code — the defect the sibling owner recorded.
    if lp_path_held "$fresh/live-paths.tsv" "$canon"; then TOCTOU_WHY="entered-during-pass ($LP_HOLD_WHY)"; rm -rf "$fresh"; return 1; fi
    if lp_path_named "$fresh/live-paths.tsv" "$canon"; then TOCTOU_WHY="argv-named-during-pass ($LP_NAME_WHY)"; rm -rf "$fresh"; return 1; fi
    # A unit file EDITED mid-pass to point at this copy is the same hazard one step later.
    if out="$(unit_reference "$c")"; then TOCTOU_WHY="unit-referenced-now ($out)"; rm -rf "$fresh"; return 1; fi
    rm -rf "$fresh" 2>/dev/null
    return 0
}

family() { # <parent-dir> <marker-rel>
    local parent="$1" marker="$2" c copies="" n newest="" newest_mt=-1 mt age out cp_count=0 left other canon newest_tie=0
    for c in "$parent"/*/; do
        c="${c%/}"
        [ -d "$c" ] && [ ! -L "$c" ] || continue
        [ -f "$c/$marker" ] || continue
        copies="$copies$c"$'\n'
    done
    n="$(printf '%s' "$copies" | sed '/^$/d' | wc -l | tr -d ' ')"
    num "$n" || n=0
    # A single copy is not a duplicate: nothing to do, and nothing worth a line. The vast majority of
    # directories under a scratch root are not families at all, so this arm must stay silent.
    [ "$n" -ge 2 ] || return 0
    FAMILIES=$((FAMILIES + 1))
    # ⛔ THE NEWEST SURVIVOR IS DECIDED FIRST, BEFORE ANY OTHER JUDGEMENT, and it is never a
    # candidate. If ANY copy's install time cannot be read we cannot prove which one is newest —
    # so the whole family is left alone rather than guessing (`reason=newest-unprovable`).
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        mt="$(file_mtime "$c/$marker")"
        if ! num "$mt"; then
            log_line "KEPT   $c reason=newest-unprovable (cannot read $marker's mtime, so which copy is newest — and therefore which one must survive — is not provable; family untouched)"
            KEPT=$((KEPT + 1))
            return 0
        fi
        cp_count=$((cp_count + 1))
        # ⛔ A TIE IS NOT A WINNER. Copies unpacked from the same release archive carry IDENTICAL marker
        # mtimes — the normal install shape — and `-gt` then picked the survivor by glob order, so the
        # copy an operator CONFIGURED (its `.runner`, its `_work`) could be the one removed while a
        # pristine copy survived (measured: `keep-newest=…/runner-1`, `REAPED …/runner-3`). The family
        # already has a keep-all arm for "which copy is newest is not provable"; a tie is that case.
        if [ "$mt" -eq "$newest_mt" ]; then newest_tie=1; fi
        if [ "$mt" -gt "$newest_mt" ]; then newest_mt="$mt"; newest="$c"; newest_tie=0; fi
    done <<<"$copies"
    if [ "$newest_tie" = 1 ]; then
        log_line "KEPT   $parent reason=newest-tied (two or more copies carry the SAME install-marker mtime, so which one must survive is not provable — the family is untouched; this is the shape of a release unpacked several times)"
        KEPT=$((KEPT + 1)); return 0
    fi
    if [ "$cp_count" -lt 2 ] || [ -z "$newest" ]; then
        log_line "KEPT   $parent reason=count-unprovable (copies=$cp_count, newest=${newest:-none}; family untouched)"
        KEPT=$((KEPT + 1)); return 0
    fi
    age=$(( ( $(now) - newest_mt ) / 60 ))
    log_line "note: family $parent marker=$marker copies=$cp_count keep-newest=$newest ($([ "$age" -ge 0 ] && printf '%s' "$age" || printf 0)m old)"

    while IFS= read -r c; do
        [ -n "$c" ] || continue
        [ "$c" = "$newest" ] && { KEPT=$((KEPT + 1)); log_line "KEPT   $c reason=newest (the newest surviving copy is never removed)"; continue; }
        # ⛔ AN UNRESOLVABLE PATH IS NOT AN IDLE ONE. `lp_path_held` treats an empty path as "not held",
        # so a copy whose physical path cannot be computed (a dangling link, a directory we cannot
        # enter) used to sail through both liveness guards and be removed. Keep it and say why.
        canon="$(lp_canon "$c")" || canon=""
        if [ -z "$canon" ]; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $c reason=unresolvable (its physical path cannot be computed, so no liveness proof is possible)"; continue
        fi
        if lp_path_held "$CENSUS" "$canon"; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $c reason=live-listener ($LP_HOLD_WHY — a runner killed mid-job is a lost job)"; continue
        fi
        if lp_path_named "$CENSUS" "$canon"; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $c reason=argv-named ($LP_NAME_WHY — a live process was started from this copy)"; continue
        fi
        if out="$(unit_reference "$c")"; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $c reason=unit-referenced ($out starts this copy)"; continue
        fi
        mt="$(file_mtime "$c/$marker")"
        num "$mt" && age=$(( ( $(now) - mt ) / 60 ))
        if num "$mt" && [ "$age" -lt "$AGED_MINUTES" ]; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $c reason=young (age=${age}m < ${AGED_MINUTES}m — a fresh install may be mid-configuration)"; continue
        fi
        CAND=$((CAND + 1))
        if [ "$DRY_RUN" = 1 ]; then
            # Path alone on its line; the reason beneath it — the family's own convention
            # (`pi-reap-worktrees.sh`: `preserve <path>` then `reason=…`).
            log_line "remove $c"
            log_line "         duplicate of $marker; the newest copy kept is $newest"
            continue
        fi
        if [ "$(now)" -ge "$DEADLINE" ]; then
            log_line "KEPT   $c reason=budget (the ${BUDGET}s budget is spent; unprocessed copies are PRESERVED)"
            KEPT=$((KEPT + 1)); continue
        fi
        # ⛔ NEVER THE LAST COPY. The newest is already excluded above, so this can only fire if the
        # survivor vanished between classification and removal — in which case removing THIS one
        # would empty the family. Refuse, loudly. NOTE: with the newest exclusion and the
        # `cp_count >= 2` requirement this arm is a DEFENCE IN DEPTH and is unreachable by
        # construction, so no test claims to cover it; the property it guards is asserted instead
        # (the newest survives, and an unprovable survivor count leaves the family untouched).
        left=0
        for other in "$parent"/*/; do
            other="${other%/}"
            [ -d "$other" ] && [ "$other" != "$c" ] && [ -f "$other/$marker" ] && left=$((left + 1))
        done
        if [ "$left" -lt 1 ]; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $c reason=last-copy (no other copy of $marker survives — refusing to empty the family)"; continue
        fi
        # ⛔ RE-PROBE IMMEDIATELY BEFORE THE DESTRUCTIVE CALL (#2676 review, cycle 1, P1). The liveness
        # tests above read a census taken ONCE at pass start, and a pass may run for the whole BUDGET,
        # so that snapshot can be minutes stale: a listener started mid-pass (`./run.sh` by hand, a
        # tmux-launched listener — the common shape here, since `unit_reference` only sees
        # unit-configured runners) would be `rm -rf`'d underneath. The sibling owner in this same PR
        # (`reap-abandoned-worktrees.sh::toctou_preserve`) exists for exactly this window and re-probes;
        # this owner did not, which made "only a copy that is PROVABLY IDLE is removed" true only at
        # pass start. An unreadable fresh census is a PRESERVE, never a pass — the same polarity as
        # every other unreadable read in this file.
        if ! toctou_preserve "$canon" "$c"; then
            KEPT=$((KEPT + 1)); log_line "KEPT   $c reason=toctou ($TOCTOU_WHY — the pass-start snapshot was stale; re-probed immediately before removal)"; continue
        fi
        if rm -rf "$c" 2>/dev/null && [ ! -d "$c" ]; then
            REAPED=$((REAPED + 1)); log_line "REAPED $c how=rm (duplicate $marker copy; newest kept is $newest)"
            log "reaped $c marker=$marker newest=$newest"
        else
            FAILED=$((FAILED + 1)); log_line "ERR    $c reason=remove-failed"; log "REMOVAL FAILED $c"
        fi
    done <<<"$copies"
    return 0
}

if ! acquire_lock; then exit 3; fi

CENSUSDIR="$(mktemp -d "${TMPDIR:-/tmp}/reap-di-census.XXXXXX" 2>/dev/null)" || CENSUSDIR=""
if [ -z "$CENSUSDIR" ]; then log_line "SKIP reason=census-dir-uncreatable"; release_lock; exit 3; fi
trap 'release_lock; rm -rf "$CENSUSDIR" 2>/dev/null' EXIT
CENSUS="$CENSUSDIR/live-paths.tsv"

MODE_TEXT=dry-run; [ "$DRY_RUN" = 1 ] || MODE_TEXT=apply
DEADLINE=$(( $(now) + BUDGET ))
log_line "reap-duplicate-installs: pass start mode=$MODE_TEXT roots=$(printf '%s' "$ROOTS" | tr ':' ',') markers=$(printf '%s' "$MARKERS" | tr ':' ',') aged=${AGED_MINUTES}m pid=$$"
# An EXPLICIT seam that does not name a readable process table forces the fail-closed arm: the seam
# says WHICH table to read, so falling through to `lsof` would silently read a different one and
# report green — the exact "the documented way to test the refusal cannot reach it" defect.
# "Readable" means it LOOKS like a process table (`self/cwd`, or a numbered pid with a `cwd`): an
# EMPTY directory — the natural spelling of a test seam (`mktemp -d`) — passed an existence check and
# fell through to `lsof`, reading a different table and reporting green.
if [ -n "${REAP_DI_PROC_ROOT:-}" ] && [ ! -e "${REAP_DI_PROC_ROOT}/self/cwd" ] && ! ls "${REAP_DI_PROC_ROOT}"/[0-9]*/cwd >/dev/null 2>&1; then
    log_line "note: REAP_DI_PROC_ROOT=$REAP_DI_PROC_ROOT is not a process table — forcing the fail-closed arm rather than reading a different one"
    LP_CENSUS_UNAVAILABLE=1
fi
export LP_PROC_ROOT="${LP_PROC_ROOT:-${REAP_DI_PROC_ROOT:-/proc}}"
if ! lp_census "$CENSUSDIR"; then
    log_line "SKIP reason=census-unreadable mechanism=${LP_CENSUS_MECH:-none} — the process list could not be read, so NO copy can be proven idle; nothing was reaped (fail closed)"
    log_line "SUMMARY class=duplicate-install mode=$MODE_TEXT families=0 candidates=0 reaped=0 kept=0 failed=0 census=unreadable"
    log "SKIP census-unreadable mechanism=${LP_CENSUS_MECH:-none}"
    exit 3
fi
log_line "reap-duplicate-installs: $(lp_description)"

while IFS= read -r root; do
    [ -n "$root" ] || continue
    [ -d "$root" ] || { log_line "note: root $root does not exist — nothing to scan there"; continue; }
    for parent in "$root"/*/; do
        parent="${parent%/}"
        [ -d "$parent" ] && [ ! -L "$parent" ] || continue
        while IFS= read -r marker; do
            [ -n "$marker" ] || continue
            # A family only exists when ≥2 children carry the marker; `family()` re-proves that.
            family "$parent" "$marker"
        done <<<"$(printf '%s\n' "$MARKERS" | tr ':' '\n')"
    done
done <<<"$(printf '%s\n' "$ROOTS" | tr ':' '\n')"

log_line "SUMMARY class=duplicate-install mode=$MODE_TEXT families=$FAMILIES candidates=$CAND reaped=$REAPED kept=$KEPT failed=$FAILED census=ok rows=$LP_CENSUS_ROWS pids=$LP_CENSUS_PIDS aged=${AGED_MINUTES}m"
log "SUMMARY mode=$MODE_TEXT families=$FAMILIES candidates=$CAND reaped=$REAPED kept=$KEPT failed=$FAILED"

[ "$FAILED" -gt 0 ] && exit 4
exit 0
